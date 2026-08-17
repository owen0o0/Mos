import XCTest
@testable import Mos_Debug

final class ButtonRemapEngineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Options.shared.buttons.remaps = []
        ButtonUtils.shared.invalidateCache()
        InputProcessor.shared.setClickCycleTestingDelays(hold: 0.05, expiry: 0.06)
        MouseInteractionSessionController.shared.setTestingMotionTapHooks()
        MouseInteractionSessionController.shared.clearAllSessions()
        ShortcutExecutor.shared.setTestingMouseEventObserver()
        ShortcutExecutor.shared.scrollActionPort = ScrollCore.shared
        ShortcutExecutor.shared.scrollModificationPort = ScrollCore.shared
        ShortcutExecutor.shared.modifierFlagsProvider = InputProcessor.shared
        InputProcessor.shared.clearActiveBindings()
        TouchSimulator.testingPostHook = nil
        TouchSimulator.resetDockSwipeStateForTesting()
        DragSessionManager.shared.testingPostHook = nil
        for kind in ScrollModificationKind.allCases {
            ScrollCore.shared.setScrollModification(kind, active: false)
        }
        ScrollCore.shared.cancelScrollGestureForTesting()
    }

    override func tearDown() {
        InputProcessor.shared.clearActiveBindings()
        InputProcessor.shared.setClickCycleTestingDelays()
        MouseInteractionSessionController.shared.clearAllSessions()
        MouseInteractionSessionController.shared.clearTestingMotionTapHooks()
        ShortcutExecutor.shared.clearTestingMouseEventObserver()
        TouchSimulator.testingPostHook = nil
        TouchSimulator.resetDockSwipeStateForTesting()
        DragSessionManager.shared.testingPostHook = nil
        DragSessionManager.shared.stop()
        for kind in ScrollModificationKind.allCases {
            ScrollCore.shared.setScrollModification(kind, active: false)
        }
        ScrollCore.shared.cancelScrollGestureForTesting()
        Options.shared.buttons.remaps = []
        ButtonUtils.shared.invalidateCache()
        super.tearDown()
    }

    private func makeRemap(
        button: UInt16,
        level: Int = 1,
        duration: ButtonTriggerDuration = .click,
        effect: ButtonEffect,
        modifiers: UInt = 0
    ) -> ButtonRemap {
        return ButtonRemap(
            trigger: ButtonTrigger(buttonNumber: button, level: level, duration: duration),
            precondition: ButtonPrecondition(keyboardModifiers: modifiers),
            effect: effect
        )
    }

    private func mouseEvent(button: UInt16, phase: InputPhase) -> InputEvent {
        return InputEvent(
            type: .mouse,
            code: button,
            modifiers: CGEventFlags(rawValue: 0),
            phase: phase,
            source: .hidPP,
            device: nil
        )
    }

    private func runMainLoop(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    // MARK: - 基础路径

    func testSingleClickMouseAction_firesOnRelease() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .systemShortcut(identifier: "mouseLeftClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .down)), .consumed)
        XCTAssertTrue(observed.isEmpty)

        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .up)), .consumed)
        XCTAssertEqual(observed, [.leftMouseDown, .leftMouseUp])
    }

    func testMouseButton_withoutRemap_passthrough() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .systemShortcut(identifier: "mouseLeftClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 4, phase: .down)), .passthrough)
        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 4, phase: .up)), .passthrough)
    }

    func testKeyboardEvent_passthroughInNewEngine() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .systemShortcut(identifier: "mouseLeftClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        let keyDown = InputEvent(
            type: .keyboard,
            code: 56,
            modifiers: CGEventFlags(rawValue: 0),
            phase: .down,
            source: .cgEvent(CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)!),
            device: nil
        )
        XCTAssertEqual(InputProcessor.shared.process(keyDown), .passthrough)
    }

    // MARK: - 修饰键前置条件

    func testPreconditionModifier_requiresConfiguredFlags() {
        let commandMask = UInt(CGEventFlags.maskCommand.rawValue)
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .systemShortcut(identifier: "mouseLeftClick"), modifiers: commandMask)
        ]
        ButtonUtils.shared.invalidateCache()

        // 无 ⌘ → 放行
        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .down)), .passthrough)
        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .up)), .passthrough)

        // 带 ⌘ → 消费
        let withCommand = InputEvent(
            type: .mouse,
            code: 3,
            modifiers: CGEventFlags.maskCommand,
            phase: .down,
            source: .hidPP,
            device: nil
        )
        XCTAssertEqual(InputProcessor.shared.process(withCommand), .consumed)
        let withCommandUp = InputEvent(
            type: .mouse,
            code: 3,
            modifiers: CGEventFlags.maskCommand,
            phase: .up,
            source: .hidPP,
            device: nil
        )
        XCTAssertEqual(InputProcessor.shared.process(withCommandUp), .consumed)
    }

    // MARK: - 双击

    func testDoubleClick_secondPressFiresLevel2Action() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "mouseLeftClick")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "mouseRightClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertTrue(observed.isEmpty)

        // 第二次按下仍挂起, 松手后 level 2 提交
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        XCTAssertTrue(observed.isEmpty)
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertEqual(observed, [.rightMouseDown, .rightMouseUp])
    }

    func testDoubleClick_withUnboundSingleClick_firesLevel2() {
        // 复现: 单击行未绑定 (isEnabled=false) + 双击行有功能, 快速双击必须触发 level 2
        InputProcessor.shared.setClickCycleTestingDelays(hold: 0.25, expiry: 0.26)
        Options.shared.buttons.remaps = [
            ButtonRemap(
                trigger: ButtonTrigger(buttonNumber: 3, level: 1, duration: .click),
                precondition: ButtonPrecondition(keyboardModifiers: 0),
                effect: .systemShortcut(identifier: "mouseLeftClick"),
                isEnabled: false
            ),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "mouseRightClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertTrue(observed.isEmpty)

        runMainLoop(0.15)
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        runMainLoop(0.5)
        XCTAssertEqual(observed, [.rightMouseDown, .rightMouseUp])

        ShortcutExecutor.shared.setTestingMouseEventObserver { _ in }
    }

    func testClickLevelCombinations_unboundRowsDoNotBlockHigherLevels() {
        // 排查组合: 未绑定 (isEnabled=false) 的层级行不应阻塞更高层级触发
        InputProcessor.shared.setClickCycleTestingDelays(hold: 0.05, expiry: 0.06)

        func run(remaps: [ButtonRemap], clicks: Int, expected: [CGEventType]) {
            Options.shared.buttons.remaps = remaps
            ButtonUtils.shared.invalidateCache()
            var observed: [CGEventType] = []
            ShortcutExecutor.shared.setTestingMouseEventObserver { event in
                observed.append(event.type)
            }
            for _ in 0..<clicks {
                _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
                _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
            }
            runMainLoop(0.2)
            XCTAssertEqual(observed, expected)
        }

        let left = ButtonEffect.systemShortcut(identifier: "mouseLeftClick")
        let middle = ButtonEffect.systemShortcut(identifier: "mouseMiddleClick")
        let right = ButtonEffect.systemShortcut(identifier: "mouseRightClick")

        func remap(level: Int, effect: ButtonEffect, enabled: Bool = true) -> ButtonRemap {
            return ButtonRemap(
                trigger: ButtonTrigger(buttonNumber: 3, level: level, duration: .click),
                precondition: ButtonPrecondition(keyboardModifiers: 0),
                effect: effect,
                isEnabled: enabled
            )
        }

        // 1. 单击未绑定 + 双击绑定 → 双击
        run(remaps: [remap(level: 1, effect: left, enabled: false), remap(level: 2, effect: right)], clicks: 2, expected: [.rightMouseDown, .rightMouseUp])
        // 2. 只有双击 → 双击
        run(remaps: [remap(level: 2, effect: right)], clicks: 2, expected: [.rightMouseDown, .rightMouseUp])
        // 3. 单击未绑定 + 双击绑定 + 三击绑定 → 三击
        run(remaps: [
            remap(level: 1, effect: left, enabled: false),
            remap(level: 2, effect: middle),
            remap(level: 3, effect: right),
        ], clicks: 3, expected: [.rightMouseDown, .rightMouseUp])
        // 4. 单击未绑定 + 双击未绑定 + 三击绑定 → 三击
        run(remaps: [
            remap(level: 1, effect: left, enabled: false),
            remap(level: 2, effect: middle, enabled: false),
            remap(level: 3, effect: right),
        ], clicks: 3, expected: [.rightMouseDown, .rightMouseUp])
        // 5. 单击绑定 + 双击未绑定 + 三击绑定 → 三击
        run(remaps: [
            remap(level: 1, effect: left),
            remap(level: 2, effect: middle, enabled: false),
            remap(level: 3, effect: right),
        ], clicks: 3, expected: [.rightMouseDown, .rightMouseUp])
        // 6. 单击未绑定 + 双击绑定 + 长按未绑定 → 双击
        run(remaps: [
            remap(level: 1, effect: left, enabled: false),
            remap(level: 2, effect: right),
            ButtonRemap(
                trigger: ButtonTrigger(buttonNumber: 3, level: 1, duration: .hold),
                precondition: ButtonPrecondition(keyboardModifiers: 0),
                effect: left,
                isEnabled: false
            ),
        ], clicks: 2, expected: [.rightMouseDown, .rightMouseUp])
        // 7. 单击未绑定 + 双击绑定 + 拖动行 → 双击 (手势未使用)
        run(remaps: [
            remap(level: 1, effect: left, enabled: false),
            remap(level: 2, effect: right),
            makeRemap(button: 3, level: 1, duration: .drag, effect: .drag(mode: .twoFingerSwipe)),
        ], clicks: 2, expected: [.rightMouseDown, .rightMouseUp])

        ShortcutExecutor.shared.setTestingMouseEventObserver { _ in }
    }

    func testDoubleClick_timingGapFiresLevel2() {
        // 生产参数验证: 层级窗口 0.26s (从按下起算), 双击间隔 0.15s 应识别为双击
        InputProcessor.shared.setClickCycleTestingDelays(hold: 0.25, expiry: 0.26)
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "mouseLeftClick")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "mouseRightClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        // 第一次点击
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        runMainLoop(0.15)
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        runMainLoop(0.5)

        XCTAssertEqual(observed, [.rightMouseDown, .rightMouseUp])
    }

    func testTripleClick_timingGapsFiresLevel3() {
        InputProcessor.shared.setClickCycleTestingDelays(hold: 0.25, expiry: 0.26)
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "mouseLeftClick")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "mouseMiddleClick")),
            makeRemap(button: 3, level: 3, effect: .systemShortcut(identifier: "mouseRightClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        // 三次点击, 每次间隔 0.15s (在 0.26s 层级窗口内)
        for _ in 0..<3 {
            _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
            _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
            runMainLoop(0.15)
        }
        runMainLoop(0.5)

        XCTAssertEqual(observed, [.rightMouseDown, .rightMouseUp])
    }

    func testDoubleClick_withDragRow_coexistFiresLevel2() {
        // 复现用户配置: 单击 + 双击 + 按住拖动 共存时, 快速双击必须触发 level 2
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "mouseLeftClick")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "mouseRightClick")),
            makeRemap(button: 3, duration: .drag, effect: .drag(mode: .twoFingerSwipe))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        runMainLoop(0.5)

        XCTAssertEqual(observed, [.rightMouseDown, .rightMouseUp])
    }

    func testFullConfig_clickLevelsWithHoldDragScroll() {
        // 用户 Release 配置全量: 单击/双击/三击 + 长按 + 拖动 + 滚动, 快速三击 → level 3
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "mouseLeftClick")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "mouseMiddleClick")),
            makeRemap(button: 3, level: 3, effect: .systemShortcut(identifier: "mouseRightClick")),
            makeRemap(button: 3, duration: .hold, effect: .systemShortcut(identifier: "mouseLeftClick")),
            makeRemap(button: 3, duration: .drag, effect: .drag(mode: .twoFingerSwipe)),
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .zoom))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        for _ in 0..<3 {
            _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
            _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        }
        runMainLoop(0.5)

        XCTAssertEqual(observed, [.rightMouseDown, .rightMouseUp])
    }

    func testSingleClick_delayedWhenDoubleClickConfigured() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "mouseLeftClick")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "mouseRightClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertTrue(observed.isEmpty)

        runMainLoop(0.12)

        XCTAssertEqual(observed, [.leftMouseDown, .leftMouseUp])
    }

    // MARK: - 长按

    func testHold_firesAfterDelayAndReleasesOnUp() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .hold, effect: .systemShortcut(identifier: "mouseLeftClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .down)), .consumed)
        XCTAssertTrue(observed.isEmpty)

        runMainLoop(0.1)
        XCTAssertEqual(observed, [.leftMouseDown])

        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .up)), .consumed)
        XCTAssertEqual(observed, [.leftMouseDown, .leftMouseUp])
    }

    func testClearActiveBindings_releasesHeldHoldSession() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .hold, effect: .systemShortcut(identifier: "mouseLeftClick"))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        runMainLoop(0.1)
        XCTAssertEqual(observed, [.leftMouseDown])

        InputProcessor.shared.clearActiveBindings()
        XCTAssertEqual(observed, [.leftMouseDown, .leftMouseUp])
    }

    // MARK: - 新动作类型

    func testSmartZoom_postsZoomToggleGesture() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .smartZoom)
        ]
        ButtonUtils.shared.invalidateCache()

        var hidTypes: [Int64] = []
        TouchSimulator.testingPostHook = { event in
            hidTypes.append(event.getIntegerValueField(CGEventField(rawValue: 110)!))
        }

        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .down)), .consumed)
        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .up)), .consumed)
        XCTAssertEqual(hidTypes, [22])
    }

    func testLookUp_postsResolvedShortcutKeyEvents() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .lookUp)
        ]
        ButtonUtils.shared.invalidateCache()

        var keyEvents: [(code: Int64, flags: UInt64, down: Bool)] = []
        ShortcutExecutor.shared.setTestingKeyEventObserver { event in
            keyEvents.append((
                code: event.getIntegerValueField(.keyboardEventKeycode),
                flags: event.flags.rawValue,
                down: event.type == .keyDown
            ))
        }

        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .down)), .consumed)
        XCTAssertEqual(InputProcessor.shared.process(mouseEvent(button: 3, phase: .up)), .consumed)

        // 优先走系统 Look Up SHK (70) 配置, 未配置时回退 Command-Control-D
        let expected = SystemShortcut.resolveSystemShortcut("lookUp")
            ?? (code: CGKeyCode(2), modifiers: UInt64(NSEvent.ModifierFlags([.command, .control]).rawValue))
        XCTAssertEqual(keyEvents.count, 2)
        XCTAssertEqual(keyEvents[0].code, Int64(expected.code))
        XCTAssertEqual(keyEvents[0].flags, expected.modifiers)
        XCTAssertTrue(keyEvents[0].down)
        XCTAssertFalse(keyEvents[1].down)

        ShortcutExecutor.shared.clearTestingKeyEventObserver()
    }

    func testSystemDefinedEvent_postsDownAndUp() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .systemDefinedEvent(type: 19, flags: 0))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertEqual(observed.count, 2)
    }

    func testMouseButtonClicks_postsConfiguredCount() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .mouseButtonClicks(buttonNumber: 5, count: 3))
        ]
        ButtonUtils.shared.invalidateCache()

        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertEqual(observed.filter { $0 == .otherMouseDown }.count, 3)
        XCTAssertEqual(observed.filter { $0 == .otherMouseUp }.count, 3)
    }

    // MARK: - 按住并滚动

    func testScrollModification_pressActivatesImmediately() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .zoom))
        ]
        ButtonUtils.shared.invalidateCache()

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        // 按下立即生效, 无需 hold 延时
        XCTAssertTrue(ScrollCore.shared.activeScrollModifications.contains(.zoom))

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertTrue(ScrollCore.shared.activeScrollModifications.isEmpty)
    }

    // MARK: - 按住并拖动

    func testDrag_pressActivatesImmediately() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .drag, effect: .drag(mode: .twoFingerSwipe))
        ]
        ButtonUtils.shared.invalidateCache()

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        XCTAssertTrue(DragSessionManager.shared.isActive)

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertFalse(DragSessionManager.shared.isActive)
    }

    // MARK: - 三指滑动 (dockSwipe 手势流)

    func testDrag_threeFingerSwipePostsDockSwipeStream() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .drag, effect: .drag(mode: .threeFingerSwipe))
        ]
        ButtonUtils.shared.invalidateCache()

        var location = CGPoint(x: 100, y: 100)
        DragSessionManager.shared.locationProvider = { location }
        DragSessionManager.shared.pollInterval = 0.01
        DragSessionManager.shared.gestureStartThreshold = 3

        var dockEvents: [(phase: Int64, axis: Double)] = []
        TouchSimulator.testingPostHook = { event in
            let hidType = event.getIntegerValueField(CGEventField(rawValue: 110)!)
            if hidType == 23 {
                dockEvents.append((
                    phase: event.getIntegerValueField(CGEventField(rawValue: 132)!),
                    axis: event.getDoubleValueField(CGEventField(rawValue: 123)!)
                ))
            }
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        runMainLoop(0.03)
        XCTAssertTrue(dockEvents.isEmpty)  // 未移动不触发

        location = CGPoint(x: 120, y: 100)  // 水平移动 20pt > 阈值
        runMainLoop(0.05)
        XCTAssertEqual(dockEvents.first?.phase, 1)  // began
        XCTAssertEqual(dockEvents.first?.axis, 1)   // horizontal

        location = CGPoint(x: 135, y: 100)
        runMainLoop(0.05)
        XCTAssertEqual(dockEvents.last?.phase, 2)   // changed

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertEqual(dockEvents.last?.phase, 4)   // ended

        TouchSimulator.testingPostHook = nil
        DragSessionManager.shared.testingPostHook = nil
        DragSessionManager.shared.locationProvider = {
            let loc = NSEvent.mouseLocation
            let screenHeight = NSScreen.main?.frame.height ?? 0
            return CGPoint(x: loc.x, y: screenHeight - loc.y)
        }
        DragSessionManager.shared.pollInterval = 1.0 / 60.0
        DragSessionManager.shared.gestureStartThreshold = 7
    }

    func testDrag_twoFingerSwipePostsGestureScrollStream() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .drag, effect: .drag(mode: .twoFingerSwipe))
        ]
        ButtonUtils.shared.invalidateCache()

        var location = CGPoint(x: 100, y: 100)
        DragSessionManager.shared.locationProvider = { location }
        DragSessionManager.shared.pollInterval = 0.01
        DragSessionManager.shared.gestureStartThreshold = 3

        var gestureScrollPhases: [Int64] = []
        var scrollPointDeltaX: [Double] = []
        TouchSimulator.testingPostHook = { event in
            // gesture 事件 (55=29, subtype 110=6 scroll)
            if event.getIntegerValueField(CGEventField(rawValue: 55)!) == 29,
               event.getIntegerValueField(CGEventField(rawValue: 110)!) == 6 {
                gestureScrollPhases.append(event.getIntegerValueField(CGEventField(rawValue: 132)!))
            }
            // scrollWheel 事件 (55=22): 记录点 delta X, 验证 3 帧平滑
            if event.getIntegerValueField(CGEventField(rawValue: 55)!) == 22 {
                scrollPointDeltaX.append(event.getDoubleValueField(CGEventField(rawValue: 97)!))
            }
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        runMainLoop(0.03)
        XCTAssertTrue(gestureScrollPhases.isEmpty)  // 未移动不触发

        location = CGPoint(x: 120, y: 100)
        runMainLoop(0.05)
        XCTAssertEqual(gestureScrollPhases.first, 1)  // began
        // 20pt 位移经 3 帧平滑: 首帧约为 1/3, 明显小于原始位移
        XCTAssertLessThan(scrollPointDeltaX.first ?? 0, 10)
        XCTAssertGreaterThan(scrollPointDeltaX.first ?? 0, 3)

        location = CGPoint(x: 135, y: 100)
        runMainLoop(0.05)
        XCTAssertEqual(gestureScrollPhases.last, 2)   // changed

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertEqual(gestureScrollPhases.last, 4)   // ended

        TouchSimulator.testingPostHook = nil
        DragSessionManager.shared.testingPostHook = nil
        DragSessionManager.shared.locationProvider = {
            let loc = NSEvent.mouseLocation
            let screenHeight = NSScreen.main?.frame.height ?? 0
            return CGPoint(x: loc.x, y: screenHeight - loc.y)
        }
        DragSessionManager.shared.pollInterval = 1.0 / 60.0
        DragSessionManager.shared.gestureStartThreshold = 7
    }

    func testScrollModification_zoomPostsMagnificationAndConsumes() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .zoom))
        ]
        ButtonUtils.shared.invalidateCache()

        var magnifications: [(phase: Int64, value: Double)] = []
        TouchSimulator.testingPostHook = { event in
            if event.getIntegerValueField(CGEventField(rawValue: 110)!) == 8 {
                magnifications.append((
                    phase: event.getIntegerValueField(CGEventField(rawValue: 132)!),
                    value: event.getDoubleValueField(CGEventField(rawValue: 113)!)
                ))
            }
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        XCTAssertTrue(ScrollCore.shared.activeScrollModifications.contains(.zoom))

        func makeScrollEvent() -> CGEvent {
            return CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 80,
                wheel2: 0,
                wheel3: 0
            )!
        }

        // 第一次滚轮 → began (首格 60px → 动画首帧 = -0.075 × 缓出曲线(1/15) ≈ -0.0092)
        XCTAssertTrue(ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent()))
        XCTAssertEqual(magnifications.first?.phase, 1)
        XCTAssertEqual(magnifications.first?.value ?? 0, -0.075 * 0.1228, accuracy: 0.002)

        // 第二次滚轮 → changed
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent())
        runMainLoop(0.05)  // 60Hz 平滑输出定时器
        XCTAssertEqual(magnifications.last?.phase, 2)

        // 松手 → ended
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertEqual(magnifications.last?.phase, 4)

        TouchSimulator.testingPostHook = nil
    }

    func testScrollModification_zoom_accelerationScalesWithScrollSpeed() {
        // 灵敏度: 每格输出像素由滚动速度决定 (慢速 60px → 快速 120px), 与原始 delta 大小无关
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .zoom))
        ]
        ButtonUtils.shared.invalidateCache()

        var magnifications: [Double] = []
        TouchSimulator.testingPostHook = { event in
            if event.getIntegerValueField(CGEventField(rawValue: 110)!) == 8 {
                magnifications.append(event.getDoubleValueField(CGEventField(rawValue: 113)!))
            }
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))

        func makeScrollEvent() -> CGEvent {
            return CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 80,
                wheel2: 0,
                wheel3: 0
            )!
        }

        // 首格 (间隔视为最大 0.16s) → 60px; 紧接着快速滚动 → 120px
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent())
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent())
        runMainLoop(0.25)  // 平滑输出收敛到累计目标 (60+120)/800 = 0.225

        let total = magnifications.reduce(0, +)
        XCTAssertGreaterThan(total.magnitude, 0.20)
        XCTAssertLessThan(total.magnitude, 0.26)

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        TouchSimulator.testingPostHook = nil
    }

    // MARK: - 四指捏合 (滚动修饰)

    func testScrollModification_fourFingerPinchPostsDockSwipeAndConsumes() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .fourFingerPinch))
        ]
        ButtonUtils.shared.invalidateCache()

        var dockEvents: [(phase: Int64, axis: Double)] = []
        TouchSimulator.testingPostHook = { event in
            if event.getIntegerValueField(CGEventField(rawValue: 110)!) == 23 {
                dockEvents.append((
                    phase: event.getIntegerValueField(CGEventField(rawValue: 132)!),
                    axis: event.getDoubleValueField(CGEventField(rawValue: 123)!)
                ))
            }
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        XCTAssertTrue(ScrollCore.shared.activeScrollModifications.contains(.fourFingerPinch))

        func makeScrollEvent() -> CGEvent {
            return CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 30,
                wheel2: 0,
                wheel3: 0
            )!
        }

        // 第一次滚轮 → began (pinch)
        XCTAssertTrue(ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent()))
        XCTAssertEqual(dockEvents.first?.phase, 1)
        XCTAssertEqual(dockEvents.first?.axis, 3)

        // 第二次滚轮 → changed
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent())
        runMainLoop(0.05)  // 60Hz 平滑输出定时器
        XCTAssertEqual(dockEvents.last?.phase, 2)

        // 松手 → ended
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertEqual(dockEvents.last?.phase, 4)

        TouchSimulator.testingPostHook = nil
    }

    func testScrollModification_fourFingerPinchEndsAfterScrollIdle() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .fourFingerPinch))
        ]
        ButtonUtils.shared.invalidateCache()

        var phases: [Int64] = []
        TouchSimulator.testingPostHook = { event in
            if event.getIntegerValueField(CGEventField(rawValue: 110)!) == 23 {
                phases.append(event.getIntegerValueField(CGEventField(rawValue: 132)!))
            }
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))

        func makeScrollEvent() -> CGEvent {
            return CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 30,
                wheel2: 0,
                wheel3: 0
            )!
        }

        // 第一次滚轮 → began; 第二次滚轮 (输入中) → changed
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent())
        XCTAssertEqual(phases.first, 1)  // began 同步输出
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent())
        runMainLoop(0.05)  // 60Hz 平滑输出定时器输出 changed
        XCTAssertTrue(phases.contains(2))

        // 输入停止短延时后 → ended (无需松手)
        runMainLoop(0.3)
        XCTAssertEqual(phases.last, 4)

        // 结束后复位: 下一次滚动重新 began
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent())
        XCTAssertEqual(phases.last, 1)

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        TouchSimulator.testingPostHook = nil
    }

    func testScrollModification_fourFingerPinch_directionChangeRestarts() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .fourFingerPinch))
        ]
        ButtonUtils.shared.invalidateCache()

        var phases: [Int64] = []
        TouchSimulator.testingPostHook = { event in
            if event.getIntegerValueField(CGEventField(rawValue: 110)!) == 23 {
                phases.append(event.getIntegerValueField(CGEventField(rawValue: 132)!))
            }
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))

        func makeScrollEvent(wheel1: Int32) -> CGEvent {
            return CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: wheel1,
                wheel2: 0,
                wheel3: 0
            )!
        }

        // 同一方向: began → changed
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent(wheel1: -30))
        XCTAssertEqual(phases.first, 1)
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent(wheel1: -30))
        runMainLoop(0.05)  // 60Hz 平滑输出定时器输出 changed
        XCTAssertTrue(phases.contains(2))

        // 方向改变: 取消当前动画 (ended), 并丢弃反向 tick (不重新 began)
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent(wheel1: 30))
        XCTAssertTrue(phases.contains(4))
        XCTAssertNotEqual(phases.last, 1)

        // 再次同向滚动 → 重新 began
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent(wheel1: 30))
        XCTAssertEqual(phases.last, 1)

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        TouchSimulator.testingPostHook = nil
    }

    func testScrollModification_doesNotTransformSyntheticEvents() {
        // 双指滑动与缩放共存: 双指滑动投递的合成滚动事件不能被激活的缩放修饰转成缩放
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .zoom)),
            makeRemap(button: 3, duration: .drag, effect: .drag(mode: .twoFingerSwipe))
        ]
        ButtonUtils.shared.invalidateCache()

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        XCTAssertTrue(ScrollCore.shared.activeScrollModifications.contains(.zoom))

        var magnifications: [Double] = []
        TouchSimulator.testingPostHook = { event in
            if event.getIntegerValueField(CGEventField(rawValue: 110)!) == 8 {
                magnifications.append(event.getDoubleValueField(CGEventField(rawValue: 113)!))
            }
        }

        // 模拟双指滑动投递的合成滚轮事件 (带 synthetic 标记)
        let synthetic = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 30,
            wheel2: 0,
            wheel3: 0
        )!
        synthetic.setIntegerValueField(.eventSourceUserData, value: MosEventMarker.syntheticCustom)

        XCTAssertFalse(ScrollCore.shared.applyActiveScrollModifications(to: synthetic))
        XCTAssertTrue(magnifications.isEmpty)

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        TouchSimulator.testingPostHook = nil
    }

    func testScrollModification_zoom_directionChangeRestarts() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .zoom))
        ]
        ButtonUtils.shared.invalidateCache()

        var phases: [Int64] = []
        TouchSimulator.testingPostHook = { event in
            if event.getIntegerValueField(CGEventField(rawValue: 110)!) == 8 {
                phases.append(event.getIntegerValueField(CGEventField(rawValue: 132)!))
            }
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))

        func makeScrollEvent(wheel1: Int32) -> CGEvent {
            return CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: wheel1,
                wheel2: 0,
                wheel3: 0
            )!
        }

        // 同一方向: began → changed
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent(wheel1: -30))
        XCTAssertEqual(phases.first, 1)
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent(wheel1: -30))
        runMainLoop(0.05)  // 60Hz 平滑输出定时器输出 changed
        XCTAssertTrue(phases.contains(2))

        // 方向改变: 取消当前动画 (ended), 并丢弃反向 tick (不重新 began)
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent(wheel1: 30))
        XCTAssertTrue(phases.contains(4))
        XCTAssertNotEqual(phases.last, 1)

        // 再次同向滚动 → 重新 began
        _ = ScrollCore.shared.applyActiveScrollModifications(to: makeScrollEvent(wheel1: 30))
        XCTAssertEqual(phases.last, 1)

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        TouchSimulator.testingPostHook = nil
    }

    // MARK: - 单击 / 拖动 / 滚动共存

    func testBackButton_clickDragScrollCoexist() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .systemShortcut(identifier: "mouseLeftClick")),
            makeRemap(button: 3, duration: .drag, effect: .drag(mode: .twoFingerSwipe)),
            makeRemap(button: 3, duration: .scroll, effect: .scrollModification(kind: .zoom))
        ]
        ButtonUtils.shared.invalidateCache()

        DragSessionManager.shared.testingPostHook = { _ in }
        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        // 按下: 拖拽会话 + 滚动修饰同时激活, 单击不立即触发
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        XCTAssertTrue(DragSessionManager.shared.isActive)
        XCTAssertTrue(ScrollCore.shared.activeScrollModifications.contains(.zoom))
        XCTAssertTrue(observed.isEmpty)

        // 快速松开 (无拖动/滚动) → 单击在松手触发
        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        XCTAssertEqual(observed, [.leftMouseDown, .leftMouseUp])
        XCTAssertFalse(DragSessionManager.shared.isActive)
        XCTAssertTrue(ScrollCore.shared.activeScrollModifications.isEmpty)
        DragSessionManager.shared.testingPostHook = nil
    }

    func testBackButton_dragStartedSuppressesClick() {
        Options.shared.buttons.remaps = [
            makeRemap(button: 3, effect: .systemShortcut(identifier: "mouseLeftClick")),
            makeRemap(button: 3, duration: .drag, effect: .drag(mode: .twoFingerSwipe))
        ]
        ButtonUtils.shared.invalidateCache()

        var location = CGPoint(x: 100, y: 100)
        DragSessionManager.shared.locationProvider = { location }
        DragSessionManager.shared.pollInterval = 0.01
        DragSessionManager.shared.gestureStartThreshold = 3

        DragSessionManager.shared.testingPostHook = { _ in }
        var observed: [CGEventType] = []
        ShortcutExecutor.shared.setTestingMouseEventObserver { event in
            observed.append(event.type)
        }

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .down))
        location = CGPoint(x: 120, y: 100)  // 移动超阈值, 拖拽启动
        runMainLoop(0.05)

        _ = InputProcessor.shared.process(mouseEvent(button: 3, phase: .up))
        // 拖拽已使用 → 松手不触发单击 (observed 只含拖拽的左键事件)
        XCTAssertFalse(observed.contains(.leftMouseDown))

        DragSessionManager.shared.locationProvider = {
            let loc = NSEvent.mouseLocation
            let screenHeight = NSScreen.main?.frame.height ?? 0
            return CGPoint(x: loc.x, y: screenHeight - loc.y)
        }
        DragSessionManager.shared.pollInterval = 1.0 / 60.0
        DragSessionManager.shared.gestureStartThreshold = 7
        DragSessionManager.shared.testingPostHook = nil
    }
}
