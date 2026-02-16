import XCTest
@testable import Ports

final class HTTPUtilitiesTests: XCTestCase {
    func testHTMLEscapedEscapesSpecialCharacters() {
        let raw = "Troy & Annie <script>alert('Greendale')</script> \"Human Being\""
        let got = HTTPUtilities.htmlEscaped(raw)
        let want = "Troy &amp; Annie &lt;script&gt;alert(&#39;Greendale&#39;)&lt;/script&gt; &quot;Human Being&quot;"
        XCTAssertEqual(got, want)
    }

    func testPercentEncodedPathEncodesUnsafeCharacters() {
        let raw = "/Greendale Community College/Senor Chang's notes.html"
        let got = HTTPUtilities.percentEncodedPath(raw)
        let want = "/Greendale%20Community%20College/Senor%20Chang's%20notes.html"
        XCTAssertEqual(got, want)
    }

    func testSanitizedHeaderValueRemovesCRLF() {
        let inputs = [
            "/path\r\nSet-Cookie: hijacked": "/pathSet-Cookie: hijacked",
            "/path\nLocation: evil.com": "/pathLocation: evil.com",
            "/path\rX-Injected: true": "/pathX-Injected: true",
            "/path\r\n\r\n<html>evil</html>": "/path<html>evil</html>",
            "/normal/path": "/normal/path",
            "": "",
        ]
        for (input, want) in inputs {
            let got = HTTPUtilities.sanitizedHeaderValue(input)
            XCTAssertEqual(got, want, "Failed for input: \(input.debugDescription)")
        }
    }

    func testSanitizedHeaderValueRemovesNullBytes() {
        let input = "/path\u{0}malicious"
        let got = HTTPUtilities.sanitizedHeaderValue(input)
        XCTAssertEqual(got, "/pathmalicious")
    }
}
