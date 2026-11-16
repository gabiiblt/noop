import XCTest
@testable import SelfHostPush

/// Fixtures/registry.json is generated from selfhost/src/noop_selfhost/registry.py
/// (`python -m noop_selfhost.registry`) and checked there by test_registry_fixture.py. This test is the
/// Swift half: a drift on either side fails one of the two suites.
final class RegistryParityTests: XCTestCase {
    private func fixture() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "registry", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(obj as? [String: Any])
        return try XCTUnwrap(root["streams"] as? [[String: Any]])
    }

    private func cols(_ value: Any?) -> [Column] {
        let arr = (value as? [[String: Any]]) ?? []
        return arr.map { d in
            Column(name: d["name"] as! String, kind: ColumnKind(rawValue: d["type"] as! String)!,
                   nullable: d["nullable"] as! Bool)
        }
    }

    func testSwiftRegistryEqualsPythonFixtureStreamByStream() throws {
        let fx = try fixture()
        XCTAssertEqual(fx.count, PushRegistry.all.count)
        for (i, f) in fx.enumerated() {
            let s = PushRegistry.all[i]
            XCTAssertEqual(s.name, f["name"] as? String, "stream #\(i)")
            XCTAssertEqual(s.phase.rawValue, f["phase"] as? String, s.name)
            XCTAssertEqual(s.delivery.rawValue, f["delivery"] as? String, s.name)
            XCTAssertEqual(s.selector?.rawValue, f["selector"] as? String, s.name)
            XCTAssertEqual(s.key, cols(f["key"]), s.name)
            XCTAssertEqual(s.data, cols(f["data"]), s.name)
            XCTAssertEqual(s.extData, cols(f["extData"]), s.name)
        }
    }

    func testV1HasExactlyTwelveStreamsAndNoForbiddenOnes() {
        XCTAssertEqual(PushRegistry.v1.count, 12)
        let names = Set(PushRegistry.all.map { $0.name })
        for bad in ["coachMessage", "device", "cursors", "rawBatch", "rawImuSample"] {
            XCTAssertFalse(names.contains(bad), bad)
        }
        XCTAssertEqual(PushRegistry.spec(named: "rrInterval")?.key.map { $0.name }, ["ts", "rrMs", "seq"])
        XCTAssertEqual(PushRegistry.spec(named: "sleepSession")?.selector, .startTs)
    }
}
