//
//  RazerDeviceManager.swift
//  Mos
//  Razer 设备管理: 枚举 / 热插拔 / 电量轮询
//  Created by Codex on 2026/8/18.
//  Copyright © 2026 Caldis. All rights reserved.
//

import IOKit
import IOKit.usb
import CoreFoundation
import Foundation
import AppKit

/// Razer 设备能力与当前状态 (UI 只读快照)
struct RazerDeviceState: Equatable {
    let locationID: UInt32
    let productID: UInt16
    let name: String
    let supportsBattery: Bool
    let supportsDPI: Bool
    let supportsPollRate: Bool

    var batteryPercent: Int? = nil
    var isCharging: Bool? = nil
    var dpi: Int? = nil
    var pollRate: Int? = nil

    /// 只覆盖成功读到的字段, 避免电量轮询把 DPI / 回报率冲掉.
    mutating func apply(
        batteryPercent: Int? = nil,
        isCharging: Bool? = nil,
        dpi: Int? = nil,
        pollRate: Int? = nil
    ) {
        if let batteryPercent {
            self.batteryPercent = batteryPercent
        }
        if let isCharging {
            self.isCharging = isCharging
        }
        if let dpi {
            self.dpi = dpi
        }
        if let pollRate {
            self.pollRate = pollRate
        }
    }
}

/// 热插拔如何改当前句柄集合.
/// FirstMatch / Terminated 迭代器只含本次事件, 不能当成完整设备列表.
enum RazerHotPlugReconcile {
    enum Event: Equatable {
        case fullSnapshot(Set<UInt32>)
        case appeared(Set<UInt32>)
        case disappeared(Set<UInt32>)
    }

    static func apply(current: Set<UInt32>, event: Event) -> (add: Set<UInt32>, remove: Set<UInt32>) {
        switch event {
        case .fullSnapshot(let found):
            return (add: found.subtracting(current), remove: current.subtracting(found))
        case .appeared(let found):
            return (add: found.subtracting(current), remove: [])
        case .disappeared(let gone):
            return (add: [], remove: current.intersection(gone))
        }
    }
}

/// Razer 设备管理器 (单例; IOKit 通知挂在主 DispatchQueue, 设备 I/O 在专用串行队列)
final class RazerDeviceManager {

    static let shared = RazerDeviceManager()

    /// 支持的鼠标 PID → (名称, 事务 ID 组)
    /// DeathAdder V3 Pro: 有线 0x00B6 / 无线 0x00B7 / 变体 0x00C2 / 0x00C3
    private static let supportedMice: [UInt16: (name: String, batteryTransaction: UInt8, miscTransaction: UInt8)] = [
        0x00B6: ("DeathAdder V3 Pro", 0x3F, 0x1F),
        0x00B7: ("DeathAdder V3 Pro", 0x3F, 0x1F),
        0x00C2: ("DeathAdder V3 Pro", 0x3F, 0x1F),
        0x00C3: ("DeathAdder V3 Pro", 0x3F, 0x1F),
    ]

    private static let razerVendorID: UInt32 = 0x1532
    /// Apple Silicon / 新 USB 栈是 IOUSBHostDevice; IOUSBDevice 留给旧系统兼容节点.
    private static let usbServiceClasses = ["IOUSBHostDevice", kIOUSBDeviceClassName]

    /// 电量轮询间隔
    var batteryPollInterval: TimeInterval = 60.0

    /// 设备列表变化回调 (主线程)
    var onDevicesChanged: (() -> Void)?

    private(set) var devices: [RazerDeviceState] = []

    private let ioQueue = DispatchQueue(label: "mos.razer.io")
    private var notificationPort: IONotificationPortRef?
    private var hotPlugIterators: [io_object_t] = []
    private var deviceHandles: [UInt32: RazerUSBDevice] = [:]
    /// 最近一次读取的设备状态缓存 (ioQueue 读写, publish 时快照到主线程)
    private var stateCache: [UInt32: RazerDeviceState] = [:]
    private var batteryTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// 设备连续控制失败计数 (>=2 触发重开/重枚举)
    private var failureCounts: [UInt32: Int] = [:]
    /// 重枚举冷却, 避免失败时高频重建句柄
    private var lastReenumerateTime: CFTimeInterval = 0
    private let reenumerateCooldown: TimeInterval = 5.0
    private var hasStarted = false
    private var isRecoveringHandle = false

    private init() {}

    // MARK: - 生命周期

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        guard let port = IONotificationPortCreate(mach_port_t(MACH_PORT_NULL)) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        // IOServiceAddMatchingNotification 会消耗 matching 字典的一份引用, 每个 class 各建两份.
        // macOS 27 上雷蛇鼠标是 IOUSBHostDevice, 不再保证有 IOUSBDevice 兼容节点.
        for className in Self.usbServiceClasses {
            registerHotPlug(port: port, className: className)
        }
        enumerateFromIterator()

        let timer = Timer(timeInterval: batteryPollInterval, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.handleSystemWake()
            }
        }
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        batteryTimer?.invalidate()
        batteryTimer = nil
        for iterator in hotPlugIterators where iterator != 0 {
            IOObjectRelease(iterator)
        }
        hotPlugIterators.removeAll()
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        ioQueue.sync {
            deviceHandles.removeAll()
            stateCache.removeAll()
            failureCounts.removeAll()
        }
        devices = []
    }

    // MARK: - 枚举与热插拔

    private func makeUSBMatching(className: String) -> CFMutableDictionary? {
        return IOServiceMatching(className)
    }

    private func registerHotPlug(port: IONotificationPortRef, className: String) {
        guard let matchAppeared = makeUSBMatching(className: className),
              let matchDisappeared = makeUSBMatching(className: className) else { return }

        var matched: io_object_t = 0
        var terminated: io_object_t = 0
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matchAppeared,
            { refcon, iterator in
                guard let refcon else { return }
                let manager = Unmanaged<RazerDeviceManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleAppeared(iterator: iterator)
            },
            refcon,
            &matched
        )
        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matchDisappeared,
            { refcon, iterator in
                guard let refcon else { return }
                let manager = Unmanaged<RazerDeviceManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleDisappeared(iterator: iterator)
            },
            refcon,
            &terminated
        )

        // 排空通知迭代器才能 arm; 不要释放, 否则后续热插拔会停.
        if matched != 0 {
            hotPlugIterators.append(matched)
            handleAppeared(iterator: matched)
        }
        if terminated != 0 {
            hotPlugIterators.append(terminated)
            handleDisappeared(iterator: terminated)
        }
    }

    /// 全量枚举 (启动 / 唤醒 / 句柄失效后重建). 一次性 iterator 必须释放.
    private func enumerateFromIterator() {
        var combined: [(locationID: UInt32, service: io_service_t)] = []
        for className in Self.usbServiceClasses {
            var iterator: io_iterator_t = 0
            guard let matching = makeUSBMatching(className: className),
                  IOServiceGetMatchingServices(mach_port_t(MACH_PORT_NULL), matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            combined.append(contentsOf: retainSupportedServices(from: iterator))
            IOObjectRelease(iterator)
        }
        ioQueue.async { [weak self] in
            self?.applyServices(combined, kind: .full)
        }
    }

    /// FirstMatch: 只新增. 通知 iterator 不能释放, 排空即重新 arm.
    private func handleAppeared(iterator: io_iterator_t) {
        let services = retainSupportedServices(from: iterator)
        ioQueue.async { [weak self] in
            self?.applyServices(services, kind: .appeared)
        }
    }

    /// Terminated: 只移除本次消失的雷蛇设备.
    private func handleDisappeared(iterator: io_iterator_t) {
        var gone: [UInt32] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let locationID = registryUInt32(service, key: "locationID"),
               isSupportedMouse(service: service) {
                gone.append(locationID)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        guard !gone.isEmpty else { return }
        ioQueue.async { [weak self] in
            self?.removeDevices(Set(gone), publish: true)
        }
    }

    private enum ApplyKind {
        case appeared
        case full
    }

    private func retainSupportedServices(from iterator: io_iterator_t) -> [(locationID: UInt32, service: io_service_t)] {
        var retained: [(locationID: UInt32, service: io_service_t)] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let locationID = registryUInt32(service, key: "locationID"),
               isSupportedMouse(service: service) {
                retained.append((locationID, service))
            } else {
                IOObjectRelease(service)
            }
            service = IOIteratorNext(iterator)
        }
        return retained
    }

    private func applyServices(
        _ services: [(locationID: UInt32, service: io_service_t)],
        kind: ApplyKind
    ) {
        var unique: [(locationID: UInt32, service: io_service_t)] = []
        var seen = Set<UInt32>()
        var extras: [io_service_t] = []
        for item in services {
            if seen.insert(item.locationID).inserted {
                unique.append(item)
            } else {
                extras.append(item.service)
            }
        }
        extras.forEach { IOObjectRelease($0) }

        let incomingIDs = Set(unique.map(\.locationID))
        let reconcileEvent: RazerHotPlugReconcile.Event
        switch kind {
        case .appeared:
            reconcileEvent = .appeared(incomingIDs)
        case .full:
            reconcileEvent = .fullSnapshot(incomingIDs)
        }
        let change = RazerHotPlugReconcile.apply(
            current: Set(deviceHandles.keys),
            event: reconcileEvent
        )

        if kind == .full {
            removeDevices(change.remove, publish: false)
        }

        var added = false
        for (locationID, service) in unique {
            defer { IOObjectRelease(service) }
            guard change.add.contains(locationID), deviceHandles[locationID] == nil else { continue }
            guard let handle = RazerUSBDevice(locationID: locationID, service: service) else { continue }
            if handle.open() {
                deviceHandles[locationID] = handle
                failureCounts[locationID] = 0
                added = true
            }
        }

        if added {
            readAllDeviceStates()
        } else if kind == .full {
            publishSnapshot()
        }
    }

    private func removeDevices(_ locationIDs: Set<UInt32>, publish: Bool) {
        var removed = false
        for locationID in locationIDs {
            if let handle = deviceHandles.removeValue(forKey: locationID) {
                handle.close()
                removed = true
            }
            stateCache.removeValue(forKey: locationID)
            failureCounts.removeValue(forKey: locationID)
        }
        if publish, removed {
            publishSnapshot()
        }
    }

    private func isSupportedMouse(service: io_service_t) -> Bool {
        guard let vendor = registryUInt32(service, key: "idVendor"),
              vendor == Self.razerVendorID,
              let product = registryUInt32(service, key: "idProduct") else {
            return false
        }
        return Self.supportedMice[UInt16(product)] != nil
    }

    private func registryUInt32(_ service: io_service_t, key: String) -> UInt32? {
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return value.uint32Value
    }

    // MARK: - 状态读取

    /// 全量刷新 (枚举时 / 手动触发). 句柄为空时重新扫 USB, 避免只读空列表.
    func refreshAll() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.deviceHandles.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.enumerateFromIterator()
                }
                return
            }
            self.readAllDeviceStates()
        }
    }

    /// 电量轮询
    func refreshBattery() {
        ioQueue.async { [weak self] in
            self?.readAllDeviceStates(batteryOnly: true)
        }
    }

    private func readAllDeviceStates(batteryOnly: Bool = false) {
        guard !deviceHandles.isEmpty else {
            publishSnapshot()
            return
        }
        for (_, handle) in deviceHandles {
            if let state = readState(from: handle, batteryOnly: batteryOnly) {
                stateCache[handle.locationID] = state
            }
        }
        publishSnapshot()
    }

    /// 读取单个设备状态 (在 ioQueue 上调用). 失败时保留上次成功值.
    private func readState(from handle: RazerUSBDevice, batteryOnly: Bool) -> RazerDeviceState? {
        guard let spec = Self.supportedMice[handle.productID] else { return nil }

        var state = stateCache[handle.locationID] ?? RazerDeviceState(
            locationID: handle.locationID,
            productID: handle.productID,
            name: handle.productName,
            supportsBattery: true,
            supportsDPI: true,
            supportsPollRate: true
        )

        var anySuccess = false
        if let response = handle.getResponse(for: RazerCommand.battery(transactionID: spec.batteryTransaction)) {
            state.apply(batteryPercent: response.batteryPercent)
            anySuccess = true
        }
        if !batteryOnly {
            if let response = handle.getResponse(for: RazerCommand.charging(transactionID: spec.batteryTransaction)) {
                state.apply(isCharging: response.isCharging)
                anySuccess = true
            }
            if let response = handle.getResponse(for: RazerCommand.getDPI(transactionID: spec.miscTransaction)) {
                state.apply(dpi: response.dpi?.x)
                anySuccess = true
            }
            if let response = handle.getResponse(for: RazerCommand.getPollRate(transactionID: spec.miscTransaction)) {
                state.apply(pollRate: response.pollRate)
                anySuccess = true
            }
        }

        if handle.isStale {
            handleFailure(handle.locationID)
            return stateCache[handle.locationID] ?? state
        }
        if anySuccess {
            failureCounts[handle.locationID] = 0
        } else {
            handleFailure(handle.locationID)
        }
        return state
    }

    /// 设备句柄失效恢复: 连续失败后先关开重试, 再不行丢弃并重新枚举
    private func handleFailure(_ locationID: UInt32) {
        guard !isRecoveringHandle else { return }
        let count = (failureCounts[locationID] ?? 0) + 1
        failureCounts[locationID] = count
        guard count >= 2 else { return }
        failureCounts[locationID] = 0

        guard let handle = deviceHandles[locationID] else { return }
        isRecoveringHandle = true
        defer { isRecoveringHandle = false }

        handle.close()
        if handle.open() {
            stateCache.removeValue(forKey: locationID)
            if let state = readState(from: handle, batteryOnly: false) {
                stateCache[locationID] = state
            }
        } else {
            deviceHandles.removeValue(forKey: locationID)
            stateCache.removeValue(forKey: locationID)
            scheduleReenumerate()
        }
    }

    /// 睡眠唤醒: 关闭全部句柄, 稍后重新枚举 (设备可能已重枚举/重置)
    private func handleSystemWake() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            for (_, handle) in self.deviceHandles {
                handle.close()
            }
            self.deviceHandles.removeAll()
            self.stateCache.removeAll()
            self.failureCounts.removeAll()
            self.publishSnapshot()
            DispatchQueue.main.async {
                self.enumerateFromIterator()
            }
        }
    }

    /// 带冷却的重枚举调度
    private func scheduleReenumerate() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastReenumerateTime > reenumerateCooldown else { return }
        lastReenumerateTime = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.enumerateFromIterator()
        }
    }

    /// 设备写操作 (DPI / 回报率), 完成后刷新快照
    func setDPI(_ dpi: Int, forLocationID locationID: UInt32) {
        ioQueue.async { [weak self] in
            guard let self,
                  let handle = self.deviceHandles[locationID],
                  let spec = Self.supportedMice[handle.productID] else { return }
            _ = handle.sendReport(RazerCommand.setDPI(dpi, transactionID: spec.miscTransaction))
            usleep(50_000)
            if let state = self.readState(from: handle, batteryOnly: false) {
                self.stateCache[handle.locationID] = state
            }
            self.publishSnapshot()
        }
    }

    func setPollRate(_ pollRate: Int, forLocationID locationID: UInt32) {
        ioQueue.async { [weak self] in
            guard let self,
                  let handle = self.deviceHandles[locationID],
                  let spec = Self.supportedMice[handle.productID] else { return }
            _ = handle.sendReport(RazerCommand.setPollRate(pollRate, transactionID: spec.miscTransaction))
            usleep(50_000)
            if let state = self.readState(from: handle, batteryOnly: false) {
                self.stateCache[handle.locationID] = state
            }
            self.publishSnapshot()
        }
    }

    // MARK: - 快照

    private func publishSnapshot() {
        var snapshot: [RazerDeviceState] = []
        for (locationID, handle) in deviceHandles.sorted(by: { $0.key < $1.key }) {
            if let state = stateCache[locationID] {
                snapshot.append(state)
            } else {
                snapshot.append(RazerDeviceState(
                    locationID: locationID,
                    productID: handle.productID,
                    name: handle.productName,
                    supportsBattery: true,
                    supportsDPI: true,
                    supportsPollRate: true
                ))
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasStarted else { return }
            self.devices = snapshot
            self.onDevicesChanged?()
        }
    }

}
