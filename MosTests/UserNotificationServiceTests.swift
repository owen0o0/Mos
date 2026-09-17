import XCTest
import UserNotifications
@testable import Mos_Debug

final class UserNotificationServiceTests: XCTestCase {

    func testMakeImmediateRequest_setsTitleSubtitleAndNilTrigger() {
        let request = UserNotificationRequestBuilder.makeImmediateRequest(
            title: "Update available",
            subtitle: "Mos 4.0",
            identifier: "notice-1"
        )

        XCTAssertEqual(request.identifier, "notice-1")
        XCTAssertEqual(request.content.title, "Update available")
        XCTAssertEqual(request.content.subtitle, "Mos 4.0")
        XCTAssertNil(request.trigger)
    }

    func testForegroundPresentationOptions_showBannerAndListWithoutSound() {
        let options = UserNotificationPresentation.foregroundOptions
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.list))
        XCTAssertFalse(options.contains(.sound))
    }

    func testSend_whenAuthorized_deliversWithoutPrompting() {
        let center = FakeUserNotificationCenter(status: .authorized)
        let service = UserNotificationService(
            center: center,
            presenter: nil,
            makeIdentifier: { "fixed-id" }
        )

        service.send(title: "Hello", subtitle: "World")

        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(center.addedRequests[0].identifier, "fixed-id")
        XCTAssertEqual(center.addedRequests[0].content.title, "Hello")
        XCTAssertEqual(center.addedRequests[0].content.subtitle, "World")
    }

    func testSend_whenProvisional_deliversWithoutPrompting() {
        let center = FakeUserNotificationCenter(status: .provisional)
        let service = UserNotificationService(center: center, presenter: nil)

        service.send(title: "Hello", subtitle: "World")

        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertEqual(center.addedRequests.count, 1)
    }

    func testSend_whenNotDeterminedAndGranted_requestsThenDelivers() {
        let center = FakeUserNotificationCenter(status: .notDetermined, requestResult: true)
        let service = UserNotificationService(center: center, presenter: nil)

        service.send(title: "Hello", subtitle: "World")

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertEqual(center.status, .authorized)
    }

    func testSend_whenNotDeterminedAndDenied_doesNotDeliver() {
        let center = FakeUserNotificationCenter(status: .notDetermined, requestResult: false)
        let service = UserNotificationService(center: center, presenter: nil)

        service.send(title: "Hello", subtitle: "World")

        XCTAssertEqual(center.authorizationRequestCount, 1)
        XCTAssertTrue(center.addedRequests.isEmpty)
    }

    func testSend_whenDenied_doesNotPromptOrDeliver() {
        let center = FakeUserNotificationCenter(status: .denied)
        let service = UserNotificationService(center: center, presenter: nil)

        service.send(title: "Hello", subtitle: "World")

        XCTAssertEqual(center.authorizationRequestCount, 0)
        XCTAssertTrue(center.addedRequests.isEmpty)
    }

    func testSend_preparesForegroundPresenter() {
        let center = FakeUserNotificationCenter(status: .authorized)
        let presenter = FakeUserNotificationPresenter()
        let service = UserNotificationService(center: center, presenter: presenter)

        service.send(title: "Hello", subtitle: "World")

        XCTAssertEqual(presenter.prepareCount, 1)
    }
}

private final class FakeUserNotificationCenter: UserNotificationDelivering {
    var status: UNAuthorizationStatus
    var requestResult: Bool
    var addedRequests: [UNNotificationRequest] = []
    var authorizationRequestCount = 0

    init(status: UNAuthorizationStatus, requestResult: Bool = true) {
        self.status = status
        self.requestResult = requestResult
    }

    func fetchAuthorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        completion(status)
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        authorizationRequestCount += 1
        if requestResult {
            status = .authorized
        }
        completion(requestResult)
    }

    func add(_ request: UNNotificationRequest) {
        addedRequests.append(request)
    }
}

private final class FakeUserNotificationPresenter: UserNotificationPresenting {
    var prepareCount = 0

    func prepareForForegroundPresentation() {
        prepareCount += 1
    }
}
