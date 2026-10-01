// @ts-check
import { defineConfig } from 'astro/config';

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

  adapter: cloudflare({
    imageService: 'compile'
  })
});
