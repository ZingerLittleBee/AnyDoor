import ApplicationServices
import Foundation
import Testing
@testable import AnyDoor

private let english = SystemNotificationFixture.english
private let chinese = SystemNotificationFixture.chinese
private func action(_ label: String) -> String { SystemNotificationFixture.action(label) }

// MARK: - Policy

struct SystemNotificationDismissPolicyTests {
    @Test func parsesCustomActionLabels() {
        #expect(SystemNotificationDismissPolicy.customActionLabel(action("Close")) == "Close")
        #expect(SystemNotificationDismissPolicy.customActionLabel(action("全部清除")) == "全部清除")
        #expect(SystemNotificationDismissPolicy.customActionLabel("Name:Clear All") == "Clear All")
        #expect(SystemNotificationDismissPolicy.customActionLabel("AXPress") == nil)
        #expect(SystemNotificationDismissPolicy.customActionLabel("AXShowMenu") == nil)
    }

    @Test func recognizesOnlyNotificationSubroles() {
        for subrole in SystemNotificationDismissPolicy.notificationSubroles {
            #expect(SystemNotificationDismissPolicy.isNotification(subrole: subrole))
        }
        for subrole in ["AXHostingView", "AXSystemDialog", "AXNotificationCenterNextFocus", "AXNotificationListItems", ""] {
            #expect(!SystemNotificationDismissPolicy.isNotification(subrole: subrole))
        }
    }

    @Test func clearAllWinsOverCloseWhateverTheActionOrder() {
        // Close on a stack may only close its top notification; the element's
        // own action order must not decide.
        let closeFirst = ["AXPress", action("Close"), action("Clear All")]
        #expect(SystemNotificationDismissPolicy.dismissAction(in: closeFirst, labels: english) == action("Clear All"))
        let banner = ["AXPress", action("Show Details"), action("Options"), action("Close")]
        #expect(SystemNotificationDismissPolicy.dismissAction(in: banner, labels: english) == action("Close"))
    }

    @Test func recognizesDismissAndDismissAllOnlyElements() {
        #expect(SystemNotificationDismissPolicy.dismissAction(in: ["AXPress", action("Dismiss")], labels: english)
            == action("Dismiss"))
        #expect(SystemNotificationDismissPolicy.dismissAction(in: ["AXPress", action("Dismiss All")], labels: english)
            == action("Dismiss All"))
        #expect(SystemNotificationDismissPolicy.dismissAction(in: [action("Dismiss"), action("Dismiss All")], labels: english)
            == action("Dismiss All"))
        #expect(SystemNotificationDismissPolicy.dismissAction(in: [action("Dismiss"), action("Close")], labels: english)
            == action("Close"))
    }

    @Test func matchesOnlyTheActiveLanguage() {
        #expect(SystemNotificationDismissPolicy.dismissAction(in: [action("显示详细信息"), action("全部清除")], labels: chinese)
            == action("全部清除"))
        // An English "Close" under a Chinese Notification Center is not its own
        // action, so it may belong to the app.
        #expect(SystemNotificationDismissPolicy.dismissAction(in: [action("Close")], labels: chinese) == nil)
    }

    @Test func leavesAmbiguousElementsAlone() {
        // The app named one of its own actions "Close" as well.
        #expect(SystemNotificationDismissPolicy.dismissAction(
            in: [action("Reply"), action("Close"), action("Close")], labels: english
        ) == nil)
        // Chinese Close and Dismiss share 关闭: one such action is fine, two are ambiguous.
        #expect(SystemNotificationDismissPolicy.dismissAction(in: [action("关闭")], labels: chinese) == action("关闭"))
        #expect(SystemNotificationDismissPolicy.dismissAction(in: [action("关闭"), action("关闭")], labels: chinese) == nil)
        // Ambiguity on the chosen label is not resolved by a lower-priority one.
        #expect(SystemNotificationDismissPolicy.dismissAction(
            in: [action("Clear All"), action("Clear All"), action("Close")], labels: english
        ) == nil)
    }

    @Test func neverGuessesByPosition() {
        // App-provided notification actions are custom actions too; a
        // positional "last action" guess would run "Delete" here.
        #expect(SystemNotificationDismissPolicy.dismissAction(
            in: ["AXPress", action("Reply"), action("Delete")], labels: english
        ) == nil)
        #expect(SystemNotificationDismissPolicy.dismissAction(in: ["AXPress", "AXShowMenu"], labels: english) == nil)
    }

    @Test func emptyLabelsRecognizeNothing() {
        let none = SystemNotificationDismissLabels(
            actionLabels: [[], [], [], []], windowTitles: ["Notification Center"], isLanguageKnown: false
        )
        #expect(SystemNotificationDismissPolicy.dismissAction(in: [action("Close")], labels: none) == nil)
    }

    @Test func nextTargetSkipsStuckAndUnrecognizedElements() {
        let elements = [
            SystemNotificationElement(id: 1, subrole: "AXNotificationCenterBanner", actions: [action("Close")]),
            SystemNotificationElement(id: 2, subrole: "AXNotificationCenterAlert", actions: [action("Reply")]),
            SystemNotificationElement(id: 3, subrole: "AXNotificationCenterAlertStack", actions: [action("Clear All")]),
        ]
        #expect(SystemNotificationDismissPolicy.nextTarget(in: elements, labels: english, skipping: [])
            == SystemNotificationChoice(index: 0, action: action("Close")))
        #expect(SystemNotificationDismissPolicy.nextTarget(in: elements, labels: english, skipping: [1])
            == SystemNotificationChoice(index: 2, action: action("Clear All")))
        #expect(SystemNotificationDismissPolicy.nextTarget(in: elements, labels: english, skipping: [1, 3]) == nil)
    }
}

// MARK: - Label resolution

struct SystemNotificationDismissLabelsTests {
    private static let tables: [String: [String: String]] = [
        "en": [
            "Clear All": "Clear All", "Dismiss All": "Dismiss All", "Close": "Close", "Dismiss": "Dismiss",
            "Notification Center": "Notification Center", "Clear": "Clear",
        ],
        "zh_CN": [
            "Clear All": "全部清除", "Dismiss All": "全部关闭", "Close": "关闭", "Dismiss": "关闭",
            "Notification Center": "通知中心", "Clear": "清除",
        ],
        "de": [
            "Clear All": "Alle entfernen", "Dismiss All": "Alle schließen", "Close": "Schließen",
            "Dismiss": "Schließen", "Notification Center": "Mitteilungszentrale", "Clear": "Löschen",
        ],
    ]

    /// A bundle with one `Localizable.loctable`, the layout current systems
    /// ship. The caller removes it.
    private func loctableBundle() throws -> URL {
        let bundle = try SystemNotificationFixture.makeBundleDirectory()
        var root: [String: Any] = Self.tables
        // Bookkeeping entry of real loctables; not a localization.
        root["LocProvenance"] = ["de": 3, "zh_CN": 3]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Resources/Localizable.loctable"))
        return bundle
    }

    /// A bundle with per-localization text `.strings` files, the layout of
    /// older systems. The caller removes it.
    private func lprojBundle() throws -> URL {
        let bundle = try SystemNotificationFixture.makeBundleDirectory()
        var tables = Self.tables
        tables["Base"] = ["Close": "Base value"]
        for (localization, table) in tables {
            let lproj = bundle.appendingPathComponent("Contents/Resources/\(localization).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let body = table.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
            try body.write(to: lproj.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        return bundle
    }

    @Test func aKnownLanguageUsesOnlyItsOwnLocalization() throws {
        let url = try loctableBundle()
        defer { try? FileManager.default.removeItem(at: url) }
        let chinese = SystemNotificationDismissLabels.resolve(bundleURL: url, languages: ["zh-Hans-CN"])
        #expect(chinese.isLanguageKnown)
        #expect(chinese.actionLabels == [["全部清除"], ["全部关闭"], ["关闭"], ["关闭"]])
        // Its own panel title only: an English "Notification Center" window is
        // not recognized under a Chinese Notification Center.
        #expect(chinese.windowTitles == ["通知中心"])

        let german = SystemNotificationDismissLabels.resolve(bundleURL: url, languages: ["de-CH"])
        #expect(german.actionLabels == [["Alle entfernen"], ["Alle schließen"], ["Schließen"], ["Schließen"]])
        #expect(german.windowTitles == ["Mitteilungszentrale"])
    }

    @Test func anUnknownLanguageAcceptsEveryLocalization() throws {
        let url = try loctableBundle()
        defer { try? FileManager.default.removeItem(at: url) }
        let labels = SystemNotificationDismissLabels.resolve(bundleURL: url, languages: [])
        #expect(!labels.isLanguageKnown)
        #expect(labels.actionLabels[0] == ["Clear All", "全部清除", "Alle entfernen"])
        #expect(labels.actionLabels[2] == ["Close", "关闭", "Schließen"])
        #expect(labels.windowTitles == ["Notification Center", "通知中心", "Mitteilungszentrale"])
    }

    @Test func theUserLanguageListFallsThroughToASupportedLanguage() {
        // Without Notification Center's own language, the global list decides:
        // its first language Notification Center ships wins.
        let labels = SystemNotificationDismissLabels.make(tables: Self.tables, languages: ["sr", "de"])
        #expect(labels.isLanguageKnown)
        #expect(labels.actionLabels[2] == ["Schließen"])
    }

    @Test func readsPerLocalizationStringsFilesOnOlderLayouts() throws {
        let url = try lprojBundle()
        defer { try? FileManager.default.removeItem(at: url) }
        let german = SystemNotificationDismissLabels.resolve(bundleURL: url, languages: ["de"])
        #expect(german.actionLabels[2] == ["Schließen"])
        let union = SystemNotificationDismissLabels.resolve(bundleURL: url, languages: [])
        #expect(union.actionLabels[2] == ["Close", "关闭", "Schließen"], "Base.lproj is not a language")
    }

    @Test func aMissingTableRecognizesNothing() throws {
        let url = try SystemNotificationFixture.makeBundleDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        let labels = SystemNotificationDismissLabels.resolve(bundleURL: url, languages: ["en"])
        #expect(!labels.isLanguageKnown)
        #expect(labels.actionLabels == [[], [], [], []])
        #expect(labels.windowTitles.isEmpty)
    }

    /// Smoke check against the system's own bundle. It ties this test to the
    /// contents of Apple's table on the machine running it (CI's macOS runner
    /// included), so it asserts only the long-standing "Close" and "Clear All"
    /// keys and the mechanism, and flags early if Apple renames either key.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: SystemNotificationDismissLabels.defaultBundleURL.path)))
    func resolvesFromTheRealNotificationCenterBundle() {
        let url = SystemNotificationDismissLabels.defaultBundleURL
        let english = SystemNotificationDismissLabels.resolve(bundleURL: url, languages: ["en"])
        #expect(english.isLanguageKnown)
        #expect(english.actionLabels[0] == ["Clear All"])
        #expect(english.actionLabels[2] == ["Close"])

        let chinese = SystemNotificationDismissLabels.resolve(bundleURL: url, languages: ["zh-Hans"])
        #expect(chinese.isLanguageKnown)
        #expect(chinese.actionLabels[0].count == 1)
        #expect(chinese.actionLabels[0].isDisjoint(with: ["Clear All"]), "zh-Hans should be translated")
        #expect(chinese.actionLabels[2].count == 1)
        #expect(chinese.actionLabels[2].isDisjoint(with: ["Close"]), "zh-Hans should be translated")

        let union = SystemNotificationDismissLabels.resolve(bundleURL: url, languages: [])
        #expect(!union.isLanguageKnown)
        #expect(union.actionLabels[2].count > 10)
    }
}

// MARK: - Walker over an injected tree

private final class FixtureNode {
    enum Attribute { case subrole, identifier, title, children, actions }

    let id: UInt
    let subrole: String?
    let identifier: String?
    let title: String?
    let actions: [String]
    let children: [FixtureNode]
    /// Attributes whose read fails, like an AX error or an exhausted deadline.
    let failing: Set<Attribute>

    init(
        _ id: UInt,
        subrole: String? = nil,
        identifier: String? = nil,
        title: String? = nil,
        actions: [String] = [],
        children: [FixtureNode] = [],
        failing: Set<Attribute> = []
    ) {
        self.id = id
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.actions = actions
        self.children = children
        self.failing = failing
    }
}

/// Serves a fixture tree and records which reads the walker made. The
/// application node's children are its windows.
private final class FixtureReader: NotificationTreeReading {
    private(set) var subroleReads: [UInt] = []
    private(set) var titleReads: [UInt] = []
    private(set) var childReads: [UInt] = []

    func windows(of application: FixtureNode) -> NotificationTreeRead<[FixtureNode]> {
        if application.failing.contains(.children) { return .failed }
        return application.children.isEmpty ? .empty : .value(application.children)
    }

    func subrole(of node: FixtureNode) -> NotificationTreeRead<String> {
        subroleReads.append(node.id)
        return read(node, .subrole, node.subrole)
    }

    func identifier(of node: FixtureNode) -> NotificationTreeRead<String> {
        read(node, .identifier, node.identifier)
    }

    func title(of window: FixtureNode) -> NotificationTreeRead<String> {
        titleReads.append(window.id)
        return read(window, .title, window.title)
    }

    func children(of node: FixtureNode) -> NotificationTreeRead<[FixtureNode]> {
        childReads.append(node.id)
        return node.failing.contains(.children) ? .failed : .value(node.children)
    }

    func actions(of node: FixtureNode) -> NotificationTreeRead<[String]> {
        node.failing.contains(.actions) ? .failed : .value(node.actions)
    }

    func identity(of node: FixtureNode) -> UInt { node.id }

    private func read(_ node: FixtureNode, _ attribute: FixtureNode.Attribute, _ value: String?) -> NotificationTreeRead<String> {
        if node.failing.contains(attribute) { return .failed }
        return value.map { .value($0) } ?? .empty
    }
}

struct NotificationTreeReadTests {
    @Test func classifiesAccessibilityReads() {
        #expect(NotificationTreeRead(.success, value: "AXSystemDialog") == .value("AXSystemDialog"))
        // Legitimately empty: nothing there, or an attribute the element lacks.
        #expect(NotificationTreeRead<String>(.success, value: nil) == .empty)
        #expect(NotificationTreeRead<String>(.noValue, value: nil) == .empty)
        #expect(NotificationTreeRead<String>(.attributeUnsupported, value: nil) == .empty)
        // Any other error may hide part of the tree.
        for error: AXError in [.cannotComplete, .invalidUIElement, .apiDisabled, .notImplemented, .failure] {
            #expect(NotificationTreeRead(error, value: "stale") == .failed)
        }
    }
}

struct NotificationTreeWalkerTests {
    /// macOS 26 banner window as reported by third-party probes:
    /// window > AXHostingView > group > scroll area > notifications.
    private func bannerWindow(id: UInt = 0, notifications: [FixtureNode]) -> FixtureNode {
        let scroll = FixtureNode(id + 3, subrole: nil, children: notifications)
        let inner = FixtureNode(id + 2, children: [scroll])
        let hosting = FixtureNode(id + 1, subrole: "AXHostingView", children: [inner])
        return FixtureNode(id, subrole: "AXSystemDialog", title: "Notification Center", children: [hosting])
    }

    private func banner(_ id: UInt, failing: Set<FixtureNode.Attribute> = []) -> FixtureNode {
        let text = FixtureNode(id + 1_000)
        return FixtureNode(
            id, subrole: "AXNotificationCenterBanner",
            actions: ["AXPress", action("Show Details"), action("Close")],
            children: [text], failing: failing
        )
    }

    private func application(_ windows: [FixtureNode], failing: Set<FixtureNode.Attribute> = []) -> FixtureNode {
        FixtureNode(999_999, children: windows, failing: failing)
    }

    @Test func findsBannersAndStacksInDocumentOrderWithoutEnteringThem() {
        let stack = FixtureNode(
            11, subrole: "AXNotificationCenterAlertStack",
            actions: ["AXPress", action("Show Details"), action("Clear All")]
        )
        let reader = FixtureReader()
        let scan = NotificationTreeWalker().scan(
            application: application([bannerWindow(notifications: [banner(10), stack])]),
            reader: reader, labels: english
        )
        #expect(scan.isComplete)
        #expect(scan.candidates.map(\.element.id) == [10, 11])
        #expect(scan.candidates.map(\.element.subrole) == ["AXNotificationCenterBanner", "AXNotificationCenterAlertStack"])
        #expect(!reader.childReads.contains(10), "must not read a notification's private text children")
        #expect(!reader.childReads.contains(11))
    }

    @Test func neverEntersWidgetWindows() {
        // Desktop widgets live in Notification Center's own windows; even a
        // notification-shaped element inside one is out of scope.
        let widget = FixtureNode(100, subrole: "AXStandardWindow", title: "Weather", children: [banner(101)])
        let untitled = FixtureNode(200, children: [banner(201)])
        let panel = FixtureNode(300, subrole: "AXStandardWindow", title: "Notification Center", children: [
            FixtureNode(301, subrole: "AXNotificationCenterAlert", actions: [action("Close")]),
        ])
        let reader = FixtureReader()
        let scan = NotificationTreeWalker().scan(
            application: application([widget, untitled, panel]), reader: reader, labels: english
        )
        #expect(scan.isComplete)
        #expect(scan.candidates.map(\.element.id) == [301])
        #expect(!reader.childReads.contains(100))
        #expect(!reader.childReads.contains(200))
    }

    @Test func neverEntersWidgetContent() {
        // Per third-party probes on macOS 26, the open panel is the banner
        // window and holds widgets next to the notification list, and widget
        // content carries `widget-local:` identifiers. However large it is,
        // it is skipped as legitimately empty, so it cannot use up the budget.
        let widget = FixtureNode(
            20, identifier: "widget-local:com.apple.weather",
            children: (1...5_000).map { FixtureNode(UInt(20_000 + $0)) } + [banner(21)]
        )
        let editor = FixtureNode(30, identifier: "widget-editor-button", children: [banner(31)])
        let panel = FixtureNode(0, subrole: "AXSystemDialog", title: "Notification Center", children: [
            FixtureNode(1, subrole: "AXHostingView", children: [FixtureNode(2, children: [banner(10)]), widget, editor]),
        ])
        // Desktop widget windows are skipped the same way even if they look
        // like banner windows, wherever the identifier sits.
        let desktop = FixtureNode(100, subrole: "AXSystemDialog", children: [
            FixtureNode(101, identifier: "widget-local:com.apple.clock", children: [banner(102)]),
        ])
        let desktopWindow = FixtureNode(
            200, subrole: "AXSystemDialog", identifier: "widget-local:com.apple.calendar", children: [banner(201)]
        )
        let reader = FixtureReader()
        let scan = NotificationTreeWalker(nodeBudget: 50).scan(
            application: application([panel, desktop, desktopWindow]), reader: reader, labels: english
        )
        #expect(scan.isComplete)
        #expect(scan.candidates.map(\.element.id) == [10])
        for skipped: UInt in [20, 30, 101, 200] {
            #expect(!reader.childReads.contains(skipped))
        }
    }

    @Test func anUnreadableIdentifierNeitherSkipsNorFails() {
        // The identifier only decides what to skip: an element whose
        // identifier cannot be read is entered as usual.
        let group = FixtureNode(20, children: [banner(21)], failing: [.identifier])
        let scan = NotificationTreeWalker().scan(
            application: application([bannerWindow(notifications: [group])]), reader: FixtureReader(), labels: english
        )
        #expect(scan.isComplete)
        #expect(scan.candidates.map(\.element.id) == [21])
    }

    @Test func recognizesThePanelByItsLocalizedTitle() {
        let panel = FixtureNode(300, title: "通知中心", children: [
            FixtureNode(301, subrole: "AXNotificationCenterAlert", actions: [action("关闭")]),
        ])
        let widget = FixtureNode(400, title: "天气", children: [banner(401)])
        let scan = NotificationTreeWalker().scan(
            application: application([widget, panel]), reader: FixtureReader(), labels: chinese
        )
        #expect(scan.candidates.map(\.element.id) == [301])
    }

    @Test func bannerWindowsComeFirstAndEachWindowSubroleIsReadOnce() {
        let panel = FixtureNode(300, title: "Notification Center", children: [
            FixtureNode(301, subrole: "AXNotificationCenterAlert", actions: [action("Close")]),
        ])
        let widget = FixtureNode(400, subrole: "AXStandardWindow", title: "Clock")
        let reader = FixtureReader()
        let scan = NotificationTreeWalker().scan(
            application: application([panel, widget, bannerWindow(notifications: [banner(10)])]),
            reader: reader, labels: english
        )
        #expect(scan.candidates.map(\.element.id) == [10, 301])
        for window: UInt in [300, 400, 0] {
            #expect(reader.subroleReads.filter { $0 == window }.count == 1)
        }
        #expect(!reader.titleReads.contains(0), "a banner window is known by its subrole alone")
    }

    @Test func untaggedGroupsWithADismissActionAreNotCandidates() {
        // No label-only fallback: only Notification Center's own subroles count.
        let group = FixtureNode(20, actions: ["AXPress", action("Close")])
        let button = FixtureNode(21, subrole: "AXCloseButton", actions: ["AXPress", action("Close")])
        let scan = NotificationTreeWalker().scan(
            application: application([bannerWindow(notifications: [group, button])]),
            reader: FixtureReader(), labels: english
        )
        #expect(scan.isComplete)
        #expect(scan.candidates.isEmpty)
    }

    @Test func noWindowsIsACompleteEmptyWalk() {
        let scan = NotificationTreeWalker().scan(application: application([]), reader: FixtureReader(), labels: english)
        #expect(scan.isComplete)
        #expect(scan.candidates.isEmpty)
    }

    @Test func legitimatelyEmptyReadsKeepTheWalkComplete() {
        // No subrole, no title, no children: unsupported or valueless
        // attributes are not failures.
        let bare = FixtureNode(50)
        let window = bannerWindow(notifications: [bare, banner(10)])
        let scan = NotificationTreeWalker().scan(
            application: application([window, FixtureNode(60)]), reader: FixtureReader(), labels: english
        )
        #expect(scan.isComplete)
        #expect(scan.candidates.map(\.element.id) == [10])
    }

    @Test func failedReadsMakeTheWalkIncomplete() {
        let walker = NotificationTreeWalker()

        let unreadableWindows = walker.scan(
            application: application([bannerWindow(notifications: [banner(10)])], failing: [.children]),
            reader: FixtureReader(), labels: english
        )
        #expect(!unreadableWindows.isComplete)
        #expect(unreadableWindows.candidates.isEmpty)

        let unclassifiedWindow = FixtureNode(100, children: [banner(101)], failing: [.subrole])
        let windowSubrole = walker.scan(
            application: application([unclassifiedWindow, bannerWindow(notifications: [banner(10)])]),
            reader: FixtureReader(), labels: english
        )
        #expect(!windowSubrole.isComplete)
        #expect(windowSubrole.candidates.map(\.element.id) == [10])

        let unreadableTitle = FixtureNode(100, failing: [.title])
        #expect(!walker.scan(application: application([unreadableTitle]), reader: FixtureReader(), labels: english).isComplete)

        // A branch whose children cannot be read hides whatever it holds; the
        // rest of the walk still reports what it found.
        let brokenBranch = FixtureNode(40, failing: [.children])
        let children = walker.scan(
            application: application([bannerWindow(notifications: [brokenBranch, banner(10)])]),
            reader: FixtureReader(), labels: english
        )
        #expect(!children.isComplete)
        #expect(children.candidates.map(\.element.id) == [10])

        // An element whose subrole cannot be read might be a notification:
        // incomplete, and never entered.
        let unknown = FixtureNode(41, children: [banner(42)], failing: [.subrole])
        let reader = FixtureReader()
        let subrole = walker.scan(
            application: application([bannerWindow(notifications: [unknown])]), reader: reader, labels: english
        )
        #expect(!subrole.isComplete)
        #expect(subrole.candidates.isEmpty)
        #expect(!reader.childReads.contains(41))

        // A notification whose actions cannot be read still counts as present.
        let actions = walker.scan(
            application: application([bannerWindow(notifications: [banner(10, failing: [.actions])])]),
            reader: FixtureReader(), labels: english
        )
        #expect(!actions.isComplete)
        #expect(actions.candidates.map(\.element.id) == [10])
        #expect(actions.candidates.first?.element.actions == [])
    }

    @Test func depthAndNodeBudgetsTruncateTheWalkAsIncomplete() {
        // A 100-deep chain with a banner at the bottom stays out of reach.
        var node = banner(1_000)
        for id in (1...100).reversed() { node = FixtureNode(UInt(id), children: [node]) }
        let deep = NotificationTreeWalker(maxDepth: 12).scan(
            application: application([bannerWindow(id: 5_000, notifications: [node])]),
            reader: FixtureReader(), labels: english
        )
        #expect(!deep.isComplete)
        #expect(deep.candidates.isEmpty)

        let wide = FixtureNode(0, subrole: "AXSystemDialog", children: (1...5_000).map { FixtureNode(UInt($0)) } + [banner(9_000)])
        let reader = FixtureReader()
        let budgeted = NotificationTreeWalker(nodeBudget: 100).scan(
            application: application([wide]), reader: reader, labels: english
        )
        #expect(!budgeted.isComplete)
        #expect(budgeted.candidates.isEmpty)
        #expect(reader.subroleReads.count <= 100)
    }
}
