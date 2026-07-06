import SwiftUI

/// Step 7 — "Image conversion". A hand-drawn mock of the conversion window
/// that replays its core loop: a file badge flies into the drop zone (with the
/// dashed accent overlay of a live drag), lands as a basket row, the Convert
/// button runs, and the output appears in the history strip — mirroring the
/// real two-row toolbar, quality slider, and format picker.
struct OnboardingImageConversionStep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase {
        case empty, dragging, basket, converting, done
    }

    @State private var phase: Phase = .empty
    @State private var dragLanded = false

    private let fileName = "IMG_0042.png"

    private var hasItem: Bool {
        phase == .basket || phase == .converting || phase == .done
    }

    var body: some View {
        OnboardingDemoStage(tint: .cyan) {
            VStack(spacing: 8) {
                mockWindow

                Label {
                    LocalizedText(.onboardingImageConversionHint)
                } icon: {
                    Image(systemName: "photo.on.rectangle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .task { await runLoop() }
    }

    // MARK: Mock conversion window

    private var mockWindow: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            dropZone
                .frame(maxHeight: .infinity)
            Divider()
            historyStrip
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary, lineWidth: 1)
        }
        .onboardingAnimation(.easeInOut(duration: 0.25), reduceMotion: reduceMotion, value: hasItem)
    }

    // Two rows like the real toolbar: title + actions, then quality + format.
    private var toolbar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                LocalizedText(.imageConversionTitle)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                convertButton
            }

            HStack(spacing: 6) {
                LocalizedText(.imageConversionQuality)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                qualitySlider
                Text(verbatim: "85%")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                LocalizedText(.imageConversionTargetFormat)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Text(verbatim: "JPEG").font(.system(size: 10, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var convertButton: some View {
        HStack(spacing: 4) {
            if phase == .converting {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
            }
            LocalizedText(phase == .converting ? .imageConversionConverting : .imageConversionConvert)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(hasItem ? Color.white : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            hasItem ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onboardingAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion, value: phase == .converting)
    }

    private var qualitySlider: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 64, height: 3)
            .overlay(alignment: .leading) {
                Capsule().fill(Color.accentColor).frame(width: 64 * 0.85, height: 3)
            }
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 9, height: 9)
                    .shadow(radius: 0.8)
                    .offset(x: 64 * 0.85 - 4.5)
            }
    }

    // MARK: Drop zone / basket

    private var dropZone: some View {
        ZStack {
            if hasItem {
                basket
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    LocalizedText(.imageConversionDropTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // Dashed accent overlay shown while the mock drag is in flight,
            // like the live drop-target highlight.
            if phase == .dragging {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    }
                    .padding(6)
                    .transition(.opacity)

                fileBadge
                    .offset(x: dragLanded ? 0 : 120, y: dragLanded ? 0 : -54)
                    .opacity(dragLanded ? 1 : 0.4)
            }
        }
        .frame(maxWidth: .infinity)
        .onboardingAnimation(.easeInOut(duration: 0.25), reduceMotion: reduceMotion, value: phase == .dragging)
    }

    private var fileBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.cyan)
            Text(verbatim: fileName)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
    }

    private var basket: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L(.imageConversionBasketCount, 1))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                thumbnail
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: fileName)
                        .font(.system(size: 11, weight: .medium))
                    Text(verbatim: "PNG · 3.2 MB")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if phase == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onboardingAnimation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion, value: phase == .done)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [.cyan.opacity(0.45), .blue.opacity(0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 22, height: 22)
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
            }
    }

    // MARK: History strip

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            LocalizedText(.imageConversionHistoryTitle)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            if phase == .done {
                HStack(spacing: 8) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: fileName)
                            .font(.system(size: 11, weight: .medium))
                        Text(verbatim: "JPEG · 96 KB")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "folder").font(.system(size: 9)).foregroundStyle(.secondary)
                    Image(systemName: "doc.on.doc").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            } else {
                LocalizedText(.imageConversionHistoryEmpty)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingAnimation(.easeInOut(duration: 0.25), reduceMotion: reduceMotion, value: phase == .done)
    }

    // MARK: Animation loop

    private func runLoop() async {
        if reduceMotion {
            phase = .done
            dragLanded = true
            return
        }

        while !Task.isCancelled {
            phase = .empty
            dragLanded = false
            try? await Task.sleep(for: .milliseconds(700))
            if Task.isCancelled { return }

            phase = .dragging
            withAnimation(.easeInOut(duration: 0.65)) { dragLanded = true }
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }

            phase = .basket
            try? await Task.sleep(for: .milliseconds(800))
            if Task.isCancelled { return }

            phase = .converting
            try? await Task.sleep(for: .milliseconds(1100))
            if Task.isCancelled { return }

            phase = .done
            try? await Task.sleep(for: .milliseconds(2800))
        }
    }
}
