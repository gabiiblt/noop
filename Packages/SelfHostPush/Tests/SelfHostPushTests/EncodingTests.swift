import XCTest
@testable import SelfHostPush

/// Oracle values below were computed independently in Python (hashlib), not by this package.
final class EncodingTests: XCTestCase {
    private let source = "3a3486dd-5030-4e17-a00d-a781399890f9"

    private func hrSpec() -> StreamSpec { return PushRegistry.spec(named: "hrSample")! }

    private func hrLines() -> [String] {
        let spec = hrSpec()
        return [
            encodeRecordLine(spec, key: ["ts": .int(1723939201)], data: ["bpm": .int(61)], ext: false),
            encodeRecordLine(spec, key: ["ts": .int(1723939202)], data: ["bpm": .int(62)], ext: false),
        ]
    }

    func testSha256KnownVectors() {
        XCTAssertEqual(sha256Hex(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testFingerprintMatchesIndependentVector() {
        XCTAssertEqual(keyFingerprint(stream: "hrSample", deviceId: "strap-local-id", keyJSON: "{\"ts\":1723939201}"),
                       "3684ed7b91292cb95768aa624dead1d844419b1eff0e7fcaca24a39dfbed274d")
        let rrSpec = PushRegistry.spec(named: "rrInterval")!
        let keyJSON = compactKey(rrSpec, ["seq": .int(1), "ts": .int(5), "rrMs": .int(800)])
        XCTAssertEqual(keyJSON, "{\"ts\":5,\"rrMs\":800,\"seq\":1}")  // registry order, not input order
        XCTAssertEqual(keyFingerprint(stream: "rrInterval", deviceId: "strap-local-id", keyJSON: keyJSON),
                       "94c9c1106e01cad3feac5f90f35d9ba53aac51b1a4a8c344f131129f59eea469")
    }

    func testHrExampleMatchesGoldenBytes() {
        let end = Cursor(rowId: 48119,
                         keySha256: "bdf66970fe6a0d9edbb58a19a3e6b514a707ff081cddd9f570e343aa241eb167")
        let b = encodeBatch(version: .v1, sourceId: source, deviceId: "strap-local-id", spec: hrSpec(),
                            recordLines: hrLines(), startCursor: nil, endCursor: end, window: nil)
        let expectedLines: [String] = [
            "{\"type\":\"batch\",\"protocolVersion\":\"1.0\",\"batchId\":\"5219c97d-40c1-5aba-a24f-a98b8d3da375\",\"sourceId\":\"3a3486dd-5030-4e17-a00d-a781399890f9\",\"deviceId\":\"strap-local-id\",\"stream\":\"hrSample\",\"delivery\":\"append\",\"recordCount\":2,\"startCursor\":null,\"endCursor\":{\"rowId\":48119,\"keySha256\":\"bdf66970fe6a0d9edbb58a19a3e6b514a707ff081cddd9f570e343aa241eb167\"}}",
            "{\"type\":\"record\",\"key\":{\"ts\":1723939201},\"data\":{\"bpm\":61}}",
            "{\"type\":\"record\",\"key\":{\"ts\":1723939202},\"data\":{\"bpm\":62}}",
        ]
        let expected = expectedLines.joined(separator: "\n") + "\n"
        XCTAssertEqual(String(decoding: b.body, as: UTF8.self), expected)
        XCTAssertEqual(b.batchId, "5219c97d-40c1-5aba-a24f-a98b8d3da375")
        XCTAssertEqual(b.recordCount, 2)
        XCTAssertEqual(b.endCursor, end)
    }

    func testBatchIdIsDeterministicAndContentSensitive() {
        let end = Cursor(rowId: 1, keySha256: String(repeating: "a", count: 64))
        let a = encodeBatch(version: .v1, sourceId: source, deviceId: "d", spec: hrSpec(),
                            recordLines: hrLines(), startCursor: nil, endCursor: end, window: nil)
        let again = encodeBatch(version: .v1, sourceId: source, deviceId: "d", spec: hrSpec(),
                                recordLines: hrLines(), startCursor: nil, endCursor: end, window: nil)
        let fewer = encodeBatch(version: .v1, sourceId: source, deviceId: "d", spec: hrSpec(),
                                recordLines: [hrLines()[0]], startCursor: nil, endCursor: end, window: nil)
        let otherSource = encodeBatch(version: .v1, sourceId: "11111111-1111-4111-8111-111111111111",
                                      deviceId: "d", spec: hrSpec(), recordLines: hrLines(),
                                      startCursor: nil, endCursor: end, window: nil)
        XCTAssertEqual(a, again)
        XCTAssertNotEqual(a.batchId, fewer.batchId)
        XCTAssertNotEqual(a.batchId, otherSource.batchId)
        XCTAssertEqual(a.batchId, a.batchId.lowercased())
        XCTAssertEqual(a.batchId.count, 36)
    }

    func testWindowHeaderEncoding() {
        let spec = PushRegistry.spec(named: "dailyMetric")!
        let line = encodeRecordLine(spec, key: ["day": .string("2026-08-06")],
                                    data: ["efficiency": .double(0.9)], ext: false)
        let expectedRecord = "{\"type\":\"record\",\"key\":{\"day\":\"2026-08-06\"},\"data\":{\"totalSleepMin\":null,\"efficiency\":0.9,\"deepMin\":null,\"remMin\":null,\"lightMin\":null,\"disturbances\":null,\"restingHr\":null,\"avgHrv\":null,\"recovery\":null,\"strain\":null,\"exerciseCount\":null,\"spo2Pct\":null,\"skinTempDevC\":null,\"respRateBpm\":null,\"steps\":null,\"activeKcalEst\":null,\"spo2Red\":null,\"spo2Ir\":null}}"
        XCTAssertEqual(line, expectedRecord)
        let w = WindowSpec(replacementId: "bf8b735e-f157-4a35-beb2-9b086d10d5bd", selector: "day",
                           startInclusive: .day("2026-08-05"), endExclusive: .day("2026-08-19"), part: 1, parts: 1)
        let b = encodeBatch(version: .v1, sourceId: source, deviceId: "dev", spec: spec, recordLines: [line],
                            startCursor: nil, endCursor: nil, window: w)
        let header = String(decoding: b.body, as: UTF8.self).split(separator: "\n").first.map(String.init)!
        let expectedTail = ",\"startCursor\":null,\"endCursor\":null,\"window\":{\"replacementId\":\"bf8b735e-f157-4a35-beb2-9b086d10d5bd\",\"selector\":\"day\",\"startInclusive\":\"2026-08-05\",\"endExclusive\":\"2026-08-19\",\"part\":1,\"parts\":1}}"
        XCTAssertTrue(header.hasSuffix(expectedTail))
        XCTAssertTrue(header.contains("\"delivery\":\"replace_window\""))
    }

    func testSnapshotWindowOmitsBounds() {
        let w = WindowSpec(replacementId: "r", selector: "all", startInclusive: nil, endExclusive: nil,
                           part: 2, parts: 3)
        XCTAssertEqual(w.compact, "{\"replacementId\":\"r\",\"selector\":\"all\",\"part\":2,\"parts\":3}")
    }

    func testExtMembersOnlyWhenExtVersion() {
        let spec = PushRegistry.spec(named: "dailyMetric")!
        let v1 = encodeRecordLine(spec, key: ["day": .string("d")], data: ["avgSdnn": .double(5)], ext: false)
        let ext = encodeRecordLine(spec, key: ["day": .string("d")], data: ["avgSdnn": .double(5)], ext: true)
        XCTAssertFalse(v1.contains("avgSdnn"))
        XCTAssertTrue(ext.contains("\"avgSdnn\":5.0"))
        XCTAssertTrue(ext.hasSuffix("\"avgSdnn\":5.0,\"skinTempC\":null,\"sleepHrOnly\":null}}"))
    }

    func testNullBoolIntAndDoubleEncoding() {
        XCTAssertEqual(JSONValue.null.compact, "null")
        XCTAssertEqual(JSONValue.bool(true).compact, "true")
        XCTAssertEqual(JSONValue.bool(false).compact, "false")
        XCTAssertEqual(JSONValue.int(-7).compact, "-7")
        XCTAssertEqual(JSONValue.double(61.5).compact, "61.5")
        XCTAssertEqual(JSONValue.double(.nan).compact, "null")
        XCTAssertEqual(JSONValue.double(.infinity).compact, "null")
    }

    func testJSONStringEscaping() {
        XCTAssertEqual(JSONValue.string("a\"b\\c").compact, "\"a\\\"b\\\\c\"")
        XCTAssertEqual(JSONValue.string("l1\nl2\t\r").compact, "\"l1\\nl2\\t\\r\"")
        XCTAssertEqual(JSONValue.string("\u{01}").compact, "\"\\u0001\"")
        XCTAssertEqual(JSONValue.string("a/b é 😀").compact, "\"a/b é 😀\"")  // `/` and non-ASCII pass through
    }

    func testCountFittingStopsAt5000Records() {
        let lines = Array(repeating: "{\"x\":1}", count: 6000)
        XCTAssertEqual(countFitting(lines), 5000)
        XCTAssertEqual(countFitting([]), 0)
    }

    func testCountFittingStopsBefore4MiB() {
        let big = String(repeating: "a", count: 1_000_000)
        let n = countFitting([big, big, big, big, big])
        XCTAssertEqual(n, 4)  // 4 * (1_000_000 + 1) + 4096 reserve < 4 MiB; a 5th would exceed it
        XCTAssertEqual(countFitting([String(repeating: "a", count: PushLimits.maxDecodedBytes)]), 0)
    }

    func testBodyIsLFTerminatedWithoutBOMOrBlankLines() {
        let b = encodeBatch(version: .v1, sourceId: source, deviceId: "d", spec: hrSpec(), recordLines: hrLines(),
                            startCursor: nil, endCursor: Cursor(rowId: 1, keySha256: String(repeating: "b", count: 64)),
                            window: nil)
        XCTAssertEqual(b.body.last, 0x0a)
        XCTAssertNotEqual(Array(b.body.prefix(3)), [0xEF, 0xBB, 0xBF])
        let text = String(decoding: b.body, as: UTF8.self)
        XCTAssertFalse(text.contains("\n\n"))
        XCTAssertEqual(text.split(separator: "\n").count, 3)
    }
}
