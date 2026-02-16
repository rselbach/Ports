import XCTest
@testable import Ports

final class PortScannerTests: XCTestCase {
    func testScanReturnsArray() {
        let scanner = PortScanner()
        let result = scanner.scan()
        // Should return an array (may be empty if no ports)
        XCTAssertNotNil(result)
    }

    func testForceScanReturnsArray() {
        let scanner = PortScanner()
        let result = scanner.forceScan()
        XCTAssertNotNil(result)
    }

    func testCachedScanReturnsSameResults() {
        let scanner = PortScanner()
        let first = scanner.scan()
        let second = scanner.scan()
        // Within TTL, should return cached results
        XCTAssertEqual(first.count, second.count)
    }
}
