#if os(iOS)
import Foundation
import SelfHostPush
import UIKit

/// Thread-safe "stop between batches" flag shared with the background-assertion expiry handler.
final class PushCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

enum PushOutcome {
    case finished(PushRunResult)
    case failed(String)

    var succeeded: Bool {
        switch self {
        case .finished(let r): return r.error == nil
        case .failed: return false
        }
    }
}

/// Owns the self-hosted push on iOS (default OFF, see `PushSettings`). Every lifecycle hook calls
/// `trigger`, which is fire-and-forget: it returns immediately, never throws, and a slow, failing or
/// unreachable receiver can never delay the strap sync, scoring or UI (docs/SCOPE.md). One run at a
/// time; progress is saved per batch so a suspended or killed run resumes on the next trigger.
@MainActor
final class PushCoordinator: ObservableObject {
    static let shared = PushCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var statusLine: String
    @Published private(set) var lastRunAt: Date?

    private var lastStartedAt: Date?
    private let cancelFlag = PushCancelFlag()

    private init() {
        let d = UserDefaults.standard
        statusLine = d.string(forKey: PushSettings.lastStatusKey) ?? "Not run yet."
        let t = d.double(forKey: PushSettings.lastRunAtKey)
        lastRunAt = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Lifecycle hooks (foreground, offload landed) call this.
    func trigger(_ trigger: PushTrigger) {
        Task { await run(trigger) }
    }

    /// Entry used by the BGProcessingTask handler; true when the pass ended without an error.
    func runForBackgroundTask() async -> Bool {
        return await run(.backgroundTask)
    }

    func cancelCurrentRun() {
        cancelFlag.set()
    }

    @discardableResult
    func run(_ trigger: PushTrigger, budget: TimeInterval? = nil) async -> Bool {
        // The gate: no endpoint, no token or switched off means no work and no network at all.
        guard PushSettings.shouldRun(), !isRunning else { return true }
        guard PushThrottle.shouldStart(manual: trigger == .manual, lastStartedAt: lastStartedAt, now: Date()) else {
            return true
        }
        isRunning = true
        lastStartedAt = Date()
        let flag = cancelFlag
        flag.reset()
        // A short grace period if the app is suspended mid-run; the expiry handler asks the engine to
        // stop between batches, which is safe because progress is only advanced after each acknowledgement.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "noop.push") { flag.set() }
        let seconds = budget ?? PushCoordinator.defaultBudget(for: trigger)
        let outcome = await Task.detached(priority: .utility) { () async -> PushOutcome in
            return await PushCoordinator.execute(trigger, seconds: seconds, flag: flag)
        }.value
        if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
        isRunning = false
        record(outcome)
        return outcome.succeeded
    }

    /// "Test connection": the authenticated capabilities request only. No database is opened and no
    /// health data is read or sent.
    func testConnection() async -> String {
        guard let endpoint = PushCoordinator.makeEndpoint() else {
            return "Enter an https:// address and a token first."
        }
        do {
            let caps = try await PushTransport().capabilities(endpoint, accept: [.ext, .v1])
            return "Connected. Protocol \(caps.protocolVersion.rawValue), \(caps.streams.count) streams accepted."
        } catch let e as PushError {
            return e.message
        } catch {
            return "Could not connect."
        }
    }

    // MARK: Work (off the main actor)

    nonisolated static func defaultBudget(for trigger: PushTrigger) -> TimeInterval {
        switch trigger {
        case .offloadLanded: return 25
        case .foreground: return 120
        case .backgroundTask: return 180
        case .manual: return 600
        }
    }

    nonisolated static func makeEndpoint() -> PushEndpoint? {
        let d = UserDefaults.standard
        return PushEndpoint(urlString: d.string(forKey: PushSettings.endpointKey) ?? "",
                            token: PushSettings.token() ?? "")
    }

    nonisolated static func makeEngine(endpoint: PushEndpoint) throws -> PushEngine {
        let dbPath = try StorePaths.defaultDatabasePath()
        let dir = URL(fileURLWithPath: dbPath).deletingLastPathComponent()
        let progressURL = dir.appendingPathComponent("push-progress.sqlite")
        let progress = try ProgressStore(url: progressURL)
        // Same protection class as the store: readable after first unlock, so a locked-phone upload works.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: progressURL.path)
        let source = try GRDBRowSource(databasePath: dbPath)
        return PushEngine(source: source, progress: progress, transport: PushTransport(),
                          endpoint: endpoint, versions: [.ext, .v1])
    }

    nonisolated static func execute(_ trigger: PushTrigger, seconds: TimeInterval,
                                    flag: PushCancelFlag) async -> PushOutcome {
        guard let endpoint = makeEndpoint() else {
            return .failed("Enter an https:// address and a token first.")
        }
        do {
            let engine = try makeEngine(endpoint: endpoint)
            let deadline = Date().addingTimeInterval(seconds)
            let result = await engine.runOnce(trigger, deadline: deadline,
                                              now: { flag.isSet ? Date.distantFuture : Date() })
            return .finished(result)
        } catch {
            return .failed("The local database is not ready yet.")
        }
    }

    // MARK: Status (never contains health values)

    private func record(_ outcome: PushOutcome) {
        let line = PushCoordinator.statusLine(for: outcome)
        let now = Date()
        statusLine = line
        lastRunAt = now
        let d = UserDefaults.standard
        d.set(line, forKey: PushSettings.lastStatusKey)
        d.set(now.timeIntervalSince1970, forKey: PushSettings.lastRunAtKey)
    }

    nonisolated static func statusLine(for outcome: PushOutcome) -> String {
        switch outcome {
        case .failed(let message):
            return message
        case .finished(let r):
            if let e = r.error {
                switch e {
                case .retryable(let m): return "Waiting: \(m). Will retry."
                case .fatal(let m), .rejected(let m): return "Problem: \(m)."
                }
            }
            if !r.pendingStreams.isEmpty {
                return "Sent \(r.sentRows) rows; more is pending and will continue on the next run."
            }
            return r.sentRows == 0 ? "Up to date." : "Up to date. Sent \(r.sentRows) rows."
        }
    }
}
#endif
