//
//  PreferencesButtonsViewController.swift
//  Mos
//  按钮绑定配置界面
//  Created by Claude on 2025/8/10.
//  Copyright © 2025年 Caldis. All rights reserved.
//

import Cocoa

class PreferencesButtonsViewController: NSViewController {

    // MARK: - Recorder
    private let gestureRecorder = ButtonGestureRecorder()

    // MARK: - Data
    private var buttonRemaps: [ButtonRemap] = []
    /// 分组平铺展示行: 每个鼠标按键一个 2 级标题行, 其后是该按键的绑定行
    fileprivate enum ButtonDisplayRow {
        case header(button: UInt16)
        case remap(ButtonRemap)
    }
    private var buttonDisplayRows: [ButtonDisplayRow] = []
    private var currentOpenTargetPopover: OpenTargetConfigPopover?

    // MARK: - UI Elements
    // 表格
    @IBOutlet weak var tableHead: NSVisualEffectView!
    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var tableEmpty: NSView!
    @IBOutlet weak var tableFoot: NSView!
    // 按钮
    @IBOutlet weak var createButton: PrimaryButton!
    @IBOutlet weak var addButton: NSButton!
    @IBOutlet weak var delButton: NSButton!
    // Logi HID 活动指示器 (底部右下角 spinner, 仅与 UI 呈现相关, 不参与业务逻辑判定)
    @IBOutlet weak var activityIndicator: NSProgressIndicator!

    // MARK: - Activity Indicator State (UI-only)
    /// 最短可见时长 (秒): 防止快速结束的查询让 spinner 只闪一下造成困惑.
    private static let activityIndicatorMinVisibleDuration: TimeInterval = 0.5
    /// popover 可见时的轮询间隔 (秒); 只在 popover show 期间开启, 关闭即停.
    private static let activityPopoverPollInterval: TimeInterval = 0.25
    /// 热区 overlay 尺寸 (pt). spinner 本身只有 12pt, 直接作为 hover 热区太小;
    /// 和冲突图标 ButtonTableCellView.conflictHitSize=28 取齐, hover 体验一致.
    private static let activityHitSize: CGFloat = 28
    /// 透明热区容器, 覆盖在 spinner 中心位置, 承担 tracking area — spinner 本身不做事件.
    private var activityHitOverlay: NSView?
    /// spinner 开始动画的时间戳 (主线程读写).
    private var activityIndicatorShownAt: Date?
    /// busy 翻回 false 但未满最短时长时的延迟停止任务; 若中途再次 busy=true 则取消.
    private var pendingActivityStopWorkItem: DispatchWorkItem?
    /// hover popover 与其 content VC (懒创建, 仅在首次 hover 时产生).
    /// content VC 复用 AdaptivePopover, 自动算尺寸 — 本 VC 只管文案更新.
    private var activityPopover: NSPopover?
    private var activityPopoverContent: ActivityPopoverViewController?
    /// popover 展示期间的轮询 timer; 关闭时必须 invalidate.
    private var activityPopoverPollTimer: Timer?
    /// spinner 上的 tracking area, bounds 变化时需重建.
    private var activityTrackingArea: NSTrackingArea?

    override func viewDidLoad() {
        super.viewDidLoad()
        // 设置代理
        gestureRecorder.delegate = self
        tableView.delegate = self
        tableView.dataSource = self
        // 读取设置
        loadOptionsToView()
        // 指示器: tooltip + 订阅 Manager 活动状态变化通知
        setupActivityIndicator()
    }

    override func viewWillAppear() {
        // 检查表格数据
        toggleNoDataHint()
        // 设置录制按钮回调
        setupRecordButtonCallback()
        // 触发一次冲突状态刷新 (30s 内最多跑一次,异步)
        LogiCenter.shared.refreshReportingStates()
        // 面板出现时同步一次当前 busy 状态, 避免错过此前发出的通知
        syncActivityIndicatorWithManager()
    }

    override func viewWillDisappear() {
        // 切 tab / 关窗时彻底收敛 popover + 轮询, 避免后台空转.
        closeActivityPopoverIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pendingActivityStopWorkItem?.cancel()
        activityPopoverPollTimer?.invalidate()
        activityPopover?.performClose(nil)
    }

    // 添加
    @IBAction func addItemClick(_ sender: NSButton) {
        gestureRecorder.startRecording(from: sender)
    }
    // 删除
    @IBAction func removeItemClick(_ sender: NSButton) {
        // 确保选择了行
        guard let remap = remap(atDisplayRow: tableView.selectedRow) else { return }
        // 统一通过 removeRemap 处理删除逻辑
        removeRemap(id: remap.id)
        // 更新删除按钮状态
        updateDelButtonState()
    }
}

/**
 * 数据持久化
 **/
extension PreferencesButtonsViewController {
    // 从 Options 加载到界面
    func loadOptionsToView() {
        buttonRemaps = Options.shared.buttons.remaps
        rebuildDisplayRows()
        tableView.reloadData()
        toggleNoDataHint()
    }

    /// 按鼠标按键分组重建平铺展示行 (按键号升序, 组内保持配置顺序)
    private func rebuildDisplayRows() {
        var rows: [ButtonDisplayRow] = []
        let grouped = Dictionary(grouping: buttonRemaps, by: { $0.trigger.buttonNumber })
        for button in grouped.keys.sorted() {
            rows.append(.header(button: button))
            for remap in grouped[button] ?? [] {
                rows.append(.remap(remap))
            }
        }
        buttonDisplayRows = rows
    }

    /// 展示行 → 绑定行映射 (标题行返回 nil)
    private func remap(atDisplayRow row: Int) -> ButtonRemap? {
        guard row >= 0, row < buttonDisplayRows.count else { return nil }
        if case .remap(let remap) = buttonDisplayRows[row] {
            return remap
        }
        return nil
    }

    // 保存界面到 Options
    // 缓存失效与 HID++ divert 用量同步由 Options 订阅自动完成 (ButtonUtils / LogiUsageBootstrap)
    func syncViewWithOptions() {
        Options.shared.buttons.remaps = buttonRemaps
    }

    // 更新删除按钮状态
    func updateDelButtonState() {
        delButton.isEnabled = tableView.selectedRow != -1
    }

    // 设置录制按钮回调
    private func setupRecordButtonCallback() {
        createButton.onMouseDown = { [weak self] target in
            self?.gestureRecorder.startRecording(from: target)
        }
    }
    
    private func addRecordedEvent(button: UInt16, modifiers: CGEventFlags, trigger: ButtonTrigger) {
        let precondition = ButtonPrecondition(keyboardModifiers: UInt(modifiers.rawValue))
        let normalizedDuplicate = buttonRemaps.contains {
            $0.trigger == trigger && $0.precondition == precondition
        }

        if normalizedDuplicate {
            if let existing = buttonRemaps.first(where: {
                $0.trigger == trigger && $0.precondition == precondition
            }) {
                highlightExistingRow(with: existing.id)
            }
            return
        }

        let remap = ButtonRemap(
            trigger: trigger,
            precondition: precondition,
            effect: .systemShortcut(identifier: "copy"),
            isEnabled: false
        )
        buttonRemaps.append(remap)
        rebuildDisplayRows()
        tableView.reloadData()
        toggleNoDataHint()
        notifyBLEHIDPPUnstableIfNeeded(for: button)
        syncViewWithOptions()
    }

    private func notifyBLEHIDPPUnstableIfNeeded(for code: UInt16) {
        guard LogiCenter.shared.isLogiCode(code) else { return }
        let status = ButtonCapturePresentationStatus.from(
            LogiCenter.shared.buttonCaptureDiagnosis(forMosCode: code)
        )
        guard status == .bleHIDPPUnstable else { return }
        LogiCenter.shared.showBLEHIDPPUnstableToast(forMosCode: code)
    }

    // 高亮已存在的行 (用于重复录制的视觉反馈)
    private func highlightExistingRow(with id: UUID) {
        guard let row = tableView.row(forRemap: id, in: buttonDisplayRows) else { return }
        tableView.deselectAll(nil)
        tableView.scrollRowToVisible(row)
        if let cellView = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ButtonRemapCellView {
            cellView.highlight()
        }
    }

    // 删除按钮重映射
    func removeRemap(id: UUID) {
        buttonRemaps.removeAll(where: { $0.id == id })
        rebuildDisplayRows()
        tableView.reloadData()
        toggleNoDataHint()
        syncViewWithOptions()
    }

    /// 更新动作 (nil = 未绑定)
    func updateEffect(id: UUID, effect: ButtonEffect?) {
        guard let index = buttonRemaps.firstIndex(where: { $0.id == id }) else { return }
        let old = buttonRemaps[index]
        buttonRemaps[index] = ButtonRemap(
            id: old.id,
            trigger: old.trigger,
            precondition: old.precondition,
            effect: effect ?? old.effect,
            isEnabled: effect != nil,
            createdAt: old.createdAt
        )
        rebuildDisplayRows()
        syncViewWithOptions()
    }

    /// 更新动作 (自定义键)
    func updateCustomKey(id: UUID, code: UInt16, modifiers: UInt64) {
        updateEffect(id: id, effect: .customKey(code: code, modifiers: modifiers))
    }

    private func presentOpenTargetPopover(forBindingID id: UUID) {
        guard let index = buttonRemaps.firstIndex(where: { $0.id == id }) else { return }
        guard let row = tableView.row(forRemap: id, in: buttonDisplayRows) else { return }
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? ButtonRemapCellView else { return }

        let existing: OpenTargetPayload?
        if case .openTarget(let payload) = buttonRemaps[index].effect {
            existing = payload
        } else {
            existing = nil
        }

        let popover = OpenTargetConfigPopover()
        currentOpenTargetPopover = popover
        popover.onCommit = { [weak self] payload in
            self?.updateEffect(id: id, effect: .openTarget(payload: payload))
            self?.currentOpenTargetPopover = nil
        }
        popover.onCancel = { [weak self] in
            self?.currentOpenTargetPopover = nil
        }
        popover.show(at: cell.actionPopUpButton, existing: existing)
    }
}

/**
 * 表格区域渲染及操作
 **/
extension PreferencesButtonsViewController: NSTableViewDelegate, NSTableViewDataSource {
    // 无数据
    func toggleNoDataHint() {
        let hasData = buttonRemaps.count != 0
        updateViewVisibility(view: createButton, visible: !hasData)
        updateViewVisibility(view: tableEmpty, visible: !hasData)
        updateViewVisibility(view: tableHead, visible: hasData)
        updateViewVisibility(view: tableFoot, visible: hasData)
    }
    private func updateViewVisibility(view: NSView, visible: Bool) {
        view.isHidden = !visible
        view.animator().alphaValue = visible ? 1 : 0
    }
    
    // 表格数据源
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumnIdentifier = tableColumn?.identifier else { return nil }

        // 分组标题行 (2 级次要 title)
        if case .header(let button) = buttonDisplayRows[row] {
            return makeGroupHeaderView(button: button)
        }

        // 绑定行
        guard case .remap(let remap) = buttonDisplayRows[row] else { return nil }
        if let cell = tableView.makeView(withIdentifier: tableColumnIdentifier, owner: self) as? ButtonRemapCellView {
            cell.configure(
                with: remap,
                onEffectChanged: { [weak self] effect in
                    self?.updateEffect(id: remap.id, effect: effect)
                },
                onCustomKeyRecorded: { [weak self] code, modifiers in
                    self?.updateCustomKey(id: remap.id, code: code, modifiers: modifiers)
                },
                onOpenTargetSelectionRequested: { [weak self] in
                    self?.presentOpenTargetPopover(forBindingID: remap.id)
                }
            )
            return cell
        }

        return nil
    }

    /// 分组标题: 次要样式 (小字号 + 次级颜色), 展示按键名称与编号
    private func makeGroupHeaderView(button: UInt16) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ButtonGroupHeaderCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -8),
            ])
        }
        let name = KeyCode.mouseMap[button] ?? "Mouse(\(button))"
        let title = name.contains("\(button)") ? name : "\(name) (\(button))"
        cell.textField?.stringValue = title
        return cell
    }
    
    // 行高
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = buttonDisplayRows[row] {
            return 26
        }
        return 44
    }
    
    // 行数
    func numberOfRows(in tableView: NSTableView) -> Int {
        return buttonDisplayRows.count
    }

    // 标题行不可选中
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = buttonDisplayRows[row] {
            return false
        }
        return true
    }

    // 选择变化
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDelButtonState()
    }

    // Type Selection 支持
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard row < buttonDisplayRows.count,
              case .remap(let remap) = buttonDisplayRows[row] else { return nil }
        let event = InputEvent(
            type: .mouse,
            code: remap.trigger.buttonNumber,
            modifiers: CGEventFlags(rawValue: UInt64(remap.precondition.keyboardModifiers)),
            phase: .down,
            source: .hidPP,
            device: nil
        )
        let components = event.displayComponents
        // 去掉第一项（修饰键），只保留实际按键用于匹配
        let keyOnly = components.count > 1 ? Array(components.dropFirst()) : components
        return keyOnly.joined(separator: " ")
    }
}

// MARK: - Logi Activity Indicator
extension PreferencesButtonsViewController {
    /// 一次性配置: tooltip + tracking area + 订阅 Manager 的活动状态通知.
    /// 通知回调 (main-thread post) 直接驱动 NSProgressIndicator, 不做任何 HID 查询,
    /// 保证视图层与检测逻辑彻底解耦.
    fileprivate func setupActivityIndicator() {
        // 不设 toolTip: 自定义 NSPopover 信息更丰富 (phase / 设备 / 进度),
        // 两者并存会在 hover 时同时弹出系统黄色 tooltip + popover, 视觉冲突.
        activityIndicator.isDisplayedWhenStopped = false
        // 程序化加一个 28pt 透明热区 overlay 覆盖 spinner 中心 (对齐 ButtonTableCellView 的 conflictHitSize=28).
        // spinner 改 mini (12pt) 后热区需独立外扩, 否则 hover 很难命中.
        setupActivityHitOverlay()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleActivityStateChanged(_:)),
            name: LogiCenter.activityChanged,
            object: nil
        )
    }

    /// 在 spinner 中心覆盖一个不绘制内容的 NSView 做热区载体, tracking area 挂它上面.
    /// overlay 一次性加入 root view, 约束跟随 spinner center, 生命周期与 VC 一致, 无需 layout 回调重建.
    private func setupActivityHitOverlay() {
        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: activityIndicator.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: activityIndicator.centerYAnchor),
            overlay.widthAnchor.constraint(equalToConstant: Self.activityHitSize),
            overlay.heightAnchor.constraint(equalToConstant: Self.activityHitSize)
        ])
        activityHitOverlay = overlay

        let area = NSTrackingArea(
            rect: .zero,  // .inVisibleRect 模式下忽略 rect, 自动用 overlay 可见区域
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        overlay.addTrackingArea(area)
        activityTrackingArea = area
    }

    @objc private func handleActivityStateChanged(_ note: Notification) {
        syncActivityIndicatorWithManager()
    }

    /// 把当前 Manager.isBusy 映射到 spinner 的可见性, 带 500ms 最短显示;
    /// 同时把 busy=false 同步到 popover (若正在展示, 立即关闭).
    fileprivate func syncActivityIndicatorWithManager() {
        let busy = LogiCenter.shared.isBusy
        if busy {
            pendingActivityStopWorkItem?.cancel()
            pendingActivityStopWorkItem = nil
            if activityIndicatorShownAt == nil {
                activityIndicatorShownAt = Date()
                activityIndicator.startAnimation(nil)
            }
        } else {
            // 用户要求: loading 结束时 popover 同步回收 (即使还在 hover).
            closeActivityPopoverIfNeeded()
            scheduleActivityIndicatorStop()
        }
    }

    private func scheduleActivityIndicatorStop() {
        guard let shownAt = activityIndicatorShownAt else { return }
        let elapsed = Date().timeIntervalSince(shownAt)
        let minDuration = Self.activityIndicatorMinVisibleDuration
        if elapsed >= minDuration {
            stopActivityIndicatorNow()
            return
        }
        pendingActivityStopWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.stopActivityIndicatorNow()
        }
        pendingActivityStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (minDuration - elapsed), execute: work)
    }

    private func stopActivityIndicatorNow() {
        pendingActivityStopWorkItem = nil
        activityIndicatorShownAt = nil
        activityIndicator.stopAnimation(nil)
    }

    // MARK: - Hover Popover

    override func mouseEntered(with event: NSEvent) {
        // 只对 spinner 的 tracking area 响应; 其他未来可能加的 tracking 不干扰.
        guard event.trackingArea === activityTrackingArea else {
            super.mouseEntered(with: event)
            return
        }
        // 不忙时不弹 (即便 tracking area 理论上已 hidden 了也兜一层)
        guard LogiCenter.shared.isBusy else { return }
        showActivityPopover()
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === activityTrackingArea else {
            super.mouseExited(with: event)
            return
        }
        closeActivityPopoverIfNeeded()
    }

    /// 参考 `ButtonTableCellView.showConflictPopover` 的极简模式:
    /// - 每次 hover 进入新建一个 NSPopover, 不复用;
    /// - 用 `conflictPopover == nil` 作为互斥守卫;
    /// - hide 时同步 `close() + popover = nil`, 不依赖 delegate 回调.
    /// 这样避免 `performClose` 关闭动画或 `.transient` 自动行为引入的中间态,
    /// 用户 mouseExit 后立即重入时 guard 放行, popover 能即刻出现.
    private func showActivityPopover() {
        guard activityPopover == nil else { return }
        let popover = makeActivityPopover()
        activityPopover = popover
        refreshActivityPopoverContent()
        popover.show(relativeTo: activityIndicator.bounds,
                     of: activityIndicator,
                     preferredEdge: .maxY)
        // 打开轮询 (main RunLoop .common, menu tracking 期间也保持节奏);
        // 关闭由 closeActivityPopoverIfNeeded 统一收口, 不依赖 popoverDidClose.
        let timer = Timer(timeInterval: Self.activityPopoverPollInterval, repeats: true) { [weak self] _ in
            self?.refreshActivityPopoverContent()
        }
        RunLoop.main.add(timer, forMode: .common)
        activityPopoverPollTimer = timer
    }

    private func closeActivityPopoverIfNeeded() {
        activityPopoverPollTimer?.invalidate()
        activityPopoverPollTimer = nil
        activityPopover?.close()
        activityPopover = nil
        activityPopoverContent = nil
    }

    /// 从 Manager 拉快照并渲染. 没有活跃 session 时展示兜底文案 (过渡态).
    /// 尺寸自适应完全由 AdaptivePopover (content VC 的父类) 负责, 本方法只推文案.
    private func refreshActivityPopoverContent() {
        guard let content = activityPopoverContent else { return }
        let summary = LogiCenter.shared.currentActivitySummary
        content.setMessage(Self.formatActivitySummary(summary))
    }

    /// 聚合多个 session 成一行或多行简短文字.
    /// 单设备: "正在刷新冲突状态 · MX Master 3S · 5/12"
    /// 多设备: 每个设备一行
    private static func formatActivitySummary(_ summary: [SessionActivityStatus]) -> String {
        guard !summary.isEmpty else {
            return NSLocalizedString("button_activity_popover_fallback",
                                     comment: "Shown when busy state ends while popover is closing")
        }
        return summary.map { status -> String in
            let phaseLabel: String
            switch status.phase {
            case .discovery:
                phaseLabel = NSLocalizedString("button_activity_phase_discovery",
                                               comment: "Phase: initial handshake / feature discovery")
            case .reportingQuery:
                phaseLabel = NSLocalizedString("button_activity_phase_reporting",
                                               comment: "Phase: refreshing per-button conflict state")
            }
            var line = "\(phaseLabel) · \(status.deviceName)"
            if let progress = status.progress {
                line += " · \(progress.current)/\(progress.total)"
            }
            return line
        }.joined(separator: "\n")
    }

    private func makeActivityPopover() -> NSPopover {
        let popover = NSPopover()
        // .applicationDefined: 开合完全由 mouseEnter/Exit 控制, 无点击外部自动关闭的副作用,
        // 和 ButtonTableCellView 冲突图标 popover 行为对齐.
        popover.behavior = .applicationDefined
        popover.animates = true
        let content = ActivityPopoverViewController()
        popover.contentViewController = content
        activityPopoverContent = content
        return popover
    }
}

private extension NSTableView {
    func row(forRemap id: UUID, in displayRows: [PreferencesButtonsViewController.ButtonDisplayRow]) -> Int? {
        return displayRows.firstIndex { row in
            if case .remap(let remap) = row {
                return remap.id == id
            }
            return false
        }
    }
}

// MARK: - ButtonGestureRecorderDelegate
extension PreferencesButtonsViewController: ButtonGestureRecorderDelegate {
    func buttonGestureRecorder(
        _ recorder: ButtonGestureRecorder,
        didRecord button: UInt16,
        modifiers: CGEventFlags,
        trigger: ButtonTrigger
    ) {
        addRecordedEvent(button: button, modifiers: modifiers, trigger: trigger)
    }

    func buttonGestureRecorderDidCancel(_ recorder: ButtonGestureRecorder) {}
}
