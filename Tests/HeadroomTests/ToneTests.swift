import XCTest
import AppKit
@testable import Headroom

final class ToneTests: XCTestCase {

    // Helper assertions for color component accuracy
    private func assertToneColors(_ tone: Tone, expectedDark: (Double, Double, Double), expectedLight: (Double, Double, Double), file: StaticString = #file, line: UInt = #line) {
        let darkColor = tone.dark.usingColorSpace(.sRGB) ?? tone.dark
        let lightColor = tone.light.usingColorSpace(.sRGB) ?? tone.light

        XCTAssertEqual(darkColor.redComponent, expectedDark.0, accuracy: 0.001, "Dark red mismatch", file: file, line: line)
        XCTAssertEqual(darkColor.greenComponent, expectedDark.1, accuracy: 0.001, "Dark green mismatch", file: file, line: line)
        XCTAssertEqual(darkColor.blueComponent, expectedDark.2, accuracy: 0.001, "Dark blue mismatch", file: file, line: line)
        XCTAssertEqual(darkColor.alphaComponent, 1.0, accuracy: 0.001, "Dark alpha mismatch", file: file, line: line)

        XCTAssertEqual(lightColor.redComponent, expectedLight.0, accuracy: 0.001, "Light red mismatch", file: file, line: line)
        XCTAssertEqual(lightColor.greenComponent, expectedLight.1, accuracy: 0.001, "Light green mismatch", file: file, line: line)
        XCTAssertEqual(lightColor.blueComponent, expectedLight.2, accuracy: 0.001, "Light blue mismatch", file: file, line: line)
        XCTAssertEqual(lightColor.alphaComponent, 1.0, accuracy: 0.001, "Light alpha mismatch", file: file, line: line)
    }

    private let greenDark = (0.07, 0.66, 0.41)
    private let greenLight = (0.29, 0.89, 0.61)

    private let yellowDark = (0.82, 0.54, 0.09)
    private let yellowLight = (1.00, 0.83, 0.48)

    private let redDark = (0.85, 0.22, 0.17)
    private let redLight = (1.00, 0.58, 0.52)

    // MARK: - Lower Tier (< 60%)

    func testForUsageUnder60PercentReturnsGreenTone() {
        let values = [-100.0, -1.0, 0.0, 30.0, 59.0, 59.9, 59.999]
        for pct in values {
            let tone = Tone.forUsage(pct)
            assertToneColors(tone, expectedDark: greenDark, expectedLight: greenLight)
        }
    }

    // MARK: - Middle Tier (60% ..< 85%)

    func testForUsage60To85PercentReturnsYellowTone() {
        let values = [60.0, 60.001, 72.5, 84.0, 84.9, 84.999]
        for pct in values {
            let tone = Tone.forUsage(pct)
            assertToneColors(tone, expectedDark: yellowDark, expectedLight: yellowLight)
        }
    }

    // MARK: - Upper Tier (>= 85%)

    func testForUsage85PercentAndAboveReturnsRedTone() {
        let values = [85.0, 85.001, 90.0, 100.0, 150.0, 1000.0]
        for pct in values {
            let tone = Tone.forUsage(pct)
            assertToneColors(tone, expectedDark: redDark, expectedLight: redLight)
        }
    }

    // MARK: - Boundary Conditions

    func testForUsage60PercentExactBoundaryTransition() {
        // Just under 60 is Green
        let under60 = Tone.forUsage(59.9999)
        assertToneColors(under60, expectedDark: greenDark, expectedLight: greenLight)

        // Exactly 60 is Yellow
        let exact60 = Tone.forUsage(60.0)
        assertToneColors(exact60, expectedDark: yellowDark, expectedLight: yellowLight)
    }

    func testForUsage85PercentExactBoundaryTransition() {
        // Just under 85 is Yellow
        let under85 = Tone.forUsage(84.9999)
        assertToneColors(under85, expectedDark: yellowDark, expectedLight: yellowLight)

        // Exactly 85 is Red
        let exact85 = Tone.forUsage(85.0)
        assertToneColors(exact85, expectedDark: redDark, expectedLight: redLight)
    }

    // MARK: - Gradient Property

    func testToneGradientCreation() {
        let tone = Tone.forUsage(50.0)
        let gradient = tone.gradient
        XCTAssertNotNil(gradient)
    }
}
