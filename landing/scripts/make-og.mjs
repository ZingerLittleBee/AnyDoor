// Generates public/og.png (1200x630 social preview card) from an inline SVG.
// Run with: bun scripts/make-og.mjs   (or: node scripts/make-og.mjs)
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <defs>
    <radialGradient id="blue" cx="80%" cy="0%" r="70%">
      <stop offset="0%" stop-color="#0a84ff" stop-opacity="0.30"/>
      <stop offset="60%" stop-color="#0a84ff" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="purple" cx="0%" cy="40%" r="70%">
      <stop offset="0%" stop-color="#bf5af2" stop-opacity="0.22"/>
      <stop offset="60%" stop-color="#bf5af2" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="logo" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#0a84ff"/>
      <stop offset="100%" stop-color="#bf5af2"/>
    </linearGradient>
    <linearGradient id="accent" x1="0" y1="0" x2="1" y2="0.4">
      <stop offset="0%" stop-color="#5e9bff"/>
      <stop offset="60%" stop-color="#bf5af2"/>
      <stop offset="110%" stop-color="#ff375f"/>
    </linearGradient>
  </defs>

  <rect width="1200" height="630" fill="#050507"/>
  <rect width="1200" height="630" fill="url(#blue)"/>
  <rect width="1200" height="630" fill="url(#purple)"/>
  <rect x="0.5" y="0.5" width="1199" height="629" fill="none" stroke="#ffffff" stroke-opacity="0.06"/>

  <!-- Logo -->
  <g transform="translate(96, 150)">
    <rect width="96" height="96" rx="24" fill="url(#logo)"/>
    <g transform="translate(24, 22)" fill="none" stroke="#ffffff" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round">
      <path d="M8 52V14a4 4 0 0 1 4-4h24a4 4 0 0 1 4 4v38"/>
      <path d="M4 52h44"/>
      <circle cx="31" cy="34" r="2.2" fill="#ffffff" stroke="none"/>
    </g>
  </g>

  <!-- Wordmark -->
  <text x="216" y="222" font-family="SF Pro Display, Helvetica Neue, Arial, sans-serif" font-size="56" font-weight="700" fill="#f5f5f7" letter-spacing="-1">AnyDoor</text>

  <!-- Headline -->
  <text x="96" y="330" font-family="SF Pro Display, Helvetica Neue, Arial, sans-serif" font-size="76" font-weight="700" fill="#f5f5f7" letter-spacing="-2">One key. <tspan fill="url(#accent)">Any door.</tspan></text>

  <!-- Subtitle -->
  <text x="96" y="392" font-family="SF Pro Text, Helvetica Neue, Arial, sans-serif" font-size="30" font-weight="400" fill="#a1a1aa">A macOS menu bar control center driven by global hotkeys.</text>

  <!-- Feature pills -->
  <g font-family="SF Pro Text, Helvetica Neue, Arial, sans-serif" font-size="22" font-weight="500" fill="#c8c8d0">
    <g transform="translate(96, 458)">
      <rect width="232" height="50" rx="25" fill="#ffffff" fill-opacity="0.05" stroke="#ffffff" stroke-opacity="0.10"/>
      <text x="24" y="33">Global hotkeys</text>
    </g>
    <g transform="translate(344, 458)">
      <rect width="178" height="50" rx="25" fill="#ffffff" fill-opacity="0.05" stroke="#ffffff" stroke-opacity="0.10"/>
      <text x="24" y="33">Hyper Key</text>
    </g>
    <g transform="translate(538, 458)">
      <rect width="210" height="50" rx="25" fill="#ffffff" fill-opacity="0.05" stroke="#ffffff" stroke-opacity="0.10"/>
      <text x="24" y="33">Port manager</text>
    </g>
    <g transform="translate(764, 458)">
      <rect width="240" height="50" rx="25" fill="#ffffff" fill-opacity="0.05" stroke="#ffffff" stroke-opacity="0.10"/>
      <text x="24" y="33">Clipboard history</text>
    </g>
  </g>

  <!-- Footer line -->
  <text x="96" y="566" font-family="SF Pro Text, Helvetica Neue, Arial, sans-serif" font-size="22" font-weight="500" fill="#6e6e76">macOS 14+ · Free &amp; open source · MIT · github.com/ZingerLittleBee/AnyDoor</text>
</svg>`;

await sharp(Buffer.from(svg)).png().toFile(join(root, 'public', 'og.png'));
console.log('Wrote public/og.png');
