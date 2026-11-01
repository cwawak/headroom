import XCTest
@testable import Headroom

final class FileWatcherTests: XCTestCase {

    func testFileWatcherDebouncingCoalescesBursts() {
        let queue = DispatchQueue(label: "com.headroom.test.fsevents")
        let expectation = expectation(description: "Debounced callback fires once for burst")

        var fireCount = 0
        let watcher = FileWatcher(
            roots: [],
            latency: 0.05,
            debounceInterval: 0.1,
            maxDeferralInterval: 1.0,
            queue: queue
        ) {
            fireCount += 1
            expectation.fulfill()
        }
        defer { watcher.stop() }

        // Simulate a rapid burst of 50 incoming FSEvents calls
        queue.async {
            let start = Date()
            for i in 0..<50 {
                let simulatedTime = start.addingTimeInterval(Double(i) * 0.001)
                watcher.handleEvent(now: simulatedTime)
            }
        }

        waitForExpectations(timeout: 2.0)
        queue.sync {
            XCTAssertEqual(fireCount, 1, "A rapid burst of events should be coalesced into a single trigger")
        }
    }

    func testFileWatcherMaxDeferralForcesFireDuringSustainedEvents() {
        let queue = DispatchQueue(label: "com.headroom.test.sustained")
        var fireCount = 0
        let watcher = FileWatcher(
            roots: [],
            latency: 0.05,
            debounceInterval: 0.05,
            maxDeferralInterval: 0.15,
            queue: queue
        ) {
            fireCount += 1
        }
        defer { watcher.stop() }

        // Simulate events every 20ms without letting the queue idle. Each burst
        // must fire after the 150ms deferral limit, despite a 50ms debounce.
        queue.sync {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            for index in 0..<8 {
                watcher.handleEvent(now: start.addingTimeInterval(Double(index) * 0.02))
            }
            XCTAssertEqual(fireCount, 0)

            watcher.handleEvent(now: start.addingTimeInterval(0.16))
            XCTAssertEqual(fireCount, 1, "The first burst must fire before events stop")

            for index in 9..<17 {
                watcher.handleEvent(now: start.addingTimeInterval(Double(index) * 0.02))
            }
            XCTAssertEqual(fireCount, 1)

            watcher.handleEvent(now: start.addingTimeInterval(0.34))
            XCTAssertEqual(fireCount, 2, "The deferral limit must apply again after firing")
        }
    }

    func testFileWatcherStopCancelsPendingDebounce() {
        let queue = DispatchQueue(label: "com.headroom.test.stop")
        let expectation = expectation(description: "No fire after stop")
        expectation.isInverted = true

        let watcher = FileWatcher(
            roots: [],
            latency: 0.05,
            debounceInterval: 0.15,
            maxDeferralInterval: 1.0,
            queue: queue
        ) {
            expectation.fulfill()
        }
        defer { watcher.stop() }

        queue.sync {
            watcher.handleEvent()
        }

        // Stop only after the event has scheduled its pending debounce.
        watcher.stop()

        waitForExpectations(timeout: 0.4)
    }
}
