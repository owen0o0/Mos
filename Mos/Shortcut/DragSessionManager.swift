//
//  DragSessionManager.swift
//  Mos
//  拖拽会话管理
//
//  - twoFingerSwipe: 拖拽位移转为双指滚动手势 (页面导航)
//  - threeFingerSwipe: 拖拽位移转为 dockSwipe 手势 (调度中心/程序切换/页面导航)
//  Created by Claude on 2026/8/17.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

final class DragSessionManager {

    static let shared = DragSessionManager()
    init() { NSLog("Module initialized: DragSessionManager") }

    // MARK: - 配置

    /// 手势滑动启动阈值 (pt): 位移超过该值才开始投递 dockSwipe
    var gestureStartThreshold: CGFloat = 7
    /// 双指滑动平滑帧数 (3 帧线性平滑, duration = 3/60s)
    var twoFingerSmoothingFrames: Int = 3
    /// 轮询间隔 (秒)
    var pollInterval: TimeInterval = 1.0 / 60.0

    /// 鼠标位置来源 (测试注入)
    var locationProvider: () -> CGPoint = {
        let location = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0
        return CGPoint(x: location.x, y: screenHeight - location.y)
    }

    // MARK: - 测试钩子

    /// 测试时拦截合成鼠标/手势事件
    var testingPostHook: ((CGEvent) -> Void)?

    // MARK: - 状态

    private var activeMode: DragMode?
    private var pollTimer: Timer?
    private var lastLocation: CGPoint?
    /// 手势滑动累计位移 (axis 判定前)
    private var gestureAccumulator = (x: 0.0, y: 0.0)
    /// 手势滑动是否已启动 (超过阈值)
    private var gestureStarted = false
    /// 手势滑动当前轴
    private var dockAxis: DockSwipeAxis?
    /// 双指滑动平滑缓冲 (3 帧移动平均)
    private var twoFingerBuffer: [(x: Double, y: Double)] = []
    /// 本次拖拽开始时快照的系统自然滚动, 避免手势中途翻转或每帧打偏好缓存
    private var sessionNaturalDirection = true

    var isActive: Bool { activeMode != nil }

    /// 本次手势是否已真正使用 (手势滑动开始)
    var hasStartedDrag: Bool {
        return gestureStarted
    }

    // MARK: - 会话控制

    func start(mode: DragMode) {
        assertMainThread()
        guard activeMode == nil else { return }
        activeMode = mode
        gestureAccumulator = (x: 0.0, y: 0.0)
        gestureStarted = false
        dockAxis = nil
        twoFingerBuffer.removeAll()
        sessionNaturalDirection = SystemScrollingPreferences.isNaturalScrollingEnabled
        let startLocation = locationProvider()
        lastLocation = startLocation

        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        assertMainThread()
        guard let mode = activeMode else { return }
        activeMode = nil
        pollTimer?.invalidate()
        pollTimer = nil

        switch mode {
        case .threeFingerSwipe:
            if gestureStarted, let axis = dockAxis {
                TouchSimulator.postDockSwipe(delta: 0, axis: axis, phase: .ended, inverted: naturalDirection)
            }
        case .twoFingerSwipe:
            if gestureStarted {
                TouchSimulator.postGestureScroll(deltaX: 0, deltaY: 0, phase: .ended, inverted: naturalDirection)
            }
        }
        gestureStarted = false
        dockAxis = nil
        lastLocation = nil
    }

    /// 强制结束 (ButtonCore 禁用等场景)
    func killAll() {
        stop()
    }

    // MARK: - 轮询

    private func poll() {
        guard let mode = activeMode else { return }
        let location = locationProvider()
        defer { lastLocation = location }

        switch mode {
        case .twoFingerSwipe, .threeFingerSwipe:
            guard let last = lastLocation else { return }
            let dx = Double(location.x - last.x)
            let dy = Double(location.y - last.y)
            if mode == .threeFingerSwipe {
                handleDockSwipe(dx: dx, dy: dy)
            } else {
                handleTwoFingerSwipe(dx: dx, dy: dy)
            }
        }
    }

    private func handleTwoFingerSwipe(dx: Double, dy: Double) {
        guard gestureStarted else {
            gestureAccumulator.x += dx
            gestureAccumulator.y += dy
            let threshold = Double(gestureStartThreshold)
            guard abs(gestureAccumulator.x) >= threshold || abs(gestureAccumulator.y) >= threshold else { return }
            gestureStarted = true
            // 启动: 累计位移补零到 N 帧, 从首帧起按平均输出 (线性摊到 N 帧, duration=3/60s)
            twoFingerBuffer = Array(repeating: (x: 0.0, y: 0.0), count: max(twoFingerSmoothingFrames - 1, 0))
            twoFingerBuffer.append((x: gestureAccumulator.x, y: gestureAccumulator.y))
            let start = directedTwoFingerDelta(average(of: twoFingerBuffer))
            TouchSimulator.postGestureScroll(
                deltaX: start.x,
                deltaY: start.y,
                phase: .began,
                inverted: naturalDirection
            )
            return
        }
        // 3 帧移动平均: 平滑输入, 输入停止后缓冲自然衰减出尾迹
        twoFingerBuffer.append((x: dx, y: dy))
        let keep = max(twoFingerSmoothingFrames, 0)
        if twoFingerBuffer.count > keep {
            twoFingerBuffer.removeFirst(twoFingerBuffer.count - keep)
        }
        let avg = directedTwoFingerDelta(average(of: twoFingerBuffer))
        TouchSimulator.postGestureScroll(deltaX: avg.x, deltaY: avg.y, phase: .changed, inverted: naturalDirection)
    }

    private func average(of buffer: [(x: Double, y: Double)]) -> (x: Double, y: Double) {
        let count = Double(max(buffer.count, 1))
        let sumX = buffer.reduce(0.0) { $0 + $1.x }
        let sumY = buffer.reduce(0.0) { $0 + $1.y }
        return (x: sumX / count, y: sumY / count)
    }

    private func handleDockSwipe(dx: Double, dy: Double) {
        guard !gestureStarted else {
            guard let axis = dockAxis else { return }
            let delta = scaledDockSwipeDelta(dx: dx, dy: dy, axis: axis)
            TouchSimulator.postDockSwipe(delta: delta, axis: axis, phase: .changed, inverted: naturalDirection)
            return
        }

        gestureAccumulator.x += dx
        gestureAccumulator.y += dy
        let threshold = Double(gestureStartThreshold)
        guard abs(gestureAccumulator.x) >= threshold || abs(gestureAccumulator.y) >= threshold else { return }

        gestureStarted = true
        let axis: DockSwipeAxis = abs(gestureAccumulator.x) >= abs(gestureAccumulator.y) ? .horizontal : .vertical
        dockAxis = axis
        let delta = scaledDockSwipeDelta(
            dx: gestureAccumulator.x,
            dy: gestureAccumulator.y,
            axis: axis
        )
        TouchSimulator.postDockSwipe(delta: delta, axis: axis, phase: .began, inverted: naturalDirection)
    }

    /// 三指滑动 dockSwipe 的缩放公式:
    /// 水平: -dx * (originOffsetForOneSpace / (屏宽 + 63)), 垂直: dy / 屏高
    private func scaledDockSwipeDelta(dx: Double, dy: Double, axis: DockSwipeAxis) -> Double {
        let screen = NSScreen.main?.frame.size ?? NSSize(width: 1440, height: 900)
        switch axis {
        case .horizontal:
            let originOffsetForOneSpace = 2.0  // 按单空间估算
            let scale = originOffsetForOneSpace / (Double(screen.width) + 63)
            return -dx * scale
        case .vertical:
            let scale = 1.0 / Double(screen.height)
            return dy * scale
        case .pinch:
            // 拖拽手势不使用 pinch 轴
            return 0
        }
    }

    /// 本次会话快照的系统"自然滚动方向"
    private var naturalDirection: Bool {
        return sessionNaturalDirection
    }

    /// 关闭自然滚动时, 双指滑动要把位移取反.
    /// 只改 inverted 标志在 macOS 27 上不够, WindowServer 会忽略该 CGEvent field.
    private func directedTwoFingerDelta(_ delta: (x: Double, y: Double)) -> (x: Double, y: Double) {
        if naturalDirection {
            return delta
        }
        return (x: -delta.x, y: -delta.y)
    }

}
