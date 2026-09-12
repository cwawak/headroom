import XCTest
@testable import Headroom

final class CalibrationTests: XCTestCase {

    func testFoldFirstObservationShortWindow() {
        var cal = Calibration(shortCapacity: 22_000_000, longCapacity: 140_000_000, shortObservations: 0, longObservations: 0)
        cal.fold(30_000_000, into: .short)
        XCTAssertEqual(cal.shortCapacity, 30_000_000, accuracy: 0.0001)
        XCTAssertEqual(cal.shortObservations, 1)
        // long window unaffected
        XCTAssertEqual(cal.longCapacity, 140_000_000, accuracy: 0.0001)
        XCTAssertEqual(cal.longObservations, 0)
    }

    func testFoldFirstObservationLongWindow() {
        var cal = Calibration(shortCapacity: 22_000_000, longCapacity: 140_000_000, shortObservations: 0, longObservations: 0)
        cal.fold(150_000_000, into: .long)
        XCTAssertEqual(cal.longCapacity, 150_000_000, accuracy: 0.0001)
        XCTAssertEqual(cal.longObservations, 1)
        // short window unaffected
        XCTAssertEqual(cal.shortCapacity, 22_000_000, accuracy: 0.0001)
        XCTAssertEqual(cal.shortObservations, 0)
    }

    func testFoldSubsequentObservationsEWMA() {
        var cal = Calibration(shortCapacity: 100.0, longCapacity: 1000.0, shortObservations: 1, longObservations: 1)
        cal.fold(200.0, into: .short)
        // EWMA: 100.0 * 0.7 + 200.0 * 0.3 = 70.0 + 60.0 = 130.0
        XCTAssertEqual(cal.shortCapacity, 130.0, accuracy: 0.0001)
        XCTAssertEqual(cal.shortObservations, 2)

        cal.fold(500.0, into: .long)
        // EWMA: 1000.0 * 0.7 + 500.0 * 0.3 = 700.0 + 150.0 = 850.0
        XCTAssertEqual(cal.longCapacity, 850.0, accuracy: 0.0001)
        XCTAssertEqual(cal.longObservations, 2)
    }

    func testFoldNonPositiveObservedIgnored() {
        var cal = Calibration(shortCapacity: 100.0, longCapacity: 1000.0, shortObservations: 1, longObservations: 1)

        cal.fold(0.0, into: .short)
        XCTAssertEqual(cal.shortCapacity, 100.0, accuracy: 0.0001)
        XCTAssertEqual(cal.shortObservations, 1)

        cal.fold(-50.0, into: .short)
        XCTAssertEqual(cal.shortCapacity, 100.0, accuracy: 0.0001)
        XCTAssertEqual(cal.shortObservations, 1)

        cal.fold(0.0, into: .long)
        XCTAssertEqual(cal.longCapacity, 1000.0, accuracy: 0.0001)
        XCTAssertEqual(cal.longObservations, 1)

        cal.fold(-100.0, into: .long)
        XCTAssertEqual(cal.longCapacity, 1000.0, accuracy: 0.0001)
        XCTAssertEqual(cal.longObservations, 1)
    }

    func testFoldMultipleSequentialFolds() {
        var cal = Calibration(shortCapacity: 0.0, longCapacity: 0.0, shortObservations: 0, longObservations: 0)

        // Fold 1: First observation sets capacity directly
        cal.fold(100.0, into: .short)
        XCTAssertEqual(cal.shortCapacity, 100.0, accuracy: 0.0001)
        XCTAssertEqual(cal.shortObservations, 1)

        // Fold 2: 100 * 0.7 + 200 * 0.3 = 70 + 60 = 130
        cal.fold(200.0, into: .short)
        XCTAssertEqual(cal.shortCapacity, 130.0, accuracy: 0.0001)
        XCTAssertEqual(cal.shortObservations, 2)

        // Fold 3: 130 * 0.7 + 50 * 0.3 = 91 + 15 = 106
        cal.fold(50.0, into: .short)
        XCTAssertEqual(cal.shortCapacity, 106.0, accuracy: 0.0001)
        XCTAssertEqual(cal.shortObservations, 3)
    }

    func testFoldWindowIsolation() {
        var cal = Calibration(shortCapacity: 10.0, longCapacity: 100.0, shortObservations: 1, longObservations: 1)

        cal.fold(50.0, into: .short)

        XCTAssertEqual(cal.shortCapacity, 10.0 * 0.7 + 50.0 * 0.3, accuracy: 0.0001)
        XCTAssertEqual(cal.shortObservations, 2)

        // Ensure long window was completely untouched
        XCTAssertEqual(cal.longCapacity, 100.0, accuracy: 0.0001)
        XCTAssertEqual(cal.longObservations, 1)
    }
}
