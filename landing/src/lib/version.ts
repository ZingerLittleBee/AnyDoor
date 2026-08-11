// Resolved from the latest default-channel appcast item. Beta items may sort
// first in the mixed feed, but must never change Stable marketing metadata.

import appcast from '../../../appcast.xml?raw';
import { parseLatestStableRelease } from './appcast-metadata';

export const latestStableRelease = parseLatestStableRelease(appcast);
export const latestVersion = latestStableRelease.version;
