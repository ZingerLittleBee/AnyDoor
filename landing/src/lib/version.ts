// Resolved from the latest default-channel appcast item. Beta items may sort
// first in the mixed feed, but must never change Stable marketing metadata.
// scripts/prepare-appcast.mjs writes the feed before every build.

import appcast from '../generated/appcast.xml?raw';
import { parseLatestStableRelease } from './appcast-metadata';

export const latestStableRelease = parseLatestStableRelease(appcast);
export const latestVersion = latestStableRelease.version;
