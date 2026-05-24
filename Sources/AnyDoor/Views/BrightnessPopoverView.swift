import SwiftUI
import CoreGraphics

struct BrightnessPopoverView: View {
    @State private var service = DisplayBrightnessService.shared
    var onHoverChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if service.displays.isEmpty {
                emptyState(text: "未检测到外置显示器", symbol: "display")
            } else if service.displays.allSatisfy({ !$0.supportsDDC }) {
                VStack(alignment: .leading, spacing: 4) {
                    emptyState(text: "未检测到支持 DDC 的外置显示器", symbol: "display.slash")
                    Text("DisplayPort/HDMI 通常可用，部分 USB-C 转接线不支持")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                ForEach(service.displays) { info in
                    DisplayBrightnessCard(info: info, service: service)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            Task { await service.refresh() }
        }
        .onHover { onHoverChange($0) }
    }

    private func emptyState(text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct DisplayBrightnessCard: View {
    let info: DisplayInfo
    @Bindable var service: DisplayBrightnessService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(info.name).font(.headline)
                if !info.supportsDDC {
                    Text("不支持 DDC")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if service.isLoading.contains(info.id) {
                    ProgressView().controlSize(.mini)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(service.levels[info.id] ?? 0.5) },
                        set: { service.setBrightness(Float($0), for: info.id) }
                    ),
                    in: 0...1
                )
                .controlSize(.large)
                .disabled(!info.supportsDDC)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity(info.supportsDDC ? 1.0 : 0.55)
    }
}
