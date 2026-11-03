// Notifier.swift - local notifications (memory, throttling, stuck GPU). Never blocks the caller.
import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called on the main queue with true when the user has turned notifications off.
    var onDeniedChange: ((Bool) -> Void)?

    private let center: UNUserNotificationCenter?
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
        // UNUserNotificationCenter traps outside an app bundle (e.g. a bare debug binary).
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
    }

    /// Asks once; later calls only refresh the denied flag.
    func requestAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error { self.log("notify: authorization error \(error.localizedDescription)") }
                    self.report(denied: !granted)
                }
            case .denied:
                self.report(denied: true)
            default:
                self.report(denied: false)
            }
        }
    }

    func post(id: String, title: String, body: String) {
        guard let center else {
            log("notify: no bundle, skipped \(id)")
            return
        }
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                self.report(denied: settings.authorizationStatus == .denied)
                if settings.authorizationStatus == .notDetermined { self.requestAuthorization() }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // A fixed identifier per kind replaces an older banner instead of stacking them.
            let request = UNNotificationRequest(identifier: "thermalbar.\(id)", content: content, trigger: nil)
            center.add(request) { error in
                if let error { self.log("notify: failed \(id): \(error.localizedDescription)") }
            }
        }
    }

    private func report(denied: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onDeniedChange?(denied) }
    }

    // Show banners even though ThermalBar is technically the active app while its panel is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
