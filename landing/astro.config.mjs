// @ts-check
import { defineConfig, fontProviders } from 'astro/config';

import cloudflare from "@astrojs/cloudflare";

// https://astro.build/config
export default defineConfig({
  site: 'https://anydoor.dev',

  // Astro 7 defaults to 'jsx', which drops the whitespace between inline
  // elements, so a heading split across spans reads "Ready whenyou are.".
  compressHTML: true,

  // The site is fully static. Without these settings the adapter adds SESSION
  // (Workers KV) and IMAGES (Cloudflare Images) bindings to the deploy, and
  // wrangler creates a KV namespace for a binding that has no id.
  session: false,

  // Self-hosted at build time. Each family exposes only its own hashed name
  // (`fallbacks: []`) so global.css can chain them into one stack: Plex covers
  // Latin, Noto Sans SC covers CJK, then the system fonts. A generic fallback
  // here would end the chain before the CJK family. Noto Sans SC ships as ~100
  // unicode-range slices; browsers fetch only the slices a page uses.
  fonts: [
    {
      provider: fontProviders.google(),
      name: 'IBM Plex Sans',
      cssVariable: '--font-plex-sans',
      weights: [400, 500, 600, 700],
      styles: ['normal'],
      fallbacks: [],
    },
    {
      provider: fontProviders.google(),
      name: 'IBM Plex Mono',
      cssVariable: '--font-plex-mono',
      weights: [400, 500, 600],
      styles: ['normal'],
      fallbacks: [],
    },
    {
      provider: fontProviders.google(),
      name: 'Noto Sans SC',
      cssVariable: '--font-noto-sc',
      // Variable font: one range keeps a single @font-face per slice instead
      // of one per weight (the inlined CSS is otherwise ~280 KB).
      weights: ['400 700'],
      styles: ['normal'],
      fallbacks: [],
    },
  ],

  adapter: cloudflare({
    imageService: 'compile'
  })
});
