import XCTest
@testable import SitePhoto

final class GPSFormatTests: XCTestCase {
    func testAustinWestLongitudeUsesWNotNegativeEast() {
        XCTAssertEqual(
            GPSFormat.coordinateString(latitude: 30.26715, longitude: -97.74306),
            "30.26715° N, 97.74306° W"
        )
    }

    func testSouthernEasternHemisphere() {
        XCTAssertEqual(
            GPSFormat.coordinateString(latitude: -33.8688, longitude: 151.2093),
            "33.86880° S, 151.20930° E"
        )
    }

    func testZeroIsNorthEast() {
        XCTAssertEqual(
            GPSFormat.coordinateString(latitude: 0, longitude: 0),
            "0.00000° N, 0.00000° E"
        )
    }

    func testNonFiniteReturnsNil() {
        XCTAssertNil(GPSFormat.coordinateString(latitude: .nan, longitude: -97))
        XCTAssertNil(GPSFormat.coordinateString(latitude: 30, longitude: .infinity))
    }
}
