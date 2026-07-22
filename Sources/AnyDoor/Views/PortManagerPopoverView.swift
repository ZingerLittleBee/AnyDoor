import PluginInterface
import PluginSupport
import SwiftUI
import AppKit

/// Root SwiftUI view shown inside the Port Manager `HoverPopover`.
///
/// Assembles the header (search + count badge), optional error banner, the
/// scrollable content area (PortListView / PortTreeView / loading / empty),
/// and the bottom toolbar (refresh + view-mode toggle). A `KeyboardMonitor`
/// helper is mounted as a background view so ⌘R / ⌘T / ESC work while the
/// popover holds key focus.
struct PortManagerPopoverView: View {
    private static let popoverWidth: CGFloat = 340
    private static let popoverHeight: CGFloat = 560

    @Bindable var inventory: PortInventory
    var onHoverChange: @MainActor (Bool) -> Void
    var onClose: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            PortManagerHeader(
                inventory: inventory,
                searchFocused: $searchFocused
            )
            Divider()
            if let err = inventory.lastError {
                PortScanErrorBanner(error: err) {
                    Task { await inventory.refresh(force: true) }
                }
            }
            content
            Divider()
            PortManagerToolbar(inventory: inventory)
        }
        .frame(width: Self.popoverWidth, height: Self.popoverHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            searchFocused = true
        }
        .onHoverSafe(perform: onHoverChange)
        .background(KeyboardMonitor(inventory: inventory, onClose: onClose))
    }

    @ViewBuilder
    private var content: some View {
        if inventory.isRefreshing && inventory.records.isEmpty {
            VStack {
                Spacer()
                ProgressView(L(.portScanning))
                Spacer()
            }
        } else if inventory.filteredRecords.isEmpty {
            VStack {
                Spacer()
                LocalizedText(.portNoMatch).foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            switch inventory.viewMode {
            case .list: PortListView(inventory: inventory)
            case .tree: PortTreeView(inventory: inventory)
            }
        }
    }
}

// MARK: - Header

private struct PortManagerHeader: View {
    @Bindable var inventory: PortInventory
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.secondary)
            TextField(L(.portSearchPlaceholder), text: $inventory.searchText)
                .textFieldStyle(.plain)
                .focused(searchFocused)
            ZStack {
                if inventory.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(inventory.filteredRecords.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

// MARK: - Toolbar

private struct PortManagerToolbar: View {
    @Bindable var inventory: PortInventory

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            PortToolbarButton(
                action: { Task { await inventory.refresh(force: true) } },
                label: L(.portToolbarRefresh),
                systemImage: "arrow.clockwise",
                shortcut: "⌘R"
            )
            PortToolbarButton(
                action: {
                    inventory.viewMode = (inventory.viewMode == .list) ? .tree : .list
                },
                label: inventory.viewMode == .list ? L(.portToolbarTreeView) : L(.portToolbarListView),
                systemImage: "list.bullet.indent",
                shortcut: "⌘T"
            )
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }
}

private struct PortToolbarButton: View {
    let action: () -> Void
    let label: String
    let systemImage: String
    let shortcut: String
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                Text(shortcut).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            // Make the entire row strip clickable (label + spacer + shortcut),
            // not just the text/icon. Idle rows stay transparent so the
            // popover's single .regularMaterial shows through and only hover
            // paints a neutral tint — matching the PortListView / PortTreeView
            // rows. (Previously each button carried an always-on interactive
            // glass surface, which rendered noticeably brighter than the list
            // above it in light mode.)
            .contentShape(Rectangle())
            .background(
                isHovered ? Color.primary.opacity(0.06) : .clear,
                in: .rect(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .onHoverSafe { isHovered = $0 }
    }
}

// MARK: - Error banner

private struct PortScanErrorBanner: View {
    let error: PortInventoryError
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message).font(.caption)
            Spacer()
            Button(action: retry) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(L(.portToolbarRefresh))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        // Flat yellow tint keeps the banner visually distinct from the
        // `.regularMaterial` parent background. Intentionally no clipShape:
        // the popover already rounds the outer envelope, and rounding this
        // strip would create misaligned corners against the header divider.
        .background(Color.yellow.opacity(0.22))
    }

    private var message: String {
        switch error {
        case .scanFailed(let detail):
            return L(.portErrorRefreshFailed, detail)
        }
    }
}

// MARK: - Keyboard monitor

/// Installs a local NSEvent key-down monitor while mounted. Handles ⌘R, ⌘T, ESC.
///
/// `NSEvent.addLocalMonitorForEvents` delivers its handler on the main thread,
/// so the closure body uses `MainThreadIsolation.run` to access the
/// `@MainActor`-isolated `PortInventory` directly without a `Task` hop. The
/// Coordinator itself is `@MainActor`-isolated to satisfy Swift 6 strict
/// concurrency when its properties are captured by the handler closure.
private struct KeyboardMonitor: NSViewRepresentable {
    @Bindable var inventory: PortInventory
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(inventory: inventory, onClose: onClose)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onClose = onClose
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        let inventory: PortInventory
        var onClose: () -> Void
        // The NSEvent monitor token is created and torn down on the main
        // thread; `nonisolated(unsafe)` lets `uninstall()` run safely.
        nonisolated(unsafe) private var monitor: Any?

        init(inventory: PortInventory, onClose: @escaping () -> Void) {
            self.inventory = inventory
            self.onClose = onClose
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func install() {
            uninstall()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // addLocalMonitorForEvents dispatches on the main thread, so we
                // can safely access @MainActor-isolated state via
                // `MainThreadIsolation.run`. We avoid carrying `event` across
                // the isolation boundary (NSEvent isn't Sendable) by extracting
                // only the bits we need and computing a bool result.
                let cmd = event.modifierFlags.contains(.command)
                let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
                let keyCode = event.keyCode
                let consumed: Bool = MainThreadIsolation.run {
                    guard let self else { return false }
                    if cmd && chars == "r" {
                        Task { await self.inventory.refresh(force: true) }
                        return true
                    }
                    if cmd && chars == "t" {
                        self.inventory.viewMode =
                            (self.inventory.viewMode == .list) ? .tree : .list
                        return true
                    }
                    if keyCode == 53 { // ESC
                        if self.inventory.searchText.isEmpty {
                            self.onClose()
                        } else {
                            self.inventory.searchText = ""
                        }
                        return true
                    }
                    return false
                }
                return consumed ? nil : event
            }
        }

        func uninstall() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }
    }
}
