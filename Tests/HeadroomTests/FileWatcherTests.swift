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

        // Simulate a rapid burst of 50 incoming FSEvents calls
        queue.async {
            let start = Date()
            for i in 0..<50 {
                let simulatedTime = start.addingTimeInterval(Double(i) * 0.001)
                watcher.handleEvent(now: simulatedTime)
            }
        }

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(fireCount, 1, "A rapid burst of events should be coalesced into a single trigger")
    }

    func testFileWatcherMaxDeferralForcesFireDuringSustainedEvents() {
        let queue = DispatchQueue(label: "com.headroom.test.sustained")
        let expectation = expectation(description: "Watcher triggers during sustained event flow")
        expectation.expectedFulfillmentCount = 2

        var fireCount = 0
        let watcher = FileWatcher(
            roots: [],
            latency: 0.05,
            debounceInterval: 0.05,
            maxDeferralInterval: 0.15,
            queue: queue
        ) {
            fireCount += 1
            expectation.fulfill()
        }

        // Continuously pump events every 20ms over a 250ms window.
        // With debounceInterval 50ms, events never idle for 50ms, but maxDeferralInterval is 150ms.
        // Therefore, it must force-fire before the burst finishes.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        var count = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler {
            count += 1
            watcher.handleEvent()
            if count >= 15 {
                timer.cancel()
            }
        }
        timer.resume()

        waitForExpectations(timeout: 2.0)
        XCTAssertGreaterThanOrEqual(fireCount, 2, "Continuous stream should force-fire due to maxDeferralInterval")
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

        queue.async {
            watcher.handleEvent()
        }

        // Stop the watcher almost immediately while debounce is scheduled
        usleep(20_000) // 20ms
        watcher.stop()

        waitForExpectations(timeout: 0.4)
    }
}
