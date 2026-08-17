import XCTest
@testable import Mos_Debug

private final class GestureRecorderStubDelegate: ButtonGestureRecorderDelegate {
    var recorded: [(button: UInt16, modifiers: CGEventFlags, trigger: ButtonTrigger)] = []
    var cancelledCount = 0

    func buttonGestureRecorder(
        _ recorder: ButtonGestureRecorder,
        didRecord button: UInt16,
        modifiers: CGEventFlags,
        trigger: ButtonTrigger
    ) {
        recorded.append((button, modifiers, trigger))
    }

    func buttonGestureRecorderDidCancel(_ recorder: ButtonGestureRecorder) {
        cancelledCount += 1
    }
}

final class ButtonGestureRecorderTests: XCTestCase {

    private var recorder: ButtonGestureRecorder!
    private var delegate: GestureRecorderStubDelegate!

    override func setUp() {
        super.setUp()
        recorder = ButtonGestureRecorder()
        recorder.holdThreshold = 0.05
        recorder.clickWindow = 0.06
        recorder.pollInterval = 0.01
        recorder.dragThreshold = 10
        delegate = GestureRecorderStubDelegate()
        recorder.delegate = delegate
        recorder.beginTestingSessionForTests()
    }

    override func tearDown() {
        recorder.stopTestingSessionForTests()
        recorder = nil
        delegate = nil
        super.tearDown()
    }

    private func runMainLoop(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    private func quickClick() {
        recorder.handleButtonDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        recorder.handleButtonUp(button: 3)
    }

    func testSingleClick_recordsClickLevel1() {
        quickClick()
        runMainLoop(0.15)
        XCTAssertEqual(delegate.recorded.count, 1)
        XCTAssertEqual(
            delegate.recorded[0].trigger,
            ButtonTrigger(buttonNumber: 3, level: 1, duration: .click)
        )
    }

    func testDoubleClick_recordsClickLevel2() {
        quickClick()
        quickClick()
        runMainLoop(0.15)
        XCTAssertEqual(delegate.recorded.count, 1)
        XCTAssertEqual(
            delegate.recorded[0].trigger,
            ButtonTrigger(buttonNumber: 3, level: 2, duration: .click)
        )
    }

    func testTripleClick_recordsClickLevel3() {
        quickClick()
        quickClick()
        quickClick()
        runMainLoop(0.15)
        XCTAssertEqual(delegate.recorded.count, 1)
        XCTAssertEqual(
            delegate.recorded[0].trigger,
            ButtonTrigger(buttonNumber: 3, level: 3, duration: .click)
        )
    }

    func testHold_recordsHold() {
        recorder.handleButtonDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        runMainLoop(0.15)  // 超过 holdThreshold
        XCTAssertEqual(delegate.recorded.count, 1)
        XCTAssertEqual(
            delegate.recorded[0].trigger,
            ButtonTrigger(buttonNumber: 3, level: 1, duration: .hold)
        )
    }

    func testDrag_recordsDragWhenMoved() {
        var location = CGPoint(x: 100, y: 100)
        recorder.locationProvider = { location }
        recorder.handleButtonDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        location = CGPoint(x: 120, y: 100)  // 位移 20 > 阈值 10
        runMainLoop(0.08)
        XCTAssertEqual(delegate.recorded.count, 1)
        XCTAssertEqual(
            delegate.recorded[0].trigger,
            ButtonTrigger(buttonNumber: 3, level: 1, duration: .drag)
        )
    }

    func testScroll_recordsHoldAndScroll() {
        recorder.handleButtonDown(button: 3, modifiers: CGEventFlags(rawValue: 0))
        recorder.handleScrollInput()
        XCTAssertEqual(delegate.recorded.count, 1)
        XCTAssertEqual(
            delegate.recorded[0].trigger,
            ButtonTrigger(buttonNumber: 3, level: 1, duration: .scroll)
        )
    }

    func testCancel_notifiesDelegate() {
        recorder.cancel()
        XCTAssertEqual(delegate.cancelledCount, 1)
        XCTAssertFalse(recorder.isRecording)
    }

    func testModifiers_preservedOnRecord() {
        recorder.handleButtonDown(button: 3, modifiers: CGEventFlags.maskCommand)
        recorder.handleButtonUp(button: 3)
        runMainLoop(0.15)
        XCTAssertEqual(delegate.recorded[0].modifiers, CGEventFlags.maskCommand)
    }
}
