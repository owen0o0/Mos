//
//  GestureScrollAdapter.swift
//  Mos
//  有些 App (iPhone 镜像等) 吃 HID/触控板式手势, 不吃 annotated session 里改过的滚轮.
//  反转开启时: HID 头拦截原始滚轮, 改投 gesture scroll.
//  目标按「事件 PID 或鼠标下的窗口」判断, 窗口未激活也能反转.
//  新的同类 App 把 bundle ID 加进 GestureScrollTarget.builtInBundleIDs 即可.
//

import Cocoa

enum GestureScrollTarget {
    /// 内置: 只吃 HID/手势滚轮的 App. 不写进用户配置, 避免改持久化格式.
    static let builtInBundleIDs: Set<String> = [
        "com.apple.ScreenContinuity",
    ]

    #if DEBUG
    static var testingAdditionalBundleIDs: Set<String> = []
    /// 单测替换「鼠标下的窗口是否为目标 App」, 避免依赖真实窗口层级.
    static var testingMatchesUnderPointer: Bool?
    #endif

    static var knownBundleIDs: Set<String> {
        #if DEBUG
        return builtInBundleIDs.union(testingAdditionalBundleIDs)
        #else
        return builtInBundleIDs
        #endif
    }

    static func matches(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return knownBundleIDs.contains(bundleIdentifier)
    }

    static func matches(_ application: NSRunningApplication?) -> Bool {
        return matches(bundleIdentifier: application?.bundleIdentifier)
    }

    /// 事件 PID 是目标, 或鼠标下的窗口是目标. 不要求前台激活.
    static func isEventTarget(_ event: CGEvent) -> Bool {
        return resolvedApplication(for: event) != nil
    }

    static func resolvedApplication(for event: CGEvent) -> NSRunningApplication? {
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        if pid > 1, let app = NSRunningApplication(processIdentifier: pid), matches(app) {
            return app
        }
        #if DEBUG
        if let forced = testingMatchesUnderPointer {
            return forced ? placeholderTargetApplication() : nil
        }
        #endif
        return matchingApplicationUnderPointer(event: event)
    }

    /// MMF: NSWindow.windowNumber(at:) + kCGWindowOwnerPID, 不用 AX (热路径太慢).
    static func matchingApplicationUnderPointer(event: CGEvent) -> NSRunningApplication? {
        let now = CFAbsoluteTimeGetCurrent()
        let point = event.unflippedLocation
        if now - underPointerCache.time < 0.15,
           abs(point.x - underPointerCache.point.x) < 8,
           abs(point.y - underPointerCache.point.y) < 8 {
            return underPointerCache.application
        }
        let application = lookupApplicationUnderPointer(cocoaPoint: point)
        let matched = matches(application) ? application : nil
        underPointerCache = (now, point, matched)
        return matched
    }

    private static var underPointerCache: (time: CFTimeInterval, point: CGPoint, application: NSRunningApplication?) = (0, .zero, nil)

    private static func lookupApplicationUnderPointer(cocoaPoint: CGPoint) -> NSRunningApplication? {
        let windowNumber = NSWindow.windowNumber(at: cocoaPoint, belowWindowWithWindowNumber: 0)
        guard windowNumber > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowNumber)) as? [[String: Any]],
              let pidValue = info.first?[kCGWindowOwnerPID as String] as? NSNumber
        else {
            return nil
        }
        let pid = pid_t(truncating: pidValue)
        guard pid > 1 else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    #if DEBUG
    private static func placeholderTargetApplication() -> NSRunningApplication? {
        return NSRunningApplication.current
    }
    #endif
}

struct GestureScrollAxisOptions: Equatable {
    var reverseVertical: Bool
    var reverseHorizontal: Bool
    var step: Double
}

struct GestureScrollPlan: Equatable {
    var swallow: Bool
    var deltaX: Double
    var deltaY: Double

    static let pass = GestureScrollPlan(swallow: false, deltaX: 0, deltaY: 0)
}

enum GestureScrollAdapter {
    static func axisOptions(application: Application?) -> GestureScrollAxisOptions {
        if let application {
            return GestureScrollAxisOptions(
                reverseVertical: application.isReverseVertical(),
                reverseHorizontal: application.isReverseHorizontal(),
                step: application.getStep()
            )
        }
        if Options.shared.application.allowlist {
            return GestureScrollAxisOptions(
                reverseVertical: false,
                reverseHorizontal: false,
                step: Options.shared.scroll.step
            )
        }
        let allowReverse = Options.shared.scroll.reverse
        return GestureScrollAxisOptions(
            reverseVertical: allowReverse && Options.shared.scroll.reverseVertical,
            reverseHorizontal: allowReverse && Options.shared.scroll.reverseHorizontal,
            step: Options.shared.scroll.step
        )
    }

    /// 离散滚轮只有 line delta 时, 扩成足够手势识别的像素位移.
    static func pixelDeltas(from event: ScrollEvent, step: Double) -> (x: Double, y: Double) {
        func pixel(_ axis: axisData) -> Double {
            guard axis.valid, axis.usableValue != 0 else { return 0 }
            if !axis.fixed {
                return axis.usableValue
            }
            let scale = max(step, 24.0)
            return axis.usableValue > 0 ? scale : -scale
        }
        return (pixel(event.X), pixel(event.Y))
    }

    static func directedDeltas(
        x: Double,
        y: Double,
        reverseVertical: Bool,
        reverseHorizontal: Bool
    ) -> (x: Double, y: Double) {
        return (
            reverseHorizontal ? -x : x,
            reverseVertical ? -y : y
        )
    }

    static func shouldConvert(
        isTarget: Bool,
        reverseVertical: Bool,
        reverseHorizontal: Bool,
        pixelX: Double,
        pixelY: Double
    ) -> Bool {
        guard isTarget else { return false }
        if reverseVertical && pixelY != 0 { return true }
        if reverseHorizontal && pixelX != 0 { return true }
        return false
    }

    static func plan(
        isTarget: Bool,
        pixelX: Double,
        pixelY: Double,
        reverseVertical: Bool,
        reverseHorizontal: Bool,
        shiftVerticalToHorizontal: Bool
    ) -> GestureScrollPlan {
        guard shouldConvert(
            isTarget: isTarget,
            reverseVertical: reverseVertical,
            reverseHorizontal: reverseHorizontal,
            pixelX: pixelX,
            pixelY: pixelY
        ) else {
            return .pass
        }

        let reverseY = shiftVerticalToHorizontal ? reverseHorizontal : reverseVertical
        var x = pixelX
        var y = pixelY
        if y != 0 && reverseY { y = -y }
        if x != 0 && reverseHorizontal { x = -x }
        if shiftVerticalToHorizontal && y != 0 && x == 0 {
            x = y
            y = 0
        }
        return GestureScrollPlan(swallow: true, deltaX: x, deltaY: y)
    }
}

/// 把连续滚轮 tick 收成 began/changed/ended 手势流.
final class GestureScrollBridge {
    static let shared = GestureScrollBridge()

    var endDelay: TimeInterval = 0.12
    private var started = false
    private var endTimer: Timer?

    func handle(deltaX: Double, deltaY: Double) {
        if deltaX == 0 && deltaY == 0 { return }
        runOnMain { [weak self] in
            self?.post(deltaX: deltaX, deltaY: deltaY)
        }
    }

    func reset() {
        runOnMain { [weak self] in
            self?.endNow()
        }
    }

    private func post(deltaX: Double, deltaY: Double) {
        let phase: GestureScrollPhase = started ? .changed : .began
        started = true
        TouchSimulator.postGestureScroll(
            deltaX: deltaX,
            deltaY: deltaY,
            phase: phase,
            inverted: true,
            tap: .cghidEventTap
        )
        scheduleEnd()
    }

    private func scheduleEnd() {
        endTimer?.invalidate()
        let timer = Timer(timeInterval: endDelay, repeats: false) { [weak self] _ in
            self?.endNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
    }

    private func endNow() {
        endTimer?.invalidate()
        endTimer = nil
        guard started else { return }
        started = false
        TouchSimulator.postGestureScroll(
            deltaX: 0,
            deltaY: 0,
            phase: .ended,
            inverted: true,
            tap: .cghidEventTap
        )
    }

    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
