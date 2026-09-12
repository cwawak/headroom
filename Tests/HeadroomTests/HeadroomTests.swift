import XCTest
import AppKit
@testable import Headroom

final class HeadroomTests: XCTestCase {
    func testSanity() {
        XCTAssertTrue(true)
    }

    func testProbeFormattedReadingAuthoritativeWithoutReset() {
        let reading = Reading.authoritative(percent: 85.0, resetsAt: nil)
        let formatted = Probe.formattedReading(for: .short, reading: reading)
        XCTAssertEqual(formatted, "  5H   85%  exact")
    }

    func testProbeFormattedReadingAuthoritativeWithReset() {
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        let reading = Reading.authoritative(percent: 50.0, resetsAt: reset)
        let formatted = Probe.formattedReading(for: .short, reading: reading, relativeTo: now)
        XCTAssertTrue(formatted.hasPrefix("  5H   50%  exact  resets "))
    }

    func testProbeFormattedReadingEstimated() {
        let reading = Reading.estimated(percent: 42.0, confidence: 0.95, resetsAt: nil)
        let formatted = Probe.formattedReading(for: .long, reading: reading)
        XCTAssertEqual(formatted, "  WK   42%  est (conf 0.95)")
    }

    func testProbeFormattedReadingUnavailable() {
        let reading = Reading.unavailable(reason: "no logs found")
        let formatted = Probe.formattedReading(for: .short, reading: reading)
        XCTAssertEqual(formatted, "  5H    —   no logs found")
    }

    func testToneForUsageUnder60PercentReturnsNormalGreenTone() {
        let testPercentages = [0.0, 59.0, 59.9]
        for pct in testPercentages {
            let tone = Tone.forUsage(pct)

            let darkColor = tone.dark.usingColorSpace(.sRGB) ?? tone.dark
            let lightColor = tone.light.usingColorSpace(.sRGB) ?? tone.light

            XCTAssertEqual(darkColor.redComponent, 0.07, accuracy: 0.001, "Failed dark red for \(pct)%")
            XCTAssertEqual(darkColor.greenComponent, 0.66, accuracy: 0.001, "Failed dark green for \(pct)%")
            XCTAssertEqual(darkColor.blueComponent, 0.41, accuracy: 0.001, "Failed dark blue for \(pct)%")
            XCTAssertEqual(darkColor.alphaComponent, 1.0, accuracy: 0.001, "Failed dark alpha for \(pct)%")

            XCTAssertEqual(lightColor.redComponent, 0.29, accuracy: 0.001, "Failed light red for \(pct)%")
            XCTAssertEqual(lightColor.greenComponent, 0.89, accuracy: 0.001, "Failed light green for \(pct)%")
            XCTAssertEqual(lightColor.blueComponent, 0.61, accuracy: 0.001, "Failed light blue for \(pct)%")
            XCTAssertEqual(lightColor.alphaComponent, 1.0, accuracy: 0.001, "Failed light alpha for \(pct)%")
        }
    }

    func testToneForUsage60To85PercentReturnsWarningYellowTone() {
        let testPercentages = [60.0, 84.0, 84.9]
        for pct in testPercentages {
            let tone = Tone.forUsage(pct)

            let darkColor = tone.dark.usingColorSpace(.sRGB) ?? tone.dark
            let lightColor = tone.light.usingColorSpace(.sRGB) ?? tone.light

            XCTAssertEqual(darkColor.redComponent, 0.82, accuracy: 0.001, "Failed dark red for \(pct)%")
            XCTAssertEqual(darkColor.greenComponent, 0.54, accuracy: 0.001, "Failed dark green for \(pct)%")
            XCTAssertEqual(darkColor.blueComponent, 0.09, accuracy: 0.001, "Failed dark blue for \(pct)%")
            XCTAssertEqual(darkColor.alphaComponent, 1.0, accuracy: 0.001, "Failed dark alpha for \(pct)%")

            XCTAssertEqual(lightColor.redComponent, 1.00, accuracy: 0.001, "Failed light red for \(pct)%")
            XCTAssertEqual(lightColor.greenComponent, 0.83, accuracy: 0.001, "Failed light green for \(pct)%")
            XCTAssertEqual(lightColor.blueComponent, 0.48, accuracy: 0.001, "Failed light blue for \(pct)%")
            XCTAssertEqual(lightColor.alphaComponent, 1.0, accuracy: 0.001, "Failed light alpha for \(pct)%")
        }
    }

    func testToneForUsage85PercentAndAboveReturnsCriticalRedTone() {
        let testPercentages = [85.0, 85.1, 100.0, 150.0]
        for pct in testPercentages {
            let tone = Tone.forUsage(pct)

            let darkColor = tone.dark.usingColorSpace(.sRGB) ?? tone.dark
            let lightColor = tone.light.usingColorSpace(.sRGB) ?? tone.light

            XCTAssertEqual(darkColor.redComponent, 0.85, accuracy: 0.001, "Failed dark red for \(pct)%")
            XCTAssertEqual(darkColor.greenComponent, 0.22, accuracy: 0.001, "Failed dark green for \(pct)%")
            XCTAssertEqual(darkColor.blueComponent, 0.17, accuracy: 0.001, "Failed dark blue for \(pct)%")
            XCTAssertEqual(darkColor.alphaComponent, 1.0, accuracy: 0.001, "Failed dark alpha for \(pct)%")

            XCTAssertEqual(lightColor.redComponent, 1.00, accuracy: 0.001, "Failed light red for \(pct)%")
            XCTAssertEqual(lightColor.greenComponent, 0.58, accuracy: 0.001, "Failed light green for \(pct)%")
            XCTAssertEqual(lightColor.blueComponent, 0.52, accuracy: 0.001, "Failed light blue for \(pct)%")
            XCTAssertEqual(lightColor.alphaComponent, 1.0, accuracy: 0.001, "Failed light alpha for \(pct)%")
        }
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
