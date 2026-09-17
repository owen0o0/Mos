//
//  PreferencesDevicesViewController.swift
//  Mos
//  设备设置页: 雷蛇鼠标 (电量 / DPI / 回报率)
//  Created by Codex on 2026/8/18.
//  Copyright © 2026 Caldis. All rights reserved.
//

import Cocoa

class PreferencesDevicesViewController: NSViewController {

    /// 设备页固定尺寸 (与 storyboard 场景一致, 保证 Tab 切换时窗口尺寸正确)
    static let preferredSize = NSSize(width: 450, height: 320)

    private let manager = RazerDeviceManager.shared

    private var stackView: NSStackView!
    private var emptyLabel: NSTextField!
    private var emptyIcon: NSTextField!
    private var deviceViews: [UInt32: DeviceRowView] = [:]
    private var dpiApplyTimers: [UInt32: Timer] = [:]

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        manager.onDevicesChanged = { [weak self] in
            self?.reloadDevices()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // 显式固定尺寸; 父级 Tab 控制器在 didSelect 时按视图 frame 测量窗口,
        // 这里设置后在下一轮 RunLoop 重新测量一次, 避免切 tab 时窗口尺寸异常
        view.frame.size = Self.preferredSize
        preferredContentSize = Self.preferredSize
        manager.start()
        manager.refreshAll()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // 视图已进入 Tab 容器后再强制一次窗口尺寸, 确保宽度/高度正确
        view.frame.size = Self.preferredSize
        preferredContentSize = Self.preferredSize
        DispatchQueue.main.async { [weak self] in
            (self?.parent as? PreferencesTabViewController)?.updateWindowSize()
        }
    }

    // MARK: - UI 构建

    private func buildUI() {
        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 3
        header.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: NSLocalizedString("devices_section_title", comment: ""))
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = NSTextField(labelWithString: NSLocalizedString("devices_section_subtitle", comment: ""))
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        header.addArrangedSubview(title)
        header.addArrangedSubview(subtitle)

        emptyIcon = NSTextField(labelWithString: "🖱️")
        emptyIcon.font = NSFont.systemFont(ofSize: 40)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel = NSTextField(wrappingLabelWithString: NSLocalizedString("devices_empty_hint", comment: ""))
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(stackView)
        view.addSubview(emptyIcon)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -22),

            stackView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),

            emptyIcon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -12),
            emptyLabel.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 6),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }

    // MARK: - 数据刷新

    private func reloadDevices() {
        let states = manager.devices
        emptyLabel.isHidden = !states.isEmpty
        emptyIcon.isHidden = !states.isEmpty

        let currentIDs = Set(deviceViews.keys)
        let newIDs = Set(states.map { $0.locationID })
        for removedID in currentIDs.subtracting(newIDs) {
            deviceViews.removeValue(forKey: removedID)?.removeFromSuperview()
            dpiApplyTimers.removeValue(forKey: removedID)?.invalidate()
        }

        for state in states {
            let row: DeviceRowView
            if let existing = deviceViews[state.locationID] {
                row = existing
            } else {
                row = DeviceRowView()
                row.onDPIChanged = { [weak self] locationID, dpi in
                    self?.scheduleDPIApply(locationID: locationID, dpi: dpi)
                }
                row.onPollRateChanged = { [weak self] locationID, pollRate in
                    self?.manager.setPollRate(pollRate, forLocationID: locationID)
                }
                deviceViews[state.locationID] = row
                stackView.addArrangedSubview(row)
                // 显式钉死行宽 = 列表宽, 不依赖 stack 对齐行为
                row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            }
            row.update(with: state)
        }
    }

    private func scheduleDPIApply(locationID: UInt32, dpi: Int) {
        dpiApplyTimers[locationID]?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.manager.setDPI(dpi, forLocationID: locationID)
            self?.dpiApplyTimers.removeValue(forKey: locationID)
        }
        RunLoop.main.add(timer, forMode: .common)
        dpiApplyTimers[locationID] = timer
    }
}

// MARK: - 设备行

private final class DeviceRowView: NSView {

    /// DPI 档位 (滑条索引 0...4)
    static let dpiPresets = [400, 800, 1600, 3200, 6400]

    var onDPIChanged: ((UInt32, Int) -> Void)?
    var onPollRateChanged: ((UInt32, Int) -> Void)?

    private var locationID: UInt32 = 0
    private let nameLabel = NSTextField(labelWithString: "")
    private let batteryBadge = BatteryBadgeView()
    private let dpiSlider = NSSlider(value: 0, minValue: 0, maxValue: 4, target: nil, action: nil)
    private let dpiValueLabel = NSTextField(labelWithString: "")
    private let tickLabels: [NSTextField] = DeviceRowView.dpiPresets.map {
        let label = NSTextField(labelWithString: "\($0)")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }
    private let pollPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var isUpdating = false

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        // 卡片背景
        let card = DeviceCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // 头部: 名称 + 电量徽标
        let header = NSStackView(views: [nameLabel, batteryBadge])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        batteryBadge.setContentHuggingPriority(.required, for: .horizontal)

        // 分隔线
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // DPI 区: 标题行 + 全宽滑条 + 档位标签行
        let dpiTitle = Self.makeSectionLabel(
            title: NSLocalizedString("devices_dpi", comment: ""),
            symbol: "scope"
        )

        dpiValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        dpiValueLabel.alignment = .right
        dpiValueLabel.translatesAutoresizingMaskIntoConstraints = false
        dpiValueLabel.setContentHuggingPriority(.required, for: .horizontal)

        dpiSlider.isContinuous = true
        dpiSlider.numberOfTickMarks = DeviceRowView.dpiPresets.count
        dpiSlider.allowsTickMarkValuesOnly = true
        dpiSlider.tickMarkPosition = .below
        dpiSlider.controlSize = .small
        dpiSlider.target = self
        dpiSlider.action = #selector(dpiSliderChanged(_:))
        dpiSlider.translatesAutoresizingMaskIntoConstraints = false
        dpiSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let tickRow = NSStackView(views: tickLabels)
        tickRow.orientation = .horizontal
        tickRow.distribution = .fillEqually
        tickRow.spacing = 0
        tickRow.translatesAutoresizingMaskIntoConstraints = false
        tickRow.alignment = .centerY

        let dpiHeaderRow = NSStackView(views: [dpiTitle, dpiValueLabel])
        dpiHeaderRow.orientation = .horizontal
        dpiHeaderRow.spacing = 10
        dpiHeaderRow.translatesAutoresizingMaskIntoConstraints = false
        dpiValueLabel.widthAnchor.constraint(equalToConstant: 48).isActive = true

        // 回报率行
        let pollTitle = Self.makeSectionLabel(
            title: NSLocalizedString("devices_poll_rate", comment: ""),
            symbol: "timer"
        )
        pollPopUp.controlSize = .small
        pollPopUp.target = self
        pollPopUp.action = #selector(pollRateChanged(_:))
        pollPopUp.translatesAutoresizingMaskIntoConstraints = false

        let pollRow = NSStackView(views: [pollTitle, pollPopUp])
        pollRow.orientation = .horizontal
        pollRow.spacing = 10
        pollRow.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, divider, dpiHeaderRow, dpiSlider, tickRow, pollRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.translatesAutoresizingMaskIntoConstraints = false
        card.contentView?.addSubview(content)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: widthAnchor),

            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),

            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            divider.widthAnchor.constraint(equalTo: content.widthAnchor),
            dpiHeaderRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            dpiSlider.widthAnchor.constraint(equalTo: content.widthAnchor),
            tickRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            pollRow.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    private var lastState: RazerDeviceState?

    func update(with state: RazerDeviceState) {
        guard lastState != state else { return }
        lastState = state
        locationID = state.locationID
        nameLabel.stringValue = state.name

        if let percent = state.batteryPercent {
            batteryBadge.isHidden = false
            batteryBadge.update(percent: percent, charging: state.isCharging == true)
        } else {
            batteryBadge.isHidden = true
        }

        isUpdating = true
        if let dpi = state.dpi {
            let nearestIndex = Self.dpiPresets.enumerated()
                .min(by: { abs($0.element - dpi) < abs($1.element - dpi) })?.offset ?? 0
            dpiSlider.doubleValue = Double(nearestIndex)
            dpiValueLabel.stringValue = "\(dpi)"
        } else {
            dpiSlider.doubleValue = 2
            dpiValueLabel.stringValue = "—"
        }
        if let pollRate = state.pollRate {
            selectPollRate(pollRate)
        }
        isUpdating = false

        dpiSlider.isEnabled = state.supportsDPI
        pollPopUp.isEnabled = state.supportsPollRate
    }

    private func selectPollRate(_ value: Int) {
        if pollPopUp.itemArray.isEmpty {
            for rate in [125, 500, 1000] {
                pollPopUp.addItem(withTitle: "\(rate) Hz")
            }
        }
        for (index, item) in pollPopUp.itemArray.enumerated() where item.title.hasPrefix("\(value)") {
            pollPopUp.selectItem(at: index)
            return
        }
    }

    @objc private func dpiSliderChanged(_ sender: NSSlider) {
        guard !isUpdating else { return }
        let index = min(max(Int(sender.doubleValue.rounded()), 0), DeviceRowView.dpiPresets.count - 1)
        let value = DeviceRowView.dpiPresets[index]
        dpiValueLabel.stringValue = "\(value)"
        onDPIChanged?(locationID, value)
    }

    @objc private func pollRateChanged(_ sender: NSPopUpButton) {
        guard !isUpdating,
              let title = sender.titleOfSelectedItem,
              let value = Int(title.replacingOccurrences(of: " Hz", with: "")) else { return }
        onPollRateChanged?(locationID, value)
    }

    /// 带 SF Symbol 图标的小标题 (macOS 11+ 显示图标, 低版本仅文本)
    private static func makeSectionLabel(title: String, symbol: String?) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        guard #available(macOS 11.0, *),
              let symbol,
              let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else {
            return label
        }
        let imageView = NSImageView(image: image)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: 14).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 14).isActive = true
        imageView.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

// MARK: - 卡片背景 (圆角 + 底色)

enum DeviceCardAppearance {
    static let cornerRadius: CGFloat = 10
    static let borderWidth: CGFloat = 1

    static func apply(to box: NSBox) {
        box.boxType = .custom
        box.cornerRadius = cornerRadius
        box.borderWidth = borderWidth
        box.borderColor = .separatorColor
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.55)
    }
}

private final class DeviceCardView: NSBox {
    init() {
        super.init(frame: .zero)
        DeviceCardAppearance.apply(to: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - 电量徽标 (圆角胶囊)

private final class BatteryBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        if #available(macOS 10.14, *) {
            layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.12).cgColor
        }
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(percent: Int, charging: Bool) {
        let icon = charging ? "⚡" : "🔋"
        label.stringValue = "\(icon) \(percent)%"
        label.textColor = percent <= 20 ? .systemRed : .labelColor
    }
}
