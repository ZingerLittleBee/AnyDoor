// Writes src/generated/appcast.xml, the feed that src/lib/version.ts reads the
// latest Stable release from at build time.
//
// ANYDOOR_APPCAST names a local appcast to use; the release pipeline points it
// at the Release's own appcast.xml asset. Otherwise the live feed is fetched,
// and a previously generated copy is kept with a warning when that fails.
// Run with: bun scripts/prepare-appcast.mjs
import { copyFile, mkdir, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const FEED_URL = 'https://anydoor.dev/appcast.xml';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const target = join(root, 'src', 'generated', 'appcast.xml');

await mkdir(dirname(target), { recursive: true });

const source = process.env.ANYDOOR_APPCAST;
if (source) {
  await copyFile(source, target);
  console.log(`appcast: ${source}`);
} else {
  try {
    const response = await fetch(FEED_URL, {
      headers: { 'Cache-Control': 'no-cache' },
      signal: AbortSignal.timeout(30_000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    await writeFile(target, await response.text());
    console.log(`appcast: ${FEED_URL}`);
  } catch (error) {
    const existing = await stat(target).catch(() => null);
    if (!existing) {
      console.error(`cannot fetch ${FEED_URL} (${error}); set ANYDOOR_APPCAST to a local appcast.xml`);
      process.exit(1);
    }
    console.warn(`warning: cannot fetch ${FEED_URL} (${error}); keeping the existing ${target}`);
  }
}
