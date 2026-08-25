import XCTest
import VestaMux

/// The cold-restore divider's escape ORDER is what makes it land under the restored history
/// instead of over the top of it, so these assert positions, not mere presence. Mirrors
/// `coldRestoreBannerSelfCheck` (run by `vesta selfcheck`) so both entry points catch a regression.
final class ColdRestoreBannerTests: XCTestCase {
    private func banner(_ cwd: String?) -> String {
        String(decoding: coldRestoreBanner(cwd: cwd), as: UTF8.self)
    }

    func testResetsComeBeforeTheCursorParkWhichComesBeforeTheRule() throws {
        let text = banner("/tmp")
        XCTAssertTrue(text.hasPrefix("\u{1b}[?1049l"), "must open by leaving the alt screen")

        let park = try XCTUnwrap(text.range(of: "\u{1b}[999;1H"), "no cursor park")
        let rule = try XCTUnwrap(text.range(of: "\u{1b}[2m── vesta: session restarted"), "no rule")
        // [r homes the cursor and ?1049l can restore a saved one — both must fire BEFORE we
        // park at the last row, or the rule paints at the top over the restored screen.
        for reset in ["\u{1b}[?1049l", "\u{1b}[?1000l", "\u{1b}[?1002l", "\u{1b}[?1003l",
                      "\u{1b}[?1006l", "\u{1b}[?7h", "\u{1b}[r", "\u{1b}[?25h", "\u{1b}(B", "\u{1b}[0m"] {
            let r = try XCTUnwrap(text.range(of: reset), "banner missing \(reset)")
            XCTAssertLessThanOrEqual(r.upperBound, park.lowerBound, "\(reset) must precede [999;1H")
        }

        let nl = try XCTUnwrap(text.range(of: "\r\n"), "no newline")
        XCTAssertEqual(park.upperBound, nl.lowerBound, "the CRLF must immediately follow the park")
        XCTAssertEqual(nl.upperBound, rule.lowerBound, "the rule must follow the CRLF, not precede it")
        XCTAssertTrue(text.hasSuffix("\u{1b}[0m\r\n"), "must end SGR-clean on its own line")
    }

    func testUnknownCwdRendersAsTilde() {
        XCTAssertTrue(banner(nil).contains("new shell in ~ ──"), "nil cwd must render as ~")
    }

    func testHomePrefixedPathIsTildeAbbreviated() {
        let text = banner(NSHomeDirectory() + "/Code/vesta")
        XCTAssertTrue(text.contains("new shell in ~/Code/vesta ──"), "home path must abbreviate")
        XCTAssertFalse(text.contains(NSHomeDirectory()), "must not leak the literal home path")
    }
}
