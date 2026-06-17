import SwiftUI

// MARK: - Demo stage

/// The "screen" the per-step mock UI is drawn onto: a rounded canvas with a soft
/// tinted backdrop and a hairline border. Keeps every step's demo visually
/// consistent and isolated from the surrounding chrome.
struct OnboardingDemoStage<Content: View>: View {
    var tint: Color = .accentColor
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.10), tint.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
    }
}

// MARK: - Mock menu bar

/// A simplified macOS menu-bar strip with the AnyDoor icon highlighted, used to
/// anchor the panel mock beneath it.
struct OnboardingMenuBarStrip: View {
    var iconHighlighted: Bool
    var iconSymbol: String = MenuBarIcon.defaultName

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi").font(.system(size: 11))
            Image(systemName: "battery.100").font(.system(size: 11))
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(iconHighlighted ? 0.22 : 0))
                    .frame(width: 24, height: 20)
                Image(systemName: iconSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconHighlighted ? Color.accentColor : .primary)
            }
            Image(systemName: "magnifyingglass").font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }
}

// MARK: - Mock panel row

/// The trailing control shown on a mock panel row.
enum OnboardingRowAccessory: Equatable {
    case toggle(Bool)
    case hotkey(String)
    case chevron
    case none
}

/// A simplified version of `PanelRowView`: icon badge + title + trailing control.
/// Hand-drawn (not the real row) so the mock has no live dependencies.
struct OnboardingMockRow: View {
    let symbol: String
    let title: String
    var tint: Color = .accentColor
    var accessory: OnboardingRowAccessory = .none

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.opacity(0.18))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            accessoryView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch accessory {
        case let .toggle(isOn):
            Capsule()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 30, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                        .shadow(radius: 0.5)
                }
        case let .hotkey(text):
            Text(text)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .chevron:
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Keycap & modifier glyph

/// A keyboard keycap used by the Hyper Key demo.
struct OnboardingKeycap: View {
    let label: String
    var width: CGFloat = 34
    var highlighted: Bool = false
    var pressed: Bool = false
    var tint: Color = .accentColor

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(highlighted ? tint.opacity(0.22) : Color(nsColor: .controlBackgroundColor))
            .frame(width: width, height: 32)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(highlighted ? tint.opacity(0.6) : Color.secondary.opacity(0.25), lineWidth: 1)
            }
            .overlay {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(highlighted ? tint : .secondary)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
            }
            .offset(y: pressed ? 2 : 0)
            .shadow(color: .black.opacity(pressed ? 0.05 : 0.12), radius: pressed ? 0.5 : 2, y: pressed ? 0.5 : 1.5)
    }
}

/// A single modifier glyph badge (⌃ ⌥ ⇧ ⌘) that "flies out" of the trigger key.
struct OnboardingModifierBadge: View {
    let glyph: String
    var tint: Color = .accentColor

    var body: some View {
        Text(glyph)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint.gradient, in: Circle())
            .shadow(color: tint.opacity(0.4), radius: 4, y: 2)
    }
}

// MARK: - Chip / pill

/// A small selectable pill used for mode bars and demo example switches.
struct OnboardingChip: View {
    let title: String
    var symbol: String? = nil
    var selected: Bool = false
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(selected ? Color.white : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            Capsule().fill(selected ? tint : Color.secondary.opacity(0.12))
        }
    }
}

// MARK: - Reduce Motion helper

extension View {
    /// Applies `animation` to `value`, but disables it when Reduce Motion is on.
    func onboardingAnimation(_ animation: Animation?, reduceMotion: Bool, value: some Equatable) -> some View {
        self.animation(reduceMotion ? nil : animation, value: value)
    }
}
