import Foundation
import Testing

@testable import NavigatorSyncCore

@Suite("CLILocator")
struct CLILocatorTests {

    @Test("finds a CLI on the first matching PATH directory")
    func foundOnPath() throws {
        let locator = CLILocator(searchPath: "/usr/bin:/opt/mytools/bin") { path in
            path == "/opt/mytools/bin/jj"
        }
        let url = try locator.locate(.jj)
        #expect(url.path == "/opt/mytools/bin/jj")
    }

    @Test("falls back to /opt/homebrew/bin when PATH misses")
    func homebrewFallback() throws {
        let locator = CLILocator(searchPath: "/usr/bin:/usr/local/bin") { path in
            path == "/opt/homebrew/bin/navigator"
        }
        let url = try locator.locate(.navigator)
        #expect(url.path == "/opt/homebrew/bin/navigator")
    }

    @Test("throws .missing with the jj install hint when absent everywhere")
    func missingJJ() {
        let locator = CLILocator(searchPath: "/usr/bin") { _ in false }
        #expect {
            try locator.locate(.jj)
        } throws: { error in
            error as? CLILocatorError == .missing(cli: .jj, installHint: "brew install jj")
        }
    }

    @Test("throws .missing with the navigator install hint when absent everywhere")
    func missingNavigator() {
        let locator = CLILocator(searchPath: "") { _ in false }
        #expect {
            try locator.locate(.navigator)
        } throws: { error in
            error as? CLILocatorError
                == .missing(
                    cli: .navigator,
                    installHint: "brew install neon-law/navigator/navigator"
                )
        }
    }

    @Test("ignores empty PATH segments and a trailing colon")
    func emptySegments() throws {
        let locator = CLILocator(searchPath: "::/opt/x/bin:") { path in
            path == "/opt/x/bin/jj"
        }
        let url = try locator.locate(.jj)
        #expect(url.path == "/opt/x/bin/jj")
    }

    @Test("searches PATH directories in order (first match wins)")
    func firstMatchWins() throws {
        let locator = CLILocator(searchPath: "/a:/b") { path in
            path == "/a/jj" || path == "/b/jj"
        }
        let url = try locator.locate(.jj)
        #expect(url.path == "/a/jj")
    }

    @Test("handles a PATH directory with a trailing slash")
    func trailingSlashDirectory() throws {
        let locator = CLILocator(searchPath: "/opt/x/bin/") { path in
            path == "/opt/x/bin/jj"
        }
        let url = try locator.locate(.jj)
        #expect(url.path == "/opt/x/bin/jj")
    }

    @Test("install hints are correct per CLI")
    func installHints() {
        #expect(CLIName.jj.installHint == "brew install jj")
        #expect(CLIName.navigator.installHint == "brew install neon-law/navigator/navigator")
    }
}
