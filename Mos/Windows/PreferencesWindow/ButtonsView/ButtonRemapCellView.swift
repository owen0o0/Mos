//
//  ButtonRemapCellView.swift
//  Mos
//  按钮重映射单元格 (新引擎) - 触发 popup + 效果 popup + Logi 冲突指示
//  Created by Claude on 2026/8/17.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

class ButtonRemapCellView: NSTableCellView, NSMenuDelegate {

    // MARK: - IBOutlets

    @IBOutlet weak var keyDisplayContainerView: NSView!
    @IBOutlet weak var actionPopUpButton: NSPopUpButton!

    // MARK: - 状态

    private var currentRemap: ButtonRemap?
    private var isCustomRecordingActive = false
    private var currentTriggerCode: UInt16 = 0
    private var currentCapturePresentationStatus: ButtonCapturePresentationStatus = .normal
    private var keyPreview: KeyPreview!
    private var conflictIconView: NSImageView?
    private var conflictTrackingArea: NSTrackingArea?
    private var conflictPopover: NSPopover?
    private var conflictObserverTokens: [NSObjectProtocol] = []
    private var originalRowBackgroundColor: NSColor?

    private lazy var conflictPopoverController: HoverIntentPopoverController = {
        let controller = HoverIntentPopoverController()
        controller.onDidClose = { [weak self] in
            self?.conflictPopover = nil
        }
        return controller
    }()

    private lazy var customRecorder: KeyRecorder = {
        let recorder = KeyRecorder()
        recorder.delegate = self
        return recorder
    }()

    private let displayRenderer = ActionDisplayRenderer()

    // MARK: - 回调

    private var onEffectChanged: ((ButtonEffect?) -> Void)?
    private var onCustomKeyRecorded: ((UInt16, UInt64) -> Void)?
    private var onOpenTargetSelectionRequested: (() -> Void)?

    // MARK: - 冲突指示常量

    private static let conflictIconSize: CGFloat = 14
    private static let conflictHitSize: CGFloat = 28
    private static let conflictIconGap: CGFloat = 6

    // MARK: - 配置

    func configure(
        with remap: ButtonRemap,
        onEffectChanged: @escaping (ButtonEffect?) -> Void,
        onCustomKeyRecorded: @escaping (UInt16, UInt64) -> Void,
        onOpenTargetSelectionRequested: @escaping () -> Void
    ) {
        self.onEffectChanged = onEffectChanged
        self.onCustomKeyRecorded = onCustomKeyRecorded
        self.onOpenTargetSelectionRequested = onOpenTargetSelectionRequested

        customRecorder.stopRecording()
        isCustomRecordingActive = false
        self.currentRemap = remap

        if originalRowBackgroundColor == nil, let rowView = self.superview as? NSTableRowView {
            originalRowBackgroundColor = rowView.backgroundColor
        }

        setupKeyDisplayView(with: remap)
        setupActionPopUpButton(showLogiActions: isLogiTrigger(remap), triggerDuration: remap.trigger.duration)

        currentTriggerCode = isLogiTrigger(remap) ? remap.trigger.buttonNumber : 0

        DispatchQueue.main.async {
            self.refreshConflictIndicator()
        }
        registerConflictObservers()
    }

    private func isLogiTrigger(_ remap: ButtonRemap) -> Bool {
        return remap.trigger.buttonNumber >= 1000
    }

    // MARK: - 按键显示

    private func setupKeyDisplayView(with remap: ButtonRemap) {
        keyDisplayContainerView.subviews.forEach { $0.removeFromSuperview() }

        keyPreview = KeyPreview()
        keyDisplayContainerView.addSubview(keyPreview)
        NSLayoutConstraint.activate([
            keyPreview.leadingAnchor.constraint(equalTo: keyDisplayContainerView.leadingAnchor),
            keyPreview.centerYAnchor.constraint(equalTo: keyDisplayContainerView.centerYAnchor),
        ])

        let event = InputEvent(
            type: .mouse,
            code: remap.trigger.buttonNumber,
            modifiers: CGEventFlags(rawValue: UInt64(remap.precondition.keyboardModifiers)),
            phase: .down,
            source: .hidPP,
            device: nil
        )
        // 触发类型徽标 (单击/长按/双击/三击/按住并拖动/按住并滚动)
        keyPreview.update(from: event.displayComponents + [triggerTypeTitle(for: remap.trigger)], status: .normal)
    }

    private func triggerTypeTitle(for trigger: ButtonTrigger) -> String {
        switch trigger.duration {
        case .click:
            switch trigger.level {
            case 1: return NSLocalizedString("button_trigger_single_click", comment: "")
            case 2: return NSLocalizedString("button_trigger_double_click", comment: "")
            default: return NSLocalizedString("button_trigger_triple_click", comment: "")
            }
        case .hold: return NSLocalizedString("button_trigger_hold", comment: "")
        case .drag: return NSLocalizedString("button_trigger_drag", comment: "")
        case .scroll: return NSLocalizedString("button_trigger_scroll", comment: "")
        }
    }

    // MARK: - 效果 popup

    private func setupActionPopUpButton(showLogiActions: Bool, triggerDuration: ButtonTriggerDuration) {
        guard let actionPopUpButton else { return }

        let menu = NSMenu()
        ButtonEffectMenuBuilder.buildMenu(
            into: menu,
            target: self,
            action: #selector(effectMenuItemSelected(_:)),
            showLogiActions: showLogiActions,
            triggerDuration: triggerDuration,
            delegate: self
        )
        disableKeyEquivalents(in: menu)
        actionPopUpButton.menu = menu
        refreshActionDisplay()
    }

    @objc private func effectMenuItemSelected(_ sender: NSMenuItem) {
        // ShortcutManager 追加的"打开应用…"/"自定义…" sentinel
        if sender.representedObject as? String == "__open__" {
            refreshActionDisplay()
            onOpenTargetSelectionRequested?()
            return
        }
        if sender.representedObject as? String == "__custom__" {
            beginCustomShortcutSelection()
            return
        }

        // 系统快捷键分类项 (ShortcutManager 追加) → 转成 systemShortcut effect
        if let shortcut = sender.representedObject as? SystemShortcut.Shortcut {
            applyEffect(.systemShortcut(identifier: shortcut.identifier))
            return
        }

        // 新效果菜单项 / nil (未绑定)
        if let effect = sender.representedObject as? ButtonEffect {
            applyEffect(effect)
            return
        }
        applyEffect(nil)
    }

    private func applyEffect(_ effect: ButtonEffect?) {
        guard let remap = currentRemap else { return }
        currentRemap = ButtonRemap(
            id: remap.id,
            trigger: remap.trigger,
            precondition: remap.precondition,
            effect: effect ?? remap.effect,
            isEnabled: effect != nil,
            createdAt: remap.createdAt
        )
        refreshActionDisplay()
        onEffectChanged?(effect)

        DispatchQueue.main.async {
            self.refreshConflictIndicator()
        }
    }

    func refreshActionDisplay() {
        let presentation = ButtonEffectDisplayResolver.resolve(
            effect: currentRemap?.effect,
            isEnabled: currentRemap?.isEnabled ?? false,
            isRecording: isCustomRecordingActive
        )
        displayRenderer.render(presentation, into: actionPopUpButton)
    }

    // MARK: - 自定义键录制

    func beginCustomShortcutSelection() {
        isCustomRecordingActive = true
        refreshActionDisplay()
        DispatchQueue.main.async { [weak self] in
            self?.refreshActionDisplay()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, self.window != nil else { return }
            self.customRecorder.startRecording(from: self.actionPopUpButton, mode: .adaptive)
        }
    }

    // MARK: - 高亮

    func highlight() {
        guard let rowView = self.superview as? NSTableRowView else { return }
        let highlightColor: NSColor
        if #available(macOS 10.14, *) {
            highlightColor = NSColor.controlAccentColor.withAlphaComponent(1)
        } else {
            highlightColor = NSColor.mainBlue
        }
        let originalColor = originalRowBackgroundColor ?? rowView.backgroundColor
        rowView.backgroundColor = highlightColor
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 1.5
            rowView.animator().backgroundColor = originalColor
        })
    }

    // MARK: - 外观变化

    private static let appearanceChangedNotification = NSNotification.Name("AppleInterfaceThemeChangedNotification")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerAppearanceObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerAppearanceObserver()
    }

    private func registerAppearanceObserver() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: Self.appearanceChangedNotification,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self, name: Self.appearanceChangedNotification, object: nil)
        unregisterConflictObservers()
    }

    @objc private func appearanceChanged() {
        refreshForAppearanceChange()
    }

    @available(macOS 10.14, *)
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshForAppearanceChange()
    }

    private func refreshForAppearanceChange() {
        if Thread.isMainThread {
            refreshActionDisplay()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.refreshActionDisplay()
        }
    }
}

// MARK: - 冲突指示器 (Logi)

extension ButtonRemapCellView {

    private func refreshConflictIndicator() {
        hideConflictPopover()
        if let view = conflictIconView {
            if let area = conflictTrackingArea {
                view.removeTrackingArea(area)
            }
            view.removeFromSuperview()
        }
        conflictIconView = nil
        conflictTrackingArea = nil
        currentCapturePresentationStatus = .normal

        guard currentTriggerCode > 0, LogiCenter.shared.isLogiCode(currentTriggerCode) else { return }

        let status = ButtonCapturePresentationStatus.from(
            LogiCenter.shared.buttonCaptureDiagnosis(forMosCode: currentTriggerCode)
        )
        currentCapturePresentationStatus = status
        guard status.shouldShowIndicator else { return }
        drawConflictIcon(status: status)
    }

    private func drawConflictIcon(status: ButtonCapturePresentationStatus) {
        guard let keyBox = keyDisplayContainerView.superview,
              let contentView = keyBox.superview else { return }
        guard let iconImage = conflictIconImage(for: status) else { return }

        let keyFrame = keyDisplayContainerView.convert(keyPreview.frame, to: contentView)
        let buttonFrame = actionPopUpButton.frame
        let horizontalMargin: CGFloat = 8.0
        let startX = keyFrame.maxX + horizontalMargin
        let endX = buttonFrame.minX - horizontalMargin
        let hitSize = Self.conflictHitSize
        let centerX = (startX + endX) / 2
        let centerY = contentView.bounds.height / 2

        let imageView = NSImageView(frame: NSRect(
            x: centerX - hitSize / 2,
            y: centerY - hitSize / 2,
            width: hitSize,
            height: hitSize
        ))
        imageView.image = iconImage
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleNone
        if #available(macOS 11.0, *) {
            imageView.contentTintColor = iconTintColor(for: status)
        }
        imageView.setAccessibilityLabel(NSLocalizedString(status.titleKey, comment: ""))

        contentView.addSubview(imageView)
        conflictIconView = imageView

        let area = NSTrackingArea(
            rect: imageView.bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        imageView.addTrackingArea(area)
        conflictTrackingArea = area
    }

    private func iconTintColor(for status: ButtonCapturePresentationStatus) -> NSColor {
        switch status {
        case .standardMouseAliasAvailable:
            return NSColor.systemBlue
        case .bleHIDPPUnstable:
            return NSColor.systemOrange
        case .normal, .conflict, .contended:
            return NSColor.systemOrange
        }
    }

    private func conflictIconImage(for status: ButtonCapturePresentationStatus) -> NSImage? {
        let size = Self.conflictIconSize
        if #available(macOS 11.0, *) {
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            let symbolNames: [String]
            switch status {
            case .bleHIDPPUnstable:
                symbolNames = [
                    "antenna.radiowaves.left.and.right",
                    "wifi.exclamationmark",
                    "exclamationmark.triangle",
                ]
            case .normal, .conflict, .contended, .standardMouseAliasAvailable:
                symbolNames = ["arrow.triangle.branch"]
            }
            for symbolName in symbolNames {
                if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    return image
                }
            }
            return nil
        }
        guard let caution = NSImage(named: NSImage.cautionName) else { return nil }
        let scaled = NSImage(size: NSSize(width: size, height: size))
        scaled.lockFocus()
        caution.draw(in: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        scaled.unlockFocus()
        return scaled
    }

    override func mouseEntered(with event: NSEvent) {
        guard conflictIconView != nil else {
            super.mouseEntered(with: event)
            return
        }
        showConflictPopover()
    }

    override func mouseExited(with event: NSEvent) {
        guard conflictIconView != nil else {
            super.mouseExited(with: event)
            return
        }
        hideConflictPopover()
    }

    private func showConflictPopover() {
        guard let anchor = conflictIconView, conflictPopover == nil else { return }
        let status = currentCapturePresentationStatus
        guard status.shouldShowIndicator else { return }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true

        let vc = NSViewController()
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: NSLocalizedString(status.titleKey, comment: ""))
        titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let detailLabel = NSTextField(wrappingLabelWithString: NSLocalizedString(status.detailKey, comment: ""))
        detailLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = NSColor.secondaryLabelColor
        detailLabel.preferredMaxLayoutWidth = 280
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(detailLabel)

        let padding: CGFloat = 12
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 300),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            detailLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            detailLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        ])

        vc.view = container
        popover.contentViewController = vc
        conflictPopover = popover
        conflictPopoverController.show(popover, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func hideConflictPopover() {
        conflictPopoverController.close()
        conflictPopover = nil
    }

    private func registerConflictObservers() {
        unregisterConflictObservers()
        let center = NotificationCenter.default
        let sessionToken = center.addObserver(
            forName: LogiCenter.sessionChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshConflictIndicator()
        }
        let reportingToken = center.addObserver(
            forName: LogiCenter.reportingDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshConflictIndicator()
        }
        let conflictToken = center.addObserver(
            forName: LogiCenter.conflictChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshConflictIndicator()
        }
        conflictObserverTokens = [sessionToken, reportingToken, conflictToken]
    }

    private func unregisterConflictObservers() {
        let center = NotificationCenter.default
        for token in conflictObserverTokens {
            center.removeObserver(token)
        }
        conflictObserverTokens.removeAll()
    }
}

// MARK: - NSMenuDelegate (keyEquivalent 防冲突)

extension ButtonRemapCellView {

    func menuWillOpen(_ menu: NSMenu) {
        adjustMenuStructure(menu)
        enableKeyEquivalents(in: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        disableKeyEquivalents(in: menu)
    }

    private func adjustMenuStructure(_ menu: NSMenu) {
        guard menu.items.count >= 3 else { return }
        let placeholderItem = menu.items[0]
        let firstSeparator = menu.items[1]
        let unboundItem = menu.items[2]
        let hasBoundAction = (currentRemap?.isEnabled ?? false) || isCustomRecordingActive

        if hasBoundAction {
            placeholderItem.isHidden = false
            firstSeparator.isHidden = false
            unboundItem.title = NSLocalizedString("unbind", comment: "")
        } else {
            placeholderItem.isHidden = true
            firstSeparator.isHidden = true
            unboundItem.title = NSLocalizedString("unbound", comment: "")
        }
    }

    private func enableKeyEquivalents(in menu: NSMenu) {
        for item in menu.items {
            if let shortcut = item.representedObject as? SystemShortcut.Shortcut {
                let keyEquivalent = shortcut.keyEquivalent
                item.keyEquivalent = keyEquivalent.keyEquivalent
                item.keyEquivalentModifierMask = keyEquivalent.modifierMask
            }
            if let submenu = item.submenu {
                enableKeyEquivalents(in: submenu)
            }
        }
    }

    private func disableKeyEquivalents(in menu: NSMenu) {
        for item in menu.items {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            if let submenu = item.submenu {
                disableKeyEquivalents(in: submenu)
            }
        }
    }
}

// MARK: - KeyRecorderDelegate (自定义键录制)

extension ButtonRemapCellView: KeyRecorderDelegate {

    func onRecordingStarted(_ recorder: KeyRecorder) {
        isCustomRecordingActive = true
        DispatchQueue.main.async {
            self.refreshActionDisplay()
        }
    }

    func onRecordingStopped(_ recorder: KeyRecorder, didRecord: Bool) {
        isCustomRecordingActive = false
        guard !didRecord else { return }
        DispatchQueue.main.async {
            self.refreshActionDisplay()
            self.refreshConflictIndicator()
        }
    }

    func onEventRecorded(_ recorder: KeyRecorder, didRecordEvent event: InputEvent, isDuplicate: Bool) {
        guard !isDuplicate else {
            restoreDisplayAfterRejectedCustomRecording()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + KeyRecorder.recordingFeedbackDelay(isDuplicate: false)) { [weak self] in
            guard let self = self, let remap = self.currentRemap else { return }
            self.isCustomRecordingActive = false
            self.currentRemap = ButtonRemap(
                id: remap.id,
                trigger: remap.trigger,
                precondition: remap.precondition,
                effect: .customKey(code: event.code, modifiers: UInt64(event.modifiers.rawValue)),
                isEnabled: true,
                createdAt: remap.createdAt
            )
            self.refreshActionDisplay()
            self.onCustomKeyRecorded?(event.code, UInt64(event.modifiers.rawValue))
        }
    }

    func validateRecordedEvent(_ recorder: KeyRecorder, event: InputEvent) -> Bool {
        guard let remap = currentRemap else { return true }
        // 不允许把"触发按钮本身"录成自定义键 (会造成递归)
        return !(event.type == .mouse && event.code == remap.trigger.buttonNumber)
    }

    private func restoreDisplayAfterRejectedCustomRecording() {
        DispatchQueue.main.asyncAfter(deadline: .now() + KeyRecorder.recordingFeedbackDelay(isDuplicate: true)) { [weak self] in
            guard let self = self else { return }
            self.isCustomRecordingActive = false
            self.refreshActionDisplay()
            DispatchQueue.main.async {
                self.refreshConflictIndicator()
            }
        }
    }
}
