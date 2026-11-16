import Foundation

public enum PushTrigger: String, Sendable {
    case offloadLanded, foreground, backgroundTask, manual
}

public struct PushRunResult: Equatable, Sendable {
    public var sentRows: Int
    /// Streams that still have data to send (deadline reached or an error stopped them).
    public var pendingStreams: [String]
    public var error: PushError?
    public var version: PushVersion?

    public var completed: Bool { return error == nil && pendingStreams.isEmpty }
}

/// One upload pass: negotiate with the receiver, then for every advertised stream and device send what
/// is new. Nothing here touches the strap or blocks on it, and every failure leaves progress intact so
/// the next pass resumes (iOS suspends the app, so delivery is catch-up, not real time).
public final class PushEngine {
    /// Replace-window runs of changed days further apart than this are sent as separate windows.
    static let windowGapDays = 30

    private let source: RowSource
    private let progress: ProgressStore
    private let transport: PushTransporting
    private let endpoint: PushEndpoint
    private let versions: [PushVersion]
    private let days: DayMath
    public var log: (String) -> Void = { _ in }

    public init(source: RowSource, progress: ProgressStore, transport: PushTransporting,
                endpoint: PushEndpoint, versions: [PushVersion] = [.v1], calendar: Calendar = .current) {
        self.source = source
        self.progress = progress
        self.transport = transport
        self.endpoint = endpoint
        self.versions = versions
        self.days = DayMath(calendar: calendar)
    }

    // MARK: Ordering

    private static let order: [String: Int] = [
        "hrSample": 0, "rrInterval": 1, "sleepSession": 2, "dailyMetric": 3, "workout": 4, "journal": 5,
        "battery": 6, "event": 7, "spo2Sample": 8, "skinTempSample": 9, "respSample": 10, "gravitySample": 11,
    ]

    static func priority(_ spec: StreamSpec) -> Int {
        return order[spec.name] ?? 50
    }

    // MARK: Run

    public func runOnce(_ trigger: PushTrigger, deadline: Date,
                        now: @escaping () -> Date = { Date() }) async -> PushRunResult {
        var result = PushRunResult(sentRows: 0, pendingStreams: [], error: nil, version: nil)
        func pend(_ name: String) {
            if !result.pendingStreams.contains(name) { result.pendingStreams.append(name) }
        }

        let caps: Capabilities
        do {
            caps = try await transport.capabilities(endpoint, accept: versions)
        } catch let e as PushError {
            result.error = e
            return result
        } catch {
            result.error = .retryable("unexpected error")
            return result
        }
        result.version = caps.protocolVersion
        let version = caps.protocolVersion
        let ext = version == .ext
        let specs = PushRegistry.streams(for: version)
            .filter { caps.streams.contains($0.name) }
            .sorted { PushEngine.priority($0) < PushEngine.priority($1) }
        let ns = progress.namespace(endpoint: endpoint.url, version: version, receiverStateId: caps.receiverStateId)

        let devices: [String]
        do {
            let live = try source.deviceIds()
            try progress.rememberDevices(live)
            let remembered = try progress.knownDevices()
            devices = Array(Set(live).union(remembered)).sorted()
        } catch {
            result.error = .fatal("local database unavailable")
            return result
        }
        log("push \(trigger.rawValue): v\(version.rawValue), \(specs.count) streams, \(devices.count) devices")

        outer: for spec in specs {
            for device in devices {
                if now() >= deadline {
                    pend(spec.name)
                    continue
                }
                do {
                    let outcome = try await push(spec, device: device, ns: ns, version: version, ext: ext,
                                                 deadline: deadline, now: now)
                    result.sentRows += outcome.sent
                    if !outcome.finished { pend(spec.name) }
                } catch let e as PushError {
                    pend(spec.name)
                    if result.error == nil { result.error = e }
                    if case .rejected = e { break }  // this stream only; the others may continue
                    break outer
                } catch {
                    pend(spec.name)
                    if result.error == nil { result.error = .fatal("local database error") }
                    break outer
                }
            }
        }
        return result
    }

    private func push(_ spec: StreamSpec, device: String, ns: String, version: PushVersion, ext: Bool,
                      deadline: Date, now: @escaping () -> Date) async throws -> (sent: Int, finished: Bool) {
        switch spec.delivery {
        case .append:
            return try await pushAppend(spec, device: device, ns: ns, version: version, ext: ext,
                                        deadline: deadline, now: now)
        case .replaceWindow:
            let sent = try await pushWindows(spec, device: device, ns: ns, version: version, ext: ext)
            return (sent, true)
        case .snapshot:
            return (0, true)
        }
    }

    // MARK: Append streams

    private func pushAppend(_ spec: StreamSpec, device: String, ns: String, version: PushVersion, ext: Bool,
                            deadline: Date, now: @escaping () -> Date) async throws -> (sent: Int, finished: Bool) {
        var cursor = try progress.verifiedCursor(ns: ns, device: device, spec: spec, source: source)
        var sent = 0
        while true {
            if now() >= deadline { return (sent, false) }
            let rows = try source.appendPage(spec, deviceId: device, afterRowId: cursor?.rowId,
                                             limit: PushLimits.maxRecords)
            if rows.isEmpty { return (sent, true) }
            let lines = rows.map { encodeRecordLine(spec, key: $0.key, data: $0.data, ext: ext) }
            let n = countFitting(lines)
            if n == 0 { throw PushError.fatal("a single \(spec.name) record is larger than 4 MiB") }
            let last = rows[n - 1]
            let end = Cursor(rowId: last.rowId, keySha256: fingerprint(of: last, spec: spec, deviceId: device))
            let batch = encodeBatch(version: version, sourceId: progress.sourceId, deviceId: device, spec: spec,
                                    recordLines: Array(lines.prefix(n)), startCursor: cursor, endCursor: end,
                                    window: nil)
            _ = try await transport.post(endpoint, batch: batch, version: version)
            try progress.setCursor(end, ns: ns, device: device, stream: spec.name)
            cursor = end
            sent += n
            if n == rows.count && rows.count < PushLimits.maxRecords { return (sent, true) }
        }
    }

    // MARK: Replace-window streams

    private func dayOf(_ row: SourceRow, _ spec: StreamSpec) -> String? {
        switch spec.selector {
        case .some(.day):
            if case .string(let d)? = row.key["day"] { return d }
            return nil
        case .some(.startTs):
            if case .int(let t)? = row.key["startTs"] { return days.day(forTimestamp: t) }
            return nil
        default:
            return nil
        }
    }

    private func pushWindows(_ spec: StreamSpec, device: String, ns: String, version: PushVersion,
                             ext: Bool) async throws -> Int {
        let all = try source.allRows(spec, deviceId: device)
        var linesByDay: [String: [String]] = [:]
        var ordered: [(day: String, line: String)] = []
        for row in all {
            guard let d = dayOf(row, spec) else { continue }
            let line = encodeRecordLine(spec, key: row.key, data: row.data, ext: ext)
            linesByDay[d, default: []].append(line)
            ordered.append((day: d, line: line))
        }
        var newHash: [String: String] = [:]
        for (d, list) in linesByDay {
            newHash[d] = sha256Hex(Data(list.joined(separator: "\n").utf8))
        }
        let old = try progress.dayHashes(ns: ns, device: device, stream: spec.name)
        let changed = Set(newHash.keys).union(old.keys).filter { newHash[$0] != old[$0] }.sorted()
        if changed.isEmpty { return 0 }

        // Contiguous runs of changed days; a long quiet gap starts a new window.
        var runs: [[String]] = []
        for d in changed {
            if let last = runs.last?.last, days.daysBetween(last, d) <= PushEngine.windowGapDays {
                runs[runs.count - 1].append(d)
            } else {
                runs.append([d])
            }
        }

        var sent = 0
        for run in runs {
            guard let first = run.first, let lastDay = run.last, let after = days.nextDay(lastDay) else { continue }
            let lines = ordered.filter { $0.day >= first && $0.day <= lastDay }.map { $0.line }
            let bounds: (WindowBound, WindowBound)
            if spec.selector == .day {
                bounds = (.day(first), .day(after))
            } else {
                guard let a = days.midnight(of: first), let b = days.midnight(of: after) else { continue }
                bounds = (.int(a), .int(b))
            }
            var chunks: [[String]] = []
            var rest = lines
            while !rest.isEmpty {
                let n = countFitting(rest)
                if n == 0 { throw PushError.fatal("a single \(spec.name) record is larger than 4 MiB") }
                chunks.append(Array(rest.prefix(n)))
                rest = Array(rest.dropFirst(n))
            }
            if chunks.isEmpty { chunks = [[]] }  // an empty authoritative window is still sent
            let boundsText = "\(bounds.0)|\(bounds.1)"
            let identity = ["window", version.rawValue, progress.sourceId, device, spec.name, boundsText,
                            sha256Hex(Data(lines.joined(separator: "\n").utf8))].joined(separator: "\n")
            let replacementId = deterministicUUID(identity)
            for (i, chunk) in chunks.enumerated() {
                let window = WindowSpec(replacementId: replacementId, selector: spec.selector?.rawValue ?? "day",
                                        startInclusive: bounds.0, endExclusive: bounds.1,
                                        part: i + 1, parts: chunks.count)
                let batch = encodeBatch(version: version, sourceId: progress.sourceId, deviceId: device, spec: spec,
                                        recordLines: chunk, startCursor: nil, endCursor: nil, window: window)
                _ = try await transport.post(endpoint, batch: batch, version: version)
                sent += chunk.count
            }
            // Every part was acknowledged: only now do the per-day hashes advance.
            var set: [String: String] = [:]
            var remove: [String] = []
            let candidates = Set(newHash.keys).union(old.keys).filter { $0 >= first && $0 <= lastDay }
            for d in candidates {
                if let h = newHash[d] { set[d] = h } else { remove.append(d) }
            }
            try progress.applyDayHashes(set: set, remove: remove, ns: ns, device: device, stream: spec.name)
        }
        return sent
    }
}
