export interface StableReleaseMetadata {
  version: string;
  downloadBytes: number;
}

const FALLBACK: StableReleaseMetadata = { version: '1.0.0', downloadBytes: 0 };

function elementText(item: string, tag: string): string | null {
  const match = item.match(new RegExp(`<${tag}>([^<]+)</${tag}>`));
  return match?.[1]?.trim() ?? null;
}

function compareBuilds(left: string, right: string): number {
  const leftParts = left.split('.').map(Number);
  const rightParts = right.split('.').map(Number);
  for (let index = 0; index < Math.max(leftParts.length, rightParts.length); index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

export function parseLatestStableRelease(appcast: string): StableReleaseMetadata {
  const items = [...appcast.matchAll(/<item>([\s\S]*?)<\/item>/g)]
    .map((match) => match[1])
    .filter((item): item is string => item !== undefined && !item.includes('<sparkle:channel>'))
    .flatMap((item) => {
      const build = elementText(item, 'sparkle:version');
      const enclosure = item.match(/<enclosure\b[^>]*>/)?.[0];
      const url = enclosure?.match(/\burl="([^"]+)"/)?.[1];
      const version = url?.match(/\/download\/v(\d+\.\d+\.\d+)\/AnyDoor-\1\.zip$/)?.[1];
      if (!build || !version || !enclosure) return [];
      const length = enclosure.match(/\blength="(\d+)"/)?.[1];
      return [{ build, version, downloadBytes: length ? Number.parseInt(length, 10) : 0 }];
    });

  const latest = items.sort((left, right) => compareBuilds(right.build, left.build))[0];
  return latest
    ? { version: latest.version, downloadBytes: latest.downloadBytes }
    : FALLBACK;
}
