import XCTest
@testable import Mos_Debug

final class TouchSimulatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TouchSimulator.testingPostHook = nil
        TouchSimulator.resetDockSwipeStateForTesting()
    }

    override func tearDown() {
        TouchSimulator.testingPostHook = nil
        TouchSimulator.resetDockSwipeStateForTesting()
        super.tearDown()
    }

    func testHIDPayload_horizontalBegan_usesDockMotionWithoutVelocity() {
        let payload = DockSwipeHIDEvent.payload(
            axis: .horizontal,
            phase: .began,
            progress: 0.25,
            velocity: nil
        )
        XCTAssertEqual(payload.motion, 1)
        XCTAssertEqual(payload.progress, 0.25)
        XCTAssertEqual(payload.phase, .began)
        XCTAssertNil(payload.velocity)
    }

    func testHIDPayload_verticalEnded_keepsVelocityInSameSpace() {
        let payload = DockSwipeHIDEvent.payload(
            axis: .vertical,
            phase: .ended,
            progress: -0.8,
            velocity: -12.0
        )
        XCTAssertEqual(payload.motion, 2)
        XCTAssertEqual(payload.progress, -0.8, accuracy: 0.0001)
        XCTAssertEqual(payload.velocity ?? 0, -12.0, accuracy: 0.0001)
    }

    func testHIDPayload_pinchUsesScaleMotion() {
        let payload = DockSwipeHIDEvent.payload(
            axis: .pinch,
            phase: .changed,
            progress: 0.4,
            velocity: nil
        )
        XCTAssertEqual(payload.motion, 3)
    }

    func testAttach_roundTripsDockSwipeFieldsOnCurrentRuntime() {
        guard DockSwipeHIDEvent.attachIsAvailable else {
            if DockSwipeHIDEvent.isRequired {
                XCTFail("macOS 27 dock swipe path requires SLEventSetIOHIDEvent / IOHIDEventCreate")
            }
            return
        }
        guard let event = CGEvent(source: nil) else {
            XCTFail("CGEventCreate failed")
            return
        }
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        let payload = DockSwipeHIDEvent.payload(
            axis: .horizontal,
            phase: .ended,
            progress: 0.5,
            velocity: 18.0
        )
        XCTAssertTrue(DockSwipeHIDEvent.attach(to: event, payload: payload))
        guard let inspection = DockSwipeHIDEvent.inspectAttached(from: event) else {
            XCTFail("attached IOHIDEvent was not readable")
            return
        }
        XCTAssertEqual(inspection.type, 23)
        XCTAssertEqual(inspection.motion, 1)
        XCTAssertEqual(inspection.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(inspection.flavor, 3)
        XCTAssertEqual(inspection.velocityX, 18.0, accuracy: 0.0001)
    }

    func testPostDockSwipe_onMacOS27AttachesHIDEvent() {
        guard DockSwipeHIDEvent.isRequired else { return }
        XCTAssertTrue(DockSwipeHIDEvent.attachIsAvailable)

        var inspections: [DockSwipeHIDEvent.Inspection] = []
        TouchSimulator.testingPostHook = { event in
            let hidType = event.getIntegerValueField(CGEventField(rawValue: 110)!)
            guard hidType == 23 else { return }
            if let inspection = DockSwipeHIDEvent.inspectAttached(from: event) {
                inspections.append(inspection)
            }
        }

        TouchSimulator.postDockSwipe(delta: 0.2, axis: .horizontal, phase: .began, inverted: true)
        TouchSimulator.postDockSwipe(delta: 0.1, axis: .horizontal, phase: .changed, inverted: true)
        TouchSimulator.postDockSwipe(delta: 0, axis: .horizontal, phase: .ended, inverted: true)

        XCTAssertEqual(inspections.count, 3)
        XCTAssertEqual(inspections.first?.motion, 1)
        XCTAssertEqual(inspections.first?.progress ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(inspections.last?.progress ?? 0, 0.3, accuracy: 0.0001)
        XCTAssertEqual(inspections.last?.velocityX ?? 0, 10.0, accuracy: 0.0001)
    }
}
