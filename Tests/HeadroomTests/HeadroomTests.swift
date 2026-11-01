import XCTest
import AppKit
@testable import Headroom

final class HeadroomTests: XCTestCase {
    func testSanity() {
        XCTAssertTrue(true)
    }

    func testCalibrateShortWindow() {
        var calibration = Calibration(shortCapacity: 22_000_000, longCapacity: 140_000_000, shortObservations: 0, longObservations: 0)
        calibration.calibrate(observedUsedPercent: 50.0, weightedSum: 10_000_000, for: .short)

        XCTAssertEqual(calibration.shortCapacity, 20_000_000, accuracy: 0.001)
        XCTAssertEqual(calibration.shortObservations, 2)
        XCTAssertEqual(calibration.longCapacity, 140_000_000)
        XCTAssertEqual(calibration.longObservations, 0)
    }

    func testCalibrateLongWindow() {
        var calibration = Calibration(shortCapacity: 22_000_000, longCapacity: 140_000_000, shortObservations: 0, longObservations: 0)
        calibration.calibrate(observedUsedPercent: 25.0, weightedSum: 30_000_000, for: .long)

        XCTAssertEqual(calibration.longCapacity, 120_000_000, accuracy: 0.001)
        XCTAssertEqual(calibration.longObservations, 2)
        XCTAssertEqual(calibration.shortCapacity, 22_000_000)
        XCTAssertEqual(calibration.shortObservations, 0)
    }

    func testCalibrateGuardConditionsNonPositiveInputs() {
        var calibration = Calibration(shortCapacity: 22_000_000, longCapacity: 140_000_000, shortObservations: 0, longObservations: 0)

        calibration.calibrate(observedUsedPercent: 0, weightedSum: 10_000_000, for: .short)
        XCTAssertEqual(calibration.shortCapacity, 22_000_000)
        XCTAssertEqual(calibration.shortObservations, 0)

        calibration.calibrate(observedUsedPercent: -10, weightedSum: 10_000_000, for: .short)
        XCTAssertEqual(calibration.shortCapacity, 22_000_000)
        XCTAssertEqual(calibration.shortObservations, 0)

        calibration.calibrate(observedUsedPercent: 50.0, weightedSum: 0, for: .short)
        XCTAssertEqual(calibration.shortCapacity, 22_000_000)
        XCTAssertEqual(calibration.shortObservations, 0)

        calibration.calibrate(observedUsedPercent: 50.0, weightedSum: -500, for: .short)
        XCTAssertEqual(calibration.shortCapacity, 22_000_000)
        XCTAssertEqual(calibration.shortObservations, 0)
    }

    func testCalibratePreservesHigherObservationCount() {
        var calibration = Calibration(shortCapacity: 22_000_000, longCapacity: 140_000_000, shortObservations: 5, longObservations: 4)

        calibration.calibrate(observedUsedPercent: 50.0, weightedSum: 15_000_000, for: .short)
        XCTAssertEqual(calibration.shortCapacity, 30_000_000, accuracy: 0.001)
        XCTAssertEqual(calibration.shortObservations, 5)

        calibration.calibrate(observedUsedPercent: 50.0, weightedSum: 50_000_000, for: .long)
        XCTAssertEqual(calibration.longCapacity, 100_000_000, accuracy: 0.001)
        XCTAssertEqual(calibration.longObservations, 4)
    }
}
