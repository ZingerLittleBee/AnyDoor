# PROTOTYPE — Onboarding UI refactor (TourKit)

**Question:** Should the first-run onboarding move from the current
"sidebar rail + live demo pane" layout to a TourKit-style slideshow card
(https://github.com/rampatra/TourKit)?

**How to view:** `swift run AnyDoor` (DEBUG build) → Settings → 通用 →
reopen onboarding (or wipe the `onboarding.completed.v1` UserDefaults key).
Cycle variants with the floating bar at the bottom of the window, or ←/→.
Selected variant persists in `prototype.onboardingVariant`.

**Variants:**

- **A — 现状 · 侧边栏** — the existing `OnboardingView`, untouched (baseline).
- **B — TourKit 原版 · 静态图** — the real `TourSlideshowView`. TourPage only
  accepts static images, so the six live demos are snapshotted at frame 0 via
  `ImageRenderer` (entry animations never run). Judged for TourKit's stock
  structure/chrome, not the artwork quality.
- **C — TourKit 风格 · 实时演示** — TourKit's structure rebuilt natively
  (dark full-bleed card, top visual, gradient blend, TourKit's `PageIndicator`,
  glass back/close, centered text, per-step tinted capsule CTA) hosting the
  live animated demos. The realistic refactor candidate if the TourKit look wins.

**Known prototype limitations:**

- Variant B images are static and may look sparse (demos animate in on appear).
- Variant B renders the stock dark TourKit card centered on a dark surround
  inside the existing 680×520 window; real adoption would size the window to
  the card (`TourKitWindowController` does this itself).
- Adopting stock TourKit loses: per-step jump navigation (rail clicks), the
  Skip affordance text, live/interactive demos, Reduce Motion handling, and
  light-mode appearance (TourKit is hard-coded dark).

**Verdict:** _pending — fill in which variant (or which mix) won and why,
then clean up._

**Cleanup checklist once decided:**

- [ ] Delete `OnboardingPrototype.swift` and this file
- [ ] Revert root swap in `OnboardingWindowController.show()` to `OnboardingView { … }`
- [ ] Drop the TourKit dependency from `Package.swift` (keep it only if B won as-is)
- [ ] Fold the winning design into `OnboardingView` properly (rewrite, not promote)
