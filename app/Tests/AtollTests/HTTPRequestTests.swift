import XCTest
@testable import Atoll

final class HTTPRequestTests: XCTestCase {
    func testFullscreenDetectionRequiresWindowToCoverTheWholeDisplay() {
        XCTAssertTrue(DisplayPolicy.windowCoversScreen(
            windowSize: CGSize(width: 1728, height: 1117),
            screenSize: CGSize(width: 1728, height: 1117)))
        XCTAssertFalse(DisplayPolicy.windowCoversScreen(
            windowSize: CGSize(width: 1728, height: 1080),
            screenSize: CGSize(width: 1728, height: 1117)))
    }

    func testRuntimeInstallerUpdatesBundledHelpersWithExecutablePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resources = root.appendingPathComponent("resources")
        let destination = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("bridge-v2".utf8).write(to: resources.appendingPathComponent("atoll-bridge"))
        try Data("status-v2".utf8).write(to: resources.appendingPathComponent("atoll-statusline.sh"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("bridge-v1".utf8).write(to: destination.appendingPathComponent("atoll-bridge"))

        try RuntimeInstaller.installHelpers(from: resources, to: destination)

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("atoll-bridge")), "bridge-v2")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("atoll-bridge").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    func testEndpointFileIsWrittenWithOwnerOnlyPermissions() throws {
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-gateway-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        try Gateway.writeEndpointFile(port: 4321, token: "secret", runDirectory: runDirectory)

        let endpoint = runDirectory.appendingPathComponent("endpoint")
        XCTAssertEqual(try String(contentsOf: endpoint, encoding: .utf8),
                       "ATOLL_PORT=4321\nATOLL_TOKEN=secret\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: endpoint.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testEndpointWriteReportsInvalidRunDirectory() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("atoll-gateway-file-\(UUID().uuidString)")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(
            try Gateway.writeEndpointFile(port: 4321, token: "secret", runDirectory: file)
        )
    }

    func testParseWaitsForCompleteBody() {
        let partial = Data("POST /decide HTTP/1.1\r\nContent-Length: 4\r\n\r\nab".utf8)
        XCTAssertNil(HTTPRequest.parse(partial))

        let complete = Data("POST /decide HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcd".utf8)
        let request = HTTPRequest.parse(complete)
        XCTAssertEqual(request?.method, "POST")
        XCTAssertEqual(request?.path, "/decide")
        XCTAssertEqual(request?.body, Data("abcd".utf8))
    }

    func testParseFormDecodesEscapedValues() {
        XCTAssertEqual(HTTPRequest.parseForm(Data("name=Atoll+App&path=%2Ftmp%2Fa".utf8)),
                       ["name": "Atoll App", "path": "/tmp/a"])
    }

    func testParseReturnsNilBeforeHeadersComplete() {
        XCTAssertNil(HTTPRequest.parse(Data("POST /hook/claude HTTP/1.1\r\nContent-Length: 2".utf8)),
                     "no blank line yet → keep buffering")
    }

    func testParseExtractsLowercasedHeadersAndToken() {
        let raw = "POST /hook/claude HTTP/1.1\r\nX-Atoll-Token: abc\r\nContent-Length: 0\r\n\r\n"
        let req = HTTPRequest.parse(Data(raw.utf8))
        XCTAssertEqual(req?.headers["x-atoll-token"], "abc", "header keys are lowercased")
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.path, "/hook/claude")
        XCTAssertEqual(req?.body.count, 0)
    }

    func testParseFormHandlesEmptyAndValuelessPairs() {
        XCTAssertEqual(HTTPRequest.parseForm(Data("".utf8)), [:])
        // A bare key with no '=' is skipped; an explicit empty value is kept.
        XCTAssertEqual(HTTPRequest.parseForm(Data("hold=1&novalue&empty=".utf8)),
                       ["hold": "1", "empty": ""])
    }

    func testParseFormKeepsLaterDuplicateKey() {
        XCTAssertEqual(HTTPRequest.parseForm(Data("source=claude&source=codex".utf8)),
                       ["source": "codex"])
    }
}
