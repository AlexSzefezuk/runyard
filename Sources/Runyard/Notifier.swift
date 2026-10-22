import AppKit
import RunyardCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()
    private let crashCategory = "crash"
    private let restartAction = "restart"
    private let logAction = "log"

    func setup() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: crashCategory, actions: [
                UNNotificationAction(identifier: restartAction, title: "Reiniciar"),
                UNNotificationAction(identifier: logAction, title: "Ver log", options: [.foreground])
            ], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("Erro ao pedir permissão de notificação: \(error.localizedDescription)")
            } else if !granted {
                print("Notificações não permitidas")
            }
        }
    }

    func serviceCrashed(_ key: ServiceKey, status: ServiceStatus, note: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = "\(key.project) / \(key.service) caiu"
        let lastLine = LogReader.lastLines(ConfigStore.logURL(project: key.project, service: key.service), count: 2)
            .first { !$0.hasPrefix("=====") }
        content.body = [StatusStyle.label(status), note, lastLine].compactMap { $0 }.joined(separator: "\n")
        content.sound = .default
        content.categoryIdentifier = crashCategory
        content.userInfo = ["project": key.project, "service": key.service]
        let request = UNNotificationRequest(identifier: "crash-\(key.project)-\(key.service)", content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                print("Erro ao enviar notificação: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        if let project = info["project"] as? String, let service = info["service"] as? String {
            Task { @MainActor in
                self.handle(action, key: ServiceKey(project: project, service: service))
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func handle(_ action: String, key: ServiceKey) {
        let manager = ProcessManager.shared
        guard action == restartAction else {
            LogWindowController.shared.show(key)
            return
        }
        guard let project = manager.projects.first(where: { $0.name == key.project }),
              let service = project.services.first(where: { $0.name == key.service }) else { return }
        manager.restart(project, service)
    }
}
