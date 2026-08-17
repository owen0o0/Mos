//
//  ScrollActionPort.swift
//  Mos
//  滚动动作端口: 解耦 ShortcutExecutor 对 ScrollCore 的具体依赖
//

import Foundation

/// ShortcutExecutor 通过此协议驱动 Mos 滚动热键 (dash/toggle/block) 状态,
/// 不直接依赖 ScrollCore, 从而打破
/// ScrollCore → InputProcessor → ShortcutExecutor → ScrollCore 三角循环。
/// ScrollCore 实现此协议, 由启动期 (AppDelegate / 测试 setUp) 注入。
protocol ScrollActionPort: AnyObject {
    func handleMosScrollAction(role: ScrollRole, isDown: Bool)
}

/// 滚动修饰端口: ShortcutExecutor 通过此协议开关"按住按钮 → 修改滚动"状态,
/// 由 ScrollCore 实现并在滚动事件回调中读取应用。
protocol ScrollModificationPort: AnyObject {
    func setScrollModification(_ kind: ScrollModificationKind, active: Bool)
}
