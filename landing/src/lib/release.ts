// Stable release metadata resolved at build time from the mixed-channel feed.
import { latestStableRelease, latestVersion } from './version';

export const REPO = 'https://github.com/ZingerLittleBee/AnyDoor';
export const RELEASES = `${REPO}/releases`;

// Direct .dmg asset for the latest release. `scripts/release.sh` always uploads
// both AnyDoor-<ver>.dmg and AnyDoor-<ver>.zip to the GitHub release.
export const dmgUrl = `${RELEASES}/download/v${latestVersion}/AnyDoor-${latestVersion}.dmg`;

// The .dmg wraps the same .app and is approximately the enclosure zip size.
const bytes = latestStableRelease.downloadBytes;
export const downloadSizeMB = bytes ? (bytes / 1_000_000).toFixed(1) : null;
