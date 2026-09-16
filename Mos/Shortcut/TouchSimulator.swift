//
//  TouchSimulator.swift
//  Mos
//  触摸手势合成
//
//  通过给合成 CGEvent 写入未文档化 HID event fields 来模拟:
//  - Smart Zoom (kIOHIDEventTypeZoomToggle = 22)
//  - 导航滑动 (kIOHIDEventTypeNavigationSwipe = 16, 浏览器前进/后退)
//
//  注意: 这些 field 常量未公开, 属于私有 API 用法; macOS 升级后可能失效.
//  macOS 27+: WindowServer 忽略上述 CGEvent fields, dock swipe 必须额外挂上 IOHIDEvent.
//  Created by Claude on 2026/8/17.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

enum TouchSimulator {

    // MARK: - HID 常量 (IOHIDEventTypes.h)

    /// kIOHIDEventTypeNavigationSwipe
    private static let hidEventTypeNavigationSwipe: Int64 = 16
    /// kIOHIDEventTypeZoomToggle
    private static let hidEventTypeZoomToggle: Int64 = 22
    /// kIOHIDEventTypeDockSwipe
    private static let hidEventTypeDockSwipe: Int64 = 23
    /// kIOHIDEventPhaseBegan
    private static let hidEventPhaseBegan: Int64 = 1
    /// kIOHIDEventPhaseEnded
    private static let hidEventPhaseEnded: Int64 = 4
    /// kIOHIDEventPhaseChanged
    private static let hidEventPhaseChanged: Int64 = 2
    /// kIOHIDEventPhaseCancelled
    private static let hidEventPhaseCancelled: Int64 = 8
    /// kIOHIDSwipeLeft
    private static let hidSwipeLeft: Int64 = 1 << 2
    /// kIOHIDSwipeRight
    private static let hidSwipeRight: Int64 = 1 << 3
    /// kIOHIDSwipeNone
    private static let hidSwipeNone: Int64 = 0

    /// 未文档化 CGEventField: event type (这里写 NSEventTypeGesture = 29)
    private static let fieldEventType: CGEventField = CGEventField(rawValue: 55)!
    /// 未文档化 CGEventField: HID event type
    private static let fieldHIDEventType: CGEventField = CGEventField(rawValue: 110)!
    /// 未文档化 CGEventField: swipe direction
    private static let fieldSwipeDirection: CGEventField = CGEventField(rawValue: 115)!
    /// 未文档化 CGEventField: HID event phase
    private static let fieldEventPhase: CGEventField = CGEventField(rawValue: 132)!
    /// 未文档化 CGEventField: dockSwipe origin offset (double)
    private static let fieldOriginOffset: CGEventField = CGEventField(rawValue: 124)!
    /// 未文档化 CGEventField: dockSwipe 方向轴 (1=水平, 2=垂直)
    private static let fieldDockAxis: CGEventField = CGEventField(rawValue: 123)!
    /// 未文档化 CGEventField: dockSwipe 方向轴 (冗余)
    private static let fieldDockAxis2: CGEventField = CGEventField(rawValue: 165)!
    /// 未文档化 CGEventField: 设备自然方向标志
    private static let fieldInvertedFromDevice: CGEventField = CGEventField(rawValue: 136)!
    /// 未文档化 CGEventField: dockSwipe 相位 (冗余)
    private static let fieldDockPhase: CGEventField = CGEventField(rawValue: 134)!
    /// 未文档化 CGEventField: 未知辅助值 (固定 33231)
    private static let fieldMystery: CGEventField = CGEventField(rawValue: 41)!
    /// 未文档化 CGEventField: dockSwipe 类型编码 (Float32 位模式)
    private static let fieldDockType: CGEventField = CGEventField(rawValue: 119)!
    /// 未文档化 CGEventField: dockSwipe 类型编码 (冗余)
    private static let fieldDockType2: CGEventField = CGEventField(rawValue: 139)!
    /// 未文档化 CGEventField: 退出速度 (end 相位)
    private static let fieldExitSpeed: CGEventField = CGEventField(rawValue: 129)!
    /// 未文档化 CGEventField: 退出速度 (冗余)
    private static let fieldExitSpeed2: CGEventField = CGEventField(rawValue: 130)!
    /// 未文档化 CGEventField: origin offset 的 Float32 位模式 (int64)
    private static let fieldOriginOffsetEncoded: CGEventField = CGEventField(rawValue: 135)!
    /// 未文档化 CGEventField: 滚动事件 isContinuous
    private static let fieldIsContinuous: CGEventField = CGEventField(rawValue: 88)!
    /// 未文档化 CGEventField: 滚动方向是否反自设备
    private static let fieldDirectionInverted: CGEventField = CGEventField(rawValue: 137)!
    /// 未文档化 CGEventField: 滚动线 delta (轴1 int)
    private static let fieldLineDeltaAxis1: CGEventField = CGEventField(rawValue: 11)!
    /// 未文档化 CGEventField: 滚动点 delta (轴1)
    private static let fieldPointDeltaAxis1: CGEventField = CGEventField(rawValue: 96)!
    /// 未文档化 CGEventField: 滚动定点 delta (轴1)
    private static let fieldFixedDeltaAxis1: CGEventField = CGEventField(rawValue: 93)!
    /// 未文档化 CGEventField: 滚动线 delta (轴2 int)
    private static let fieldLineDeltaAxis2: CGEventField = CGEventField(rawValue: 12)!
    /// 未文档化 CGEventField: 滚动点 delta (轴2)
    private static let fieldPointDeltaAxis2: CGEventField = CGEventField(rawValue: 97)!
    /// 未文档化 CGEventField: 滚动定点 delta (轴2)
    private static let fieldFixedDeltaAxis2: CGEventField = CGEventField(rawValue: 94)!
    /// 未文档化 CGEventField: 滚动相位
    private static let fieldScrollPhase: CGEventField = CGEventField(rawValue: 99)!
    /// 未文档化 CGEventField: 动量相位
    private static let fieldMomentumPhase: CGEventField = CGEventField(rawValue: 123)!
    /// 未文档化 CGEventField: 手势 delta X (gesture event)
    private static let fieldGestureDeltaX: CGEventField = CGEventField(rawValue: 116)!
    /// 未文档化 CGEventField: 手势 delta Y (gesture event)
    private static let fieldGestureDeltaY: CGEventField = CGEventField(rawValue: 119)!
    /// 未文档化 CGEventField: magnification 量
    private static let fieldMagnification: CGEventField = CGEventField(rawValue: 113)!

    // MARK: - 测试钩子

    /// 测试时拦截合成事件, 避免在单测进程中真实注入手势
    static var testingPostHook: ((CGEvent) -> Void)?

    // MARK: - 手势合成

    /// 导航滑动: 浏览器/Apple 应用中的前进后退
    static func postNavigationSwipeEvent(direction: NavigationSwipeDirection) {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(fieldEventType, value: Int64(NSEvent.EventType.gesture.rawValue))
        event.setIntegerValueField(fieldHIDEventType, value: hidEventTypeNavigationSwipe)
        event.setIntegerValueField(fieldEventPhase, value: hidEventPhaseBegan)
        event.setIntegerValueField(fieldSwipeDirection, value: direction == .left ? hidSwipeLeft : hidSwipeRight)
        post(event)

        event.setIntegerValueField(fieldSwipeDirection, value: hidSwipeNone)
        event.setIntegerValueField(fieldEventPhase, value: hidEventPhaseEnded)
        post(event)
    }

    /// 双指滚动手势:
    /// 两条事件 (scrollWheel + gesture), 模拟触控板双指滑动, 驱动页面导航/惯性滚动
    static func postGestureScroll(
        deltaX: Double,
        deltaY: Double,
        phase: GestureScrollPhase,
        inverted: Bool
    ) {
        // 只有 ended 相位允许零 delta (对齐真实触控板行为)
        if deltaX == 0 && deltaY == 0 && phase != .ended {
            return
        }

        let lineY = deltaY / 10.0
        let lineX = deltaX / 10.0
        let lineIntY = Int64(lineY.rounded())
        let lineIntX = Int64(lineX.rounded())

        // 事件 1: scrollWheel (55=22)
        let scrollEvent = CGEvent(source: nil)
        scrollEvent?.setIntegerValueField(fieldEventType, value: Int64(NSEvent.EventType.scrollWheel.rawValue))
        scrollEvent?.setIntegerValueField(fieldIsContinuous, value: 1)
        scrollEvent?.setIntegerValueField(fieldDirectionInverted, value: inverted ? 1 : 0)
        scrollEvent?.setIntegerValueField(fieldLineDeltaAxis1, value: lineIntY)
        scrollEvent?.setIntegerValueField(fieldLineDeltaAxis2, value: lineIntX)
        scrollEvent?.setDoubleValueField(fieldPointDeltaAxis1, value: deltaY)
        scrollEvent?.setDoubleValueField(fieldPointDeltaAxis2, value: deltaX)
        scrollEvent?.setIntegerValueField(fieldFixedDeltaAxis1, value: fixedScrollDelta(lineY))
        scrollEvent?.setIntegerValueField(fieldFixedDeltaAxis2, value: fixedScrollDelta(lineX))
        scrollEvent?.setIntegerValueField(fieldScrollPhase, value: phase.rawValue)
        scrollEvent?.setIntegerValueField(fieldMomentumPhase, value: 0)
        if let scrollEvent {
            post(scrollEvent, to: .cgSessionEventTap)
        }

        // 事件 2: gesture (55=29, subtype 110=6 scroll)
        let gestureEvent = CGEvent(source: nil)
        gestureEvent?.setIntegerValueField(fieldEventType, value: Int64(NSEvent.EventType.gesture.rawValue))
        gestureEvent?.setIntegerValueField(fieldHIDEventType, value: 6)  // kIOHIDEventTypeScroll
        gestureEvent?.setDoubleValueField(fieldGestureDeltaX, value: deltaX)
        gestureEvent?.setDoubleValueField(fieldGestureDeltaY, value: deltaY)
        gestureEvent?.setIntegerValueField(fieldEventPhase, value: phase.rawValue)
        if let gestureEvent {
            post(gestureEvent, to: .cgSessionEventTap)
        }
    }

    /// 双指捏合缩放: magnification 事件流 (field 110 = 8)
    static func postMagnification(magnification: Double, phase: GestureScrollPhase) {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(fieldEventType, value: Int64(NSEvent.EventType.gesture.rawValue))
        event.setIntegerValueField(fieldHIDEventType, value: 8)  // kIOHIDEventTypeZoom
        event.setIntegerValueField(fieldEventPhase, value: phase.rawValue)
        event.setDoubleValueField(fieldMagnification, value: magnification)
        post(event)
    }

    /// Dock Swipe:
    /// 持续手势流 (began → changed* → ended), 驱动调度中心/程序切换/页面导航
    static func postDockSwipe(
        delta: Double,
        axis: DockSwipeAxis,
        phase: DockSwipePhase,
        inverted: Bool
    ) {
        // 兼容处理: pinch 且未 inverted 时强制 inverted 并取反 (打开 Launchpad 的已知 bug 补偿)
        var effectiveDelta = delta
        var effectiveInverted = inverted
        if axis == .pinch && !effectiveInverted {
            effectiveInverted = true
            effectiveDelta = -delta
        }

        // 更新累计 origin offset
        switch phase {
        case .began:
            dockSwipeOriginOffset = effectiveDelta
        case .changed:
            guard effectiveDelta != 0 else { return }
            dockSwipeOriginOffset += effectiveDelta
        case .ended, .cancelled:
            break
        }

        // end 相位: 最后位移方向与累计方向相反时视为取消
        var effectivePhase = phase
        if phase == .ended || phase == .cancelled {
            if signOf(dockSwipeLastDelta) != signOf(dockSwipeOriginOffset) {
                effectivePhase = .cancelled
            }
        }

        // 事件 1: NSEventTypeGesture (29) + 辅助值
        let gestureEvent = CGEvent(source: nil)
        gestureEvent?.setIntegerValueField(fieldEventType, value: Int64(NSEvent.EventType.gesture.rawValue))
        gestureEvent?.setIntegerValueField(fieldMystery, value: 33231)

        // 事件 2: NSEventTypeMagnify (30) + dockSwipe 字段
        let dockEvent = CGEvent(source: nil)
        dockEvent?.setIntegerValueField(fieldEventType, value: Int64(NSEvent.EventType.magnify.rawValue))
        dockEvent?.setIntegerValueField(fieldHIDEventType, value: hidEventTypeDockSwipe)
        dockEvent?.setIntegerValueField(fieldEventPhase, value: effectivePhase.rawValue)
        dockEvent?.setIntegerValueField(fieldDockPhase, value: effectivePhase.rawValue)
        dockEvent?.setDoubleValueField(fieldOriginOffset, value: dockSwipeOriginOffset)
        dockEvent?.setIntegerValueField(fieldOriginOffsetEncoded, value: float32Bits(of: dockSwipeOriginOffset))
        dockEvent?.setIntegerValueField(fieldMystery, value: 33231)

        let weirdType = Double(Float(bitPattern: UInt32(axis.rawValue)))
        dockEvent?.setDoubleValueField(fieldDockType, value: weirdType)
        dockEvent?.setDoubleValueField(fieldDockType2, value: weirdType)
        dockEvent?.setDoubleValueField(fieldDockAxis, value: Double(axis.rawValue))
        dockEvent?.setDoubleValueField(fieldDockAxis2, value: Double(axis.rawValue))
        dockEvent?.setIntegerValueField(fieldInvertedFromDevice, value: effectiveInverted ? 1 : 0)

        var exitSpeed: Double?
        if effectivePhase == .ended || effectivePhase == .cancelled {
            exitSpeed = dockSwipeLastDelta * 100
            if let exitSpeed {
                dockEvent?.setDoubleValueField(fieldExitSpeed, value: exitSpeed)
                dockEvent?.setDoubleValueField(fieldExitSpeed2, value: exitSpeed)
            }
        }

        if let dockEvent {
            attachDockSwipeHIDEventIfNeeded(
                to: dockEvent,
                axis: axis,
                phase: effectivePhase,
                progress: dockSwipeOriginOffset,
                velocity: exitSpeed,
                inverted: effectiveInverted
            )
            post(dockEvent, to: .cgSessionEventTap)
        }
        if let gestureEvent {
            post(gestureEvent, to: .cgSessionEventTap)
        }

        dockSwipeLastDelta = effectiveDelta
    }

    /// 重置 dockSwipe 状态 (测试用)
    static func resetDockSwipeStateForTesting() {
        dockSwipeOriginOffset = 0
        dockSwipeLastDelta = 0
    }

    /// Smart Zoom: 触控板双指缩放切换 (Safari/Mail/Preview 等)
    static func postSmartZoomEvent() {
        guard let event = CGEvent(source: nil) else { return }
        event.setIntegerValueField(fieldEventType, value: Int64(NSEvent.EventType.gesture.rawValue))
        event.setIntegerValueField(fieldHIDEventType, value: hidEventTypeZoomToggle)
        post(event)
    }

    /// macOS 27+ 把真实 IOHIDEvent 挂到 dock swipe CGEvent 上.
    /// HID 事件没有 invertedFromDevice 字段, 自然滚动时由 payload 把方向一起取反.
    private static func attachDockSwipeHIDEventIfNeeded(
        to event: CGEvent,
        axis: DockSwipeAxis,
        phase: DockSwipePhase,
        progress: Double,
        velocity: Double?,
        inverted: Bool
    ) {
        guard DockSwipeHIDEvent.isRequired else { return }
        let attached = DockSwipeHIDEvent.attach(
            to: event,
            payload: DockSwipeHIDEvent.payload(
                axis: axis,
                phase: phase,
                progress: progress,
                velocity: velocity,
                inverted: inverted
            )
        )
        if !attached {
            logHIDAttachFailureOnce()
        }
    }

    private static var didLogHIDAttachFailure = false
    private static func logHIDAttachFailureOnce() {
        guard !didLogHIDAttachFailure else { return }
        didLogHIDAttachFailure = true
        NSLog("TouchSimulator: failed to attach dock swipe HID event on macOS 27+")
    }

    private static func post(_ event: CGEvent) {
        post(event, to: .cghidEventTap)
    }

    private static func post(_ event: CGEvent, to tap: CGEventTapLocation) {
        // 标记为 Mos 合成事件, 避免 ScrollCore/ButtonCore 把自身输出当真实输入处理
        event.setIntegerValueField(.eventSourceUserData, value: MosEventMarker.syntheticCustom)
        if let testingPostHook {
            testingPostHook(event)
            return
        }
        event.post(tap: tap)
    }

    private static func signOf(_ value: Double) -> Int {
        if value > 0 { return 1 }
        if value < 0 { return -1 }
        return 0
    }

    private static func float32Bits(of value: Double) -> Int64 {
        return Int64(Float(value).bitPattern)
    }

    /// 定点 delta 转换 (round(d * 2^16))
    private static func fixedScrollDelta(_ value: Double) -> Int64 {
        return Int64((value * 65536).rounded())
    }
}

// MARK: - DockSwipe 类型

enum DockSwipeAxis: Int {
    case horizontal = 1
    case vertical = 2
    case pinch = 3
}

enum DockSwipePhase: Int64 {
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
}

enum GestureScrollPhase: Int64 {
    case began = 1
    case changed = 2
    case ended = 4
}

extension TouchSimulator {
    private static var dockSwipeOriginOffset: Double = 0
    private static var dockSwipeLastDelta: Double = 0
}
