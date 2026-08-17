//
//  ButtonUtils.swift
//  Mos
//  按钮绑定工具类 - 获取配置和管理绑定 (带缓存)
//  Created by Claude on 2025/8/10.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa

struct ButtonBindingTriggerKey: Hashable {
    let type: EventType
    let code: UInt16
}

class ButtonUtils {

    // 单例
    static let shared = ButtonUtils()
    init() {
        // 绑定组变更时自动失效缓存 (订阅者为进程级单例, 无需注销)
        Options.shared.observe([.buttons]) { [weak self] _ in
            self?.invalidateCache()
        }
    }

    // MARK: - 缓存

    /// 缓存的绑定列表 (已预解析 custom:: 字段)
    private var cachedBindings: [ButtonBinding] = []
    private var cachedBindingsByTriggerKey: [ButtonBindingTriggerKey: [ButtonBinding]] = [:]
    /// 缓存的按钮重映射列表 (新引擎)
    private var cachedRemaps: [ButtonRemap] = []
    private var cachedRemapsByButton: [UInt16: [ButtonRemap]] = [:]
    private var isDirty = true

    // MARK: - 获取按钮绑定配置

    /// 获取当前应用的按钮绑定配置 (带缓存和预解析)
    /// - Returns: 按钮绑定列表
    func getButtonBindings() -> [ButtonBinding] {
        refreshCacheIfNeeded()
        return cachedBindings
    }

    func getButtonBindings(for type: EventType, code: UInt16) -> [ButtonBinding] {
        refreshCacheIfNeeded()
        return cachedBindingsByTriggerKey[ButtonBindingTriggerKey(type: type, code: code)] ?? []
    }

    func getBestMatchingBinding(
        for event: InputEvent,
        where predicate: ((ButtonBinding) -> Bool)? = nil
    ) -> ButtonBinding? {
        let candidates = getButtonBindings(for: event.type, code: event.code)
        var bestBinding: ButtonBinding?
        var bestPriority = Int.min

        for binding in candidates {
            guard binding.isEnabled else {
                continue
            }
            if let predicate, !predicate(binding) {
                continue
            }
            guard let priority = binding.triggerEvent.matchPriority(for: event) else {
                continue
            }
            if priority > bestPriority {
                bestBinding = binding
                bestPriority = priority
            }
        }

        return bestBinding
    }

    /// 标记缓存失效 (绑定变更后调用)
    func invalidateCache() {
        assertMainThread()
        isDirty = true
    }

    private func refreshCacheIfNeeded() {
        guard isDirty else { return }

        cachedBindings = Options.shared.buttons.binding.map { binding in
            var b = binding
            b.prepareCustomCache()
            return b
        }

        cachedBindingsByTriggerKey = Dictionary(grouping: cachedBindings) { binding in
            ButtonBindingTriggerKey(
                type: binding.triggerEvent.type,
                code: binding.triggerEvent.code
            )
        }

        cachedRemaps = Options.shared.buttons.remaps
        cachedRemapsByButton = Dictionary(grouping: cachedRemaps) { remap in
            remap.trigger.buttonNumber
        }

        isDirty = false
    }

    // MARK: - 分应用支持 (预留接口)

    /// 获取当前焦点应用的配置对象 (预留)
    /// - Returns: Application 对象或 nil
    private func getTargetApplication() -> Application? {
        return nil
    }

    // MARK: - 按钮重映射查询 (新引擎)

    /// 是否已配置任何按钮重映射 (新引擎启用开关)
    var hasButtonRemaps: Bool {
        refreshCacheIfNeeded()
        return !cachedRemaps.isEmpty
    }

    /// 获取当前应用的按钮重映射列表
    func getRemaps() -> [ButtonRemap] {
        refreshCacheIfNeeded()
        return cachedRemaps
    }

    /// 获取指定按钮的重映射候选
    func getRemaps(for button: UInt16) -> [ButtonRemap] {
        refreshCacheIfNeeded()
        return cachedRemapsByButton[button] ?? []
    }

    /// 当前修饰键下该按钮配置的最大点击层级 (0 = 无匹配 remap)
    func maxLevel(for button: UInt16, modifiers: CGEventFlags) -> Int {
        var result = 0
        for remap in getRemaps(for: button) where remap.isEnabled {
            guard remap.precondition.matchPriority(for: modifiers) != nil else { continue }
            result = max(result, remap.trigger.level)
        }
        return result
    }

    /// 查询 (button, level, duration) 的最佳匹配 remap
    func remap(
        for button: UInt16,
        level: Int,
        duration: ButtonTriggerDuration,
        modifiers: CGEventFlags
    ) -> ButtonRemap? {
        let candidates = getRemaps(for: button).filter {
            $0.isEnabled &&
            $0.trigger.level == level &&
            $0.trigger.duration == duration
        }
        var best: ButtonRemap?
        var bestPriority = Int.min
        for candidate in candidates {
            guard let priority = candidate.precondition.matchPriority(for: modifiers) else { continue }
            if priority > bestPriority {
                best = candidate
                bestPriority = priority
            }
        }
        return best
    }
}
