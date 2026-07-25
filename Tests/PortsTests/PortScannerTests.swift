import XCTest
@testable import Ports

final class PortScannerTests: XCTestCase {
    /// Captured from `lsof -iTCP -sTCP:LISTEN -n -P -Fpcn -c0`. lsof emits the
    /// f (descriptor) field even when it was not requested, one process header
    /// covers several sockets, and the same port shows up once per descriptor
    /// and once per address family.
    private let sample = """
    p1014
    crapportd
    f12
    n*:50004
    f19
    n*:50004
    p1505
    cpostgres
    f7
    n[::1]:5432
    f8
    n127.0.0.1:5432
    p7711
    cT3 Code (Nightly)
    f17
    n*:3773
    """

    func testParseLsofOutputExtractsPortsProcessesAndAddresses() {
        let got = PortScanner().parseLsofOutput(sample)

        XCTAssertEqual(got.map(\.port), [50004, 5432, 3773], "one entry per port, in the order lsof reported them")

        XCTAssertEqual(got[0], PortInfo(port: 50004, pid: 1014, processName: "rapportd", address: "*"))
        // The first descriptor for a port wins, so the IPv6 form is what is kept.
        XCTAssertEqual(got[1], PortInfo(port: 5432, pid: 1505, processName: "postgres", address: "[::1]"))
        // Command names are not truncated and may contain spaces and parentheses.
        XCTAssertEqual(got[2], PortInfo(port: 3773, pid: 7711, processName: "T3 Code (Nightly)", address: "*"))
    }

    func testParseLsofOutputIgnoresUnusableLines() {
        let cases = [
            "": 0,
            "\n\n": 0,
            "p1234\ncbroken": 0,                       // a process with no socket
            "n*:8080": 0,                              // a socket with no preceding process
            "pnotanumber\ncx\nn*:8080": 0,             // unparsable pid
            "p1\ncx\nn*:notaport": 0,                  // unparsable port
            "p1\ncx\nn*:99999": 0,                     // out of UInt16 range
            "p1\ncx\nn*:8080": 1,
        ]
        for (input, want) in cases {
            XCTAssertEqual(PortScanner().parseLsofOutput(input).count, want, "input: \(input.debugDescription)")
        }
    }

    func testParseLsofOutputFallsBackWhenTheCommandIsMissing() {
        let got = PortScanner().parseLsofOutput("p42\nn*:8080")
        XCTAssertEqual(got, [PortInfo(port: 8080, pid: 42, processName: "unknown", address: "*")])
    }

    func testScanCachesResultsAndForceScanRefreshesThem() {
        let scanner = PortScanner()
        let first = scanner.scan()
        XCTAssertEqual(scanner.scan(), first, "a scan within the TTL must return the cached results verbatim")
        XCTAssertEqual(scanner.forceScan().map(\.port).sorted(), scanner.scan().map(\.port).sorted(),
                       "a forced scan must refresh the cache it then serves")
    }
}
