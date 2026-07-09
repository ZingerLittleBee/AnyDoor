import XCTest
@testable import AnyDoor

/// Pins the Source → commit-intent mapping so the palette's four commit
/// semantics (drill-in / confirm / stay-open / close-then-act) stay explicit.
final class CommandPaletteCommitIntentTests: XCTestCase {

    // MARK: - Builtins

    @MainActor
    func testOptionParentsDrillInRegardlessOfKind() {
        // keepAwake and scheduledShutdown are toggle-kind but must open their
        // duration list, not flip directly.
        for item: BuiltinItem in [.keepAwake, .scheduledShutdown, .brightness,
                                  .hostsManager, .portManager, .pickColor, .captureTimer] {
            XCTAssertEqual(
                CommandPaletteCommitIntent.classify(.builtin(item)),
                .drillIntoOptions(item),
                "\(item) should drill into options"
            )
        }
    }

    @MainActor
    func testPlainToggleBuiltinTogglesAndCloses() {
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.builtin(.darkMode)),
            .toggleBuiltin(.darkMode)
        )
    }

    @MainActor
    func testPlainActionBuiltinRunsAndCloses() {
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.builtin(.lockScreen)),
            .runBuiltin(.lockScreen)
        )
    }

    @MainActor
    func testNonParentSubmenuAndHiddenHotkeyDismiss() {
        for item: BuiltinItem in [.appShortcuts, .windowLayout, .bluetoothBattery, .brightnessUp] {
            XCTAssertEqual(
                CommandPaletteCommitIntent.classify(.builtin(item)),
                .dismiss,
                "\(item) has no palette commit action"
            )
        }
    }

    // MARK: - Stay-open sources

    @MainActor
    func testPaletteOptionRunsOrConfirms() {
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.paletteOption(id: "port.kill.123")),
            .runOrConfirmOption(id: "port.kill.123")
        )
    }

    @MainActor
    func testPortRecordAsksForKillConfirmation() {
        let record = PortRecord(
            port: 8080, pid: 123, processName: "node",
            executablePath: nil, commandLine: nil,
            binds: [PortBind(address: "*", family: .ipv4)]
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.portRecord(record)),
            .confirmPortKill(record)
        )
    }

    @MainActor
    func testDevToolScopeSuggestionEntersScope() {
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.devToolScopeSuggestion(.base64)),
            .enterDevToolScope(.base64)
        )
    }

    // MARK: - Close-then-act sources

    @MainActor
    func testAppSourcesLaunch() {
        let id = UUID()
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.appShortcut(id)),
            .launchAppShortcut(id: id)
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .installedApp(bundleID: "com.example.app", path: "/Applications/Example.app")
            ),
            .launchApp(bundleID: "com.example.app", path: "/Applications/Example.app")
        )
    }

    @MainActor
    func testCalcResultCopiesWithValueEchoingToast() {
        let result = CalcResult(value: 42, display: "42", copyText: "42")
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.calcResult(result)),
            .copyToClipboard(text: "42", toast: .calc(display: "42"))
        )
    }

    @MainActor
    func testDevToolAndConversionCopyWithGenericToast() {
        let devTool = DevToolResult(toolID: "hash.md5", output: "abc")
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.devTool(devTool)),
            .copyToClipboard(text: "abc", toast: .generic)
        )
        let conversion = ConversionResult(
            kind: .unit, value: 0.9144, display: "0.9144 m",
            copyText: "0.9144", detail: "3 ft", symbol: "ruler"
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.conversion(conversion)),
            .copyToClipboard(text: "0.9144", toast: .generic)
        )
    }

    @MainActor
    func testHostProfileTogglesActivation() {
        let id = UUID()
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.hostProfile(id: id)),
            .toggleHostProfile(id: id)
        )
    }

    @MainActor
    func testQuicklinkIntentsDeclarePlainTemplateAndArgumentRows() {
        let id = UUID()
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.quicklink(id: id)),
            .openQuicklink(id: id)
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.quicklinkTemplate(id: id)),
            .enterQuicklinkArgument(id: id)
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.quicklinkArgument(id: id, argument: "AnyDoor")),
            .openQuicklinkArgument(id: id, argument: "AnyDoor")
        )
    }
}
