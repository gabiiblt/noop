#if os(iOS)
import Foundation
import SelfHostPush
import UIKit

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

/// One run's background-time assertion and worker task, owned together so the iOS expiry handler can
/// cancel the work AND end the assertion at once. iOS terminates an app that does not end a background
/// task after its expiry handler has run, so a handler that only set a flag would be a way to get the
/// app killed (this runs mostly on a BLE wake, in the background, during the strap sync).
final class PushRunHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<PushOutcome, Never>?
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    private var expired = false

    func setAssertion(_ id: UIBackgroundTaskIdentifier) {
        lock.lock()
        assertion = id
        lock.unlock()
    }

    func attach(_ worker: Task<PushOutcome, Never>) {
        lock.lock()
        task = worker
        let alreadyExpired = expired
        lock.unlock()
        if alreadyExpired { worker.cancel() }
    }

    /// iOS calls this on the main thread when the background time is about to be reclaimed. The engine
    /// stops between requests; an in-flight request is cancelled with the task.
    func expire() {
        lock.lock()
        expired = true
        let worker = task
        lock.unlock()
        worker?.cancel()
        end()
    }

    /// Idempotent: the expiry path and the normal completion path can both call it.
    func end() {
        lock.lock()
        let id = assertion
        assertion = .invalid
        lock.unlock()
        if id != .invalid {
            MainActor.assumeIsolated { UIApplication.shared.endBackgroundTask(id) }
        }
    }
}

/// Owns the self-hosted push on iOS (default OFF, see `PushSettings`). Every lifecycle hook calls
/// `trigger`, which is fire-and-forget: it returns immediately, never throws, and a slow, failing or
/// unreachable receiver can never delay the strap sync, scoring or UI (docs/SCOPE.md). One run at a
/// time; progress is saved per batch so a suspended or killed run resumes on the next trigger. A trigger
/// that arrives mid-run or inside the throttle gap is remembered and run afterwards, not dropped.
@MainActor
final class PushCoordinator: ObservableObject {
    static let shared = PushCoordinator()

    @Published private(set) var isRunning = false
    @Published private(set) var statusLine: String
    @Published private(set) var lastRunAt: Date?

    private var lastStartedAt: Date?
    private var currentHandle: PushRunHandle?
    private var rerunRequested = false
    private var retryTask: Task<Void, Never>?

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

    /// Called when a BGTask expires: cancels the work and ends the background assertion.
    func cancelCurrentRun() {
        currentHandle?.expire()
    }

    @discardableResult
    func run(_ trigger: PushTrigger, budget: TimeInterval? = nil) async -> Bool {
        // The gate: no endpoint, no token or switched off means no work and no network at all.
        guard PushSettings.shouldRun() else { return true }
        // A remote wake is the server asking for fresh data now: like "Upload now", never held by the gap.
        switch PushThrottle.decision(manual: trigger == .manual || trigger == .remoteWake, isRunning: isRunning,
                                     lastStartedAt: lastStartedAt, now: Date()) {
        case .rerunAfterCurrent:
            rerunRequested = true
            return true
        case .retryAt(let date):
            scheduleRetry(at: date)
            return true
        case .start:
            break
        }

        isRunning = true
        lastStartedAt = Date()
        let handle = PushRunHandle()
        currentHandle = handle
        // A short grace period if the app is suspended mid-run. The expiry handler cancels the work and
        // ends the assertion immediately; progress is only advanced after each acknowledgement.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "noop.push") { handle.expire() }
        handle.setAssertion(assertion)
        let seconds = budget ?? PushCoordinator.defaultBudget(for: trigger)
        let work = Task.detached(priority: .utility) { () async -> PushOutcome in
            return await PushCoordinator.execute(trigger, seconds: seconds)
        }
        handle.attach(work)
        let outcome = await work.value
        handle.end()
        currentHandle = nil
        isRunning = false
        record(outcome)
        if rerunRequested {
            rerunRequested = false
            scheduleRetry(at: Date())
        }
        return outcome.succeeded
    }

    /// Runs again once `date` has passed (the throttle decides whether that is immediately).
    private func scheduleRetry(at date: Date) {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            let wait = date.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard let self else { return }
            self.retryTask = nil
            if !Task.isCancelled { await self.run(.offloadLanded) }
        }
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
        case .remoteWake: return PushWake.wakeBudget
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

    /// Runs inside the detached worker task, so the engine sees that task's cancellation.
    nonisolated static func execute(_ trigger: PushTrigger, seconds: TimeInterval) async -> PushOutcome {
        guard let endpoint = makeEndpoint() else {
            return .failed("Enter an https:// address and a token first.")
        }
        do {
            let engine = try makeEngine(endpoint: endpoint)
            let result = await engine.runOnce(trigger, deadline: Date().addingTimeInterval(seconds))
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
