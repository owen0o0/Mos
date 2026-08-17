//
//  ButtonEffectDisplayResolver.swift
//  Mos
//  ButtonEffect → ActionPresentation (新引擎单元格显示)
//  Created by Claude on 2026/8/17.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

enum ButtonEffectDisplayResolver {

    static func resolve(
        effect: ButtonEffect?,
        isEnabled: Bool,
        isRecording: Bool
    ) -> ActionPresentation {
        if isRecording {
            return ActionPresentation(
                kind: .recordingPrompt,
                title: NSLocalizedString("custom-recording-prompt", comment: "")
            )
        }
        guard let effect, isEnabled else {
            return ActionPresentation(
                kind: .unbound,
                title: NSLocalizedString("unbound", comment: "")
            )
        }

        switch effect {
        case .systemShortcut(let identifier):
            return namedActionPresentation(for: identifier)

        case .customKey(let code, let modifiers):
            return keyComboPresentation(type: .keyboard, code: code, modifiers: modifiers)

        case .customMouseButton(let buttonNumber, let modifiers):
            return keyComboPresentation(type: .mouse, code: buttonNumber, modifiers: modifiers)

        case .mouseButtonClicks(let buttonNumber, let count):
            let buttonName = KeyCode.mouseMap[buttonNumber] ?? "Mouse \(buttonNumber)"
            return ActionPresentation(
                kind: .namedAction,
                title: "\(buttonName) ×\(count)",
                symbolName: "repeat"
            )

        case .mosScroll(let role):
            let identifier: String
            switch role {
            case .dash: identifier = "mosScrollDash"
            case .toggle: identifier = "mosScrollToggle"
            case .block: identifier = "mosScrollBlock"
            }
            return namedActionPresentation(for: identifier)

        case .systemDefinedEvent(let type, _):
            if let event = MediaSystemEvent(type: type) {
                return ActionPresentation(
                    kind: .namedAction,
                    title: NSLocalizedString(event.titleKey, comment: ""),
                    symbolName: event.symbolName
                )
            }
            return ActionPresentation(
                kind: .namedAction,
                title: NSLocalizedString("button_effect_system_event", comment: ""),
                symbolName: "gearshape"
            )

        case .smartZoom:
            return ActionPresentation(
                kind: .namedAction,
                title: NSLocalizedString("button_effect_smart_zoom", comment: ""),
                symbolName: "plus.magnifyingglass"
            )

        case .lookUp:
            return ActionPresentation(
                kind: .namedAction,
                title: NSLocalizedString("button_effect_look_up", comment: ""),
                symbolName: "text.magnifyingglass"
            )

        case .navigationSwipe(let direction):
            return ActionPresentation(
                kind: .namedAction,
                title: NSLocalizedString(
                    direction == .left ? "button_effect_navigation_back" : "button_effect_navigation_forward",
                    comment: ""
                ),
                symbolName: direction == .left ? "chevron.left" : "chevron.right"
            )

        case .openTarget(let payload):
            return openTargetPresentation(for: payload)

        case .logiAction(let identifier):
            return namedActionPresentation(for: identifier)

        case .drag(let mode):
            let titleKey: String
            let symbol: String?
            switch mode {
            case .twoFingerSwipe:
                titleKey = "button_effect_drag_two_finger"
                symbol = "arrow.left.and.right"
            case .threeFingerSwipe:
                titleKey = "button_effect_drag_three_finger"
                symbol = "arrow.up.and.down"
            }
            return ActionPresentation(
                kind: .namedAction,
                title: NSLocalizedString(titleKey, comment: ""),
                symbolName: symbol
            )

        case .scrollModification(let kind):
            let titleKey: String
            let symbol: String?
            switch kind {
            case .zoom:
                titleKey = "button_effect_scroll_zoom"
                symbol = "plus.magnifyingglass"
            case .fourFingerPinch:
                titleKey = "button_effect_scroll_four_finger_pinch"
                symbol = "hand.pinch"
            }
            return ActionPresentation(
                kind: .namedAction,
                title: NSLocalizedString(titleKey, comment: ""),
                symbolName: symbol
            )
        }
    }

    // MARK: - 子展示

    private static func namedActionPresentation(for identifier: String) -> ActionPresentation {
        if let shortcut = SystemShortcut.getShortcut(named: identifier) {
            return ActionPresentation(
                kind: .namedAction,
                title: shortcut.localizedName,
                symbolName: shortcut.symbolName,
                tag: BrandTag.tagForAction(identifier)
            )
        }
        return ActionPresentation(
            kind: .namedAction,
            title: identifier,
            symbolName: nil
        )
    }

    private static func keyComboPresentation(type: EventType, code: UInt16, modifiers: UInt64) -> ActionPresentation {
        let tag = BrandTag.tagForCode(code)
        let event = InputEvent(
            type: type,
            code: code,
            modifiers: CGEventFlags(rawValue: modifiers),
            phase: .down,
            source: .hidPP,
            device: nil
        )
        let marker = tag.map { "[\($0.name)]" }
        let badgeComponents = event.displayComponents.filter { component in
            guard let marker else { return true }
            return component != marker
        }
        return ActionPresentation(
            kind: .keyCombo,
            title: "",
            badgeComponents: badgeComponents,
            tag: tag
        )
    }

    private static func openTargetPresentation(for payload: OpenTargetPayload) -> ActionPresentation {
        let workspace = NSWorkspace.shared
        let resolvedURL: URL? = {
            if let bundleID = payload.bundleID,
               let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                return url
            }
            let url = URL(fileURLWithPath: payload.path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }()

        let title: String
        let icon: NSImage?
        if let url = resolvedURL {
            if payload.kind == .application, let bundle = Bundle(url: url) {
                title = bundle.localizedDisplayName
                    ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle.infoDictionary?["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
            } else {
                title = url.lastPathComponent
            }
            icon = workspace.icon(forFile: url.path)
        } else {
            let basename = (payload.path as NSString).lastPathComponent
            let staleTag = NSLocalizedString("open-target-placeholder-stale", comment: "")
            title = basename.isEmpty ? staleTag : "\(basename) \(staleTag)"
            icon = nil
        }

        return ActionPresentation(
            kind: .openTarget,
            title: title,
            symbolName: nil,
            image: icon
        )
    }
}
