import XCTest
import PluginInterface
@testable import AnyDoor

/// Pins the hosts-profile palette row source: the first descriptor-based
/// `PluginRowSource` (ADR-0007). Rows must render and act exactly like the
/// retired `Source.hostProfile` case did.
final class HostProfileRowSourceTests: XCTestCase {

    @MainActor
    func testRowsMapProfilesSortedByDisplayOrder() {
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }

        let dev = HostProfile(name: "Dev", isActive: true, displayOrder: 200)
        let prod = HostProfile(name: "Prod", isActive: false, displayOrder: 100)
        let source = HostProfileRowSource(
            profiles: { [dev, prod] },
            reload: {},
            setActive: { _, _ in }
        )

        let rows = source.rows()
        XCTAssertEqual(rows.map(\.title), ["Prod", "Dev"])
        XCTAssertEqual(rows.map(\.id), [prod.id.uuidString, dev.id.uuidString])
        XCTAssertEqual(rows.map(\.subtitle), [nil, "Active"])
        XCTAssertEqual(rows.map(\.symbol), ["circle", "checkmark.circle.fill"])
        XCTAssertEqual(rows.map(\.actionLabel), ["Toggle", "Toggle"])
        XCTAssertEqual(rows.map(\.commit), [.closeThenAct, .closeThenAct])
    }

    @MainActor
    func testPerformRowTogglesTheMatchingProfile() async {
        let dev = HostProfile(name: "Dev", isActive: true)
        let prod = HostProfile(name: "Prod", isActive: false)
        var toggles: [(name: String, active: Bool)] = []
        let source = HostProfileRowSource(
            profiles: { [dev, prod] },
            reload: {},
            setActive: { profile, active in toggles.append((profile.name, active)) }
        )

        await source.performRow(id: dev.id.uuidString)
        await source.performRow(id: prod.id.uuidString)

        XCTAssertEqual(toggles.map(\.name), ["Dev", "Prod"])
        XCTAssertEqual(toggles.map(\.active), [false, true])
    }

    @MainActor
    func testPerformRowIgnoresUnknownIDs() async {
        var toggled = false
        let source = HostProfileRowSource(
            profiles: { [HostProfile(name: "Dev")] },
            reload: {},
            setActive: { _, _ in toggled = true }
        )

        await source.performRow(id: "not-a-uuid")
        await source.performRow(id: UUID().uuidString)

        XCTAssertFalse(toggled)
    }

    @MainActor
    func testReloadRunsTheInjectedRefresh() {
        var reloads = 0
        let source = HostProfileRowSource(
            profiles: { [] },
            reload: { reloads += 1 },
            setActive: { _, _ in }
        )
        source.reload()
        XCTAssertEqual(reloads, 1)
    }

    @MainActor
    func testCoreRegistryRegistersTheHostsRowSource() {
        XCTAssertNotNil(CommandPaletteExtensions.shared.rowSource(withID: HostProfileRowSource.sourceID))
    }

    @MainActor
    func testRowSourceRegistrationAndUnregistration() {
        let registry = CommandPaletteExtensions()
        XCTAssertTrue(registry.rowSources.isEmpty)

        let source = HostProfileRowSource(profiles: { [] }, reload: {}, setActive: { _, _ in })
        registry.registerRowSource(source, sectionTitleKey: .commandPaletteSectionHosts)

        XCTAssertEqual(registry.rowSources.count, 1)
        XCTAssertTrue(registry.rowSource(withID: HostProfileRowSource.sourceID) === source)

        registry.unregisterRowSource(id: HostProfileRowSource.sourceID)
        XCTAssertTrue(registry.rowSources.isEmpty)
        XCTAssertNil(registry.rowSource(withID: HostProfileRowSource.sourceID))
    }
}
