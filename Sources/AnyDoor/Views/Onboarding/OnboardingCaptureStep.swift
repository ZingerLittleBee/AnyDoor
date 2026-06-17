import SwiftUI

/// Step 4 — "Handle screenshots on the spot". A looping, non-functional demo:
/// a selection box is dragged out, the screen flashes, the shot flies into the
/// corner as a thumbnail, and a Quick Access overlay of actions expands.
struct OnboardingCaptureStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CapturePhase = .selecting
    @State private var selectedMode: CaptureMode = .region

    enum CapturePhase: Int, Comparable {
        case selecting, flash, thumbnail, overlay
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum CaptureMode: CaseIterable {
        case region, window, fullscreen, timer, recording, scrolling
        var symbol: String {
            switch self {
            case .region:     return "camera.viewfinder"
            case .window:     return "macwindow"
            case .fullscreen: return "rectangle.dashed"
            case .timer:      return "timer"
            case .recording:  return "record.circle"
            case .scrolling:  return "arrow.down.to.line"
            }
        }
        var titleKey: L10n.Key {
            switch self {
            case .region:     return .captureModeBarRegion
            case .window:     return .captureModeBarWindow
            case .fullscreen: return .captureModeBarFullscreen
            case .timer:      return .captureModeBarTimer
            case .recording:  return .captureModeBarRecording
            case .scrolling:  return .captureModeBarScrolling
            }
        }
    }

    private struct OverlayAction: Identifiable {
        let id = UUID()
        let symbol: String
        let titleKey: L10n.Key
    }

    private let overlayActions: [OverlayAction] = [
        OverlayAction(symbol: "doc.on.doc", titleKey: .captureOverlayCopy),
        OverlayAction(symbol: "square.and.arrow.down", titleKey: .captureOverlaySave),
        OverlayAction(symbol: "pencil.tip.crop.circle", titleKey: .captureOverlayEdit),
        OverlayAction(symbol: "pin", titleKey: .captureOverlayPin),
    ]

    var body: some View {
        OnboardingDemoStage(tint: .orange) {
            VStack(spacing: 10) {
                modeBar
                GeometryReader { geo in stage(in: geo.size) }
                Label {
                    LocalizedText(.onboardingCaptureDemoCaption)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
        }
        .task { await runLoop() }
    }

    // MARK: Mode bar

    private var modeBar: some View {
        // Horizontal scroll so the six mode chips never clip when the longer
        // English labels exceed the content width.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(CaptureMode.allCases, id: \.self) { mode in
                    OnboardingChip(
                        title: L(mode.titleKey),
                        symbol: mode.symbol,
                        selected: mode == selectedMode,
                        tint: .orange
                    )
                    .contentShape(Capsule())
                    .onTapGesture {
                        if reduceMotion { selectedMode = mode }
                        else { withAnimation(.easeInOut(duration: 0.2)) { selectedMode = mode } }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Stage

    private func stage(in size: CGSize) -> some View {
        let w = size.width
        let h = size.height
        let isThumb = phase >= .thumbnail
        let shotSize = isThumb ? CGSize(width: 96, height: 62) : CGSize(width: w * 0.52, height: h * 0.56)
        let shotCenter = isThumb ? CGPoint(x: w - 58, y: h - 40) : CGPoint(x: w * 0.46, y: h * 0.48)

        return ZStack(alignment: .topLeading) {
            // Mock desktop
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [.orange.opacity(0.12), .purple.opacity(0.10)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .topLeading) { mockWindowChrome.padding(12) }

            // The shot: a dashed selection while selecting, a solid thumbnail once captured
            shot(isThumb: isThumb)
                .frame(width: shotSize.width, height: shotSize.height)
                .position(shotCenter)
                .onboardingAnimation(.spring(response: 0.5, dampingFraction: 0.8), reduceMotion: reduceMotion, value: phase)

            // Timer countdown badge
            if selectedMode == .timer && phase == .selecting {
                Text("3")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.black.opacity(0.55), in: Circle())
                    .position(x: w * 0.46, y: h * 0.48)
                    .transition(.scale.combined(with: .opacity))
            }

            // Quick Access overlay
            if phase == .overlay {
                overlay
                    .position(x: w - 58, y: h - 94)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }

            // Capture flash
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white)
                .opacity(phase == .flash ? 0.85 : 0)
                .allowsHitTesting(false)
                .onboardingAnimation(.easeOut(duration: 0.18), reduceMotion: reduceMotion, value: phase)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func shot(isThumb: Bool) -> some View {
        RoundedRectangle(cornerRadius: isThumb ? 7 : 4, style: .continuous)
            .fill(isThumb
                  ? AnyShapeStyle(LinearGradient(colors: [.blue.opacity(0.6), .teal.opacity(0.5)],
                                                 startPoint: .top, endPoint: .bottom))
                  : AnyShapeStyle(Color.orange.opacity(0.10)))
            .overlay {
                RoundedRectangle(cornerRadius: isThumb ? 7 : 4, style: .continuous)
                    .strokeBorder(isThumb ? Color.white.opacity(0.8) : Color.orange,
                                  style: StrokeStyle(lineWidth: isThumb ? 1.5 : 1.5, dash: isThumb ? [] : [5, 3]))
            }
            .overlay {
                if !isThumb {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            .shadow(color: .black.opacity(isThumb ? 0.25 : 0), radius: isThumb ? 6 : 0, y: isThumb ? 3 : 0)
    }

    private var overlay: some View {
        HStack(spacing: 6) {
            ForEach(overlayActions) { action in
                Image(systemName: action.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 24)
                    .background(.regularMaterial, in: Circle())
                    .help(L(action.titleKey))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        .help(L(.onboardingCaptureOverlayHint))
    }

    private var mockWindowChrome: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(.red.opacity(0.7)).frame(width: 6, height: 6)
                Circle().fill(.yellow.opacity(0.7)).frame(width: 6, height: 6)
                Circle().fill(.green.opacity(0.7)).frame(width: 6, height: 6)
            }
            RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.18)).frame(width: 120, height: 8)
            RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.12)).frame(width: 90, height: 8)
        }
    }

    // MARK: Demo timeline

    private func runLoop() async {
        if reduceMotion {
            phase = .overlay
            return
        }
        while !Task.isCancelled {
            setPhase(.selecting)
            try? await Task.sleep(for: .milliseconds(950))
            setPhase(.flash)
            try? await Task.sleep(for: .milliseconds(180))
            setPhase(.thumbnail)
            try? await Task.sleep(for: .milliseconds(260))
            setPhase(.overlay)
            try? await Task.sleep(for: .milliseconds(2400))
        }
    }

    private func setPhase(_ new: CapturePhase) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { phase = new }
    }
}
