import SwiftUI

struct PortTreeView: View {
    @Bindable var inventory: PortInventory

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(inventory.groupedByProcess) { group in
                    PortProcessGroupRow(group: group, inventory: inventory)
                }
            }
            .overlayScrollers()
        }
    }
}

private struct PortProcessGroupRow: View {
    let group: ProcessGroup
    @Bindable var inventory: PortInventory
    @State private var isExpanded: Bool = false
    @State private var isHeaderHovered: Bool = false

    /// Shared width for the trailing slot so kill / error / placeholder all align
    /// and the row doesn't jitter as the hover state toggles the button in and out.
    private static let trailingSlotWidth: CGFloat = 22

    private var rowState: PortStatusDot.State {
        if inventory.failedKillPIDs[group.pid] != nil { return .failed }
        if inventory.killingPIDs.contains(group.pid)  { return .killing }
        return .listening
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                ForEach(group.ports) { record in
                    leaf(record)
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .frame(width: 12)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            PortStatusDot(state: rowState).frame(width: 10)
            Text(group.processName)
                .fontWeight(.semibold)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "PID \(group.pid)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !isExpanded {
                Text(verbatim: "\(group.ports.count)")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
            trailingControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(headerBackground, in: .rect(cornerRadius: 6))
        .onHoverSafe { isHeaderHovered = $0 }
    }

    private var headerBackground: Color {
        isHeaderHovered ? Color.primary.opacity(0.06) : .clear
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch rowState {
        case .killing:
            ProgressView()
                .controlSize(.small)
                .frame(width: Self.trailingSlotWidth, height: Self.trailingSlotWidth)
        case .failed:
            Button {
                inventory.dismissError(for: group.pid)
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: Self.trailingSlotWidth, height: Self.trailingSlotWidth)
            }
            .buttonStyle(.plain)
            .help(L(.portActionClearError))
            .accessibilityLabel(L(.portActionClearError))
        case .listening:
            if isHeaderHovered {
                Button {
                    Task { await inventory.kill(pid: group.pid) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: Self.trailingSlotWidth, height: Self.trailingSlotWidth)
                }
                .buttonStyle(.plain)
                .help(L(.portActionKillPID, Int64(group.pid)))
            } else {
                Color.clear.frame(width: Self.trailingSlotWidth, height: Self.trailingSlotWidth)
            }
        }
    }

    private func leaf(_ record: PortRecord) -> some View {
        HStack(spacing: 12) {
            Spacer().frame(width: 28)
            Text(verbatim: ":\(record.port)")
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 60, alignment: .leading)
            Text(bindSummary(for: record))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(record.binds.map { "\($0.address) (\($0.family.rawValue))" }.joined(separator: "\n"))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contextMenu { PortRecordContextMenu(record: record) }
    }

    private func bindSummary(for record: PortRecord) -> String {
        let binds = record.binds
        switch binds.count {
        case 0:
            return ""
        case 1:
            return binds[0].address
        case 2:
            if Set(binds.map(\.family)) == Set([.ipv4, .ipv6]) {
                let v4 = binds.first(where: { $0.family == .ipv4 })?.address ?? ""
                let v6 = binds.first(where: { $0.family == .ipv6 })?.address ?? ""
                return "\(v4) · \(v6)"
            }
            return binds.map(\.address).joined(separator: " · ")
        default:
            return L(.portBindCount, binds.count)
        }
    }
}
