import SwiftUI

/// Root SwiftUI view shown inside the Bluetooth Battery `HoverPopover`.
///
/// Lists every connected accessory macOS reports a battery level for. Earbuds
/// render their left / right / case triple; everything else shows a single
/// level badge. Data comes from `BluetoothBatteryService.shared`, refreshed on
/// hover (see `MenuBarView.mountPopoverContent`).
struct BluetoothBatteryPopoverView: View {
    private static let popoverWidth: CGFloat = 300

    @Bindable var service: BluetoothBatteryService
    var onHoverChange: @MainActor (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: Self.popoverWidth)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHoverSafe(perform: onHoverChange)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "battery.100")
                .foregroundStyle(.secondary)
            LocalizedText(.builtinBluetoothBattery)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if service.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await service.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L(.bluetoothBatteryRefresh))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if service.isRefreshing && service.devices.isEmpty {
            centered { ProgressView(L(.bluetoothBatteryReading)) }
        } else if service.devices.isEmpty {
            centered {
                LocalizedText(service.lastError == nil ? .bluetoothBatteryEmpty : .bluetoothBatteryError)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(service.devices) { device in
                        BluetoothBatteryRow(device: device)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
        }
    }

    private func centered<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        VStack {
            inner()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 28)
    }
}

// MARK: - Device row

private struct BluetoothBatteryRow: View {
    let device: BluetoothBatteryDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if device.isEarbuds {
                    earbudsLevels
                }
            }
            Spacer(minLength: 8)
            if !device.isEarbuds, let main = device.main {
                BatteryBadge(level: main)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var earbudsLevels: some View {
        HStack(spacing: 8) {
            if let left = device.left { MiniLevel(label: "L", level: left) }
            if let right = device.right { MiniLevel(label: "R", level: right) }
            if let caseLevel = device.caseLevel { MiniLevel(label: L(.bluetoothBatteryCase), level: caseLevel) }
        }
    }
}

// MARK: - Battery badges

private struct BatteryBadge: View {
    let level: Int

    var body: some View {
        HStack(spacing: 4) {
            // Number first, icon last: the badge is right-aligned in the row, so
            // a trailing fixed-width icon keeps every icon's right edge aligned
            // and the percentages right-aligned against it (regardless of 2- vs
            // 3-digit levels like 85% / 100%).
            Text("\(level)%")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: level.batterySymbolName)
                .font(.system(size: 14))
                .foregroundStyle(BatteryPalette.color(level))
        }
    }
}

private struct MiniLevel: View {
    let label: String
    let level: Int

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(level)%")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(BatteryPalette.color(level))
        }
    }
}

private enum BatteryPalette {
    static func color(_ level: Int) -> Color {
        switch level {
        case ...20: return .red
        case ...35: return .yellow
        default:    return .green
        }
    }
}
