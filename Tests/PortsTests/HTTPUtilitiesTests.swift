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
}
