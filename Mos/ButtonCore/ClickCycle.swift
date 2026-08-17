//
//  ClickCycle.swift
//  Mos
//  点击周期状态机
//
//  与常见全局单状态实现不同, Mos 按按钮独立跟踪周期,
//  以支持同时按住多个侧键分别映射为不同动作.
//
//  相位语义:
//  - press: 按下, 携带当前点击层级 (1=单击, 2=双击 ...)
//  - hold:  长按 holdDelay 后触发 (若该按钮配置了 hold 动作或更高点击层级)
//  - release: 松手
//  - levelExpired: 层级判定超时, 迟到的 click 在此提交
//  - releaseFromHold: 长按结束后松手
//
//  拖拽/滚动触发:
//  - 触发类型 .drag / .scroll 在按下时立即激活 (无 hold 延时), 松手时结束;
//  - 可与单击/长按动作共存 (如: 单击=后退, 按住拖动=拖拽窗口).
//  Created by Claude on 2026/8/17.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

// MARK: - 相位与结果

enum ClickCyclePhase: Equatable {
    case press(level: Int)
    case hold(level: Int)
    case release(level: Int)
    case levelExpired(level: Int)
    case releaseFromHold(level: Int)
}

enum ClickCycleEventResult {
    case consumed
    case passthrough
}

// MARK: - Delegate

protocol ClickCycleDelegate: AnyObject {
    /// 当前修饰键下, 该按钮配置的最大点击层级 (0 = 无 remap, 事件应放行)
    func clickCycle(_ cycle: ClickCycle, maxLevelForButton button: UInt16, modifiers: CGEventFlags) -> Int
    /// 查询 (button, level, duration) 的最佳匹配 remap
    func clickCycle(_ cycle: ClickCycle, remapForButton button: UInt16, level: Int, duration: ButtonTriggerDuration, modifiers: CGEventFlags) -> ButtonRemap?
    /// 该动作是否为 stateful (需要 down/up 配对)
    func clickCycle(_ cycle: ClickCycle, isStatefulEffect effect: ButtonEffect) -> Bool
    /// 提交动作: stateful 执行 down (返回会话 ID), trigger 一次性执行 (返回 nil)
    func clickCycle(_ cycle: ClickCycle, didCommit remap: ButtonRemap, phase: ClickCyclePhase, button: UInt16, modifiers: CGEventFlags) -> UUID?
    /// 释放 stateful 会话 (执行 up)
    func clickCycle(_ cycle: ClickCycle, didRelease remap: ButtonRemap, button: UInt16, modifiers: CGEventFlags, sessionID: UUID?)
    /// 本次按下期间手势 (拖拽/滚动) 是否已被实际使用
    func clickCycle(_ cycle: ClickCycle, isGestureUsedForButton button: UInt16) -> Bool
}

// MARK: - ClickCycle

final class ClickCycle {

    /// 长按判定延时 (默认 0.25s)
    var holdDelay: TimeInterval = 0.25
    /// 层级判定超时 (0.26s, 从最近一次按下起算, 每次按下重启)
    var levelExpiryDelay: TimeInterval = 0.26

    weak var delegate: ClickCycleDelegate?

    private enum PressState {
        case down
        case held
    }

    private struct ActiveSession {
        let remap: ButtonRemap
        let sessionID: UUID?
    }

    private struct CycleState {
        var clickLevel = 0
        var pressState: PressState = .down
        /// 已提交的 stateful 动作 (press 立即提交 / hold 提交 / drag / scroll)
        /// 同一按钮可同时持有 click 会话与 drag/scroll 手势会话
        var activeSessions: [ActiveSession] = []
        /// 等待 release / levelExpired 提交的 click 动作
        var pendingClick: ButtonRemap?
        var holdTimer: Timer?
        var expiryTimer: Timer?
    }

    private var states: [UInt16: CycleState] = [:]

    /// 当前处于按住状态的 stateful 动作 (供虚拟修饰键 flags 重算)
    var activeStatefulEffects: [ButtonEffect] {
        return states.values.flatMap { $0.activeSessions.map { $0.remap.effect } }
    }

    // MARK: - 输入

    func handleDown(button: UInt16, modifiers: CGEventFlags) -> ClickCycleEventResult {
        assertMainThread()
        let maxLevel = delegate?.clickCycle(self, maxLevelForButton: button, modifiers: modifiers) ?? 0
        guard maxLevel > 0 else { return .passthrough }

        var state = states[button] ?? CycleState()
        // 上一轮 stateful 会话尚未释放 (重复 down / 丢失 up): 先释放再重建
        releaseAllSessions(in: &state, button: button, modifiers: modifiers)
        state.clickLevel = Self.cycledLevel(state.clickLevel + 1, max: maxLevel)
        state.pressState = .down
        state.pendingClick = nil
        cancelTimers(in: &state)
        let level = state.clickLevel

        let clickRemap = delegate?.clickCycle(self, remapForButton: button, level: level, duration: .click, modifiers: modifiers)
        let holdRemap = delegate?.clickCycle(self, remapForButton: button, level: level, duration: .hold, modifiers: modifiers)
        let dragRemap = delegate?.clickCycle(self, remapForButton: button, level: level, duration: .drag, modifiers: modifiers)
        let scrollRemap = delegate?.clickCycle(self, remapForButton: button, level: level, duration: .scroll, modifiers: modifiers)
        let greaterLevelExists = maxLevel > level
#if DEBUG
        NSLog("[ClickCycle] down btn=\(button) maxLevel=\(maxLevel) level=\(level) click=\(clickRemap != nil) hold=\(holdRemap != nil) drag=\(dragRemap != nil) scroll=\(scrollRemap != nil)")
#endif

        // 按住并拖动 / 按住并滚动: 按下同时激活两者 (无 hold 延时), 与 click/hold 逻辑独立
        if let dragRemap {
            commitGesture(dragRemap, level: level, button: button, modifiers: modifiers, into: &state)
        }
        if let scrollRemap {
            commitGesture(scrollRemap, level: level, button: button, modifiers: modifiers, into: &state)
        }

        // 单击统一在松手后提交 (按下松开语义)
        state.pendingClick = clickRemap
        states[button] = state

        // hold timer (总是计时, 用于区分点击与长按; 到点按长按动作处理)
        scheduleHoldTimer(button: button, level: level, modifiers: modifiers, holdRemap: holdRemap, into: &state)
        // levelExpiry (从按下起算, 每次按下重启; 到点提交 click 或吞掉本次 press)
        if clickRemap != nil || greaterLevelExists {
            scheduleExpiryTimer(button: button, level: level, modifiers: modifiers, into: &state)
        }
        states[button] = state
        return .consumed
    }

    func handleUp(button: UInt16, modifiers: CGEventFlags) -> ClickCycleEventResult {
        assertMainThread()
        guard var state = states[button] else { return .passthrough }
        let level = state.clickLevel

        if state.pressState == .held {
            // 长按后松手: 释放全部会话并结束周期
            releaseAllSessions(in: &state, button: button, modifiers: modifiers)
            cancelTimers(in: &state)
            states[button] = nil
            return .consumed
        }

        cancelHoldTimer(in: &state)
        states[button] = state

        if !state.activeSessions.isEmpty {
            // 手势会话随松手结束
            let gestureUsed = delegate?.clickCycle(self, isGestureUsedForButton: button) ?? false
            releaseAllSessions(in: &state, button: button, modifiers: modifiers)
            let maxLevel = delegate?.clickCycle(self, maxLevelForButton: button, modifiers: modifiers) ?? 0

            if !gestureUsed, maxLevel > level {
                // 手势未使用且有更高层级 (双击/三击): 保留周期等待下一次按下,
                // 无论本层 click 是否绑定 (未绑定行不阻塞更高层级)
                states[button] = state
                return .consumed
            }

            if let pending = state.pendingClick, !gestureUsed {
                // 无更高层级: 松手立即提交单击
                cancelTimers(in: &state)
                states[button] = nil
                let sessionID = commit(pending, phase: .release(level: level), button: button, modifiers: modifiers)
                release(pending, button: button, modifiers: modifiers, sessionID: sessionID)
                return .consumed
            }

            // 手势已使用或无 pending: 结束周期
            cancelTimers(in: &state)
            states[button] = nil
            return .consumed
        }

        if let pending = state.pendingClick {
            let maxLevel = delegate?.clickCycle(self, maxLevelForButton: button, modifiers: modifiers) ?? 0
#if DEBUG
            NSLog("[ClickCycle] up btn=\(button) level=\(level) pendingClick=true maxLevel=\(maxLevel) -> \(maxLevel > level ? "wait levelExpired" : "commit now")")
#endif
            if maxLevel > level {
                // 有更高层级: 保留周期, 等按下时已排的层级超时 (双击/三击判定)
                states[button] = state
            } else {
                // 无更高层级 (纯单击 / click+hold): 松手立即提交
                cancelTimers(in: &state)
                states[button] = nil
                let sessionID = commit(pending, phase: .release(level: level), button: button, modifiers: modifiers)
                release(pending, button: button, modifiers: modifiers, sessionID: sessionID)
            }
            return .consumed
        }

        // pendingClick == nil: 仅更高层级存在 (本次 press 被吞掉, 如只有双击时单击一次)
        // 松手起算窗口清理周期, 后续点击在同一窗口内升层级
        let maxLevel = delegate?.clickCycle(self, maxLevelForButton: button, modifiers: modifiers) ?? 0
        if maxLevel > level {
            // 仅更高层级存在: 保留周期, 等按下时已排的层级超时清理
            states[button] = state
            return .consumed
        }

        // 无任何待办 (如 hold-only 快速松手) → 清理周期
        cancelTimers(in: &state)
        states[button] = nil
        return .consumed
    }

    /// 清空所有周期: 释放活跃 stateful 会话并取消全部定时器
    func killAll() {
        assertMainThread()
        for (button, var state) in states {
            releaseAllSessions(in: &state, button: button, modifiers: CGEventFlags(rawValue: 0))
            cancelTimers(in: &state)
        }
        states.removeAll()
    }

    // MARK: - 定时器

    private func scheduleHoldTimer(button: UInt16, level: Int, modifiers: CGEventFlags, holdRemap: ButtonRemap?, into state: inout CycleState) {
        state.holdTimer?.invalidate()
        let timer = Timer(timeInterval: holdDelay, repeats: false) { [weak self] _ in
            self?.fireHold(button: button, level: level, modifiers: modifiers, holdRemap: holdRemap)
        }
        RunLoop.main.add(timer, forMode: .common)
        state.holdTimer = timer
    }

    private func scheduleExpiryTimer(button: UInt16, level: Int, modifiers: CGEventFlags, into state: inout CycleState) {
        state.expiryTimer?.invalidate()
        let timer = Timer(timeInterval: levelExpiryDelay, repeats: false) { [weak self] _ in
            self?.fireLevelExpired(button: button, level: level, modifiers: modifiers)
        }
        RunLoop.main.add(timer, forMode: .common)
        state.expiryTimer = timer
    }

    private func fireHold(button: UInt16, level: Int, modifiers: CGEventFlags, holdRemap: ButtonRemap?) {
        guard var state = states[button], state.clickLevel == level, state.pressState == .down else { return }
        state.pressState = .held
        state.expiryTimer?.invalidate()
        state.expiryTimer = nil
        if let holdRemap {
            let sessionID = commit(holdRemap, phase: .hold(level: level), button: button, modifiers: modifiers)
            state.activeSessions.append(ActiveSession(remap: holdRemap, sessionID: sessionID))
        }
        states[button] = state
    }

    private func fireLevelExpired(button: UInt16, level: Int, modifiers: CGEventFlags) {
        guard var state = states[button],
              state.clickLevel == level,
              state.pressState == .down else { return }
        cancelTimers(in: &state)
        states[button] = nil
        if let pending = state.pendingClick {
            // 迟到的 click: 按钮已经松开, stateful 动作以 tap (down+up) 提交
            let sessionID = commit(pending, phase: .levelExpired(level: level), button: button, modifiers: modifiers)
            release(pending, button: button, modifiers: modifiers, sessionID: sessionID)
        }
    }

    // MARK: - 提交与释放

    private func commit(_ remap: ButtonRemap, phase: ClickCyclePhase, button: UInt16, modifiers: CGEventFlags) -> UUID? {
        return delegate?.clickCycle(self, didCommit: remap, phase: phase, button: button, modifiers: modifiers)
    }

    private func commitGesture(
        _ remap: ButtonRemap,
        level: Int,
        button: UInt16,
        modifiers: CGEventFlags,
        into state: inout CycleState
    ) {
        let sessionID = commit(remap, phase: .press(level: level), button: button, modifiers: modifiers)
        if delegate?.clickCycle(self, isStatefulEffect: remap.effect) == true {
            state.activeSessions.append(ActiveSession(remap: remap, sessionID: sessionID))
        }
    }

    private func release(_ remap: ButtonRemap, button: UInt16, modifiers: CGEventFlags, sessionID: UUID?) {
        delegate?.clickCycle(self, didRelease: remap, button: button, modifiers: modifiers, sessionID: sessionID)
    }

    private func releaseAllSessions(in state: inout CycleState, button: UInt16, modifiers: CGEventFlags) {
        for session in state.activeSessions {
            delegate?.clickCycle(
                self,
                didRelease: session.remap,
                button: button,
                modifiers: modifiers,
                sessionID: session.sessionID
            )
        }
        state.activeSessions.removeAll()
    }

    // MARK: - 工具

    private func cancelTimers(in state: inout CycleState) {
        state.holdTimer?.invalidate()
        state.holdTimer = nil
        state.expiryTimer?.invalidate()
        state.expiryTimer = nil
    }

    private func cancelHoldTimer(in state: inout CycleState) {
        state.holdTimer?.invalidate()
        state.holdTimer = nil
    }

    private static func cycledLevel(_ value: Int, max: Int) -> Int {
        guard max > 0 else { return 1 }
        return ((value - 1) % max) + 1
    }
}
