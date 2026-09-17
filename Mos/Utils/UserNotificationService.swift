//
//  UserNotificationService.swift
//  Mos
//
//  UserNotifications.framework replacement for the deprecated NSUserNotification API.
//

import UserNotifications

protocol UserNotificationDelivering: AnyObject {
    func fetchAuthorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void)
    func requestAuthorization(_ completion: @escaping (Bool) -> Void)
    func add(_ request: UNNotificationRequest)
}

protocol UserNotificationPresenting: AnyObject {
    func prepareForForegroundPresentation()
}

enum UserNotificationRequestBuilder {
    static func makeImmediateRequest(
        title: String,
        subtitle: String,
        identifier: String
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

enum UserNotificationPresentation {
    static let foregroundOptions: UNNotificationPresentationOptions = [.banner, .list]
    static let authorizationOptions: UNAuthorizationOptions = [.alert]
}

final class SystemUserNotificationDeliverer: UserNotificationDelivering {
    static let shared = SystemUserNotificationDeliverer()

    private let center = UNUserNotificationCenter.current()

    func fetchAuthorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        center.getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: UserNotificationPresentation.authorizationOptions) { granted, _ in
            completion(granted)
        }
    }

    func add(_ request: UNNotificationRequest) {
        center.add(request, withCompletionHandler: nil)
    }
}

final class SystemUserNotificationPresenter: NSObject, UserNotificationPresenting, UNUserNotificationCenterDelegate {
    static let shared = SystemUserNotificationPresenter()

    private weak var forwardingDelegate: UNUserNotificationCenterDelegate?

    func prepareForForegroundPresentation() {
        let center = UNUserNotificationCenter.current()
        if center.delegate !== self {
            forwardingDelegate = center.delegate
            center.delegate = self
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(UserNotificationPresentation.foregroundOptions)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
        guard let forwardingDelegate, forwardingDelegate.responds(to: selector) else {
            completionHandler()
            return
        }
        forwardingDelegate.userNotificationCenter?(
            center,
            didReceive: response,
            withCompletionHandler: completionHandler
        )
    }
}

final class UserNotificationService {
    static let shared = UserNotificationService()

    private let center: UserNotificationDelivering
    private let presenter: UserNotificationPresenting?
    private let makeIdentifier: () -> String

    init(
        center: UserNotificationDelivering = SystemUserNotificationDeliverer.shared,
        presenter: UserNotificationPresenting? = SystemUserNotificationPresenter.shared,
        makeIdentifier: @escaping () -> String = { UUID().uuidString }
    ) {
        self.center = center
        self.presenter = presenter
        self.makeIdentifier = makeIdentifier
    }

    func send(title: String, subtitle: String) {
        presenter?.prepareForForegroundPresentation()
        let request = UserNotificationRequestBuilder.makeImmediateRequest(
            title: title,
            subtitle: subtitle,
            identifier: makeIdentifier()
        )
        deliver(request)
    }

    private func deliver(_ request: UNNotificationRequest) {
        center.fetchAuthorizationStatus { [center] status in
            switch status {
            case .authorized, .provisional:
                center.add(request)
            case .notDetermined:
                center.requestAuthorization { granted in
                    guard granted else { return }
                    center.add(request)
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }
}
