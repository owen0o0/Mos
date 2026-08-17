import XCTest
@testable import Mos_Debug

private final class ClickCycleStubDelegate: ClickCycleDelegate {

    var remaps: [ButtonRemap] = []
    var statefulEffects: [ButtonEffect] = []
    var committed: [(remap: ButtonRemap, phase: ClickCyclePhase, sessionID: UUID?)] = []
    var released: [(remap: ButtonRemap, sessionID: UUID?)] = []
    var gestureUsedForButton: Bool = false

    private var nextSessionID = UUID()

    func clickCycle(_ cycle: ClickCycle, maxLevelForButton button: UInt16, modifiers: CGEventFlags) -> Int {
        return remaps
            .filter { $0.trigger.buttonNumber == button && $0.precondition.matchPriority(for: modifiers) != nil }
            .map { $0.trigger.level }
            .max() ?? 0
    }

    func clickCycle(_ cycle: ClickCycle, remapForButton button: UInt16, level: Int, duration: ButtonTriggerDuration, modifiers: CGEventFlags) -> ButtonRemap? {
        var best: ButtonRemap?
        var bestPriority = Int.min
        for candidate in remaps where candidate.isEnabled {
            guard candidate.trigger.buttonNumber == button,
                  candidate.trigger.level == level,
                  candidate.trigger.duration == duration,
                  let priority = candidate.precondition.matchPriority(for: modifiers) else { continue }
            if priority > bestPriority {
                best = candidate
                bestPriority = priority
            }
        }
        return best
    }

    func clickCycle(_ cycle: ClickCycle, isStatefulEffect effect: ButtonEffect) -> Bool {
        return statefulEffects.contains(effect)
    }

    func clickCycle(_ cycle: ClickCycle, didCommit remap: ButtonRemap, phase: ClickCyclePhase, button: UInt16, modifiers: CGEventFlags) -> UUID? {
        let sessionID = isStateful(remap.effect) ? nextSessionID : nil
        committed.append((remap, phase, sessionID))
        return sessionID
    }

    func clickCycle(_ cycle: ClickCycle, didRelease remap: ButtonRemap, button: UInt16, modifiers: CGEventFlags, sessionID: UUID?) {
        released.append((remap, sessionID))
    }

    func clickCycle(_ cycle: ClickCycle, isGestureUsedForButton button: UInt16) -> Bool {
        return gestureUsedForButton
    }

    private func isStateful(_ effect: ButtonEffect) -> Bool {
        return statefulEffects.contains(effect)
    }
}

final class ClickCycleTests: XCTestCase {

    private var cycle: ClickCycle!
    private var delegate: ClickCycleStubDelegate!

    override func setUp() {
        super.setUp()
        cycle = ClickCycle()
        cycle.holdDelay = 0.05
        cycle.levelExpiryDelay = 0.06
        delegate = ClickCycleStubDelegate()
        cycle.delegate = delegate
    }

    override func tearDown() {
        cycle.killAll()
        cycle = nil
        delegate = nil
        super.tearDown()
    }

    private func makeRemap(
        button: UInt16,
        level: Int = 1,
        duration: ButtonTriggerDuration = .click,
        effect: ButtonEffect = .systemShortcut(identifier: "copy"),
        modifiers: UInt = 0
    ) -> ButtonRemap {
        return ButtonRemap(
            trigger: ButtonTrigger(buttonNumber: button, level: level, duration: duration),
            precondition: ButtonPrecondition(keyboardModifiers: modifiers),
            effect: effect
        )
    }

    private func runMainLoop(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    // MARK: - 基础匹配

    func testHandleDown_noRemap_passthrough() {
        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .passthrough)
    }

    func testHandleUp_withoutPriorDown_passthrough() {
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .passthrough)
    }

    // MARK: - 单击 (松手提交)

    func testSingleClick_oneShotCommitsOnRelease() {
        delegate.remaps = [makeRemap(button: 3)]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)

        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.committed[0].phase, .release(level: 1))
        XCTAssertNil(delegate.committed[0].sessionID)
    }

    func testSingleClick_statefulCommitsAsTapOnRelease() {
        let effect = ButtonEffect.customKey(code: 56, modifiers: 0)
        delegate.remaps = [makeRemap(button: 3, effect: effect)]
        delegate.statefulEffects = [effect]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)

        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.committed[0].phase, .release(level: 1))
        XCTAssertNotNil(delegate.committed[0].sessionID)
        XCTAssertEqual(delegate.released.count, 1)
        XCTAssertEqual(delegate.released[0].sessionID, delegate.committed[0].sessionID)
    }

    // MARK: - 双击

    func testDoubleClick_secondPressCommitsLevel2() {
        delegate.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "copy")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "paste"))
        ]

        // 第一次按下: 挂起等待层级判定
        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)
        // 第一次松开: 仍挂起
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)
        // 第二次按下 (超时前): 仍挂起, 松手后提交 level 2
        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)
        // 第二次松开: level 2 无更高层级 → 松手立即提交
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.committed[0].phase, .release(level: 2))
    }

    func testSingleClick_withDoubleClickConfigured_firesOnLevelExpired() {
        delegate.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "copy")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "paste"))
        ]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)

        runMainLoop(0.12)

        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.committed[0].phase, .levelExpired(level: 1))
    }

    func testSingleClick_withDoubleClickConfigured_slowPressSuppressedByHoldTimer() {
        delegate.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "copy")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "paste"))
        ]

        // 时序: 按下超过 holdDelay (0.05 测试值) 被长按计时接管, 单击不触发
        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        runMainLoop(0.1)
        XCTAssertTrue(delegate.committed.isEmpty)

        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        runMainLoop(0.12)
        XCTAssertTrue(delegate.committed.isEmpty)
    }

    // MARK: - 点击 + 长按

    func testClickAndHold_quickReleaseCommitsClickAtRelease() {
        let clickEffect = ButtonEffect.systemShortcut(identifier: "copy")
        let holdEffect = ButtonEffect.systemShortcut(identifier: "paste")
        delegate.remaps = [
            makeRemap(button: 3, duration: .click, effect: clickEffect),
            makeRemap(button: 3, duration: .hold, effect: holdEffect)
        ]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)

        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.committed[0].phase, .release(level: 1))
    }

    func testClickAndHold_longPressCommitsHoldAndReleasesFromHold() {
        let clickEffect = ButtonEffect.systemShortcut(identifier: "copy")
        let holdEffect = ButtonEffect.customKey(code: 56, modifiers: 0)
        delegate.remaps = [
            makeRemap(button: 3, duration: .click, effect: clickEffect),
            makeRemap(button: 3, duration: .hold, effect: holdEffect)
        ]
        delegate.statefulEffects = [holdEffect]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)

        runMainLoop(0.1)

        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.committed[0].phase, .hold(level: 1))
        XCTAssertNotNil(delegate.committed[0].sessionID)

        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.released.count, 1)
        XCTAssertEqual(delegate.released[0].sessionID, delegate.committed[0].sessionID)
    }

    // MARK: - 仅更高层级

    func testGreaterLevelOnly_firstPressSwallowed() {
        delegate.remaps = [
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "copy"))
        ]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)

        // 层级超时后周期结束, 无动作
        runMainLoop(0.12)
        XCTAssertTrue(delegate.committed.isEmpty)

        // 第二下在超时后按下 → 新周期 level 1 (被吞掉)
        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)
        cycle.killAll()
    }

    // MARK: - hold-only 快速松手

    func testHoldOnly_quickReleaseLeavesNoStaleState() {
        let holdEffect = ButtonEffect.customKey(code: 56, modifiers: 0)
        delegate.remaps = [makeRemap(button: 3, duration: .hold, effect: holdEffect)]
        delegate.statefulEffects = [holdEffect]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertTrue(delegate.committed.isEmpty)

        // 残留状态不得消费孤立 up
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .passthrough)
    }

    // MARK: - 层级循环

    func testClickLevel_cyclesWithinMax() {
        delegate.remaps = [
            makeRemap(button: 3, level: 1, effect: .systemShortcut(identifier: "copy")),
            makeRemap(button: 3, level: 2, effect: .systemShortcut(identifier: "paste"))
        ]

        // 第一次双击序列: 1 → 2
        _ = cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        _ = cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0))
        _ = cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        _ = cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0))
        XCTAssertEqual(delegate.committed.last?.phase, .release(level: 2))
        cycle.killAll()
        delegate.committed.removeAll()

        // 第二次序列: 回到 1 → 2 (wrap)
        _ = cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        _ = cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0))
        _ = cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        _ = cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0))
        XCTAssertEqual(delegate.committed.last?.phase, .release(level: 2))
    }

    // MARK: - 重复 down 与 killAll

    func testRepeatedDownWithoutUp_releasesPreviousGestureSession() {
        let effect = ButtonEffect.drag(mode: .twoFingerSwipe)
        delegate.remaps = [makeRemap(button: 3, duration: .drag, effect: effect)]
        delegate.statefulEffects = [effect]

        _ = cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        XCTAssertEqual(delegate.committed.count, 1)

        // 丢失 up 后再次 down: 旧会话必须先释放
        _ = cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        XCTAssertEqual(delegate.released.count, 1)
        XCTAssertEqual(delegate.released[0].sessionID, delegate.committed[0].sessionID)
    }

    func testKillAll_releasesActiveSessionsAndClearsState() {
        let effect = ButtonEffect.drag(mode: .twoFingerSwipe)
        delegate.remaps = [makeRemap(button: 3, duration: .drag, effect: effect)]
        delegate.statefulEffects = [effect]

        _ = cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        XCTAssertEqual(delegate.committed.count, 1)

        cycle.killAll()

        XCTAssertEqual(delegate.released.count, 1)
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .passthrough)
    }

    // MARK: - 按住并拖动 / 按住并滚动 (按下即激活)

    func testDragTrigger_commitsImmediatelyOnPressAndReleasesOnUp() {
        let effect = ButtonEffect.drag(mode: .twoFingerSwipe)
        delegate.remaps = [makeRemap(button: 3, duration: .drag, effect: effect)]
        delegate.statefulEffects = [effect]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.committed[0].phase, .press(level: 1))
        XCTAssertNotNil(delegate.committed[0].sessionID)

        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.released.count, 1)
        XCTAssertEqual(delegate.released[0].sessionID, delegate.committed[0].sessionID)
    }

    func testScrollTrigger_commitsImmediatelyOnPressAndReleasesOnUp() {
        let effect = ButtonEffect.scrollModification(kind: .zoom)
        delegate.remaps = [makeRemap(button: 3, duration: .scroll, effect: effect)]
        delegate.statefulEffects = [effect]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.committed[0].phase, .press(level: 1))

        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.released.count, 1)
    }

    func testDragAndClick_coexistOnSamePress() {
        let clickEffect = ButtonEffect.customKey(code: 56, modifiers: 0)
        let dragEffect = ButtonEffect.drag(mode: .twoFingerSwipe)
        delegate.remaps = [
            makeRemap(button: 3, duration: .click, effect: clickEffect),
            makeRemap(button: 3, duration: .drag, effect: dragEffect)
        ]
        delegate.statefulEffects = [clickEffect, dragEffect]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        // 按下只提交 drag; click 等松手
        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.committed[0].phase, .press(level: 1))

        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        // 手势未使用 → 松手提交 click, 连同 drag 一起释放
        XCTAssertEqual(delegate.committed.count, 2)
        XCTAssertEqual(delegate.committed[1].phase, .release(level: 1))
        XCTAssertEqual(delegate.released.count, 2)
    }

    func testClickWithGesture_dragUsedSuppressesClick() {
        let clickEffect = ButtonEffect.customKey(code: 56, modifiers: 0)
        let dragEffect = ButtonEffect.drag(mode: .twoFingerSwipe)
        delegate.remaps = [
            makeRemap(button: 3, duration: .click, effect: clickEffect),
            makeRemap(button: 3, duration: .drag, effect: dragEffect)
        ]
        delegate.statefulEffects = [clickEffect, dragEffect]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.committed.count, 1)

        // 拖拽已使用 → 松手不再触发单击
        delegate.gestureUsedForButton = true
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.released.count, 1)
    }

    func testDragAndScroll_bothActivatedOnPress() {
        let dragEffect = ButtonEffect.customMouseButton(buttonNumber: 0, modifiers: 0)
        let scrollEffect = ButtonEffect.customKey(code: 56, modifiers: 0)
        delegate.remaps = [
            makeRemap(button: 3, duration: .drag, effect: dragEffect),
            makeRemap(button: 3, duration: .scroll, effect: scrollEffect)
        ]
        delegate.statefulEffects = [dragEffect, scrollEffect]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        // drag 和 scroll 同时激活
        XCTAssertEqual(delegate.committed.count, 2)
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(delegate.released.count, 2)
    }

    func testDragTrigger_quickPressRelease_noHoldDelay() {
        let effect = ButtonEffect.drag(mode: .twoFingerSwipe)
        delegate.remaps = [makeRemap(button: 3, duration: .drag, effect: effect)]
        delegate.statefulEffects = [effect]

        XCTAssertEqual(cycle.handleDown(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        XCTAssertEqual(cycle.handleUp(button: 3, modifiers: CGEventFlags(rawValue: 0)), .consumed)
        // 无需等待 hold 延时
        XCTAssertEqual(delegate.committed.count, 1)
        XCTAssertEqual(delegate.released.count, 1)
    }
}
