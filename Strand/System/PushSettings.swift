import Foundation
import Security

/// Settings and gating for the optional self-hosted one-way push (docs/SCOPE.md, "Experimental
/// exception"; wire format docs/PUSH_PROTOCOL.md). Default OFF. With the switch off, no endpoint or no
/// token, nothing runs: no network egress and no change to sync, scores or screens.
///
/// Lives in the shared tree (Foundation + Security only) so the gate is unit-tested on the macOS test
/// target; the engine and UI that use it are iOS-only (StrandiOS/Push/).
enum PushSettings {
    static let enabledKey = "noop.push.enabled"
    static let endpointKey = "noop.push.endpoint"
    static let lastRunAtKey = "noop.push.lastRunAt"
    static let lastStatusKey = "noop.push.lastStatus"

    private static let service = "com.noop.push"
    private static let account = "bearer-token"

    /// `<bundle id>.push`, like every other background-task identifier; it must also appear in
    /// `BGTaskSchedulerPermittedIdentifiers` (project.yml).
    static func taskIdentifier(bundleID: String?) -> String {
        return (bundleID ?? "com.noopapp.noop") + ".push"
    }

    /// HTTPS with a host: a bearer token never travels in clear text.
    static func isValidEndpoint(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// The single gate every trigger passes through.
    static func shouldRun(enabled: Bool, endpoint: String, token: String?) -> Bool {
        guard enabled, isValidEndpoint(endpoint) else { return false }
        return !(token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldRun() -> Bool {
        let d = UserDefaults.standard
        return shouldRun(enabled: d.bool(forKey: enabledKey),
                         endpoint: d.string(forKey: endpointKey) ?? "",
                         token: token())
    }

    // MARK: Bearer token (Keychain, never UserDefaults)

    private static var baseQuery: [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Store (or replace) the token. Readable after first unlock so a background upload works with the
    /// phone locked; never synced to other devices.
    @discardableResult
    static func setToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func token() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func clearToken() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// When the system may wake the app to upload. A processing task suits the nightly catch-up: iOS
/// runs it when the phone is idle (often charging overnight) and has network.
enum PushSchedulePolicy {
    static let minimumInterval: TimeInterval = 15 * 60

    static func earliestBeginDate(after now: Date) -> Date {
        return now.addingTimeInterval(minimumInterval)
    }

    static func shouldSchedule(gateOpen: Bool) -> Bool {
        return gateOpen
    }
}

/// Foreground and offload-completed triggers can fire in bursts (reconnect flaps, rapid re-opens); an
/// explicit "Upload now" is never throttled.
enum PushThrottle {
    static let minimumGap: TimeInterval = 120

    static func shouldStart(manual: Bool, lastStartedAt: Date?, now: Date) -> Bool {
        if manual { return true }
        guard let last = lastStartedAt else { return true }
        return now.timeIntervalSince(last) >= minimumGap
    }

    /// What to do with a trigger. A trigger that is throttled or arrives mid-run is REMEMBERED, never
    /// dropped: the offload that lands while a foreground run is still going is exactly the data the
    /// midnight debrief needs.
    static func decision(manual: Bool, isRunning: Bool, lastStartedAt: Date?, now: Date) -> PushRunDecision {
        if isRunning { return .rerunAfterCurrent }
        if shouldStart(manual: manual, lastStartedAt: lastStartedAt, now: now) { return .start }
        let earliest = (lastStartedAt ?? now).addingTimeInterval(minimumGap)
        return .retryAt(earliest)
    }
}

enum PushRunDecision: Equatable {
    case start
    case rerunAfterCurrent
    case retryAt(Date)
}
