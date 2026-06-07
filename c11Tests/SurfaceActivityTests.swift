import XCTest

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

/// Pure tests for `SurfaceActivityTracker`. Per `CLAUDE.md`, never run
/// locally — CI only.
final class SurfaceActivityTests: XCTestCase {

    func testRecordActivityIsAsyncButReadable() {
        let tracker = SurfaceActivityTracker()
        let surface = "S1"
        let when = Date(timeIntervalSince1970: 1000)
        tracker.recordActivity(surfaceId: surface, at: when)
        // Force synchronous read — drains the serial queue.
        let read = tracker.lastActivity(for: surface)
        XCTAssertEqual(read?.timeIntervalSince1970, 1000)
    }

    func testInputBurstCoalescedWithDebounce() {
        let tracker = SurfaceActivityTracker()
        let base = Date()
        // First write fires.
        tracker.recordActivity(surfaceId: "S1", at: base)
        // Burst of writes inside the debounce window must NOT advance the
        // timestamp — the leading-edge value is what we want.
        tracker.recordActivity(surfaceId: "S1", at: base.addingTimeInterval(0.05))
        tracker.recordActivity(surfaceId: "S1", at: base.addingTimeInterval(0.10))
        tracker.recordActivity(surfaceId: "S1", at: base.addingTimeInterval(0.20))
        guard let read = tracker.lastActivity(for: "S1") else {
            XCTFail("expected S1 activity to be recorded")
            return
        }
        XCTAssertEqual(read.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 0.001,
                       "burst inside the debounce window must not advance the timestamp")
    }

    func testWritesPastDebounceWindowAdvanceTheTimestamp() {
        let tracker = SurfaceActivityTracker()
        let base = Date()
        tracker.recordActivity(surfaceId: "S1", at: base)
        let later = base.addingTimeInterval(SurfaceActivityTracker.debounceInterval + 0.1)
        tracker.recordActivity(surfaceId: "S1", at: later)
        guard let read = tracker.lastActivity(for: "S1") else {
            XCTFail("expected S1 activity to be recorded")
            return
        }
        XCTAssertEqual(read.timeIntervalSince1970, later.timeIntervalSince1970, accuracy: 0.001)
    }

    func testEmptyOrWhitespaceSurfaceIdIgnored() {
        let tracker = SurfaceActivityTracker()
        tracker.recordActivity(surfaceId: "", at: Date())
        tracker.recordActivity(surfaceId: "   ", at: Date())
        XCTAssertNil(tracker.lastActivity(for: ""))
        XCTAssertNil(tracker.lastActivity(for: "   "))
    }

    func testSeedAndSnapshotRoundTrip() {
        let tracker = SurfaceActivityTracker()
        let now = Date()
        tracker.seed(from: ["S1": now, "S2": now.addingTimeInterval(-60)])
        let snap = tracker.snapshot()
        guard let s1 = snap["S1"], let s2 = snap["S2"] else {
            XCTFail("expected seeded activity for S1 and S2")
            return
        }
        XCTAssertEqual(s1.timeIntervalSince1970,
                       now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(s2.timeIntervalSince1970,
                       now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snap.count, 2)
    }

    func testClearWipesSurfaceOnly() {
        let tracker = SurfaceActivityTracker()
        let now = Date()
        tracker.recordActivity(surfaceId: "S1", at: now)
        tracker.recordActivity(surfaceId: "S2", at: now)
        tracker.clear(surfaceId: "S1")
        XCTAssertNil(tracker.lastActivity(for: "S1"))
        XCTAssertNotNil(tracker.lastActivity(for: "S2"))
    }
}
