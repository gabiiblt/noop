#if os(iOS)
import BackgroundTasks
import Foundation

/// Nightly catch-up for the self-hosted push. A processing task runs when the phone is idle and online
/// (often charging overnight), which is when a large backlog is best drained; the foreground and
/// offload-completed triggers handle the rest. The request is single-shot, so the handler re-arms the
/// next one first; iOS may discard requests, so the lifecycle hooks re-submit on every transition.
@MainActor
enum PushBackgroundScheduler {
    static var taskIdentifier: String {
        return PushSettings.taskIdentifier(bundleID: Bundle.main.bundleIdentifier)
    }

    /// Register at launch, before the first scene finishes connecting. The identifier must also be listed
    /// in `BGTaskSchedulerPermittedIdentifiers` (project.yml) or iOS refuses it.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            let completion = TaskCompletionGuard(task: task)
            let worker = Task { @MainActor in
                schedule()
                let succeeded = await PushCoordinator.shared.runForBackgroundTask()
                guard !Task.isCancelled else { return }
                completion.finish(success: succeeded)
            }
            task.expirationHandler = {
                worker.cancel()
                Task { @MainActor in PushCoordinator.shared.cancelCurrentRun() }
                completion.finish(success: false)
            }
        }
    }

    /// Keep exactly one pending request, and only while the gate is open.
    static func schedule(now: Date = Date()) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        guard PushSchedulePolicy.shouldSchedule(gateOpen: PushSettings.shouldRun()) else { return }
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = PushSchedulePolicy.earliestBeginDate(after: now)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    /// Idempotent: arms the request while enabled and configured, cancels it otherwise.
    static func updateSchedule() {
        if PushSettings.shouldRun() { schedule() } else { cancel() }
    }

    /// `BGTask` completion is single-shot even when normal completion races expiration.
    private final class TaskCompletionGuard: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var finished = false

        init(task: BGTask) { self.task = task }

        func finish(success: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            task.setTaskCompleted(success: success)
            task.expirationHandler = nil
        }
    }
}
#endif
