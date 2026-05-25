// Resolved at build time from the repo's CHANGELOG.md so the marketing page
// always reflects the most recently shipped release. Vite inlines the file
// contents via the `?raw` query, so no fs access is needed at runtime.

import changelog from '../../../CHANGELOG.md?raw';

const FALLBACK = '1.0.0';

// Match the first `## [x.y.z]` heading; skip `[Unreleased]`.
const match = changelog.match(/^##\s*\[(\d+\.\d+\.\d+)\]/m);
export const latestVersion = match?.[1] ?? FALLBACK;
