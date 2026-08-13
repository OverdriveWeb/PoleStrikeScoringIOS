import XCTest

// Real XCTest wrappers for the checks in `DetectionSelfTests`.
//
// This file lives OUTSIDE PoleScore.swiftpm on purpose. A Swift Playgrounds app
// package has a single executable product and no way to host a test target, so
// putting this inside the package would break the build on the device the app
// is actually developed on. Use it when you open the package in Xcode on a Mac:
//
//   1. File > New > Target > Unit Testing Bundle.
//   2. Add this file, plus DetectionSelfTests.swift, YOLOOutputParser.swift,
//      DetectionCoordinateMapper.swift and Geometry.swift to the test target's
//      Compile Sources (or mark them @testable importable from the app target).
//   3. Cmd-U.
//
// The bodies are deliberately thin. The assertions that matter live in
// DetectionSelfTests so they can also run on-device from Coach > Detection
// self-checks with the developer overlay switched on — one set of checks, two
// ways to run them, no chance of the two drifting apart.

final class DetectionTests: XCTestCase {

    private func assertPassed(_ result: DetectionSelfTests.Result,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.passed, "\(result.name): \(result.detail)", file: file, line: line)
    }

    // MARK: - Confidence filtering

    func testConfidenceFilteringDropsWeakDetections() {
        assertPassed(DetectionSelfTests.confidenceFilteringDropsWeakDetections())
    }

    func testDetectionExactlyAtThresholdIsKept() {
        assertPassed(DetectionSelfTests.confidenceFilteringKeepsThreshold())
    }

    // MARK: - Non-maximum suppression

    func testNonMaximumSuppressionCollapsesOverlaps() {
        assertPassed(DetectionSelfTests.nonMaximumSuppressionCollapsesOverlaps())
    }

    func testNonMaximumSuppressionKeepsDifferentClasses() {
        assertPassed(DetectionSelfTests.nonMaximumSuppressionKeepsDifferentClasses())
    }

    // MARK: - Coordinate conversion

    func testVisionBoxFlipsToTopLeft() {
        assertPassed(DetectionSelfTests.visionBoxFlipsToTopLeft())
    }

    func testAspectFillCropIsAccountedFor() {
        assertPassed(DetectionSelfTests.aspectFillCropIsAccountedFor())
    }

    func testAspectFitLetterboxesInstead() {
        assertPassed(DetectionSelfTests.aspectFitLetterboxesInstead())
    }

    func testNoCropMeansPlainScaling() {
        assertPassed(DetectionSelfTests.squareVideoInSquareViewIsIdentity())
    }

    func testCentreStaysCentredUnderCrop() {
        assertPassed(DetectionSelfTests.centreBoxStaysCentredUnderCrop())
    }

    // MARK: - Failure states

    func testMissingModelIsRecoverable() {
        assertPassed(DetectionSelfTests.missingModelIsRecoverable())
    }

    // MARK: - Everything at once

    func testAllSelfChecksPass() {
        let failures = DetectionSelfTests.runAll().filter { !$0.passed }
        XCTAssertTrue(failures.isEmpty,
                      "failing checks: " + failures.map(\.name).joined(separator: ", "))
    }
}
