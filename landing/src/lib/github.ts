// Build-time GitHub star count, used as social proof near the hero CTA.
// Resolved when the page is rendered (build time for the prerendered page); on
// any failure — offline, rate-limited, shape mismatch — it returns null and the
// UI omits the proof, so the build can never break on a flaky network.

const REPO = 'ZingerLittleBee/AnyDoor';

export async function getStarCount(): Promise<number | null> {
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 3000);
    const res = await fetch(`https://api.github.com/repos/${REPO}`, {
      headers: { Accept: 'application/vnd.github+json', 'User-Agent': 'anydoor-landing' },
      signal: ctrl.signal,
    });
    clearTimeout(timer);
    if (!res.ok) return null;
    const data = (await res.json()) as { stargazers_count?: number };
    return typeof data.stargazers_count === 'number' ? data.stargazers_count : null;
  } catch {
    return null;
  }
}

// 1234 -> "1.2k", 12345 -> "12k", 980 -> "980".
export function formatStars(n: number): string {
  if (n >= 1000) return (n / 1000).toFixed(n >= 10000 ? 0 : 1).replace(/\.0$/, '') + 'k';
  return String(n);
}
