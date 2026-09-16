import XCTest
@testable import CorniceKit

/// Fixture text is real `lsof -nP -iTCP -sTCP:LISTEN -FpcnL` output.
final class LsofParserTests: XCTestCase {

    func testParsesFieldOutput() {
        let output = """
        p8477
        cnode
        Lkirolos
        f4
        PTCP
        n127.0.0.1:3000
        """

        let listeners = LsofParser.parseListeners(output)

        XCTAssertEqual(listeners.count, 1)
        XCTAssertEqual(listeners[3000]?.pid, 8477)
        XCTAssertEqual(listeners[3000]?.command, "node")
        XCTAssertEqual(listeners[3000]?.user, "kirolos")
        XCTAssertEqual(listeners[3000]?.boundAddress, "127.0.0.1")
    }

    /// Field mode is used precisely because column mode truncates at nine
    /// characters. A name longer than that must survive intact.
    func testPreservesLongCommandNamesWithSpaces() {
        let output = """
        p8477
        cChatGPT for Chrome
        Lkirolos
        f4
        n127.0.0.1:64218
        """

        XCTAssertEqual(LsofParser.parseListeners(output)[64218]?.command, "ChatGPT for Chrome")
    }

    /// A server bound to both stacks appears twice. It is one server.
    func testDeduplicatesIPv4AndIPv6ForSamePort() {
        let output = """
        p596
        crapportd
        Lkirolos
        f10
        n*:50319
        f11
        n*:50319
        """

        let listeners = LsofParser.parseListeners(output)

        XCTAssertEqual(listeners.count, 1)
        XCTAssertEqual(listeners[50319]?.pid, 596)
    }

    /// Fields carry forward within a process record, so a new `p` line must
    /// reset them — otherwise a process with no `c` line inherits the previous
    /// process's name.
    func testProcessFieldsDoNotLeakBetweenRecords() {
        let output = """
        p100
        cfirst
        Luser
        f3
        n*:3000
        p200
        f4
        n*:4000
        """

        let listeners = LsofParser.parseListeners(output)

        XCTAssertEqual(listeners[3000]?.command, "first")
        XCTAssertEqual(listeners[4000]?.pid, 200)
        XCTAssertEqual(listeners[4000]?.command, "", "must not inherit 'first'")
    }

    func testMultipleDistinctPortsForOneProcess() {
        let output = """
        p651
        cControlCenter
        Lkirolos
        f8
        n*:7000
        f10
        n*:5000
        """

        let listeners = LsofParser.parseListeners(output)

        XCTAssertEqual(Set(listeners.keys), [7000, 5000])
        XCTAssertEqual(listeners[5000]?.command, "ControlCenter")
    }

    // MARK: - Address splitting

    func testSplitsWildcardAddress() {
        let parsed = LsofParser.splitAddress("*:8080")

        XCTAssertEqual(parsed?.address, "*")
        XCTAssertEqual(parsed?.port, 8080)
    }

    /// IPv6 literals are full of colons, so splitting on the *first* colon —
    /// or on any colon but the last — produces nonsense.
    func testSplitsIPv6Address() {
        let parsed = LsofParser.splitAddress("[::1]:5173")

        XCTAssertEqual(parsed?.address, "::1")
        XCTAssertEqual(parsed?.port, 5173)
    }

    func testSplitsIPv6AddressWithZoneIdentifier() {
        let parsed = LsofParser.splitAddress("[fe80::1%en0]:8000")

        XCTAssertEqual(parsed?.address, "fe80::1%en0")
        XCTAssertEqual(parsed?.port, 8000)
    }

    func testRejectsMalformedAddresses() {
        XCTAssertNil(LsofParser.splitAddress("no-colon"))
        XCTAssertNil(LsofParser.splitAddress("*:notaport"))
        XCTAssertNil(LsofParser.splitAddress("*:0"), "port 0 is not listenable")
        XCTAssertNil(LsofParser.splitAddress("*:99999"), "out of range")
    }

    func testPublicBindingDetection() {
        let wildcard = ListeningProcess(pid: 1, command: "n", user: "u", boundAddress: "*")
        let loopback = ListeningProcess(pid: 1, command: "n", user: "u", boundAddress: "127.0.0.1")

        XCTAssertTrue(wildcard.isPubliclyBound)
        XCTAssertFalse(loopback.isPubliclyBound)
    }

    // MARK: - ps elapsed time

    /// `ps` writes `[[dd-]hh:]mm:ss`. The day separator is a hyphen, which is
    /// the part naive colon-splitting gets wrong.
    func testParsesElapsedTimeFormats() {
        XCTAssertEqual(LsofParser.parseElapsed("05:12"), 312)
        XCTAssertEqual(LsofParser.parseElapsed("01:05:12"), 3912)
        XCTAssertEqual(LsofParser.parseElapsed("3-04:15:12"), 3 * 86_400 + 15_312)
        XCTAssertEqual(LsofParser.parseElapsed("00:00"), 0)
    }

    func testRejectsMalformedElapsedTime() {
        XCTAssertNil(LsofParser.parseElapsed(""))
        XCTAssertNil(LsofParser.parseElapsed("abc"))
        XCTAssertNil(LsofParser.parseElapsed("12"), "a bare number is ambiguous")
    }

    func testParsesUptimeTable() {
        let output = """
          8477       05:12
           596    3-04:15:12
        """

        let uptimes = LsofParser.parseUptimes(output)

        XCTAssertEqual(uptimes[8477], 312)
        XCTAssertEqual(uptimes[596], 3 * 86_400 + 15_312)
    }
}
