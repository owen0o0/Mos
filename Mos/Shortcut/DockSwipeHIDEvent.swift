//
//  DockSwipeHIDEvent.swift
//  Mos
//  macOS 27+ dock swipe 需要把 IOHIDEvent 挂到 CGEvent 上.
//  旧的未文档化 CGEvent fields 在 27 上会被 WindowServer 忽略.
//  Created by Claude on 2026/9/16.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa
import Darwin

/// 通过 SkyLight 的 `SLEventSetIOHIDEvent` 把 dock swipe `IOHIDEvent` 挂到合成 CGEvent 上.
/// 符号全部运行时 dlsym, 避免链接私有框架, 也避免 SDK 缺失这些声明.
enum DockSwipeHIDEvent {

    /// macOS 27 起必须走 HID 挂载, 仅写 CGEvent fields 不会再驱动 Spaces / Mission Control.
    static var isRequired: Bool {
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    struct Payload: Equatable {
        var motion: Int
        var progress: Double
        var phase: DockSwipePhase
        var velocity: Double?
    }

    struct Inspection: Equatable {
        var type: UInt32
        var motion: Int
        var progress: Double
        var flavor: Int
        var velocityX: Double
    }

    static var attachIsAvailable: Bool {
        return Runtime.shared.isAvailable
    }

    /// HID 路径没有 invertedFromDevice 字段; 自然滚动时必须把 progress 和结束速度一起取反,
    /// 只取反 progress 会让松手速度反向, 造成桌面切换回弹.
    static func payload(
        axis: DockSwipeAxis,
        phase: DockSwipePhase,
        progress: Double,
        velocity: Double?,
        inverted: Bool
    ) -> Payload {
        let sign = inverted ? -1.0 : 1.0
        return Payload(
            motion: axis.rawValue,
            progress: progress * sign,
            phase: phase,
            velocity: velocity.map { $0 * sign }
        )
    }

    /// 把 dock swipe HID 事件挂到 `event` 上. 调用方仍需自己 `post`.
    /// `SLEventSetIOHIDEvent` 会复制 payload, 因此这里创建的 IOHIDEvent 在返回前释放.
    @discardableResult
    static func attach(to event: CGEvent, payload: Payload) -> Bool {
        guard let runtime = Runtime.shared.takeIfAvailable() else { return false }
        let options = UInt32(payload.phase.rawValue) << eventOptionPhaseShift
        guard let hidEvent = runtime.create(nil, hidEventTypeDockSwipe, 0, options) else {
            return false
        }
        runtime.setInteger(hidEvent, fieldDockSwipeMotion, payload.motion)
        runtime.setDouble(hidEvent, fieldDockSwipeProgress, payload.progress)
        runtime.setInteger(hidEvent, fieldDockSwipeFlavor, gestureFlavorDockPrimary)

        if let velocity = payload.velocity {
            if let child = runtime.create(nil, hidEventTypeVelocity, 0, 0) {
                runtime.setDouble(child, fieldVelocityX, velocity)
                runtime.setDouble(child, fieldVelocityY, velocity)
                runtime.setDouble(child, fieldVelocityZ, 0)
                runtime.append(hidEvent, child, 0)
                runtime.release(child)
            }
        }

        runtime.setHID(cgEventPointer(event), hidEvent)
        runtime.release(hidEvent)
        return true
    }

    static func inspectAttached(from event: CGEvent) -> Inspection? {
        guard let runtime = Runtime.shared.takeIfAvailable(), let copyHID = runtime.copyHID else {
            return nil
        }
        guard let hidEvent = copyHID(cgEventPointer(event)) else { return nil }
        defer { runtime.release(hidEvent) }
        let type = runtime.getType(hidEvent)
        guard type == hidEventTypeDockSwipe else { return nil }
        return Inspection(
            type: type,
            motion: runtime.getInteger(hidEvent, fieldDockSwipeMotion),
            progress: runtime.getDouble(hidEvent, fieldDockSwipeProgress),
            flavor: runtime.getInteger(hidEvent, fieldDockSwipeFlavor),
            velocityX: runtime.getDouble(hidEvent, fieldVelocityX)
        )
    }
}

// MARK: - HID 常量 (IOHIDEventTypes.h)

private let hidEventTypeVelocity: UInt32 = 9
private let hidEventTypeDockSwipe: UInt32 = 23
private let eventOptionPhaseShift: UInt32 = 24
/// kIOHIDGestureFlavorDockPrimary
private let gestureFlavorDockPrimary = 3
private let fieldDockSwipeMotion: UInt32 = hidEventTypeDockSwipe << 16 | 1
private let fieldDockSwipeProgress: UInt32 = hidEventTypeDockSwipe << 16 | 2
private let fieldDockSwipeFlavor: UInt32 = hidEventTypeDockSwipe << 16 | 5
private let fieldVelocityX: UInt32 = hidEventTypeVelocity << 16
private let fieldVelocityY: UInt32 = hidEventTypeVelocity << 16 | 1
private let fieldVelocityZ: UInt32 = hidEventTypeVelocity << 16 | 2

// MARK: - 运行时符号

private final class Runtime {
    static let shared = Runtime()

    typealias CreateFn = @convention(c) (UnsafeRawPointer?, UInt32, UInt64, UInt32) -> OpaquePointer?
    typealias SetIntegerFn = @convention(c) (OpaquePointer, UInt32, Int) -> Void
    typealias SetDoubleFn = @convention(c) (OpaquePointer, UInt32, Double) -> Void
    typealias AppendFn = @convention(c) (OpaquePointer, OpaquePointer, UInt32) -> Void
    typealias SetHIDFn = @convention(c) (OpaquePointer, OpaquePointer) -> Void
    typealias CopyHIDFn = @convention(c) (OpaquePointer) -> OpaquePointer?
    typealias GetTypeFn = @convention(c) (OpaquePointer) -> UInt32
    typealias GetIntegerFn = @convention(c) (OpaquePointer, UInt32) -> Int
    typealias GetDoubleFn = @convention(c) (OpaquePointer, UInt32) -> Double

    let create: CreateFn?
    let setInteger: SetIntegerFn?
    let setDouble: SetDoubleFn?
    let append: AppendFn?
    let setHID: SetHIDFn?
    let copyHID: CopyHIDFn?
    let getType: GetTypeFn?
    let getInteger: GetIntegerFn?
    let getDouble: GetDoubleFn?

    var isAvailable: Bool {
        return create != nil
            && setInteger != nil
            && setDouble != nil
            && append != nil
            && setHID != nil
            && getType != nil
            && getInteger != nil
            && getDouble != nil
    }

    struct Available {
        let create: CreateFn
        let setInteger: SetIntegerFn
        let setDouble: SetDoubleFn
        let append: AppendFn
        let setHID: SetHIDFn
        let copyHID: CopyHIDFn?
        let getType: GetTypeFn
        let getInteger: GetIntegerFn
        let getDouble: GetDoubleFn

        func release(_ pointer: OpaquePointer) {
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(pointer)).release()
        }
    }

    func takeIfAvailable() -> Available? {
        guard
            let create = create,
            let setInteger = setInteger,
            let setDouble = setDouble,
            let append = append,
            let setHID = setHID,
            let getType = getType,
            let getInteger = getInteger,
            let getDouble = getDouble
        else { return nil }
        return Available(
            create: create,
            setInteger: setInteger,
            setDouble: setDouble,
            append: append,
            setHID: setHID,
            copyHID: copyHID,
            getType: getType,
            getInteger: getInteger,
            getDouble: getDouble
        )
    }

    private init() {
        let skyLight = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        )
        let ioKit = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit",
            RTLD_LAZY
        )
        create = loadSymbol("IOHIDEventCreate", handle: ioKit)
        setInteger = loadSymbol("IOHIDEventSetIntegerValue", handle: ioKit)
        if let setDoubleValue: SetDoubleFn = loadSymbol("IOHIDEventSetDoubleValue", handle: ioKit) {
            setDouble = setDoubleValue
        } else {
            setDouble = loadSymbol("IOHIDEventSetFloatValue", handle: ioKit)
        }
        append = loadSymbol("IOHIDEventAppendEvent", handle: ioKit)
        setHID = loadSymbol("SLEventSetIOHIDEvent", handle: skyLight)
        if let copyFromSkyLight: CopyHIDFn = loadSymbol("SLEventCopyIOHIDEvent", handle: skyLight) {
            copyHID = copyFromSkyLight
        } else {
            copyHID = loadSymbol("CGEventCopyIOHIDEvent")
        }
        getType = loadSymbol("IOHIDEventGetType", handle: ioKit)
        getInteger = loadSymbol("IOHIDEventGetIntegerValue", handle: ioKit)
        if let getDoubleValue: GetDoubleFn = loadSymbol("IOHIDEventGetFloatValue", handle: ioKit) {
            getDouble = getDoubleValue
        } else {
            getDouble = nil
        }
    }
}

private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

private func loadSymbol<T>(_ name: String, handle: UnsafeMutableRawPointer? = nil) -> T? {
    let resolved: UnsafeMutableRawPointer?
    if let handle = handle, let fromHandle = dlsym(handle, name) {
        resolved = fromHandle
    } else {
        resolved = dlsym(rtldDefault, name)
    }
    guard let resolved = resolved else { return nil }
    return unsafeBitCast(resolved, to: T.self)
}

private func cgEventPointer(_ event: CGEvent) -> OpaquePointer {
    return OpaquePointer(Unmanaged.passUnretained(event).toOpaque())
}
