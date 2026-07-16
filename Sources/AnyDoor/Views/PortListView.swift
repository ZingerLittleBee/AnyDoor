import PluginInterface
import SwiftUI

struct PortListView: View {
    @Bindable var inventory: PortInventory

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(inventory.filteredRecords) { record in
                    PortRowView(record: record, inventory: inventory)
                }
            }
            .overlayScrollers()
        }
    }
}

struct PortRowView: View {
    let record: PortRecord
    @Bindable var inventory: PortInventory
    @State private var isHovered = false

    /// Shared width for the trailing slot so kill / error / placeholder all align
    /// and the row doesn't jitter as the hover state toggles the button in and out.
    private static let trailingSlotWidth: CGFloat = 22

    private var rowState: PortStatusDot.State {
        if inventory.failedKillPIDs[record.pid] != nil { return .failed }
        if inventory.killingPIDs.contains(record.pid)  { return .killing }
        return .listening
    }

    var body: some View {
        HStack(spacing: 12) {
            PortStatusDot(state: rowState).frame(width: 10)
            Text(verbatim: ":\(record.port)")
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .frame(minWidth: 60, alignment: .leading)
            Text(record.processName)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: "PID \(record.pid)")
                .font(.caption)
                .foregroundStyle(.secondary)
            trailingControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(rowBackground, in: .rect(cornerRadius: 6))
        .onHoverSafe { isHovered = $0 }
        .help(tooltipText)
        .contextMenu { PortRecordContextMenu(record: record) }
    }

    private var rowBackground: Color {
        isHovered ? Color.primary.opacity(0.06) : .clear
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
                inventory.dismissError(for: record.pid)
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: Self.trailingSlotWidth, height: Self.trailingSlotWidth)
            }
            .buttonStyle(.plain)
            .help(L(.portActionClearError))
            .accessibilityLabel(L(.portActionClearError))
        case .listening:
            if isHovered {
                Button {
                    Task { await inventory.kill(pid: record.pid) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: Self.trailingSlotWidth, height: Self.trailingSlotWidth)
                }
                .buttonStyle(.plain)
                .help(L(.portActionKillPID, Int64(record.pid)))
            } else {
                Color.clear.frame(width: Self.trailingSlotWidth, height: Self.trailingSlotWidth)
            }
        }
    }

    private var tooltipText: String {
        var lines: [String] = [record.processName]
        if let cmd = record.commandLine, !cmd.isEmpty, cmd != record.processName {
            lines.append(cmd)
        }
        if let path = record.executablePath, !path.isEmpty { lines.append(path) }
        lines.append("")
        lines.append(L(.portTooltipBindAddress))
        for bind in record.binds {
            lines.append("  \(bind.address) (\(bind.family.rawValue))")
        }
        if let failure = inventory.failedKillPIDs[record.pid] {
            lines.append("")
            switch failure.reason {
            case .permissionDenied:
                lines.append(L(.portTooltipKillFailedPermission))
            case .processGone:
                lines.append(L(.portTooltipKillFailedGone))
            case .other(let code):
                lines.append(L(.portTooltipKillFailedOther, Int64(code)))
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct PortRecordContextMenu: View {
    let record: PortRecord

    var body: some View {
        Button {
            PortActions.copyToPasteboard(String(record.port))
        } label: {
            Label(L(.portActionCopyPort), systemImage: "number")
        }
        Button {
            PortActions.copyToPasteboard(String(record.pid))
        } label: {
            Label(L(.portActionCopyPID), systemImage: "number")
        }
        Button {
            PortActions.copyToPasteboard(PortActions.commandText(for: record))
        } label: {
            Label(L(.portActionCopyCommand), systemImage: "terminal")
        }
        Button {
            PortActions.copyToPasteboard(PortActions.localhostURLString(for: record))
        } label: {
            Label(L(.portActionCopyLocalhost), systemImage: "link")
        }
        Button {
            PortActions.openLocalhost(for: record)
        } label: {
            Label(L(.portActionOpenLocalhost), systemImage: "safari")
        }
    }
}

struct PortStatusDot: View {
    enum State { case listening, killing, failed }
    let state: State

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch state {
        case .listening: return .green
        case .killing:   return .gray
        case .failed:    return .red
        }
    }
}
