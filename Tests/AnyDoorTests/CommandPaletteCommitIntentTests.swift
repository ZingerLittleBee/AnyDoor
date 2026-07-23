import XCTest
import PluginInterface
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
                                  .portManager, .pickColor, .captureTimer] {
            XCTAssertEqual(
                CommandPaletteCommitIntent.classify(.builtin(item)),
                .drillIntoOptions(item),
                "\(item) should drill into options"
            )
        }
    }

    @MainActor
    func testPluginRegisteredOptionParentDrillsInOnlyWhileRegistered() {
        // hostsManager's option parent is registered by its plugin's install
        // (not by the Core table), so classification follows the registration.
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.builtin(.hostsManager)),
            .dismiss
        )
        let registry = CommandPaletteExtensions()
        registry.registerOptionParent(for: .hostsManager, CommandPaletteOptionParent(
            listsAtRoot: { true },
            buildOptions: { [] }
        ))
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.builtin(.hostsManager), extensions: registry),
            .drillIntoOptions(.hostsManager)
        )
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
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(.builtin(.imageConversion)),
            .runBuiltin(.imageConversion)
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
    func testPluginRowMapsDeclaredCloseThenActSemantics() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "hosts"),
            localID: "profiles"
        )
        let descriptor = PluginRowDescriptor(
            id: "profile-1", title: "Dev", symbol: "circle", commit: .closeThenAct
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
            ),
            .pluginRowCloseThenAct(sourceKey: sourceKey, rowID: "profile-1")
        )
    }

    @MainActor
    func testPluginRowMapsDeclaredStayOpenSemantics() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "test.plugin"),
            localID: "some.source"
        )
        let descriptor = PluginRowDescriptor(
            id: "row-2", title: "Row", symbol: "circle", commit: .stayOpen
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
            ),
            .pluginRowStayOpen(sourceKey: sourceKey, rowID: "row-2")
        )
    }

    @MainActor
    func testPluginRowPushDetailStaysOpenAndCarriesTitle() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:com.acme.posts"),
            localID: "rows"
        )
        let descriptor = PluginRowDescriptor(
            id: "post-1", title: "Latest Post", symbol: "doc", commit: .pushDetail
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
            ),
            .pluginRowPushDetail(sourceKey: sourceKey, rowID: "post-1", title: "Latest Post")
        )
    }

    @MainActor
    func testPluginRowPushListStaysOpenAndCarriesListIDAndTitle() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:com.acme.v2ex"),
            localID: "rows"
        )
        let descriptor = PluginRowDescriptor(
            id: "hot", title: "View Hot Topics", symbol: "flame", commit: .pushList("hot")
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
            ),
            .pluginRowPushList(sourceKey: sourceKey, listID: "hot", title: "View Hot Topics")
        )
    }

    @MainActor
    func testPluginRowEnterArgumentStaysOpenAndCarriesTitle() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:com.acme.search"),
            localID: "rows"
        )
        let descriptor = PluginRowDescriptor(
            id: "search", title: "Search", symbol: "magnifyingglass", commit: .enterArgument
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
            ),
            .pluginRowEnterArgument(sourceKey: sourceKey, rowID: "search", title: "Search")
        )
    }

    @MainActor
    func testPluginRowOpenURLClosesAndOpens() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:com.acme.posts"),
            localID: "rows"
        )
        let descriptor = PluginRowDescriptor(
            id: "post-1", title: "Open", symbol: "link",
            commit: .openURL("https://example.com/post/1")
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
            ),
            .openURL(url: "https://example.com/post/1")
        )
    }

    @MainActor
    func testPluginRowOpenURLWithNonWebSchemeIsRejected() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:com.acme.posts"),
            localID: "rows"
        )
        // file:// (filesystem), a custom app scheme, and a scheme-less string are
        // all outside the openURL capability's http/https surface (ADR-0009), so
        // they classify as a rejection (failure toast) rather than opening.
        for url in ["file:///etc/hosts", "raycast://extensions", "example.com"] {
            let descriptor = PluginRowDescriptor(
                id: "post-1", title: "Open", symbol: "link", commit: .openURL(url)
            )
            XCTAssertEqual(
                CommandPaletteCommitIntent.classify(
                    .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
                ),
                .openURLRejected,
                "\(url) should be rejected"
            )
        }
    }

    @MainActor
    func testPluginRowCopyClosesAndCopiesGenericToast() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:com.acme.posts"),
            localID: "rows"
        )
        let descriptor = PluginRowDescriptor(
            id: "post-1", title: "Copy", symbol: "doc.on.doc",
            commit: .copy("copied text")
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
            ),
            .copyToClipboard(text: "copied text", toast: .generic)
        )
    }

    @MainActor
    func testPluginRowNoActionIsInert() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:com.acme.posts"),
            localID: "rows"
        )
        let descriptor = PluginRowDescriptor(
            id: "__status", title: "Loading…", symbol: "hourglass", commit: .noAction
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
            ),
            .noAction
        )
    }

    @MainActor
    func testPluginRowRunArgumentClosesAndCarriesArgument() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "script:com.acme.search"),
            localID: "rows"
        )
        let descriptor = PluginRowDescriptor(
            id: "search", title: "Search — anydoor", symbol: "magnifyingglass",
            commit: .runArgument("anydoor")
        )
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(
                .pluginRow(sourceKey: sourceKey, descriptor: descriptor)
            ),
            .pluginRowRunArgument(sourceKey: sourceKey, rowID: "search", argument: "anydoor")
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
