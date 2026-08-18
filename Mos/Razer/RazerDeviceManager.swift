//
//  RazerDeviceManager.swift
//  Mos
//  Razer 设备管理: 枚举 / 热插拔 / 电量轮询
//  Created by Codex on 2026/8/18.
//  Copyright © 2026 Caldis. All rights reserved.
//

import IOKit
import CoreFoundation
import Foundation

/// Razer 设备能力与当前状态 (UI 只读快照)
struct RazerDeviceState {
    let locationID: UInt32
    let productID: UInt16
    let name: String
    let supportsBattery: Bool
    let supportsDPI: Bool
    let supportsPollRate: Bool

    var batteryPercent: Int?
    var isCharging: Bool?
    var dpi: Int?
    var pollRate: Int?
}

/// Razer 设备管理器 (单例; IOKit 通知挂在主 RunLoop, 设备 I/O 在专用串行队列)
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

    /// 电量轮询间隔
    var batteryPollInterval: TimeInterval = 60.0

    /// 设备列表变化回调 (主线程)
    var onDevicesChanged: (() -> Void)?

    private(set) var devices: [RazerDeviceState] = []

    private let ioQueue = DispatchQueue(label: "mos.razer.io")
    private var notificationPort: IONotificationPortRef?
    private var matchedNotification: io_object_t = 0
    private var terminatedNotification: io_object_t = 0
    private var deviceHandles: [UInt32: RazerUSBDevice] = [:]
    /// 最近一次读取的设备状态缓存 (ioQueue 读写, publish 时快照)
    private var stateCache: [UInt32: RazerDeviceState] = [:]
    private var batteryTimer: Timer?
    private var hasStarted = false

    private init() {}

    // MARK: - 生命周期

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // IOKit 通知 (主 RunLoop)
        guard let port = IONotificationPortCreate(mach_port_t(MACH_PORT_NULL)) else { return }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)

        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        guard let matching else { return }

        IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matching,
            { refcon, iterator in
                guard let refcon else { return }
                let manager = Unmanaged<RazerDeviceManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.consume(iterator: iterator)
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &matchedNotification
        )

        IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            matching,
            { refcon, iterator in
                guard let refcon else { return }
                let manager = Unmanaged<RazerDeviceManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.consume(iterator: iterator)
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &terminatedNotification
        )

        // 初始枚举 (通知回调也负责; 这里主动跑一次覆盖回调前的设备)
        enumerateFromIterator()

        // 电量轮询
        let timer = Timer(timeInterval: batteryPollInterval, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        batteryTimer?.invalidate()
        batteryTimer = nil
        if matchedNotification != 0 {
            IOObjectRelease(matchedNotification)
            matchedNotification = 0
        }
        if terminatedNotification != 0 {
            IOObjectRelease(terminatedNotification)
            terminatedNotification = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        deviceHandles.removeAll()
        devices = []
    }

    // MARK: - 枚举与热插拔

    /// 从通知迭代器消费全部 service (先过滤再建句柄, 避免为无关设备开接口)
    private func enumerateFromIterator() {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        guard let matching,
              IOServiceGetMatchingServices(mach_port_t(MACH_PORT_NULL), matching, &iterator) == KERN_SUCCESS else {
            return
        }
        consume(iterator: iterator)
    }

    /// 消费一个 service 迭代器, 过滤并建立 Razer 句柄
    private func consume(iterator: io_iterator_t) {
        var found: [UInt32: RazerUSBDevice] = [:]
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let locationID = registryUInt32(service, key: "locationID"),
               isSupportedMouse(service: service),
               let device = RazerUSBDevice(locationID: locationID, service: service) {
                found[locationID] = device
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)

        ioQueue.async { [weak self] in
            self?.synchronizeDevices(found)
        }
    }

    private func synchronizeDevices(_ found: [UInt32: RazerUSBDevice]) {
        let removed = deviceHandles.keys.filter { found[$0] == nil }
        for locationID in removed {
            deviceHandles.removeValue(forKey: locationID)
            stateCache.removeValue(forKey: locationID)
        }

        var updated = false
        for (locationID, handle) in found where deviceHandles[locationID] == nil {
            if handle.open() {
                deviceHandles[locationID] = handle
                stateCache.removeValue(forKey: locationID)
                updated = true
            }
        }

        if updated || !deviceHandles.isEmpty {
            readAllDeviceStates()
        }
    }

    private func isSupportedMouse(service: io_service_t) -> Bool {
        guard let vendor = registryUInt32(service, key: "idVendor"),
              vendor == 0x1532,
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

    /// 全量刷新 (枚举时 / 手动触发)
    func refreshAll() {
        ioQueue.async { [weak self] in
            self?.readAllDeviceStates()
        }
    }

    /// 电量轮询
    func refreshBattery() {
        ioQueue.async { [weak self] in
            self?.readAllDeviceStates(batteryOnly: true)
        }
    }

    private func readAllDeviceStates(batteryOnly: Bool = false) {
        guard !deviceHandles.isEmpty else { return }
        for (_, handle) in deviceHandles {
            if let state = readState(from: handle, batteryOnly: batteryOnly) {
                stateCache[handle.locationID] = state
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.publishSnapshot()
        }
    }

    /// 读取单个设备状态 (在 ioQueue 上调用)
    private func readState(from handle: RazerUSBDevice, batteryOnly: Bool) -> RazerDeviceState? {
        guard let spec = Self.supportedMice[handle.productID] else { return nil }

        var state = RazerDeviceState(
            locationID: handle.locationID,
            productID: handle.productID,
            name: handle.productName,
            supportsBattery: true,
            supportsDPI: true,
            supportsPollRate: true
        )

        if let response = handle.getResponse(for: RazerCommand.battery(transactionID: spec.batteryTransaction)) {
            state.batteryPercent = response.batteryPercent
            state.isCharging = response.isCharging
        }
        if !batteryOnly {
            if let response = handle.getResponse(for: RazerCommand.getDPI(transactionID: spec.miscTransaction)) {
                state.dpi = response.dpi?.x
            }
            if let response = handle.getResponse(for: RazerCommand.getPollRate(transactionID: spec.miscTransaction)) {
                state.pollRate = response.pollRate
            }
        }
        return state
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
            DispatchQueue.main.async { self.publishSnapshot() }
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
            DispatchQueue.main.async { self.publishSnapshot() }
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
        devices = snapshot
        onDevicesChanged?()
    }

}
