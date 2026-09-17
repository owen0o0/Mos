//
//  ScrollEventTests.swift
//  MosTests
//
//  ScrollEvent 事件解析优先级/reverse/normalize/clear 测试 (Task 8)
//

import XCTest
@testable import Mos_Debug

final class ScrollEventTests: XCTestCase {

    // MARK: - 辅助: 创建 CGEvent

    /// 创建滚动事件并设置指定轴的值
    private func makeScrollEvent(
        deltaAxis1: Int64 = 0, ptDeltaAxis1: Double = 0.0, fixPtDeltaAxis1: Double = 0.0,
        deltaAxis2: Int64 = 0, ptDeltaAxis2: Double = 0.0, fixPtDeltaAxis2: Double = 0.0
    ) -> CGEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0) else {
            return nil
        }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: deltaAxis1)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: ptDeltaAxis1)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixPtDeltaAxis1)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: deltaAxis2)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: ptDeltaAxis2)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixPtDeltaAxis2)
        return event
    }

    // MARK: - initEvent: 优先级 (scrollPt > scrollFixPt > scrollFix)

    func testInitEvent_prefersPtOverFixPt() throws {
        // CGEvent scrollWheelEventPointDelta 字段会截断小数部分, 10.5 实际存储为 10.0
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 3, ptDeltaAxis1: 10.0, fixPtDeltaAxis1: 5.0))
        let scrollEvent = ScrollEvent(with: cgEvent)

        XCTAssertEqual(scrollEvent.Y.usableValue, 10.0, "scrollPt should take priority")
        XCTAssertFalse(scrollEvent.Y.fixed, "scrollPt-based data should not be marked as fixed")
        XCTAssertTrue(scrollEvent.Y.valid)
    }

    func testInitEvent_prefersFixPtOverFix() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 3, ptDeltaAxis1: 0.0, fixPtDeltaAxis1: 5.0))
        let scrollEvent = ScrollEvent(with: cgEvent)

        XCTAssertEqual(scrollEvent.Y.usableValue, 5.0, "scrollFixPt should be used when scrollPt is 0")
        XCTAssertTrue(scrollEvent.Y.fixed, "scrollFixPt-based data should be marked as fixed")
        XCTAssertTrue(scrollEvent.Y.valid)
    }

    func testInitEvent_fallsBackToFix() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 3, ptDeltaAxis1: 0.0, fixPtDeltaAxis1: 0.0))
        let scrollEvent = ScrollEvent(with: cgEvent)

        XCTAssertEqual(scrollEvent.Y.usableValue, 3.0, "scrollFix should be used as fallback")
        XCTAssertTrue(scrollEvent.Y.fixed, "scrollFix-based data should be marked as fixed")
        XCTAssertTrue(scrollEvent.Y.valid)
    }

    func testInitEvent_allZero_notValid() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent())
        let scrollEvent = ScrollEvent(with: cgEvent)

        XCTAssertFalse(scrollEvent.Y.valid, "all-zero data should not be valid")
        XCTAssertEqual(scrollEvent.Y.usableValue, 0.0)
    }

    // MARK: - initEvent: X 轴

    func testInitEvent_xAxis_prefersPt() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis2: 2, ptDeltaAxis2: 7.0, fixPtDeltaAxis2: 3.0))
        let scrollEvent = ScrollEvent(with: cgEvent)

        XCTAssertEqual(scrollEvent.X.usableValue, 7.0, "X axis scrollPt should take priority")
        XCTAssertFalse(scrollEvent.X.fixed)
        XCTAssertTrue(scrollEvent.X.valid)
    }

    func testInitEvent_xAxis_fallbackToFix() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis2: -4))
        let scrollEvent = ScrollEvent(with: cgEvent)

        XCTAssertEqual(scrollEvent.X.usableValue, -4.0)
        XCTAssertTrue(scrollEvent.X.fixed)
        XCTAssertTrue(scrollEvent.X.valid)
    }

    // MARK: - reverse (Y 轴)

    func testReverseY_negatesAllYFields() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 5, ptDeltaAxis1: 10.0, fixPtDeltaAxis1: 7.5))
        let scrollEvent = ScrollEvent(with: cgEvent)

        ScrollEvent.reverseY(scrollEvent)

        // usableValue 应该取反
        XCTAssertEqual(scrollEvent.Y.usableValue, -10.0, accuracy: 1e-10)

        // CGEvent 字段也应该取反
        let newDelta = scrollEvent.event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        XCTAssertEqual(newDelta, -5)

        let newPt = scrollEvent.event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        XCTAssertEqual(newPt, -10.0, accuracy: 1e-10)

        let newFixPt = scrollEvent.event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        XCTAssertEqual(newFixPt, -7.5, accuracy: 1e-10)
    }

    func testReverseY_doubleReverse_restoresOriginal() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 3, ptDeltaAxis1: 6.0, fixPtDeltaAxis1: 4.5))
        let scrollEvent = ScrollEvent(with: cgEvent)

        ScrollEvent.reverseY(scrollEvent)
        ScrollEvent.reverseY(scrollEvent)

        XCTAssertEqual(scrollEvent.Y.usableValue, 6.0, accuracy: 1e-10, "double reverse should restore original")
    }

    // MARK: - reverse (X 轴)

    func testReverseX_negatesAllXFields() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis2: 3, ptDeltaAxis2: 8.0, fixPtDeltaAxis2: 4.0))
        let scrollEvent = ScrollEvent(with: cgEvent)

        ScrollEvent.reverseX(scrollEvent)

        XCTAssertEqual(scrollEvent.X.usableValue, -8.0, accuracy: 1e-10)

        let newDelta = scrollEvent.event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        XCTAssertEqual(newDelta, -3)
    }

    // MARK: - normalize (Y 轴)

    func testNormalizeY_positiveBelowThreshold_clampsUp() throws {
        // CGEvent scrollWheelEventPointDelta 截断小数, 使用 fixPtDelta 来传递小数值
        let cgEvent = try XCTUnwrap(makeScrollEvent(fixPtDeltaAxis1: 0.5))
        let scrollEvent = ScrollEvent(with: cgEvent)

        let threshold = 2.0
        ScrollEvent.normalizeY(scrollEvent, threshold)

        XCTAssertEqual(scrollEvent.Y.usableValue, threshold, accuracy: 1e-10,
            "positive value below threshold should be clamped up to threshold")
    }

    func testNormalizeY_negativeBelowThreshold_clampsDown() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(ptDeltaAxis1: -0.5))
        let scrollEvent = ScrollEvent(with: cgEvent)

        let threshold = 2.0
        ScrollEvent.normalizeY(scrollEvent, threshold)

        XCTAssertEqual(scrollEvent.Y.usableValue, -threshold, accuracy: 1e-10,
            "negative value below threshold should be clamped to -threshold")
    }

    func testNormalizeY_aboveThreshold_unchanged() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(ptDeltaAxis1: 5.0))
        let scrollEvent = ScrollEvent(with: cgEvent)

        let threshold = 2.0
        ScrollEvent.normalizeY(scrollEvent, threshold)

        XCTAssertEqual(scrollEvent.Y.usableValue, 5.0, accuracy: 1e-10,
            "value above threshold should remain unchanged")
    }

    // MARK: - normalize (X 轴)

    func testNormalizeX_positiveBelowThreshold_clampsUp() throws {
        // CGEvent scrollWheelEventPointDelta 截断小数, 使用 fixPtDelta 来传递小数值
        let cgEvent = try XCTUnwrap(makeScrollEvent(fixPtDeltaAxis2: 0.3))
        let scrollEvent = ScrollEvent(with: cgEvent)

        let threshold = 1.0
        ScrollEvent.normalizeX(scrollEvent, threshold)

        XCTAssertEqual(scrollEvent.X.usableValue, threshold, accuracy: 1e-10)
    }

    // MARK: - clear (Y 轴)

    func testClearY_zerosAllYFields() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 5, ptDeltaAxis1: 10.0, fixPtDeltaAxis1: 7.5))
        let scrollEvent = ScrollEvent(with: cgEvent)

        ScrollEvent.clearY(scrollEvent)

        XCTAssertEqual(scrollEvent.Y.scrollFix, 0)
        XCTAssertEqual(scrollEvent.Y.scrollPt, 0.0, accuracy: 1e-10)
        XCTAssertEqual(scrollEvent.Y.scrollFixPt, 0.0, accuracy: 1e-10)
        XCTAssertEqual(scrollEvent.Y.usableValue, 0.0, accuracy: 1e-10)

        // CGEvent 字段也应该被清零
        XCTAssertEqual(scrollEvent.event.getIntegerValueField(.scrollWheelEventDeltaAxis1), 0)
        XCTAssertEqual(scrollEvent.event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), 0.0, accuracy: 1e-10)
        XCTAssertEqual(scrollEvent.event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), 0.0, accuracy: 1e-10)
    }

    func testClearY_doesNotAffectXAxis() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 5, ptDeltaAxis1: 10.0, deltaAxis2: 3, ptDeltaAxis2: 6.0))
        let scrollEvent = ScrollEvent(with: cgEvent)

        ScrollEvent.clearY(scrollEvent)

        // X 轴不受影响
        XCTAssertEqual(scrollEvent.X.usableValue, 6.0, accuracy: 1e-10, "clearY should not affect X axis")
    }

    // MARK: - clear (X 轴)

    func testClearX_zerosAllXFields() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis2: 3, ptDeltaAxis2: 6.0, fixPtDeltaAxis2: 4.0))
        let scrollEvent = ScrollEvent(with: cgEvent)

        ScrollEvent.clearX(scrollEvent)

        XCTAssertEqual(scrollEvent.X.scrollFix, 0)
        XCTAssertEqual(scrollEvent.X.scrollPt, 0.0, accuracy: 1e-10)
        XCTAssertEqual(scrollEvent.X.scrollFixPt, 0.0, accuracy: 1e-10)
        XCTAssertEqual(scrollEvent.X.usableValue, 0.0, accuracy: 1e-10)
    }

    func testClearX_doesNotAffectYAxis() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 5, ptDeltaAxis1: 10.0, deltaAxis2: 3, ptDeltaAxis2: 6.0))
        let scrollEvent = ScrollEvent(with: cgEvent)

        ScrollEvent.clearX(scrollEvent)

        XCTAssertEqual(scrollEvent.Y.usableValue, 10.0, accuracy: 1e-10, "clearX should not affect Y axis")
    }

    // MARK: - 负值 scrollFix

    func testInitEvent_negativeDeltaFix() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: -7))
        let scrollEvent = ScrollEvent(with: cgEvent)

        XCTAssertEqual(scrollEvent.Y.usableValue, -7.0)
        XCTAssertTrue(scrollEvent.Y.fixed)
        XCTAssertTrue(scrollEvent.Y.valid)
    }

    // MARK: - axisData 结构体默认值

    func testAxisData_defaults() {
        let data = axisData()
        XCTAssertEqual(data.scrollFix, 0)
        XCTAssertEqual(data.scrollPt, 0.0)
        XCTAssertEqual(data.scrollFixPt, 0.0)
        XCTAssertFalse(data.fixed)
        XCTAssertFalse(data.valid)
        XCTAssertEqual(data.usableValue, 0.0)
    }

    // MARK: - HID 手势滚轮适配 (iPhone 镜像等)

    func testGestureScrollTarget_includesIPhoneMirroring() {
        XCTAssertTrue(GestureScrollTarget.knownBundleIDs.contains("com.apple.ScreenContinuity"))
        XCTAssertTrue(GestureScrollTarget.matches(bundleIdentifier: "com.apple.ScreenContinuity"))
        XCTAssertFalse(GestureScrollTarget.matches(bundleIdentifier: "com.apple.Safari"))
    }

    func testGestureScrollTarget_canRegisterAnotherApp() {
        GestureScrollTarget.testingAdditionalBundleIDs = ["com.example.Mirror"]
        defer { GestureScrollTarget.testingAdditionalBundleIDs = [] }
        XCTAssertTrue(GestureScrollTarget.matches(bundleIdentifier: "com.example.Mirror"))
        XCTAssertTrue(GestureScrollTarget.knownBundleIDs.contains("com.apple.ScreenContinuity"))
    }

    func testGestureScroll_pixelDeltas_discreteLineTickScalesToStep() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 1))
        let scrollEvent = ScrollEvent(with: cgEvent)
        let pixels = GestureScrollAdapter.pixelDeltas(from: scrollEvent, step: 33.6)
        XCTAssertEqual(pixels.y, 33.6, accuracy: 1e-9)
        XCTAssertEqual(pixels.x, 0)
    }

    func testGestureScroll_pixelDeltas_negativeDiscreteTickScalesNegative() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: -1))
        let scrollEvent = ScrollEvent(with: cgEvent)
        let pixels = GestureScrollAdapter.pixelDeltas(from: scrollEvent, step: 33.6)
        XCTAssertEqual(pixels.y, -33.6, accuracy: 1e-9)
    }

    func testGestureScroll_pixelDeltas_pointDeltaKeepsPixels() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(ptDeltaAxis1: 12.0))
        let scrollEvent = ScrollEvent(with: cgEvent)
        let pixels = GestureScrollAdapter.pixelDeltas(from: scrollEvent, step: 33.6)
        XCTAssertEqual(pixels.y, 12.0, accuracy: 1e-9)
        XCTAssertFalse(scrollEvent.Y.fixed)
    }

    func testGestureScroll_pixelDeltas_tinyStepStillMeetsMinimumScale() throws {
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 1))
        let scrollEvent = ScrollEvent(with: cgEvent)
        let pixels = GestureScrollAdapter.pixelDeltas(from: scrollEvent, step: 10)
        XCTAssertEqual(pixels.y, 24.0, accuracy: 1e-9, "gesture lineY = delta/10; sub-24 ticks round to 0")
    }

    func testGestureScroll_directedDeltas_reverseAxesIndependently() {
        let both = GestureScrollAdapter.directedDeltas(x: 3, y: 10, reverseVertical: true, reverseHorizontal: true)
        XCTAssertEqual(both.x, -3)
        XCTAssertEqual(both.y, -10)
        let verticalOnly = GestureScrollAdapter.directedDeltas(x: 3, y: 10, reverseVertical: true, reverseHorizontal: false)
        XCTAssertEqual(verticalOnly.x, 3)
        XCTAssertEqual(verticalOnly.y, -10)
        let none = GestureScrollAdapter.directedDeltas(x: 3, y: 10, reverseVertical: false, reverseHorizontal: false)
        XCTAssertEqual(none.x, 3)
        XCTAssertEqual(none.y, 10)
    }

    func testGestureScroll_shouldConvert_onlyWhenReverseHasDelta() {
        XCTAssertFalse(GestureScrollAdapter.shouldConvert(
            isTarget: false, reverseVertical: true, reverseHorizontal: true, pixelX: 0, pixelY: 10
        ))
        XCTAssertFalse(GestureScrollAdapter.shouldConvert(
            isTarget: true, reverseVertical: false, reverseHorizontal: false, pixelX: 0, pixelY: 10
        ))
        XCTAssertFalse(GestureScrollAdapter.shouldConvert(
            isTarget: true, reverseVertical: true, reverseHorizontal: false, pixelX: 8, pixelY: 0
        ), "horizontal-only tick must pass through when only vertical reverse is on")
        XCTAssertTrue(GestureScrollAdapter.shouldConvert(
            isTarget: true, reverseVertical: true, reverseHorizontal: false, pixelX: 0, pixelY: 10
        ))
    }

    func testGestureScroll_plan_reverseNegatesAndSwallows() {
        let plan = GestureScrollAdapter.plan(
            isTarget: true,
            pixelX: 0,
            pixelY: 33.6,
            reverseVertical: true,
            reverseHorizontal: false,
            shiftVerticalToHorizontal: false
        )
        XCTAssertTrue(plan.swallow)
        XCTAssertEqual(plan.deltaY, -33.6, accuracy: 1e-9)
        XCTAssertEqual(plan.deltaX, 0)
    }

    func testGestureScroll_plan_shiftVerticalToHorizontal() {
        let plan = GestureScrollAdapter.plan(
            isTarget: true,
            pixelX: 0,
            pixelY: 33.6,
            reverseVertical: true,
            reverseHorizontal: true,
            shiftVerticalToHorizontal: true
        )
        XCTAssertTrue(plan.swallow)
        XCTAssertEqual(plan.deltaX, -33.6, accuracy: 1e-9)
        XCTAssertEqual(plan.deltaY, 0)
    }

    func testGestureScroll_axisOptions_followGlobalAndAllowlist() {
        let savedReverse = Options.shared.scroll.reverse
        let savedV = Options.shared.scroll.reverseVertical
        let savedH = Options.shared.scroll.reverseHorizontal
        let savedAllowlist = Options.shared.application.allowlist
        defer {
            Options.shared.scroll.reverse = savedReverse
            Options.shared.scroll.reverseVertical = savedV
            Options.shared.scroll.reverseHorizontal = savedH
            Options.shared.application.allowlist = savedAllowlist
        }

        Options.shared.application.allowlist = false
        Options.shared.scroll.reverse = true
        Options.shared.scroll.reverseVertical = true
        Options.shared.scroll.reverseHorizontal = false
        let on = GestureScrollAdapter.axisOptions(application: nil)
        XCTAssertTrue(on.reverseVertical)
        XCTAssertFalse(on.reverseHorizontal)

        Options.shared.scroll.reverse = false
        let off = GestureScrollAdapter.axisOptions(application: nil)
        XCTAssertFalse(off.reverseVertical)

        Options.shared.scroll.reverse = true
        Options.shared.application.allowlist = true
        let blocked = GestureScrollAdapter.axisOptions(application: nil)
        XCTAssertFalse(blocked.reverseVertical)
    }

    func testGestureScroll_axisOptions_perAppIgnoresAllowlist() {
        let savedAllowlist = Options.shared.application.allowlist
        defer { Options.shared.application.allowlist = savedAllowlist }
        Options.shared.application.allowlist = true
        let application = Application(path: "/Applications/iPhone Mirroring.app")
        application.inherit = false
        application.scroll.reverse = true
        application.scroll.reverseVertical = true
        application.scroll.reverseHorizontal = false
        let options = GestureScrollAdapter.axisOptions(application: application)
        XCTAssertTrue(options.reverseVertical)
        XCTAssertFalse(options.reverseHorizontal)
    }

    func testGestureScroll_isTarget_usesWindowUnderPointerWhenEventPidIsNotTarget() throws {
        GestureScrollTarget.testingMatchesUnderPointer = true
        defer { GestureScrollTarget.testingMatchesUnderPointer = nil }
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 1))
        cgEvent.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
        XCTAssertTrue(
            GestureScrollTarget.isEventTarget(cgEvent),
            "inactive iPhone Mirroring window under the cursor must still reverse"
        )
    }

    func testGestureScroll_isTarget_ignoresNonTargetWindowUnderPointer() throws {
        GestureScrollTarget.testingMatchesUnderPointer = false
        defer { GestureScrollTarget.testingMatchesUnderPointer = nil }
        let cgEvent = try XCTUnwrap(makeScrollEvent(deltaAxis1: 1))
        cgEvent.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(GestureScrollTarget.isEventTarget(cgEvent))
        cgEvent.setIntegerValueField(.eventTargetUnixProcessID, value: 0)
        XCTAssertFalse(GestureScrollTarget.isEventTarget(cgEvent))
    }

    func testGestureScrollBridge_postsBeganThenEnded() {
        let savedDelay = GestureScrollBridge.shared.endDelay
        GestureScrollBridge.shared.endDelay = 0.05
        var phases: [Int64] = []
        let fieldScrollPhase = CGEventField(rawValue: 99)!
        let fieldEventType = CGEventField(rawValue: 55)!
        TouchSimulator.testingPostHook = { event in
            let eventType = event.getIntegerValueField(fieldEventType)
            if eventType == Int64(NSEvent.EventType.scrollWheel.rawValue) {
                phases.append(event.getIntegerValueField(fieldScrollPhase))
            }
        }
        defer {
            TouchSimulator.testingPostHook = nil
            GestureScrollBridge.shared.endDelay = savedDelay
            GestureScrollBridge.shared.reset()
        }

        GestureScrollBridge.shared.handle(deltaX: 0, deltaY: 33.6)
        XCTAssertEqual(phases, [GestureScrollPhase.began.rawValue])
        GestureScrollBridge.shared.handle(deltaX: 0, deltaY: 33.6)
        XCTAssertEqual(phases, [GestureScrollPhase.began.rawValue, GestureScrollPhase.changed.rawValue])

        let ended = expectation(description: "gesture ended")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if phases.last == GestureScrollPhase.ended.rawValue {
                ended.fulfill()
            }
        }
        wait(for: [ended], timeout: 1.0)
    }
}
