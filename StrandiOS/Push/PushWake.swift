import Foundation
import SelfHostPush
import UIKit

/// Lets the receiver's MCP server wake NOOP with a silent APNs notification so the phone uploads now,
/// instead of waiting for the next offload, foreground or nightly task (`request_phone_sync`).
///
/// Off unless the self-hosted export is on (`PushSettings.shouldRun`). A silent notification needs no
/// notification permission and shows nothing; it carries no data, only `"noop": "sync"`. iOS rate-limits
/// these wakes, gives the app about 30 seconds, and never wakes an app the user force-quit, so a wake is a
/// request the phone answers when iOS lets it. The build needs the Push Notifications capability (a paid
/// Apple developer account); without it registration fails quietly and everything else works as before.
@MainActor
enum PushWake {
    /// Set by the app at launch: asks the strap for a fresh offload when a wake arrives. Uses the ordinary,
    /// floored sync request (`BackfillTrigger.foreground`), so a burst of wakes cannot hammer the strap.
    static var onWake: (() -> Void)?

    /// Background notifications get roughly 30 seconds; stop the upload early enough to report back.
    nonisolated static let wakeBudget: TimeInterval = 22
    /// Re-send an unchanged registration at most this often, so a receiver whose database was reset
    /// relearns the token within a day without a POST on every foreground.
    static let resendInterval: TimeInterval = 24 * 3600

    private static let sentFingerprintKey = "noop.push.wake.sentFingerprint"
    private static let sentAtKey = "noop.push.wake.sentAt"
    private static var lastDeviceToken: Data?

    /// APNs environment of this build: an Xcode debug run gets a sandbox token, a distributed build a
    /// production one. The receiver retries the other environment if this guess is wrong.
    static var environment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    /// Asks iOS for the device token (delivered to `didRegister`). Cheap and idempotent: call on every
    /// foreground and whenever the export settings change.
    static func registerIfEnabled() {
        guard PushSettings.shouldRun() else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// After the address or token changed: send the registration again even if it looks unchanged.
    static func reRegister() {
        if let token = lastDeviceToken {
            didRegister(deviceToken: token, force: true)
        } else {
            registerIfEnabled()
        }
    }

    static func didRegister(deviceToken: Data, force: Bool = false) {
        lastDeviceToken = deviceToken
        guard PushSettings.shouldRun(), let endpoint = PushCoordinator.makeEndpoint(),
              let topic = Bundle.main.bundleIdentifier else { return }
        let env = environment
        let fingerprint = [endpoint.url.absoluteString, PushTransport.hexToken(deviceToken), env, topic]
            .joined(separator: "|")
        let defaults = UserDefaults.standard
        let recent = Date().timeIntervalSince1970 - defaults.double(forKey: sentAtKey) < resendInterval
        if !force && recent && defaults.string(forKey: sentFingerprintKey) == fingerprint { return }
        Task {
            do {
                try await PushTransport().registerWakeToken(endpoint, deviceToken: deviceToken,
                                                            environment: env, topic: topic)
                defaults.set(fingerprint, forKey: sentFingerprintKey)
                defaults.set(Date().timeIntervalSince1970, forKey: sentAtKey)
            } catch {
                // Retried on the next foreground. The export itself does not depend on this.
            }
        }
    }

    /// A silent notification arrived. Only NOOP's own wake is acted on; anything else reports no data.
    static func handle(_ userInfo: [AnyHashable: Any],
                       completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard userInfo["noop"] as? String == "sync", PushSettings.shouldRun() else {
            completion(.noData)
            return
        }
        onWake?()
        Task {
            let ok = await PushCoordinator.shared.run(.remoteWake, budget: wakeBudget)
            completion(ok ? .newData : .failed)
        }
    }
}

/// APNs callbacks. They live on the existing app delegate (the SwiftUI app has exactly one) and only
/// forward to `PushWake`.
extension HomeScreenQuickActionAppDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushWake.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Typically a build without the Push Notifications capability. Nothing else depends on it.
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        PushWake.handle(userInfo, completion: completionHandler)
    }
}
