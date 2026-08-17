//
//  ButtonEffectMenuBuilder.swift
//  Mos
//  按钮效果菜单构建 (新引擎)
//
//  菜单结构:
//  - 占位符 (NSPopUpButton 显示当前选中项)
//  - "未绑定"
//  - 手势 / 媒体与系统 / 连击 (新动作类型)
//  - ShortcutManager 分类 (系统快捷键/鼠标按键/Mos/Logi) + "打开应用…"/"自定义…"
//  Created by Claude on 2026/8/17.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

// MARK: - 媒体/系统定义事件

enum MediaSystemEvent: CaseIterable {
    case playPause
    case nextTrack
    case previousTrack
    case volumeUp
    case volumeDown
    case mute
    case brightnessUp
    case brightnessDown

    /// 系统定义事件类型 (媒体键/音量/亮度等)
    var type: UInt32 {
        switch self {
        case .playPause: return 16
        case .nextTrack: return 19
        case .previousTrack: return 20
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .mute: return 7
        case .brightnessUp: return 2
        case .brightnessDown: return 3
        }
    }

    var titleKey: String {
        switch self {
        case .playPause: return "button_effect_play_pause"
        case .nextTrack: return "button_effect_next_track"
        case .previousTrack: return "button_effect_previous_track"
        case .volumeUp: return "button_effect_volume_up"
        case .volumeDown: return "button_effect_volume_down"
        case .mute: return "button_effect_mute"
        case .brightnessUp: return "button_effect_brightness_up"
        case .brightnessDown: return "button_effect_brightness_down"
        }
    }

    var symbolName: String? {
        switch self {
        case .playPause: return "playpause.fill"
        case .nextTrack: return "forward.fill"
        case .previousTrack: return "backward.fill"
        case .volumeUp: return "speaker.wave.2.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        }
    }

    var effect: ButtonEffect {
        return .systemDefinedEvent(type: type, flags: 0)
    }

    init?(type: UInt32) {
        guard let match = Self.allCases.first(where: { $0.type == type }) else { return nil }
        self = match
    }
}

// MARK: - 效果菜单构建

enum ButtonEffectMenuBuilder {

    static func buildMenu(
        into menu: NSMenu,
        target: AnyObject,
        action: Selector,
        showLogiActions: Bool,
        triggerDuration: ButtonTriggerDuration,
        delegate: NSMenuDelegate?
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.delegate = delegate

        // 占位符 (button face 显示当前选中项)
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // 未绑定
        let unboundItem = NSMenuItem(title: NSLocalizedString("unbound", comment: ""), action: action, keyEquivalent: "")
        unboundItem.target = target
        unboundItem.representedObject = nil
        menu.addItem(unboundItem)

        // 触发类型约束: 按住并拖动只能选手势滑动, 按住并滚动只能选捏合缩放
        switch triggerDuration {
        case .drag:
            menu.addItem(NSMenuItem.separator())
            // 拖拽选项直接放到一级
            menu.addItem(makeItem(effect: .drag(mode: .twoFingerSwipe), titleKey: "button_effect_drag_two_finger", symbol: "arrow.left.and.right", target: target, action: action))
            menu.addItem(makeItem(effect: .drag(mode: .threeFingerSwipe), titleKey: "button_effect_drag_three_finger", symbol: "arrow.up.and.down", target: target, action: action))

        case .scroll:
            menu.addItem(NSMenuItem.separator())
            // 滚动修饰选项直接放到一级
            menu.addItem(makeItem(effect: .scrollModification(kind: .zoom), titleKey: "button_effect_scroll_zoom", symbol: "plus.magnifyingglass", target: target, action: action))
            menu.addItem(makeItem(effect: .scrollModification(kind: .fourFingerPinch), titleKey: "button_effect_scroll_four_finger_pinch", symbol: "hand.pinch", target: target, action: action))

        case .click, .hold:
            menu.addItem(NSMenuItem.separator())

            // 手势
            addSubmenu(
                into: menu,
                titleKey: "button_effect_section_gestures",
                target: target,
                action: action,
                items: [
                    makeItem(effect: .smartZoom, titleKey: "button_effect_smart_zoom", symbol: "plus.magnifyingglass", target: target, action: action),
                    makeItem(effect: .lookUp, titleKey: "button_effect_look_up", symbol: "text.magnifyingglass", target: target, action: action),
                    makeItem(effect: .navigationSwipe(direction: .left), titleKey: "button_effect_navigation_back", symbol: "chevron.left", target: target, action: action),
                    makeItem(effect: .navigationSwipe(direction: .right), titleKey: "button_effect_navigation_forward", symbol: "chevron.right", target: target, action: action),
                ]
            )

            // 媒体与系统
            addSubmenu(
                into: menu,
                titleKey: "button_effect_section_media",
                target: target,
                action: action,
                items: MediaSystemEvent.allCases.map { event in
                    makeItem(effect: event.effect, titleKey: event.titleKey, symbol: event.symbolName, target: target, action: action)
                }
            )

            // 鼠标连击
            addClickComboSubmenu(into: menu, target: target, action: action)

            menu.addItem(NSMenuItem.separator())

            // 系统快捷键 / 鼠标按键 / Mos / Logi / 打开应用 / 自定义
            ShortcutManager.appendShortcutMenuItems(
                into: menu,
                target: target,
                action: action,
                showLogiActions: showLogiActions
            )
        }
    }

    // MARK: - 子菜单

    private static func addSubmenu(
        into menu: NSMenu,
        titleKey: String,
        target: AnyObject,
        action: Selector,
        items: [NSMenuItem]
    ) {
        let title = NSLocalizedString(titleKey, comment: "")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for subItem in items {
            submenu.addItem(subItem)
        }
        item.submenu = submenu
        menu.addItem(item)
    }

    private static func addClickComboSubmenu(into menu: NSMenu, target: AnyObject, action: Selector) {
        let title = NSLocalizedString("button_effect_section_click_combo", comment: "")
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false

        for buttonNumber: UInt16 in [0, 1, 2, 3, 4] {
            let buttonName = KeyCode.mouseMap[buttonNumber] ?? "Mouse \(buttonNumber)"
            for count in [2, 3] {
                let effect = ButtonEffect.mouseButtonClicks(buttonNumber: buttonNumber, count: count)
                let comboItem = NSMenuItem(
                    title: "\(buttonName) ×\(count)",
                    action: action,
                    keyEquivalent: ""
                )
                comboItem.target = target
                comboItem.representedObject = effect
                if #available(macOS 11.0, *) {
                    comboItem.image = NSImage(systemSymbolName: "repeat", accessibilityDescription: nil)
                }
                submenu.addItem(comboItem)
            }
        }

        item.submenu = submenu
        menu.addItem(item)
    }

    private static func makeItem(
        effect: ButtonEffect,
        titleKey: String,
        symbol: String?,
        target: AnyObject,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: NSLocalizedString(titleKey, comment: ""), action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = effect
        if #available(macOS 11.0, *) {
            if let symbol {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
        }
        return item
    }
}
