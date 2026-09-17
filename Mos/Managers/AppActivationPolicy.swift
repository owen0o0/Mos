//
//  AppActivationPolicy.swift
//  Mos
//  窗口显示时切到 regular, 关闭后交还菜单栏再回到 accessory, 避免菜单栏上下跳.
//

import Cocoa

enum AppActivationPolicy {
    enum RestoreAction: Equatable {
        case none
        case becomeAccessory
        case yieldThenBecomeAccessory
    }

    private static var previousApplication: NSRunningApplication?
    private static var restoreGeneration: UInt64 = 0

    static func restoreAction(
        remainingWindowCount: Int,
        isActive: Bool,
        canYieldToPreviousApp: Bool
    ) -> RestoreAction {
        guard remainingWindowCount == 0 else { return .none }
        if isActive && canYieldToPreviousApp {
            return .yieldThenBecomeAccessory
        }
        return .becomeAccessory
    }

    static func capturePreviousApplicationIfNeeded(
        frontmost: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) {
        guard let frontmost, frontmost != NSRunningApplication.current else { return }
        previousApplication = frontmost
    }

    static func becomeRegular() {
        restoreGeneration += 1
        apply(.regular)
        Utils.isDockIconVisible = true
    }

    static func restoreAccessoryIfNoWindowsRemain(windowCount: Int) {
        guard AppRuntime.shouldRunAppStartupSideEffects else { return }
        let yieldTarget = applicationToYieldTo()
        switch restoreAction(
            remainingWindowCount: windowCount,
            isActive: NSApp.isActive,
            canYieldToPreviousApp: yieldTarget != nil
        ) {
        case .none:
            return
        case .becomeAccessory:
            becomeAccessory()
        case .yieldThenBecomeAccessory:
            yieldThenBecomeAccessory(to: yieldTarget)
        }
    }

    static func handleDidResignActive() {
        guard AppRuntime.shouldRunAppStartupSideEffects else { return }
        guard WindowManager.shared.refs.isEmpty else { return }
        becomeAccessory()
    }

    static func applicationToYieldTo() -> NSRunningApplication? {
        if let previous = previousApplication,
           !previous.isTerminated,
           previous != NSRunningApplication.current {
            return previous
        }
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular &&
            !$0.isTerminated &&
            $0 != NSRunningApplication.current
        }
    }
}

private extension AppActivationPolicy {
    static func yieldThenBecomeAccessory(to app: NSRunningApplication?) {
        restoreGeneration += 1
        let generation = restoreGeneration
        _ = activate(app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard generation == restoreGeneration else { return }
            guard WindowManager.shared.refs.isEmpty else { return }
            becomeAccessory()
        }
    }

    static func becomeAccessory() {
        previousApplication = nil
        apply(.accessory)
        Utils.isDockIconVisible = false
    }

    static func apply(_ policy: NSApplication.ActivationPolicy) {
        guard AppRuntime.shouldRunAppStartupSideEffects else { return }
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    @discardableResult
    static func activate(_ app: NSRunningApplication?) -> Bool {
        guard AppRuntime.shouldRunAppStartupSideEffects, let app else { return false }
        if #available(macOS 14.0, *) {
            return app.activate(from: NSRunningApplication.current)
        }
        return app.activate(options: .activateIgnoringOtherApps)
    }
}
