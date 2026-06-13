import XCTest

@testable import AnyDoor

final class PortActionsTests: XCTestCase {
    func testLocalhostURLStringUsesHTTPAndPort() {
        let record = PortRecord(port: 5173, pid: 42, processName: "vite",
                                executablePath: nil, commandLine: nil,
                                binds: [PortBind(address: "*", family: .ipv4)])

        XCTAssertEqual(PortActions.localhostURLString(for: record), "http://localhost:5173")
    }

    func testCommandTextPrefersFullCommandThenExecutableThenProcessName() {
        let full = PortRecord(port: 3000, pid: 1, processName: "node",
                              executablePath: "/usr/local/bin/node",
                              commandLine: "node server.js",
                              binds: [])
        let executable = PortRecord(port: 3001, pid: 2, processName: "node",
                                    executablePath: "/usr/local/bin/node",
                                    commandLine: nil,
                                    binds: [])
        let fallback = PortRecord(port: 3002, pid: 3, processName: "node",
                                  executablePath: nil, commandLine: nil,
                                  binds: [])

        XCTAssertEqual(PortActions.commandText(for: full), "node server.js")
        XCTAssertEqual(PortActions.commandText(for: executable), "/usr/local/bin/node")
        XCTAssertEqual(PortActions.commandText(for: fallback), "node")
    }
}
