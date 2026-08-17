//
//  ButtonRemap.swift
//  Mos
//  按钮重映射数据模型
//  Created by Claude on 2026/8/17.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

// MARK: - NavigationSwipeDirection
/// 通用前进/后退导航滑动方向
enum NavigationSwipeDirection: String, Codable {
    case left
    case right
}

// MARK: - DragMode
/// 拖拽模式
enum DragMode: String, Codable, CaseIterable {
    /// 拖拽动作转为双指滑动 (页面导航)
    case twoFingerSwipe
    /// 拖拽动作转为三指滑动 (调度中心 / 程序切换 / 页面导航)
    case threeFingerSwipe
}

// MARK: - ScrollModificationKind
/// 滚动修饰
enum ScrollModificationKind: String, Codable, CaseIterable {
    /// 双指捏合缩放 (滚轮 → magnification 事件)
    case zoom
    /// 四指捏合 (按住按钮 + 滚轮 → 显示桌面/启动台)
    case fourFingerPinch
}

// MARK: - ScrollRole Codable
/// ScrollRole 目前只声明了 Hashable; 这里补 Codable 以便作为 ButtonEffect 持久化字段
extension ScrollRole: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "dash": self = .dash
        case "toggle": self = .toggle
        case "block": self = .block
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown ScrollRole value: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .dash: try container.encode("dash")
        case .toggle: try container.encode("toggle")
        case .block: try container.encode("block")
        }
    }
}

// MARK: - ButtonTriggerDuration
/// 触发类型:
/// - click: 单击 (短按)
/// - hold: 长按 (holdDelay 后)
/// - drag: 按住并拖动 (按下即激活, 移动超过阈值才真正拖拽)
/// - scroll: 按住并滚动 (按下即激活)
enum ButtonTriggerDuration: String, Codable, CaseIterable {
    case click
    case hold
    case drag
    case scroll
}

// MARK: - ButtonTrigger
/// 触发条件: 哪个按钮、第几次点击、单击还是长按
///
/// `buttonNumber` 与 InputEvent.code 使用同一套编码:
/// - 原生鼠标按钮: CG 事件按钮号 (0=左, 1=右, 2=中, 3=后退, 4=前进, ...)
/// - Logi HID++ 按键: >= 1000 的 Mos 码
struct ButtonTrigger: Codable, Equatable {
    let buttonNumber: UInt16
    /// 点击层级: 1=单击, 2=双击, 3=三击 ...
    let level: Int
    let duration: ButtonTriggerDuration

    init(buttonNumber: UInt16, level: Int = 1, duration: ButtonTriggerDuration = .click) {
        self.buttonNumber = buttonNumber
        self.level = level
        self.duration = duration
    }
}

// MARK: - ButtonPrecondition
/// 触发前置条件: 键盘修饰键
struct ButtonPrecondition: Codable, Equatable {
    /// 键盘修饰键 flags (NSEvent.ModifierFlags / CGEventFlags 同一套 bit 布局)
    var keyboardModifiers: UInt

    init(keyboardModifiers: UInt = 0) {
        self.keyboardModifiers = keyboardModifiers
    }

    /// 鼠标事件的修饰键匹配: 允许事件带额外修饰键, 绑定自身修饰键越多优先级越高
    /// (与旧 RecordedEvent.matchPriority 语义保持一致)
    func matchPriority(for modifiers: CGEventFlags) -> Int? {
        let expected = UInt64(keyboardModifiers) & KeyCode.modifiersMask
        let actual = modifiers.rawValue & KeyCode.modifiersMask
        guard actual & expected == expected else { return nil }
        return expected.nonzeroBitCount
    }
}

// MARK: - ButtonEffect
/// 按钮动作: 动作类型 + 变体载荷
enum ButtonEffect: Equatable {
    /// 系统快捷键库中的命名动作 (copy / missionControl / mouseLeftClick / mosScrollDash / logiSmartShiftToggle ...)
    case systemShortcut(identifier: String)
    /// 自定义键盘键 (按住时保持按下)
    case customKey(code: UInt16, modifiers: UInt64)
    /// 自定义鼠标按钮 (按住时保持按下)
    case customMouseButton(buttonNumber: UInt16, modifiers: UInt64)
    /// 任意鼠标按钮 n 连击 (一次性)
    case mouseButtonClicks(buttonNumber: UInt16, count: Int)
    /// Mos Scroll 状态动作 (dash / toggle / block)
    case mosScroll(role: ScrollRole)
    /// 媒体/亮度等系统定义事件 (一次性)
    case systemDefinedEvent(type: UInt32, flags: UInt64)
    /// Smart Zoom (一次性)
    case smartZoom
    /// 查询与快速查看 (Look Up & Quick Look, 与触控板用力点按相同)
    case lookUp
    /// 通用前进/后退导航滑动 (一次性)
    case navigationSwipe(direction: NavigationSwipeDirection)
    /// 打开应用/脚本/文件 (一次性)
    case openTarget(payload: OpenTargetPayload)
    /// Logi HID++ 动作 (一次性)
    case logiAction(identifier: String)
    /// 拖拽 (stateful: 按住期间模拟左键拖拽或手势滑动)
    case drag(mode: DragMode)
    /// 滚动修饰 (stateful: 按住期间修改滚动行为)
    case scrollModification(kind: ScrollModificationKind)
}

// MARK: - ButtonEffect Codable
extension ButtonEffect: Codable {
    private enum CodingTag: String, Codable {
        case systemShortcut
        case customKey
        case customMouseButton
        case mouseButtonClicks
        case mosScroll
        case systemDefinedEvent
        case smartZoom
        case lookUp
        case navigationSwipe
        case openTarget
        case logiAction
        case drag
        case scrollModification
    }

    private enum CodingKeys: String, CodingKey {
        case tag
        case identifier
        case code
        case modifiers
        case buttonNumber
        case count
        case role
        case type
        case flags
        case direction
        case payload
        case mode
        case kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(CodingTag.self, forKey: .tag)
        switch tag {
        case .systemShortcut:
            self = .systemShortcut(identifier: try container.decode(String.self, forKey: .identifier))
        case .customKey:
            self = .customKey(
                code: try container.decode(UInt16.self, forKey: .code),
                modifiers: try container.decode(UInt64.self, forKey: .modifiers)
            )
        case .customMouseButton:
            self = .customMouseButton(
                buttonNumber: try container.decode(UInt16.self, forKey: .buttonNumber),
                modifiers: try container.decode(UInt64.self, forKey: .modifiers)
            )
        case .mouseButtonClicks:
            self = .mouseButtonClicks(
                buttonNumber: try container.decode(UInt16.self, forKey: .buttonNumber),
                count: try container.decode(Int.self, forKey: .count)
            )
        case .mosScroll:
            self = .mosScroll(role: try container.decode(ScrollRole.self, forKey: .role))
        case .systemDefinedEvent:
            self = .systemDefinedEvent(
                type: try container.decode(UInt32.self, forKey: .type),
                flags: try container.decode(UInt64.self, forKey: .flags)
            )
        case .smartZoom:
            self = .smartZoom
        case .lookUp:
            self = .lookUp
        case .navigationSwipe:
            self = .navigationSwipe(
                direction: try container.decode(NavigationSwipeDirection.self, forKey: .direction)
            )
        case .openTarget:
            self = .openTarget(payload: try container.decode(OpenTargetPayload.self, forKey: .payload))
        case .logiAction:
            self = .logiAction(identifier: try container.decode(String.self, forKey: .identifier))
        case .drag:
            self = .drag(mode: try container.decode(DragMode.self, forKey: .mode))
        case .scrollModification:
            self = .scrollModification(
                kind: try container.decode(ScrollModificationKind.self, forKey: .kind)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .systemShortcut(let identifier):
            try container.encode(CodingTag.systemShortcut, forKey: .tag)
            try container.encode(identifier, forKey: .identifier)
        case .customKey(let code, let modifiers):
            try container.encode(CodingTag.customKey, forKey: .tag)
            try container.encode(code, forKey: .code)
            try container.encode(modifiers, forKey: .modifiers)
        case .customMouseButton(let buttonNumber, let modifiers):
            try container.encode(CodingTag.customMouseButton, forKey: .tag)
            try container.encode(buttonNumber, forKey: .buttonNumber)
            try container.encode(modifiers, forKey: .modifiers)
        case .mouseButtonClicks(let buttonNumber, let count):
            try container.encode(CodingTag.mouseButtonClicks, forKey: .tag)
            try container.encode(buttonNumber, forKey: .buttonNumber)
            try container.encode(count, forKey: .count)
        case .mosScroll(let role):
            try container.encode(CodingTag.mosScroll, forKey: .tag)
            try container.encode(role, forKey: .role)
        case .systemDefinedEvent(let type, let flags):
            try container.encode(CodingTag.systemDefinedEvent, forKey: .tag)
            try container.encode(type, forKey: .type)
            try container.encode(flags, forKey: .flags)
        case .smartZoom:
            try container.encode(CodingTag.smartZoom, forKey: .tag)
        case .lookUp:
            try container.encode(CodingTag.lookUp, forKey: .tag)
        case .navigationSwipe(let direction):
            try container.encode(CodingTag.navigationSwipe, forKey: .tag)
            try container.encode(direction, forKey: .direction)
        case .openTarget(let payload):
            try container.encode(CodingTag.openTarget, forKey: .tag)
            try container.encode(payload, forKey: .payload)
        case .logiAction(let identifier):
            try container.encode(CodingTag.logiAction, forKey: .tag)
            try container.encode(identifier, forKey: .identifier)
        case .drag(let mode):
            try container.encode(CodingTag.drag, forKey: .tag)
            try container.encode(mode, forKey: .mode)
        case .scrollModification(let kind):
            try container.encode(CodingTag.scrollModification, forKey: .tag)
            try container.encode(kind, forKey: .kind)
        }
    }
}

// MARK: - ButtonRemap
/// 一条按钮重映射: 触发 + 前置条件 + 动作
struct ButtonRemap: Codable, Equatable {
    let id: UUID
    let trigger: ButtonTrigger
    let precondition: ButtonPrecondition
    let effect: ButtonEffect
    var isEnabled: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        trigger: ButtonTrigger,
        precondition: ButtonPrecondition = ButtonPrecondition(),
        effect: ButtonEffect,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.trigger = trigger
        self.precondition = precondition
        self.effect = effect
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}
