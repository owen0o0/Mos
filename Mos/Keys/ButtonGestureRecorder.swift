//
//  ButtonGestureRecorder.swift
//  Mos
//  按钮手势录制器: 录制时自动识别触发类型
//
//  识别规则 (优先级从高到低):
//  - 按住期间滚动 → 按住并滚动
//  - 按住期间位移超过阈值 → 按住并拖动
//  - 按住超过 holdThreshold → 长按
//  - 快速按下松开 → 单击 / 双击 / 三击 (点击次数)
//  Created by Claude on 2026/8/17.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

protocol ButtonGestureRecorderDelegate: AnyObject {
    func buttonGestureRecorder(
        _ recorder: ButtonGestureRecorder,
        didRecord button: UInt16,
        modifiers: CGEventFlags,
        trigger: ButtonTrigger
    )
    func buttonGestureRecorderDidCancel(_ recorder: ButtonGestureRecorder)
}

final class ButtonGestureRecorder {

    weak var delegate: ButtonGestureRecorderDelegate?
    private(set) var isRecording = false

    /// CGEventTap 回调无法捕获上下文, 通过静态弱引用取当前录制器 (同一时间只有一个在录制)
    private static weak var activeRecorder: ButtonGestureRecorder?

    // MARK: - 阈值 (测试可注入)

    /// 长按判定延时
    var holdThreshold: TimeInterval = 0.35
    /// 双击/三击判定窗口 (与引擎 levelExpiryDelay 一致, 0.26s)
    var clickWindow: TimeInterval = 0.26
    /// 拖拽判定位移 (pt)
    var dragThreshold: CGFloat = 15
    /// 总超时 (秒)
    var timeout: TimeInterval = 10
    /// 拖拽检测轮询间隔
    var pollInterval: TimeInterval = 1.0 / 60.0
    /// 鼠标位置来源 (测试注入)
    var locationProvider: () -> CGPoint = {
        let location = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        return CGPoint(x: location.x, y: screenHeight - location.y)
    }

    // MARK: - 状态

    private var interceptor: Interceptor?
    private var hidEventObserver: NSObjectProtocol?
    private var keyPopover: KeyPopover?

    private var currentButton: UInt16?
    private var currentModifiers: CGEventFlags = []
    private var clickCount = 0
    private var isHeld = false
    private var dragDetected = false
    private var scrollDetected = false
    private var pressLocation: CGPoint?
    private var holdTimer: Timer?
    private var clickWindowTimer: Timer?
    private var timeoutTimer: Timer?
    private var pollTimer: Timer?

    // MARK: - 录制控制

    func startRecording(from sourceView: NSView) {
        assertMainThread()
        guard !isRecording else { return }
        isRecording = true
        Self.activeRecorder = self
        resetSession()

        keyPopover = KeyPopover()
        keyPopover?.show(at: sourceView)
        LogiCenter.shared.beginKeyRecording()

        installEventTap()
        observeHIDEvents()
        startTimeoutTimer()
    }

    func stopRecording() {
        assertMainThread()
        isRecording = false
        if Self.activeRecorder === self {
            Self.activeRecorder = nil
        }
        cancelTimers()
        resetSession()
        interceptor?.stop()
        interceptor = nil
        if let observer = hidEventObserver {
            NotificationCenter.default.removeObserver(observer)
            hidEventObserver = nil
        }
        keyPopover?.hide()
        keyPopover = nil
        LogiCenter.shared.endKeyRecording()
    }

    func cancel() {
        delegate?.buttonGestureRecorderDidCancel(self)
        stopRecording()
    }

    // MARK: - 测试钩子 (不安装事件 tap / UI)

    func beginTestingSessionForTests() {
        isRecording = true
        resetSession()
    }

    func stopTestingSessionForTests() {
        isRecording = false
        cancelTimers()
        resetSession()
    }

    // MARK: - 事件处理 (主线程, 测试可直接调用)

    func handleButtonDown(button: UInt16, modifiers: CGEventFlags) {
        assertMainThread()
        guard isRecording else { return }

        // 会话未开始: 用第一个按下的按钮建立会话
        if currentButton == nil {
            currentButton = button
            currentModifiers = modifiers
            clickCount = 1
            beginPress()
            return
        }

        // 同一按钮再次按下 (双击/三击的第二、三击)
        guard button == currentButton else { return }
        clickWindowTimer?.invalidate()
        clickWindowTimer = nil
        clickCount += 1
        beginPress()
    }

    func handleButtonUp(button: UInt16) {
        assertMainThread()
        guard isRecording, button == currentButton else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil

        if dragDetected {
            finalize(.drag, level: 1)
        } else if scrollDetected {
            finalize(.scroll, level: 1)
        } else if isHeld {
            finalize(.hold, level: 1)
        } else {
            // 快速点击: 等待窗口判定单击/双击/三击
            let timer = Timer(timeInterval: clickWindow, repeats: false) { [weak self] _ in
                self?.finalizeClick()
            }
            RunLoop.main.add(timer, forMode: .common)
            clickWindowTimer = timer
        }
    }

    func handleScrollInput() {
        assertMainThread()
        guard isRecording, currentButton != nil else { return }
        scrollDetected = true
        finalize(.scroll, level: 1)
    }

    func handlePoll() {
        assertMainThread()
        guard isRecording, currentButton != nil, !dragDetected, let pressLocation else { return }
        let location = locationProvider()
        let distance = hypot(pressLocation.x - location.x, pressLocation.y - location.y)
        if distance >= dragThreshold {
            dragDetected = true
            finalize(.drag, level: 1)
        }
    }

    // MARK: - 会话内部

    private func beginPress() {
        isHeld = false
        dragDetected = false
        scrollDetected = false
        pressLocation = locationProvider()

        holdTimer?.invalidate()
        let holdTimer = Timer(timeInterval: holdThreshold, repeats: false) { [weak self] _ in
            self?.handleHoldElapsed()
        }
        RunLoop.main.add(holdTimer, forMode: .common)
        self.holdTimer = holdTimer

        pollTimer?.invalidate()
        let pollTimer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.handlePoll()
        }
        RunLoop.main.add(pollTimer, forMode: .common)
        self.pollTimer = pollTimer
    }

    private func handleHoldElapsed() {
        guard isRecording, currentButton != nil else { return }
        isHeld = true
        finalize(.hold, level: 1)
    }

    private func finalizeClick() {
        finalize(.click, level: min(max(clickCount, 1), 3))
    }

    private func finalize(_ duration: ButtonTriggerDuration, level: Int) {
        guard let button = currentButton else { return }
        let modifiers = currentModifiers
        let trigger = ButtonTrigger(buttonNumber: button, level: level, duration: duration)
        stopRecording()
        delegate?.buttonGestureRecorder(self, didRecord: button, modifiers: modifiers, trigger: trigger)
    }

    private func resetSession() {
        currentButton = nil
        currentModifiers = []
        clickCount = 0
        isHeld = false
        dragDetected = false
        scrollDetected = false
        pressLocation = nil
    }

    private func cancelTimers() {
        holdTimer?.invalidate()
        holdTimer = nil
        clickWindowTimer?.invalidate()
        clickWindowTimer = nil
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startTimeoutTimer() {
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            self?.cancel()
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer
    }

    // MARK: - 事件接入

    private func installEventTap() {
        let leftDown = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
        let leftUp = CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        let scroll = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        let keyDown = CGEventMask(1 << CGEventType.keyDown.rawValue)

        do {
            interceptor = try Interceptor(
                event: leftDown | leftUp | scroll | keyDown,
                handleBy: { (_, type, event, _) in
                    let recorder = ButtonGestureRecorder.activeRecorder
                    // Mos 合成事件不消费 (避免吞掉平滑滚动等)
                    if event.getIntegerValueField(.eventSourceUserData) == MosEventMarker.syntheticCustom {
                        return Unmanaged.passUnretained(event)
                    }
                    switch type {
                    case .otherMouseDown:
                        let button = UInt16(event.getIntegerValueField(.mouseEventButtonNumber))
                        let modifiers = event.flags
                        DispatchQueue.main.async {
                            recorder?.handleButtonDown(button: button, modifiers: modifiers)
                        }
                        return nil  // 消费录制的按钮, 防止引擎/系统响应
                    case .otherMouseUp:
                        let button = UInt16(event.getIntegerValueField(.mouseEventButtonNumber))
                        DispatchQueue.main.async {
                            recorder?.handleButtonUp(button: button)
                        }
                        return nil
                    case .scrollWheel:
                        DispatchQueue.main.async {
                            recorder?.handleScrollInput()
                        }
                        return Unmanaged.passUnretained(event)
                    case .keyDown:
                        if event.keyCode == KeyCode.escape {
                            DispatchQueue.main.async {
                                recorder?.cancel()
                            }
                            return nil
                        }
                        return Unmanaged.passUnretained(event)
                    default:
                        return Unmanaged.passUnretained(event)
                    }
                },
                listenOn: CGEventTapLocation.cgSessionEventTap,
                placeAt: CGEventTapPlacement.headInsertEventTap,
                for: CGEventTapOptions.defaultTap
            )
        } catch {
            NSLog("[ButtonGestureRecorder] Failed to start event tap: \(error)")
            isRecording = false
        }
    }

    private func observeHIDEvents() {
        hidEventObserver = NotificationCenter.default.addObserver(
            forName: LogiCenter.buttonEventRelay,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, self.isRecording else { return }
            guard let event = notification.userInfo?["event"] as? InputEvent else { return }
            switch event.phase {
            case .down:
                self.handleButtonDown(button: event.code, modifiers: event.modifiers)
            case .up:
                self.handleButtonUp(button: event.code)
            }
        }
    }
}
