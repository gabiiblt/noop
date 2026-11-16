import XCTest
@testable import Strand

/// The self-hosted push is default-off and endpoint-gated (docs/SCOPE.md "Experimental exception"):
/// with nothing configured it must never run, so there is no network egress and no behaviour change.
final class PushGateTests: XCTestCase {

    func testNeverRunsWhenDisabled() {
        XCTAssertFalse(PushSettings.shouldRun(enabled: false, endpoint: "https://server.ts.net/push", token: "secret"))
    }

    func testNeverRunsWithEmptyOrBlankEndpoint() {
        XCTAssertFalse(PushSettings.shouldRun(enabled: true, endpoint: "", token: "secret"))
        XCTAssertFalse(PushSettings.shouldRun(enabled: true, endpoint: "   ", token: "secret"))
    }

    func testRejectsHttpAndHostlessEndpoints() {
        for bad in ["http://server.ts.net/push", "https://", "ftp://x.y/z", "server.ts.net/push", "not a url"] {
            XCTAssertFalse(PushSettings.isValidEndpoint(bad), bad)
            XCTAssertFalse(PushSettings.shouldRun(enabled: true, endpoint: bad, token: "secret"), bad)
        }
        XCTAssertTrue(PushSettings.isValidEndpoint("https://server.tailfb9ed9.ts.net/push"))
        XCTAssertTrue(PushSettings.isValidEndpoint("  HTTPS://server.tailfb9ed9.ts.net/push  "))
    }

    func testNeverRunsWithoutAToken() {
        XCTAssertFalse(PushSettings.shouldRun(enabled: true, endpoint: "https://server.ts.net/push", token: nil))
        XCTAssertFalse(PushSettings.shouldRun(enabled: true, endpoint: "https://server.ts.net/push", token: ""))
        XCTAssertFalse(PushSettings.shouldRun(enabled: true, endpoint: "https://server.ts.net/push", token: " \n"))
    }

    func testRunsOnlyWhenEnabledWithValidEndpointAndToken() {
        XCTAssertTrue(PushSettings.shouldRun(enabled: true, endpoint: "https://server.ts.net/push", token: "secret"))
    }

    func testTaskIdentifierDerivesFromTheBundleIdLikeEveryOtherScheduler() {
        XCTAssertEqual(PushSettings.taskIdentifier(bundleID: "com.noopapp.noop"), "com.noopapp.noop.push")
        XCTAssertEqual(PushSettings.taskIdentifier(bundleID: "com.mine.noop"), "com.mine.noop.push")
        XCTAssertEqual(PushSettings.taskIdentifier(bundleID: nil), "com.noopapp.noop.push")
    }

    func testScheduleOnlyWhileTheGateIsOpenAndNeverSoonerThanFifteenMinutes() {
        XCTAssertTrue(PushSchedulePolicy.shouldSchedule(gateOpen: true))
        XCTAssertFalse(PushSchedulePolicy.shouldSchedule(gateOpen: false))
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(PushSchedulePolicy.earliestBeginDate(after: now), now.addingTimeInterval(15 * 60))
    }

    func testAutomaticTriggersAreThrottledButManualIsNot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(PushThrottle.shouldStart(manual: false, lastStartedAt: nil, now: now))
        XCTAssertFalse(PushThrottle.shouldStart(manual: false, lastStartedAt: now.addingTimeInterval(-30), now: now))
        XCTAssertTrue(PushThrottle.shouldStart(manual: false, lastStartedAt: now.addingTimeInterval(-121), now: now))
        XCTAssertTrue(PushThrottle.shouldStart(manual: true, lastStartedAt: now.addingTimeInterval(-1), now: now))
    }

    func testTokenIsNeverStoredInUserDefaults() throws {
        guard PushSettings.setToken("super-secret-token-value") else {
            throw XCTSkip("Keychain is unavailable in this test host")
        }
        defer { PushSettings.clearToken() }
        for (_, value) in UserDefaults.standard.dictionaryRepresentation() {
            XCTAssertFalse("\(value)".contains("super-secret-token-value"))
        }
        XCTAssertEqual(PushSettings.token(), "super-secret-token-value")
        PushSettings.clearToken()
        XCTAssertNil(PushSettings.token())
    }
}
