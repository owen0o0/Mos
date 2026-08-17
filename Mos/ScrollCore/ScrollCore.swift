//
//  ScrollCore.swift
//  Mos
//  滚动事件截取与插值计算核心类
//  Created by Caldis on 2017/1/14.
//  Copyright © 2017年 Caldis. All rights reserved.
//

import Cocoa

class ScrollCore: ScrollActionPort, ScrollModificationPort {

    // 单例
    static let shared = ScrollCore()
    init() { NSLog("Module initialized: ScrollCore") }
    
    // 执行状态
    var isActive = false
    // 热键数据
    var dashScroll = false
    var dashAmplification = 1.0
    var toggleScroll = false {
        didSet { ScrollPoster.shared.updateShifting(enable: toggleScroll) }
    }
    var blockSmooth = false
    // 非修饰键热键的按下状态跟踪
    var dashKeyHeld = false
    var toggleKeyHeld = false
    var blockKeyHeld = false
    private var mosDashActionCount = 0
    private var mosToggleActionCount = 0
    private var mosBlockActionCount = 0
    // 例外应用数据
    var application: Application?
    var currentApplication: Application? // 用于区分按下热键及抬起时的作用目标
    // 滚动修饰 (按住按钮期间生效)
    private(set) var activeScrollModifications: Set<ScrollModificationKind> = []
    /// 滚动手势相位控制:
    /// 每个滚轮 tick 重启一个固定时长的动画 (zoom 250ms 缓出曲线 / pinch 180ms 线性),
    /// 动画自然完成发 ended; 方向改变取消动画并丢弃反向 tick
    private var scrollGestureActive = false
    /// 当前手势对应的输出类型
    private var scrollGestureKind: ScrollModificationKind?
    /// 60Hz 平滑输出定时器
    private var scrollGestureOutputTimer: Timer?
    /// 当前动画仍未交付的累计值 (输出单位)
    private var gesturePending: Double = 0
    /// 当前动画窗口内已交付值 (每个 tick 重启动画时清零)
    private var gestureDelivered: Double = 0
    /// 当前动画窗口总值 (pending 快照, 每个 tick 重启时更新)
    private var gestureAnimationTotal: Double = 0
    /// 当前动画窗口起点 (每个 tick 重启时更新)
    private var gestureAnimationStartTime: CFTimeInterval = 0
    /// 当前手势累计 delta (用于方向改变判定)
    private var gestureAccumulatedDelta: Double = 0
    /// 动画时长 (zoom 250ms / pinch 180ms)
    var scrollGestureZoomDuration: TimeInterval = 0.25
    var scrollGesturePinchDuration: TimeInterval = 0.18
    /// 平滑输出间隔 (60Hz)
    var scrollGestureOutputInterval: TimeInterval = 1.0 / 60.0
    /// 加速曲线参数 (中等速度档): 把滚动速度(ticks/s)映射为每格像素
    /// 输出灵敏度不依赖鼠标原始 delta 大小
    let scrollGestureAccelerationXMin = 1.0 / 0.16      // 6.25 ticks/s (consecutiveScrollTickIntervalMax)
    let scrollGestureAccelerationXMax = 1.0 / 0.015     // 66.67 ticks/s (AccelerationEnd)
    let scrollGestureAccelerationYMin = 60.0
    let scrollGestureAccelerationYMax = 120.0
    /// 上次手势输入时间戳 (计算 tick 间隔 → 滚动速度)
    private var lastScrollGestureInputTime: CFTimeInterval = 0
    /// 本次按住期间是否发生过滚动输入 (用于单击/手势干涉判定)
    private(set) var hasReceivedScrollInput = false
    // 拦截层
    var scrollEventInterceptor: Interceptor?
    var hotkeyEventInterceptor: Interceptor?
    var mouseEventInterceptor: Interceptor?
    // 拦截掩码
    let scrollEventMask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let hotkeyEventMask: CGEventMask = {
        let flagsChanged = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let keyDown = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let keyUp = CGEventMask(1 << CGEventType.keyUp.rawValue)
        let otherMouseDown = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        let otherMouseUp = CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        return flagsChanged | keyDown | keyUp | otherMouseDown | otherMouseUp
    }()
    let mouseLeftEventMask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
    
    // MARK: - 滚动事件处理
    let scrollEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        _ = refcon
        // Tap 被系统禁用或重启边界时，强制清理 poster 上下文并失效历史异步帧
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            ScrollPoster.shared.stop(.TrackingEnd)
            return Unmanaged.passUnretained(event)
        }
        if type != .scrollWheel {
            return Unmanaged.passUnretained(event)
        }
        // 跳过 Mos 自己合成的平滑事件，避免重复进入平滑管线
        if ScrollUtils.shared.isSyntheticSmoothEvent(event) {
#if DEBUG
            ScrollPoster.shared.recordSkippedSyntheticEvent()
#endif
            return Unmanaged.passUnretained(event)
        }
        // 跳过 Mos 合成的其它滚动事件 (如双指滑动投递的滚轮事件), 不进修饰/平滑管线
        if event.getIntegerValueField(.eventSourceUserData) == MosEventMarker.syntheticCustom {
            return Unmanaged.passUnretained(event)
        }
        // 滚动修饰 (返回 true = 事件已消费, 不再进入平滑管线)
        if ScrollCore.shared.applyActiveScrollModifications(to: event) {
            return nil
        }
        // 滚动事件
        let scrollEvent = ScrollEvent(with: event)
        let hasVerticalDelta = scrollEvent.Y.valid && scrollEvent.Y.usableValue != 0.0
        let hasHorizontalDelta = scrollEvent.X.valid && scrollEvent.X.usableValue != 0.0
        if hasVerticalDelta || hasHorizontalDelta {
            // 只有真实滚动才会取消 tap replay, 同时触发丢失 mouseUp 的轻量兜底释放。
            InputProcessor.shared.markMosScrollActionSessionsUsedForScroll()
            InputProcessor.shared.releaseMosScrollMouseSessionsIfPhysicalButtonsAreUp()
        }
        // 不处理触控板
        // 无法区分黑苹果, 因为黑苹果的触控板驱动直接模拟鼠标输入
        // 无法区分 Magic Mouse, 因为其滚动特征与内置的 Trackpad 一致
        if scrollEvent.isTrackpad() {
            return Unmanaged.passUnretained(event)
        }
        // 当事件来自远程桌面，且其发送的事件 isContinuous=1.0，此时跳过本地平滑
        if ScrollUtils.shared.isRemoteSmoothedEvent(event) {
            return Unmanaged.passUnretained(event)
        }
        // 当鼠标输入, 根据需要执行翻转方向/平滑滚动
        // 获取事件目标
        let targetRunningApplication = ScrollUtils.shared.getRunningApplication(from: event)
        // 获取列表中应用程序的列外设置信息
        ScrollCore.shared.application = ScrollUtils.shared.getTargetApplication(from: targetRunningApplication)
        // 平滑/翻转
        var enableSmooth = false,
            enableSmoothVertical = false,
            enableSmoothHorizontal = false,
            enableReverseVertical = false,
            enableReverseHorizontal = false
        var step = Options.shared.scroll.step,
            speed = Options.shared.scroll.speed,
            duration = Options.shared.scroll.durationTransition
        if let targetApplication = ScrollCore.shared.application {
            enableSmooth = targetApplication.isSmooth(ScrollCore.shared.blockSmooth)
            enableSmoothVertical = targetApplication.isSmoothVertical(ScrollCore.shared.blockSmooth)
            enableSmoothHorizontal = targetApplication.isSmoothHorizontal(ScrollCore.shared.blockSmooth)
            enableReverseVertical = targetApplication.isReverseVertical()
            enableReverseHorizontal = targetApplication.isReverseHorizontal()
            step = targetApplication.getStep()
            speed = targetApplication.getSpeed()
            duration = targetApplication.getDuration()
        } else if !Options.shared.application.allowlist {
            enableSmooth = Options.shared.scroll.smooth && !ScrollCore.shared.blockSmooth
            enableSmoothVertical = enableSmooth && Options.shared.scroll.smoothVertical
            enableSmoothHorizontal = enableSmooth && Options.shared.scroll.smoothHorizontal
            let allowReverse = Options.shared.scroll.reverse
            enableReverseVertical = allowReverse && Options.shared.scroll.reverseVertical
            enableReverseHorizontal = allowReverse && Options.shared.scroll.reverseHorizontal
        }
        // Launchpad 激活则强制屏蔽平滑
        if ScrollUtils.shared.getLaunchpadActivity(withRunningApplication: targetRunningApplication) {
            enableSmooth = false
            enableSmoothVertical = false
            enableSmoothHorizontal = false
        }
        let willShiftVerticalToHorizontal = ScrollCore.shared.toggleScroll && hasVerticalDelta && !hasHorizontalDelta
        let verticalReversePreference = willShiftVerticalToHorizontal ? enableReverseHorizontal : enableReverseVertical
        if hasVerticalDelta && verticalReversePreference {
            ScrollEvent.reverseY(scrollEvent)
        }
        if hasHorizontalDelta && enableReverseHorizontal {
            ScrollEvent.reverseX(scrollEvent)
        }

        let verticalPreference = willShiftVerticalToHorizontal ? enableSmoothHorizontal : enableSmoothVertical
        var shouldSmoothVertical = hasVerticalDelta && verticalPreference
        var shouldSmoothHorizontal = hasHorizontalDelta && enableSmoothHorizontal

        if !enableSmooth {
            shouldSmoothVertical = false
            shouldSmoothHorizontal = false
        }

        var smoothedY = 0.0
        var smoothedX = 0.0

        if shouldSmoothVertical {
            if scrollEvent.Y.usableValue.magnitude < step {
                ScrollEvent.normalizeY(scrollEvent, step)
            }
            smoothedY = scrollEvent.Y.usableValue
        }
        if shouldSmoothHorizontal {
            if scrollEvent.X.usableValue.magnitude < step {
                ScrollEvent.normalizeX(scrollEvent, step)
            }
            smoothedX = scrollEvent.X.usableValue
        }

        let needVerticalPassthrough = hasVerticalDelta && !shouldSmoothVertical
        let needHorizontalPassthrough = hasHorizontalDelta && !shouldSmoothHorizontal
        let needsPassthrough = needVerticalPassthrough || needHorizontalPassthrough
        let shouldSmoothAny = (smoothedY != 0.0) || (smoothedX != 0.0)

        if shouldSmoothAny {
            ScrollPoster.shared.update(
                event: event,
                duration: duration,
                y: smoothedY,
                x: smoothedX,
                speed: speed,
                amplification: ScrollCore.shared.dashAmplification
            ).tryStart()
        }

        if needsPassthrough {
            if shouldSmoothVertical {
                ScrollEvent.clearY(scrollEvent)
            }
            if shouldSmoothHorizontal {
                ScrollEvent.clearX(scrollEvent)
            }
            return Unmanaged.passUnretained(event)
        }

        if shouldSmoothAny {
            if ScrollPoster.shared.isAvailable {
                return nil
            } else {
                return Unmanaged.passUnretained(event)
            }
        } else {
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - 滚动修饰

    func setScrollModification(_ kind: ScrollModificationKind, active: Bool) {
        assertMainThread()
        if active {
            activeScrollModifications.insert(kind)
        } else {
            activeScrollModifications.remove(kind)
            if activeScrollModifications.isEmpty {
                hasReceivedScrollInput = false
            }
            // 手势进行中若对应修饰被关闭 (松手), 立即结束手势
            if scrollGestureActive, scrollGestureKind == kind {
                finishScrollGesture()
            }
        }
    }

    /// 在滚动事件进入平滑管线前应用按钮滚动修饰 (直接改 CGEvent 轴数据与 flags)
    /// 返回 true 表示事件已被消费 (如四指捏合), 调用方应直接返回 nil
    @discardableResult
    func applyActiveScrollModifications(to event: CGEvent) -> Bool {
        guard !activeScrollModifications.isEmpty else { return false }
        // Mos 自身合成的滚动事件 (如双指滑动) 不应用滚动修饰
        if event.getIntegerValueField(.eventSourceUserData) == MosEventMarker.syntheticCustom {
            return false
        }
        hasReceivedScrollInput = true

        if activeScrollModifications.contains(.fourFingerPinch) {
            handleFourFingerPinch(on: event)
            return true
        }
        if activeScrollModifications.contains(.zoom) {
            handleZoom(on: event)
            return true
        }

        return false
    }

    /// 四指捏合: 滚轮 delta 转为 dockSwipe pinch (显示桌面 / 启动台)
    private func handleFourFingerPinch(on event: CGEvent) {
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        // 方向反转: 原生为 -(dx + dy)/600, 按用户要求反向 → +(dx + dy)/600
        handleScrollGestureInput(kind: .fourFingerPinch, orientedDelta: dx + dy, divisor: 600.0)
    }

    /// 双指捏合缩放: 滚轮 delta 转为 magnification 事件
    private func handleZoom(on event: CGEvent) {
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        // 方向反转: 原生为 (dx + dy)/800, 按用户要求反向 → -(dx + dy)/800
        let orientedDelta = -(dx + dy)

        var firstFrameExtra = 0.0
        var firstFramePhase = GestureScrollPhase.began
        // Chromium 预热: 首帧先发小 began (应用忽略), changed 帧再叠加 380/800 或 250/800
        if !scrollGestureActive, orientedDelta != 0, isChromiumBrowserUnderPointer(event: event) {
            firstFrameExtra = orientedDelta > 0 ? 380.0 / 800.0 : -250.0 / 800.0
            firstFramePhase = .changed
        }
        handleScrollGestureInput(kind: .zoom, orientedDelta: orientedDelta, divisor: 800.0, firstFrameExtra: firstFrameExtra, firstFramePhase: firstFramePhase)
    }

    /// 加速曲线: 按滚动速度(tick/s)返回本格应输出的像素数
    /// 曲线为 BezierCappedAccelerationCurve (curvature 0.25) 的线性近似,
    /// x∈[6.25, 66.67] ticks/s, y∈[60, 120] px, 输出与鼠标原始 delta 大小无关
    private func scrollGesturePixelsPerTick(for rawDelta: Double) -> Double {
        guard rawDelta != 0 else { return 0 }

        let now = CFAbsoluteTimeGetCurrent()
        let interval: CFTimeInterval
        if scrollGestureActive && lastScrollGestureInputTime > 0 {
            interval = min(max(now - lastScrollGestureInputTime, 0.001), 0.16)
        } else {
            interval = 0.16
        }
        lastScrollGestureInputTime = now

        let speed = 1.0 / interval
        let clamped = min(max(speed, scrollGestureAccelerationXMin), scrollGestureAccelerationXMax)
        let progress = (clamped - scrollGestureAccelerationXMin) / (scrollGestureAccelerationXMax - scrollGestureAccelerationXMin)
        let pixels = scrollGestureAccelerationYMin + (scrollGestureAccelerationYMax - scrollGestureAccelerationYMin) * progress

        return rawDelta > 0 ? pixels : -pixels
    }

    /// Chromium 系浏览器 (Chrome/Chromium/Arc/Opera/Edge/Vivaldi/Brave) 对缩放 delta 不敏感
    private func isChromiumBrowserUnderPointer(event: CGEvent) -> Bool {
        guard let bundleID = ScrollUtils.shared.getRunningApplication(from: event)?.bundleIdentifier else {
            return false
        }
        let chromiumBundlePrefixes = [
            "com.google.Chrome",
            "org.chromium.Chromium",
            "company.thebrowser.Browser",
            "com.operasoftware.Opera",
            "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi",
            "com.brave.Browser",
        ]
        return chromiumBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    // MARK: - 滚动手势相位管理

    /// 处理一次手势输入:
    /// 每个 tick 经加速曲线算出像素并追加到动画; 方向改变取消动画并丢弃反向 tick
    private func handleScrollGestureInput(
        kind: ScrollModificationKind,
        orientedDelta: Double,
        divisor: Double,
        firstFrameExtra: Double = 0,
        firstFramePhase: GestureScrollPhase = .began
    ) {
        let inputDelta = scrollGesturePixelsPerTick(for: orientedDelta) / divisor
        guard inputDelta != 0 else { return }

        // 方向改变 → 取消当前动画 (发 ended), 丢弃反向 tick (需用户再次滚动)
        if scrollGestureActive,
           signOf(inputDelta) != 0,
           signOf(gestureAccumulatedDelta) != 0,
           signOf(inputDelta) != signOf(gestureAccumulatedDelta) {
            finishScrollGesture(postEnded: true)
            return
        }

        let isBeginning = !scrollGestureActive
        if isBeginning {
            scrollGestureActive = true
            scrollGestureKind = kind
            gestureAccumulatedDelta = 0
            gesturePending = 0
            gestureDelivered = 0
        }

        // 每个 tick 重启动画, total = 未交付 + 新 tick
        gesturePending += inputDelta
        gestureAccumulatedDelta += inputDelta
        gestureAnimationTotal = gesturePending
        gestureDelivered = 0
        gestureAnimationStartTime = CFAbsoluteTimeGetCurrent()

        startOutputTimer()

        // 首帧同步输出 (首帧 = 一个刷新周期, 相位 began)
        if isBeginning {
            outputFirstFrame(kind: kind, phase: firstFramePhase, extraDelta: firstFrameExtra)
        }
    }

    private func startOutputTimer() {
        scrollGestureOutputTimer?.invalidate()
        let timer = Timer(timeInterval: scrollGestureOutputInterval, repeats: true) { [weak self] _ in
            self?.outputTimerTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollGestureOutputTimer = timer
    }

    private func outputTimerTick() {
        guard scrollGestureActive, let kind = scrollGestureKind else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let duration = gestureAnimationDuration(for: kind)
        let progress = min(max((now - gestureAnimationStartTime) / duration, 0), 1)
        let target = gestureAnimationCurve(kind, progress) * gestureAnimationTotal
        let frame = target - gestureDelivered
        gestureDelivered = target
        gesturePending -= frame

        let isLast = progress >= 1
        if frame != 0 {
            postGestureFrame(kind: kind, delta: frame, phase: isLast ? .ended : .changed)
        }
        if isLast {
            if frame == 0 {
                // 动画结束帧必然发 end 事件
                switch kind {
                case .fourFingerPinch:
                    TouchSimulator.postDockSwipe(delta: 0, axis: .pinch, phase: .ended, inverted: true)
                case .zoom:
                    TouchSimulator.postMagnification(magnification: 0, phase: .ended)
                }
            }
            resetScrollGesture()
        }
    }

    /// 首帧同步输出: 按一个刷新周期 (1/60s) 的曲线进度输出;
    /// Chromium 预热时先发 began (首帧值, 应用忽略), 再发 changed (首帧值 + 预热量)
    private func outputFirstFrame(kind: ScrollModificationKind, phase: GestureScrollPhase, extraDelta: Double) {
        let duration = gestureAnimationDuration(for: kind)
        let progress = min((1.0 / 60.0) / duration, 1)
        let target = gestureAnimationCurve(kind, progress) * gestureAnimationTotal
        let frame = target - gestureDelivered
        gestureDelivered = target
        gesturePending -= frame
        if extraDelta != 0 {
            postGestureFrame(kind: kind, delta: frame, phase: .began)
            postGestureFrame(kind: kind, delta: frame + extraDelta, phase: .changed)
        } else {
            postGestureFrame(kind: kind, delta: frame, phase: phase)
        }
    }

    private func postGestureFrame(kind: ScrollModificationKind, delta: Double, phase: GestureScrollPhase) {
        guard delta != 0 else { return }
        switch kind {
        case .fourFingerPinch:
            let dockPhase = DockSwipePhase(rawValue: phase.rawValue) ?? .changed
            TouchSimulator.postDockSwipe(delta: delta, axis: .pinch, phase: dockPhase, inverted: true)
        case .zoom:
            TouchSimulator.postMagnification(magnification: delta, phase: phase)
        }
    }

    /// 动画时长: zoom 250ms / pinch 180ms
    private func gestureAnimationDuration(for kind: ScrollModificationKind) -> TimeInterval {
        switch kind {
        case .zoom: return scrollGestureZoomDuration
        case .fourFingerPinch: return scrollGesturePinchDuration
        }
    }

    /// 动画曲线 (归一化进度 x ∈ [0,1] → 已交付比例):
    /// - zoom: 贝塞尔 [(0,0),(0,0),(0.5,1),(1,1)], 参数 t 满足 x=1.5t²-0.5t³, y=3t²-2t³
    /// - pinch: 线性 y=x
    private func gestureAnimationCurve(_ kind: ScrollModificationKind, _ progress: Double) -> Double {
        switch kind {
        case .zoom: return zoomTouchDriverCurveY(atX: progress)
        case .fourFingerPinch: return progress
        }
    }

    /// 缓出曲线: Newton 求 x(t)=1.5t²-0.5t³ 的参数 t, 返回 y=3t²-2t³
    private func zoomTouchDriverCurveY(atX x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<5 {
            let f = 1.5 * t * t - 0.5 * t * t * t - x
            let fp = 3.0 * t - 1.5 * t * t
            guard fp > 0.0001 else { break }
            t -= f / fp
        }
        return 3.0 * t * t - 2.0 * t * t * t
    }

    /// 结束手势: 发 ended(0) (取消/松手) 并复位
    private func finishScrollGesture(postEnded: Bool = true) {
        scrollGestureOutputTimer?.invalidate()
        scrollGestureOutputTimer = nil
        guard scrollGestureActive, let kind = scrollGestureKind else { return }
        if postEnded {
            switch kind {
            case .fourFingerPinch:
                TouchSimulator.postDockSwipe(delta: 0, axis: .pinch, phase: .ended, inverted: true)
            case .zoom:
                TouchSimulator.postMagnification(magnification: 0, phase: .ended)
            }
        }
        resetScrollGesture()
    }

    private func resetScrollGesture() {
        scrollGestureOutputTimer?.invalidate()
        scrollGestureOutputTimer = nil
        scrollGestureActive = false
        scrollGestureKind = nil
        gestureAccumulatedDelta = 0
        gesturePending = 0
        gestureDelivered = 0
        gestureAnimationTotal = 0
        gestureAnimationStartTime = 0
    }

    /// 测试清理: 取消未决定时器且不投递事件
    func cancelScrollGestureForTesting() {
        resetScrollGesture()
    }

    private func signOf(_ value: Double) -> Int {
        if value > 0 { return 1 }
        if value < 0 { return -1 }
        return 0
    }

    // MARK: - HID++ 滚动热键处理

    /// 跟踪当前由哪个 HID++ 按键码激活了热键状态
    /// key-up 时按 code 清除, 不依赖当前 app 的热键配置, 避免跨应用释放时状态卡死
    private var hidDashHeldCode: UInt16?
    private var hidToggleHeldCode: UInt16?
    private var hidBlockHeldCode: UInt16?

    func handleMosScrollAction(role: ScrollRole, isDown: Bool) {
        assertMainThread()
        switch role {
        case .dash:
            mosDashActionCount = updatedActionCount(mosDashActionCount, isDown: isDown)
            refreshDashState()
        case .toggle:
            mosToggleActionCount = updatedActionCount(mosToggleActionCount, isDown: isDown)
            refreshToggleState()
        case .block:
            mosBlockActionCount = updatedActionCount(mosBlockActionCount, isDown: isDown)
            refreshBlockState()
        }
    }

    private func updatedActionCount(_ count: Int, isDown: Bool) -> Int {
        if isDown {
            return count + 1
        }
        return max(0, count - 1)
    }

    private func refreshDashState() {
        dashScroll = dashKeyHeld || mosDashActionCount > 0
        dashAmplification = dashScroll ? 5.0 : 1.0
    }

    private func refreshToggleState() {
        toggleScroll = toggleKeyHeld || mosToggleActionCount > 0
    }

    private func refreshBlockState() {
        blockSmooth = blockKeyHeld || mosBlockActionCount > 0
    }

    /// 处理来自 Logitech HID++ 的按键事件, 匹配 dash/toggle/block 滚动热键
    @discardableResult
    func handleScrollHotkey(code: UInt16, isDown: Bool) -> Bool {
        assertMainThread()
        // Key-up: 按跟踪的 code 清除状态 (不依赖当前 app 配置, 防止焦点切换导致状态卡死)
        if !isDown {
            var matched = false
            if hidDashHeldCode == code {
                dashKeyHeld = false
                hidDashHeldCode = nil
                refreshDashState()
                matched = true
            }
            if hidToggleHeldCode == code {
                toggleKeyHeld = false
                hidToggleHeldCode = nil
                refreshToggleState()
                matched = true
            }
            if hidBlockHeldCode == code {
                blockKeyHeld = false
                hidBlockHeldCode = nil
                refreshBlockState()
                matched = true
            }
            return matched
        }

        // Key-down: 刷新前台应用上下文 (HID++ 事件不经过滚动事件路径, application 可能陈旧)
        application = ScrollUtils.shared.getTargetApplication(from: NSWorkspace.shared.frontmostApplication)

        let dashHotkey = ScrollUtils.shared.optionsDashKey(application: application)
        let toggleHotkey = ScrollUtils.shared.optionsToggleKey(application: application)
        let blockHotkey = ScrollUtils.shared.optionsBlockKey(application: application)

        var matched = false

        if let h = dashHotkey, h.type == .mouse, h.code == code {
            dashKeyHeld = true
            hidDashHeldCode = code
            refreshDashState()
            matched = true
        }
        if let h = toggleHotkey, h.type == .mouse, h.code == code {
            toggleKeyHeld = true
            hidToggleHeldCode = code
            refreshToggleState()
            matched = true
        }
        if let h = blockHotkey, h.type == .mouse, h.code == code {
            blockKeyHeld = true
            hidBlockHeldCode = code
            refreshBlockState()
            matched = true
        }

        return matched
    }

    // MARK: - 热键事件处理 (CGEventTap)
    let hotkeyEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        // 跳过 Mos 合成事件, 避免 executeCustom 的 flagsChanged 误触发 dash/toggle/block
        if event.getIntegerValueField(.eventSourceUserData) == MosEventMarker.syntheticCustom {
            return nil  // listenOnly tap 返回值无影响
        }
        if type == .keyDown || type == .flagsChanged || type == .otherMouseDown,
           ScrollCore.shared.shouldDeferToMosScrollButtonBinding(event) {
            // Mos Scroll 动作由 ButtonCore/InputProcessor 接管。若同一触发器也被旧滚动
            // 热键配置使用, listenOnly tap 不能再创建第二份 held 状态。
            return nil
        }

        let keyCode = event.keyCode
        let mouseButton = UInt16(event.getIntegerValueField(.mouseEventButtonNumber))

        // 判断事件类型
        let isMouseEvent = (type == .otherMouseDown || type == .otherMouseUp)
        let isKeyDown = (type == .keyDown || type == .otherMouseDown)
        let isKeyUp = (type == .keyUp || type == .otherMouseUp)
        let isFlagsChanged = (type == .flagsChanged)

        // 记录按键时的目标应用
        if (event.isKeyDown || isKeyDown) && ScrollCore.shared.currentApplication == nil {
            ScrollCore.shared.currentApplication = ScrollCore.shared.application
        }

        // 获取配置的热键
        let dashHotkey = ScrollUtils.shared.optionsDashKey(application: ScrollCore.shared.application)
        let toggleHotkey = ScrollUtils.shared.optionsToggleKey(application: ScrollCore.shared.application)
        let blockHotkey = ScrollUtils.shared.optionsBlockKey(application: ScrollCore.shared.application)

        // 检测热键是否匹配并更新状态
        func checkAndUpdateHotkey(_ hotkey: ScrollHotkey?, keyHeld: inout Bool) -> Bool? {
            guard let hotkey = hotkey else { return nil }

            if hotkey.isModifierKey {
                // 修饰键：通过 flagsChanged 事件检测
                if isFlagsChanged && keyCode == hotkey.code {
                    return event.flags.contains(hotkey.modifierMask)
                }
            } else if hotkey.matches(event, keyCode: keyCode, mouseButton: mouseButton, isMouseEvent: isMouseEvent) {
                // 普通按键或鼠标按键
                if isKeyDown { keyHeld = true }
                if isKeyUp { keyHeld = false }
                return keyHeld
            }
            return nil
        }

        // Dash
        if let isPressed = checkAndUpdateHotkey(dashHotkey, keyHeld: &ScrollCore.shared.dashKeyHeld) {
            ScrollCore.shared.dashKeyHeld = isPressed
            ScrollCore.shared.refreshDashState()
        }
        // Toggle
        if let isPressed = checkAndUpdateHotkey(toggleHotkey, keyHeld: &ScrollCore.shared.toggleKeyHeld) {
            ScrollCore.shared.toggleKeyHeld = isPressed
            ScrollCore.shared.refreshToggleState()
        }
        // Block
        if let isPressed = checkAndUpdateHotkey(blockHotkey, keyHeld: &ScrollCore.shared.blockKeyHeld) {
            ScrollCore.shared.blockKeyHeld = isPressed
            ScrollCore.shared.refreshBlockState()
        }

        // 处理抬起时焦点 App 变化
        let isAppTargetChanged = ScrollCore.shared.currentApplication != ScrollCore.shared.application
        let isAnyKeyUp = event.isKeyUp || isKeyUp
        if isAppTargetChanged && isAnyKeyUp {
            // 重置按键状态
            ScrollCore.shared.dashKeyHeld = false
            ScrollCore.shared.toggleKeyHeld = false
            ScrollCore.shared.blockKeyHeld = false
            ScrollCore.shared.refreshDashState()
            ScrollCore.shared.refreshToggleState()
            ScrollCore.shared.refreshBlockState()
            // 并更新记录器
            ScrollCore.shared.currentApplication = nil
        }
        // 不返回原始事件
        return nil
    }

    private func shouldDeferToMosScrollButtonBinding(_ event: CGEvent) -> Bool {
        let inputEvent = InputEvent(fromCGEvent: event)
        return ButtonUtils.shared.getBestMatchingBinding(
            for: inputEvent,
            where: { ShortcutExecutor.isMosScrollActionIdentifier($0.systemShortcutName) }
        ) != nil
    }
    
    // MARK: - 鼠标事件处理
    let mouseLeftEventCallBack: CGEventTapCallBack = { (proxy, type, event, refcon) in
        // 如果点击左键则停止滚动
        ScrollPoster.shared.stop()
        return nil
    }
    
    // MARK: - 事件运行管理
    // 启动
    func enable() {
        // Guard
        if isActive { return }
        isActive = true
        // 启动事件拦截层
        do {
            scrollEventInterceptor = try Interceptor(
                event: scrollEventMask,
                handleBy: scrollEventCallBack,
                listenOn: .cgAnnotatedSessionEventTap,
                placeAt: .tailAppendEventTap,
                for: .defaultTap
            )
            scrollEventInterceptor?.onRestart = {
                ScrollPoster.shared.stop(.TrackingEnd)
            }
            hotkeyEventInterceptor = try Interceptor(
                event: hotkeyEventMask,
                handleBy: hotkeyEventCallBack,
                listenOn: .cgAnnotatedSessionEventTap,
                placeAt: .tailAppendEventTap,
                for: .listenOnly
            )
            mouseEventInterceptor = try Interceptor(
                event: mouseLeftEventMask,
                handleBy: mouseLeftEventCallBack,
                listenOn: .cgAnnotatedSessionEventTap,
                placeAt: .tailAppendEventTap,
                for: .listenOnly
            )
            // 初始化滚动事件发送器
            ScrollPoster.shared.create()
            ScrollPoster.shared.startKeeper()
        } catch {
            print("[ScrollCore] Create Interceptor failure: \(error)")
        }
    }
    // 停止
    func disable() {
        // Guard
        if !isActive {return}
        isActive = false
        // 停止滚动事件发送器
        ScrollPoster.shared.stop()
        ScrollPoster.shared.stopKeeper()
        // 停止截取事件
        scrollEventInterceptor?.stop()
        hotkeyEventInterceptor?.stop()
        mouseEventInterceptor?.stop()
        // 显式释放, 避免旧 tap 残留在对象图中
        scrollEventInterceptor = nil
        hotkeyEventInterceptor = nil
        mouseEventInterceptor = nil
    }
}
