// Release metadata resolved at build time so the marketing page can't drift
// from the actual shipped artifacts. Vite inlines the repo's appcast.xml via
// the `?raw` query; no runtime fs access is needed.

import appcast from '../../../appcast.xml?raw';
import { latestVersion } from './version';

export const REPO = 'https://github.com/ZingerLittleBee/AnyDoor';
export const RELEASES = `${REPO}/releases`;

// Direct .dmg asset for the latest release. `scripts/release.sh` always uploads
// both AnyDoor-<ver>.dmg and AnyDoor-<ver>.zip to the GitHub release.
export const dmgUrl = `${RELEASES}/download/v${latestVersion}/AnyDoor-${latestVersion}.dmg`;

// Approximate download size, derived from the first <enclosure length="…"> in
// appcast.xml (the Sparkle .zip; the .dmg wraps the same .app and is ~the same
// size). Reported in decimal MB to match how download sizes are usually shown.
const lenMatch = appcast.match(/<enclosure[^>]*\blength="(\d+)"/);
const bytes = lenMatch ? Number.parseInt(lenMatch[1], 10) : 0;
export const downloadSizeMB = bytes ? (bytes / 1_000_000).toFixed(1) : null;
