import XCTest
@testable import Ports

final class SavedServerTests: XCTestCase {
    func testLegacySavedServerDefaultsLANExposureToFalse() throws {
        let data = Data(#"{"port":8080,"directoryPath":"/tmp/Greendale Community College"}"#.utf8)
        let saved = try JSONDecoder().decode(SavedServer.self, from: data)

        XCTAssertEqual(saved.port, 8080)
        XCTAssertEqual(saved.directoryPath, "/tmp/Greendale Community College")
        XCTAssertFalse(saved.exposeToLAN)
    }

    func testSavedServerRoundTripsLANExposure() throws {
        let input = SavedServer(port: 9090, directoryPath: "/tmp/Troy Barnes", exposeToLAN: true)
        let data = try JSONEncoder().encode(input)
        let output = try JSONDecoder().decode(SavedServer.self, from: data)

        XCTAssertEqual(output.port, 9090)
        XCTAssertEqual(output.directoryPath, "/tmp/Troy Barnes")
        XCTAssertTrue(output.exposeToLAN)
    }
}
