# Target Size Format Expansion: Lossy Compression Beyond JPEG/HEIC/AVIF

- **Research date:** 2026-07-11
- **Scope:** pngquant/libimagequant, oxipng/zopfli, gifsicle/giflossy/gifski, libwebp native target-size encoding, macOS ImageIO WebP status, Accelerate/vImage/CoreImage/NSBitmapImageRep quantization, ImageIO AVIF/HEIC encoder knobs, libcaesium `compress_to_size`, Clop targetSize loop, TIFF/BMP/ICO/PDF feasibility, and licensing for an MIT notarized macOS app.
- **Question:** How do market tools achieve lossy size compression for formats beyond JPEG/HEIC/AVIF, and what implementation paths are viable for a Swift/SPM macOS 14+ app?
- **Relationship to prior research:** This extends [2026-07-10-image-target-size-compression-market-research.md](./2026-07-10-image-target-size-compression-market-research.md), which established the product landscape and the ImageIO quality-search design for JPEG/HEIC/AVIF, and explicitly deferred the decision to extend target-size to PNG/GIF/WebP/TIFF. Do not duplicate that file; this one answers the deferred library-level question.

## Executive Summary

Market tools shrink formats beyond JPEG/HEIC/AVIF three ways, and licensing — not technical difficulty — decides which are viable for AnyDoor (an MIT, notarized app):

1. **PNG/GIF: adaptive palette quantization.** TinyPNG-style PNG shrinking is median-cut + K-means palette quantization with dithering (libimagequant → indexed PNG). GIF uses the same idea (gifsicle `--lossy` / gifski). Neither libimagequant/pngquant (GPLv3-or-commercial), gifsicle (GPLv2-only), nor gifski (AGPL-or-commercial) can be bundled into an MIT notarized app without a paid commercial license, and none has a built-in byte-target mode — an app must hand-roll the search.

2. **WebP: native encoder rate-control.** libwebp's `WebPConfig.target_size` is a **built-in byte-target encoder** — set the target bytes and a pass count, and libwebp iterates quality internally; no hand-rolled search needed. libwebp is **BSD-3-Clause** (bundleable) and is genuinely required because **macOS ImageIO can decode but not encode WebP**. This is the single best expansion opportunity.

3. **Dimension downscaling: format-agnostic fallback.** Clop's targetSize loop actually keeps its optimizer at a *fixed* aggressive quality and hits the byte budget **only by downscaling** (up to 5 passes at `sqrt(target/current)*0.92`), whereas libcaesium bisects a per-format quality/palette knob. AnyDoor's existing quality-search design mirrors libcaesium.

Apple's own frameworks offer **no adaptive palette quantizer** (vImage does histograms not median-cut; CIColorPosterize is fixed uniform reduction; NSBitmapImageRep has no palette control), and ImageIO exposes **only a quality knob** for AVIF/HEIC (no effort/speed dial). TIFF is lossless-only (target-size degenerates to picking the smallest lossless encoder); BMP/ICO/PDF have no lossy quality parameter and are not meaningfully size-targetable.

**Recommendation:** expand to **WebP first** via bundled libwebp with native `target_size` (permissive, built-in, high value). Treat PNG as a larger follow-up gated on either a prototype proving a permissive Swift quantizer is good enough or a commercial libimagequant license. Keep GIF/TIFF/BMP/ICO/PDF out of Target Size scope.

## 1. PNG Lossy Compression (pngquant / libimagequant)

### Algorithm

TinyPNG-style "lossy PNG" is not a lossy entropy codec — it is **adaptive palette quantization**: a truecolor RGBA image is reduced to an 8-bit (or fewer) indexed-color PNG, which then compresses far better because each pixel becomes a small palette index instead of 24/32 bits. pngquant.org documents the algorithm as a "modified version of Median Cut quantization" (boxes selected to minimize variance from their median), refined by "Voronoi iteration (K-means), which guarantees locally optimal palette," plus a "unique adaptive dithering algorithm that adds less noise to images than the standard Floyd-Steinberg" (error diffusion applied only where several neighboring pixels quantize to the same value and are not edges), working in premultiplied-alpha space. So the pipeline is: median-cut → K-means refinement → adaptive Floyd-Steinberg-style dithering → indexed PNG. Source: <https://pngquant.org/>

`libimagequant` is the palette-quantization library that powers pngquant and other PNG optimizers. It was originally C (2.x); as of version 4.0 it is "rewritten entirely in Rust" while keeping a C ABI for backward compatibility (via `imagequant-sys`). Current version 4.5.0. Sources: <https://github.com/ImageOptim/libimagequant>, <https://raw.githubusercontent.com/ImageOptim/libimagequant/main/Cargo.toml>

### Tunable knobs

pngquant CLI (from the `kornelski/pngquant` README; note `pngquant.org/pngquant.1.html` 404s):
- `--quality min-max` (0–100, JPEG-like): "pngquant will use the least amount of colors required to meet or exceed the max quality. If conversion results in quality below the min quality the image won't be saved … and pngquant will exit with status code 99."
- A positional integer sets the max palette size (up to 256, e.g. `pngquant 256`).
- `--posterize bits` reduces palette precision; `--speed N` (1 slowest/best … 11 fastest, default 4); `--floyd=N` sets dithering level 0–1; `--nofs` disables dithering.

Source: <https://github.com/kornelski/pngquant>

libimagequant / `imagequant` Rust API (from docs.rs): `set_quality(min, max)` (0–100; aborts with an error if the minimum cannot be met; default 0…100 never aborts); `set_speed(1..10)`; `set_max_colors(...)`; and dithering level `set_dithering_level(0.0..1.0)` on the `QuantizationResult` (0 = fast non-dithered, otherwise Floyd-Steinberg-variant diffusion). Source: <https://docs.rs/imagequant/latest/imagequant/struct.Attributes.html>

### Byte-target search feasibility

**There is no built-in target-byte mode in pngquant or libimagequant** — the only controls are palette size, quality min-max, dithering level, posterization, and speed. An app hitting a byte budget must build its own search loop (quantize → encode → measure → adjust). A binary search over colors (2..256) or over the quality ceiling is feasible and is what tools do, but libimagequant explicitly warns that fewer colors "are not always smaller, due to increased dithering it causes" — so encoded size is near-monotonic but not strictly monotonic in the knobs. The correct pattern is to measure actual encoded bytes at each step and retain the best-seen candidate rather than trusting a clean bisection. Sources: <https://github.com/kornelski/pngquant>, <https://docs.rs/imagequant/latest/imagequant/struct.Attributes.html>

Claimed reductions: pngquant.org states conversion "reduces file sizes significantly (often as much as 70%)," with a worked example of 75,628 → 19,996 bytes (73% smaller). Source: <https://pngquant.org/>

### Licensing — the blocking constraint

libimagequant (Rust 4.x and C 2.x) and the pngquant CLI are all **`GPL-3.0-or-later` OR commercial**. The crate `Cargo.toml` license field is literally `GPL-3.0-or-later`, and the README states the dual model: GPLv3+ for FLOSS, "For use in closed-source software, AppStore distribution, and other non-GPL uses, you can obtain a commercial license." Sources: <https://raw.githubusercontent.com/ImageOptim/libimagequant/main/Cargo.toml>, <https://github.com/ImageOptim/libimagequant>, <https://github.com/kornelski/pngquant>

Verdict for AnyDoor (MIT, notarized): bundling libimagequant/pngquant — whether linked via FFI or shelled out as a bundled binary — is **not permitted under the free GPLv3 license** and would require purchasing the commercial license. This is the single biggest obstacle to a TinyPNG-quality PNG path.

## 2. Lossless PNG Recompression (oxipng / zopfli)

Both are *lossless* re-encoders that run **after** quantization: they re-optimize the PNG's DEFLATE stream and filter selection without changing pixels.

- **oxipng** (github.com/shssoichiro/oxipng): multithreaded lossless PNG/APNG optimizer in Rust, usable both as a CLI and as a Rust library crate; can optionally invoke Zopfli via `-z`. License: **MIT**. Source: <https://github.com/shssoichiro/oxipng>
- **zopfli / zopflipng** (github.com/google/zopfli): C library plus CLI providing "very good, but slow, deflate or zlib compression"; zopflipng is the PNG tool built on it. License: **Apache-2.0**. The repository was archived / made read-only on 2025-10-14. Source: <https://github.com/google/zopfli>

**Marginal gain (honest):** these re-optimize the DEFLATE/filter stage of an already-quantized PNG; gains are incremental (zopflipng typically squeezes a bit more than oxipng's default at a large CPU cost). A precise "X% after quantization" figure is **not published by either repo — mark unknown**; the defensible claim is only "lossless, re-optimizes DEFLATE/filters, gains are incremental."

**Embeddability:** oxipng is Rust (C-FFI shim or CLI); zopfli is C (directly embeddable via an SPM C target/FFI, or CLI). Both are permissive (MIT / Apache-2.0) and **GPL-free**, so unlike libimagequant they carry no copyleft obstacle. Note, however, that a lossless recompressor is only useful *after* a quantization step has already produced the indexed PNG — on its own it does not deliver TinyPNG-scale reductions.

## 3. GIF (gifsicle / giflossy / gifski)

### gifsicle knobs

From the official man page (<https://www.lcdf.org/gifsicle/man.html>):
- `--lossy[=N]`: "Alter image colors to shrink output file size at the cost of artifacts and noise." Default 20; higher values permit more artifacts / smaller files.
- `--colors N`: "Reduce the number of distinct colors … to num or less. Num must be between 2 and 256."
- `--dither[=method]`: Floyd-Steinberg by default; also `atkinson`, `ordered`, etc.
- `--color-method`: `diversity` (default), `blend-diversity`, `median-cut`.
- `--optimize[=level]` (`-O1/-O2/-O3`): shrink GIF animations by storing changed regions / adding transparency / trying multiple methods.

`--lossy` originated as the **giflossy** fork by Kornel Lesiński (relaxes GIF's LZW dictionary matching to pick "similar enough" pixel strings, hiding distortion with dithering) and was merged upstream. The archived fork's banner reads "Merged into Gifsicle!" and the upstream README credits "Kornel Lesiński — `--lossy` option." The exact upstream release tag that first shipped it is **unknown** (giflossy's own final release was 1.91), so old distro packages may lack `--lossy`. Sources: <https://github.com/kornelski/giflossy>, <https://github.com/kohler/gifsicle/pull/16>, <https://raw.githubusercontent.com/kohler/gifsicle/master/README.md>

### Size targeting

**No built-in target-size mode.** To hit a byte budget for an animated GIF you must hand-roll an external search over `--lossy=N` (and optionally `--colors`), re-encoding and measuring each probe. This is tractable but slow (each probe re-encodes every frame) and only near-monotonic, so the search is heuristic. Source: <https://www.lcdf.org/gifsicle/man.html>

### Licensing — blocking

gifsicle is **`GPL-2.0-only`** ("distributed under the GNU General Public License, Version 2 (and only Version 2)"), with no commercial option. Linking it into an MIT app would force the whole app to GPLv2; the only clean use is invoking a *separate, user-installed* CLI process (mere aggregation), and even then a bundled/redistributed gifsicle binary carries GPLv2 source-offer obligations. Source: <https://raw.githubusercontent.com/kohler/gifsicle/master/README.md>

### gifski (the modern alternative — also copyleft)

Note that current libcaesium (see §8) does GIF via **gifski**, not gifsicle. gifski is **`AGPL-3.0` OR commercial** — an even stronger (network) copyleft. So both mainstream high-quality GIF backends are copyleft-or-commercial. Source: <https://raw.githubusercontent.com/ImageOptim/gifski/HEAD/LICENSE>

## 4. WebP (libwebp native target-size) and macOS ImageIO WebP Status

### libwebp has a BUILT-IN target-size encoder

This is the strongest finding for format expansion. `WebPConfig` in `src/webp/encode.h` exposes (verbatim field comments):
- `target_size`: "if non-zero, set the desired target size in bytes. Takes precedence over the 'compression' parameter."
- `target_PSNR`: "if non-zero, specifies the minimal distortion to try to achieve. Takes precedence over target_size."
- `pass`: "number of entropy-analysis passes (in [1..10])."
- `method`: "quality/speed trade-off (0=fast, 6=slower-better)"; `quality` (0–100); `lossless` (0=lossy default, 1=lossless).

Precedence is `target_PSNR` > `target_size` > `quality`. When `target_size` is set, libwebp runs an **internal rate-control loop**, iterating its quality parameter across up to `pass` entropy-analysis passes to converge on the requested byte count — more passes = closer convergence at higher cost. **An app does not need to hand-roll a binary search**; it sets `config.target_size = <bytes>` (typically raising `config.pass` to 6–10 for accuracy) and calls `WebPEncode`. Source: <https://raw.githubusercontent.com/webmproject/libwebp/main/src/webp/encode.h>

The `cwebp` CLI exposes the same via `-size <bytes>` / `-psnr <db>`. Source: <https://github.com/webmproject/libwebp/blob/main/examples/cwebp.c>

### macOS ImageIO cannot ENCODE WebP

ImageIO gained WebP **decoding** on macOS 11 / iOS 14, but has **no WebP encoder**: `org.webmproject.webp` is not in `CGImageDestinationCopyTypeIdentifiers`, so `CGImageDestinationCreateWithURL/Data` for WebP fails with "unsupported file format 'org.webmproject.webp'". This is **runtime-observed / widely-reported**, not a formal Apple statement (Apple documents decode; the absence of encode is demonstrated by the runtime error). Sources: <https://developer.apple.com/forums/thread/688001>, <https://github.com/SDWebImage/SDWebImageWebPCoder>. Implication: to *write* `.webp` at all, AnyDoor must bundle libwebp (or shell out to `cwebp`).

### Bundling libwebp in Swift/SPM (permissive license)

libwebp is **BSD-3-Clause** (Copyright Google Inc.) — no copyleft, redistribution only requires reproducing the notice; fully compatible with an MIT notarized app. Source: <https://raw.githubusercontent.com/webmproject/libwebp/main/COPYING>

SPM integration options:
- **`SDWebImage/libwebp-Xcode`** — the primary maintained SPM wrapper. It is a **source-compiled** SPM target (compiles `libwebp/src` + `sharpyuv`), not a prebuilt binary target; import name `libwebp`; declared platforms `macOS 10.10+` (covers macOS 14+). Source: <https://raw.githubusercontent.com/SDWebImage/libwebp-Xcode/master/Package.swift>
- **`SDWebImage/SDWebImageWebPCoder`** — higher-level static+animated WebP coder depending on `libwebp-Xcode`; heavier than a raw encode call unless already using SDWebImage. Source: <https://github.com/SDWebImage/SDWebImageWebPCoder>
- **`ainame/Swift-WebP`** — a thinner Swift wrapper over libwebp; maintenance status **unknown**. Source: <https://swiftpackageregistry.com/ainame/Swift-WebP>
- **`the-swift-collective/libwebp`** — searched, **not found / unconfirmed**; treat as unknown. The de-facto SPM standard is `SDWebImage/libwebp-Xcode`.
- Homebrew `webp` provides `cwebp`/`dwebp` (BSD) as a dev-time shell-out path, but a notarized app should link libwebp rather than depend on a user's Homebrew install.

## 5. AVIF / HEIC Deeper Encoder Knobs in ImageIO

**ImageIO exposes only a quality knob — no encoder effort/speed/complexity dial** (high confidence; this is a negative claim inferred from the published constant set, since Apple documents what exists, not what is absent). The public `CGImageDestination` option keys are `kCGImageDestinationLossyCompressionQuality` (the sole quality control, 0.0–1.0, 1.0 = lossless where supported), plus `kCGImageDestinationImageMaxPixelSize`, `kCGImageDestinationBackgroundColor`, `kCGImageDestinationEmbedThumbnail`, `kCGImageDestinationOptimizeColorForSharing`, and the metadata/orientation keys. There is no libaom/x265-style speed setting. Sources: <https://developer.apple.com/documentation/imageio/kcgimagedestinationlossycompressionquality>, <https://developer.apple.com/documentation/imageio/kcgimagedestinationimagemaxpixelsize>

The newer `kCGImageDestinationEncodeRequest*` family (`…EncodeToISOGainmap`, `…EncodeToISOHDR`, `…EncodeTonemapMode`, `…EncodeToSDR`) concerns **HDR / ISO gain-map / tonemapping** for HEIC, not codec effort — so it does not add a size/quality dial (per-constant semantics not fully verified — treat as plausible). Runtime caveats worth carrying forward: AVIF *encoding* via ImageIO reportedly needs an OS AV1 hardware encoder (Apple Silicon M3+; pre-M3 rejects AVIF encode) — community/runtime-reported, medium-high confidence; and HEIC finalize commonly fails without an ICC-based (sRGB) color profile on the source `CGImage`. Source: <https://developer.apple.com/forums/thread/87111>

Bottom line: the existing JPEG/HEIC/AVIF quality-search design from the prior research remains the only ImageIO lever; there is no additional knob to exploit for these formats.

## 6. macOS System-Framework Palette Quantization

The question: can PNG palette quantization be done with Apple frameworks alone, avoiding GPL libimagequant? **No turnkey system API exists** (the load-bearing claims here are negatives — Apple documents what exists, so confidence is "high but inferred").

- **vImage / Accelerate:** provides histogram *analysis/tone* functions (`vImageHistogramCalculation_ARGB8888`, `vImageEqualization`, `vImageContrastStretch`, `vImageHistogramSpecification`) that compute or apply histograms per channel, but **none generate an optimized N-color palette or an index map**. There is no median-cut/Wu/k-means quantizer and no "posterize/indexed/palette" API in the vImage operations index. The closest thing is Apple's *sample code* "Calculating the dominant colors in an image," which hand-implements k-means on top of vImage primitives and produces a centroid-quantized **truecolor** buffer (Apple frames it as "creating color palettes for GIF image creation") — i.e. you write the clustering yourself, and it still does not emit an indexed PNG. Sources: <https://developer.apple.com/documentation/accelerate/1545743-vimagehistogramcalculation_argb8>, <https://developer.apple.com/documentation/accelerate/vimage/calculating_the_dominant_colors_in_an_image>
- **CoreImage `CIColorPosterize`:** `inputLevels` (default 6) snaps each channel to N evenly-spaced levels — a **fixed uniform** per-channel reduction, not adaptive palette quantization, with no dithering. By itself it does not produce an indexed PNG (ImageIO still encodes truecolor); a posterized truecolor PNG has fewer distinct colors so DEFLATE compresses somewhat better, but it will not match an indexed-palette PNG at equal quality, and the magnitude is **unknown / image-dependent**. Sources: <https://developer.apple.com/documentation/coreimage/cicolorposterize>, <https://cifilter.io/CIColorPosterize/>
- **NSBitmapImageRep:** its PNG writer exposes compression/interlace/gamma/ICC-profile properties but **no palette / PLTE / bit-depth-reduction key** — output is truecolor/grayscale, with no way to supply a custom N-color palette. Source: <https://developer.apple.com/documentation/appkit/nsbitmapimagerep>

**Honest comparison to libimagequant:** there is no Apple-published benchmark and no Apple adaptive-palette quantizer to compare against. Matching TinyPNG-quality shrink with system frameworks alone would require hand-implementing a quantizer (median-cut/Wu/k-means) + dithering + an indexed-PNG writer in Swift. Whether `CGImageDestination` even emits a real color-type-3 PLTE PNG from an indexed `CGColorSpace` is itself **unverified / needs prototyping**, and **how close a hand-rolled Swift quantizer could get to libimagequant is unknown** without a prototype — libimagequant's quality comes from a tuned combination (adaptive median-cut + Voronoi/k-means + perceptual weighting + adaptive dithering + per-image quality targeting) that a naive median-cut will visibly underperform.

## 7. TIFF / BMP / ICO / PDF Size-Targeting Feasibility

- **TIFF** (spec-cited): baseline/common TIFF compressions (none, LZW, Deflate/ZIP, PackBits) are all **lossless** — there is no continuous quality knob to bisect. The one lossy option (JPEG-compressed tiles) is rare and not what image tools emit. libcaesium's `compress_to_size` therefore treats TIFF as "try the lossless algorithms and keep the smallest" (Deflate/Best, LZW, PackBits) — not a quality search. So "target a size" degenerates to picking the smallest lossless encoder or downscaling. Sources: <https://raw.githubusercontent.com/Lymphatus/libcaesium/0.20.3/src/lib.rs> (TIFF branch), <https://libtiff.gitlab.io/libtiff/>
- **BMP** (reasoned from format properties): almost always uncompressed (BI_RGB); BI_RLE8/RLE4 are lossless run-length only. No quality parameter, no entropy coder to search — the only levers are dimensions or bit depth. Not a compression codec.
- **ICO** (reasoned): a container of small fixed icon sizes (16/32/48/256 px), each stored as uncompressed BMP or embedded PNG. No lossy quality dial; the sizes are prescribed by the icon use-case, so "target an arbitrary byte size" is undefined.
- **PDF** (reasoned): a document/page container, not a raster codec. "Compressing a PDF" means recompressing/downsampling the raster images embedded inside it — out of scope for a single-image converter. (Tellingly, Clop treats PDF as its own media type with a DPI-stop ladder — `targetSizePDF` — precisely because it is size-targeted by re-rasterizing embedded images, not a quality knob.)

libcaesium's `compress_to_size` **explicitly rejects everything except JPEG/PNG/GIF/WebP/TIFF** with error 10200 "Format not supported for compression to size" — i.e. BMP/ICO/PDF are not size-targetable there. Source: <https://raw.githubusercontent.com/Lymphatus/libcaesium/0.20.3/src/lib.rs>

**Conclusion:** among these four, only TIFF is "size-targetable," and only in the trivial lossless-selection sense. The honest answer for BMP/ICO/PDF is: document *why not*, and keep them out of any Target Size scope.

## 8. How libcaesium and Clop Wire Format-Specific Compressors for Size Targets

### libcaesium 0.20.3 — one generic quality bisection dispatched per format

`compress_to_size` runs **one generic binary search on a single integer `quality`** (start 80, clamped 1–100, ≤10 tries, 2% tolerance) and feeds that value into the matching format module. Source: <https://raw.githubusercontent.com/Lymphatus/libcaesium/0.20.3/src/lib.rs>

- **PNG:** the bisected `quality` becomes libimagequant's quality **ceiling** — `liq.set_quality(0, quality)` — then quantize + remap + encode via lodepng palette. So for PNG the searched knob is **libimagequant's quality**, not oxipng level and not downscale. Caveat: this lossy path runs only when `png.optimize == false`; if optimize is true it calls the oxipng lossless path which ignores `quality` (the size search would be a no-op). Source: <https://raw.githubusercontent.com/Lymphatus/libcaesium/0.20.3/src/png.rs>
- **JPEG:** drives mozjpeg quality (`jpeg_set_quality`). Source: <https://raw.githubusercontent.com/Lymphatus/libcaesium/0.20.3/src/jpeg.rs>
- **WebP:** passes `quality` as the encoder quality factor via the Rust `webp` crate — it does **NOT** use libwebp's native `target_size`; libcaesium reimplements the search itself. Source: <https://raw.githubusercontent.com/Lymphatus/libcaesium/0.20.3/src/webp.rs>
- **GIF:** drives **gifski** quality (not gifsicle). Source: <https://raw.githubusercontent.com/Lymphatus/libcaesium/0.20.3/src/gif.rs>

Correction to a common assumption: current libcaesium uses **gifski (AGPL) for GIF and imagequant+lodepng (GPL) for lossy PNG** — oxipng is only the lossless PNG path, and gifsicle is not used. Effective license of a default-feature build is therefore copyleft (see §9). Dependencies from `Cargo.toml`: mozjpeg-sys, oxipng 9, webp 0.3, imagequant 4.3, lodepng 3.10, gifski 1.34, tiff 0.9, image 0.25. Source: <https://raw.githubusercontent.com/Lymphatus/libcaesium/0.20.3/Cargo.toml>

### Clop v3.2.3 — targetSize downscales; optimizer quality is FIXED

Clop's image `targetSize` path runs **one aggressive optimise pass, then up to 5 downscale passes** at `factor = max(0.2, sqrt(target/current) * 0.92)`. Source: <https://raw.githubusercontent.com/FuzzyIdeas/Clop/v3.2.3/Clop/PipelineExecution.swift> (`targetSizeImage`, ~L1322–1348)

Critically, the loop emits only `.optimise` and `.downscale(factor:)` actions and passes `aggressiveOptimisation: true` every pass. The pngquant `--quality` and gifsicle `-O/--lossy/--colors` arguments are pure functions of the compression *factor*, which is fixed by the `aggressiveOptimisation` flag (`factor = 64`) — **not** of the target size or the iteration. Concretely the optimizer runs at fixed `pngquant --quality 0-64`, `gifsicle -O3 --lossy=80 --colors=202`, `jpeg --max 58` throughout. **Clop's targetSize loop reaches the byte budget solely by shrinking pixel dimensions, re-running the optimizer at the same fixed aggressive quality — it does not bisect the optimizer's quality/lossy parameters.** Sources: <https://raw.githubusercontent.com/FuzzyIdeas/Clop/v3.2.3/Clop/Images.swift>, <https://raw.githubusercontent.com/FuzzyIdeas/Clop/v3.2.3/Shared.swift>

**Takeaway:** the two reference implementations pick opposite strategies. libcaesium *bisects a quality/palette knob* per format (and pays the GPL/AGPL cost of imagequant+gifski for PNG/GIF). Clop *fixes the optimizer at an aggressive quality and only downscales* to hit the target (still linking GPL pngquant/gifsicle, but keeping the search dimension-only). AnyDoor's existing JPEG/HEIC/AVIF design already bisects quality, so libcaesium's model is the closer analogue — but only WebP offers that model without a copyleft library.

## 9. Licensing Summary for an MIT Notarized macOS App

AnyDoor is **MIT** (repo `LICENSE`). The gate is whether a library can be bundled/linked without copyleft contamination of a notarized, distributed, non-GPL app.

| Library | License | Bundleable into MIT/proprietary notarized app? | Source |
|---|---|---|---|
| **libwebp** | BSD-3-Clause | **YES** — permissive; reproduce notice. Provides native target-size encode. | <https://raw.githubusercontent.com/webmproject/libwebp/main/COPYING> |
| **oxipng** | MIT | **YES** — permissive (lossless PNG recompress). | <https://github.com/shssoichiro/oxipng> |
| **zopfli / zopflipng** | Apache-2.0 | **YES** — permissive (include NOTICE). | <https://github.com/google/zopfli> |
| **mozjpeg / libjpeg-turbo** | BSD-style (IJG + 3-clause BSD + zlib SIMD) | **YES** — permissive; reproduce notices. | <https://raw.githubusercontent.com/mozilla/mozjpeg/master/LICENSE.md> |
| **ImageIO** (Apple) | Proprietary Apple SDK | **YES** — system framework, linked not bundled. | Apple SDK |
| **libimagequant / pngquant** | GPL-3.0-or-later **or commercial** | **NO** under the free license — needs paid commercial license. | <https://github.com/kornelski/pngquant> |
| **gifsicle** | GPL-2.0-only | **NO** — copyleft, no commercial option. | <https://raw.githubusercontent.com/kohler/gifsicle/master/README.md> |
| **gifski** | AGPL-3.0 **or commercial** | **NO** under the free license — needs commercial license. | <https://raw.githubusercontent.com/ImageOptim/gifski/HEAD/LICENSE> |
| **libcaesium** | Apache-2.0 (own) | **Conditional** — Apache core is fine, but the `png` feature links imagequant (GPL) and the `gif` feature links gifski (AGPL); only a `jpg`+`webp`+`tiff` build stays permissive. | <https://raw.githubusercontent.com/Lymphatus/libcaesium/0.20.3/LICENSE> |

**Net:** the high-quality PNG and GIF quantizers (libimagequant, gifsicle, gifski) are all copyleft-or-commercial and cannot be bundled for free. libwebp, oxipng, zopfli, and mozjpeg are clean. This asymmetry — WebP has both a permissive library *and* a native target-size encoder, while PNG/GIF have neither for free — drives the recommendations below.

## Implications for AnyDoor

The market achieves "lossy size compression" outside JPEG/HEIC/AVIF in three ways: (1) **adaptive palette quantization** for PNG/GIF (libimagequant, gifski) — highest quality but copyleft-or-commercial; (2) **native encoder rate-control** for WebP (libwebp `target_size`) — permissive and built-in; (3) **dimension downscaling** as a format-agnostic fallback (Clop). For a Swift/SPM macOS 14+ MIT app, licensing is the dominant constraint: WebP is the one format that gains a *permissive library with a built-in byte-target search*, while PNG/GIF quality quantizers are GPL/AGPL, and Apple's own frameworks provide no adaptive palette quantizer.

Concrete options, ranked by effort/risk:

**Option A — Add WebP via bundled libwebp with native `target_size` (recommended first expansion).**
- Effort: moderate. Add `SDWebImage/libwebp-Xcode` (source SPM target, macOS 10.10+, BSD-3), decode the source to a bitmap, set `WebPConfig.target_size = <bytes>` + `pass = 6..10`, call `WebPEncode`. No hand-rolled search — the encoder converges internally.
- Risk: low-to-moderate. BSD license is clean; libwebp is battle-tested; the main work is bridging a C API and adding a THIRD-PARTY-LICENSES entry. ImageIO cannot write WebP, so libwebp is genuinely required — this also unlocks WebP as a normal (non-target) output format, which the app lacks today.
- Payoff: highest. Turns "format list too small" into a real, high-demand format with a first-class byte-target contract that mirrors the existing JPEG/HEIC/AVIF `reached`/`targetUnattainable` outcome.

**Option B — Add PNG target-size via a permissively-licensed, hand-rolled quantizer + quality search.**
- Effort: high. No free library does this: libimagequant/pngquant are GPL/commercial. A clean-license path means implementing median-cut/Wu quantization + dithering + indexed-PNG encoding in Swift (or vendoring a permissive quantizer), then binary-searching palette size / quality against the byte budget with a best-seen candidate (size is only near-monotonic). Optionally finish with oxipng/zopfli (MIT/Apache) lossless recompression.
- Risk: high. Quality parity with libimagequant is **unknown without a prototype**, `CGImageDestination`'s ability to emit a color-type-3 indexed PNG is **unverified**, and the search is slower and noisier than WebP's internal loop. Alternative: buy the libimagequant commercial license (removes the quality risk, adds cost + a proprietary dependency to track).
- Payoff: real (PNG is ubiquitous) but gated on the quantizer quality question.

**Option C — System-framework-only quantization (CIColorPosterize / hand-rolled k-means on vImage).**
- Effort: moderate. Zero third-party licensing. Use `CIColorPosterize` or Apple's k-means sample to reduce distinct colors, then encode PNG and search the posterize level against the target.
- Risk: moderate-to-high on *outcome quality*. This produces a color-reduced **truecolor** PNG (no PLTE), so DEFLATE gains are smaller than true indexed quantization, and there is no dithering sophistication. Savings magnitude is **unknown / image-dependent**. Best viewed as a low-quality fallback, not a TinyPNG substitute.
- Payoff: modest; keeps everything permissive but likely disappoints on aggressive targets.

**Option D — Keep V1 scope (JPEG/HEIC/AVIF only) and document the rest as out of scope.**
- Effort: none. Risk: none. For GIF, TIFF, BMP, ICO, PDF this is arguably the *correct* answer: GIF's quality backends are copyleft/commercial with no built-in target mode; TIFF is lossless-only (target-size degenerates to picking the smallest lossless encoder or downscaling); BMP/ICO/PDF have no lossy quality knob at all.
- Payoff: honesty. If the format list must grow, grow it with WebP (Option A), not with formats that cannot honor a byte-target contract cleanly.

**Suggested sequencing:** Option A (WebP) is the clear next step — permissive, built-in target search, high user value, and it fits the existing outcome contract. Option B (PNG) is a worthwhile but larger follow-up that hinges on either a prototype proving a permissive Swift quantizer is good enough, or a decision to license libimagequant commercially. Option C is a fallback only if B's licensing/quality both prove unacceptable. GIF/TIFF/BMP/ICO/PDF should stay out of Target Size scope (Option D) with the rationale documented above.

## Unknowns flagged in this research

- Exact post-quantization size gain from oxipng/zopfli — not published; unknown.
- Whether `CGImageDestination` emits a real color-type-3 indexed PNG from an indexed `CGColorSpace` — unverified, needs prototyping.
- How close a hand-rolled permissive Swift quantizer could get to libimagequant quality — unknown without a prototype.
- Exact `CIColorPosterize` slider min/max and the file-size magnitude of posterize-only PNG reduction — image-dependent / unverified.
- Precise upstream gifsicle version that first shipped `--lossy`, and the maintenance status of `ainame/Swift-WebP` — unknown.
- `the-swift-collective/libwebp` — not found; the confirmed SPM path is `SDWebImage/libwebp-Xcode`.
- AVIF-encode hardware gating (M3+) and the HEIC ICC-profile finalize requirement are runtime-reported, not Apple-documented.
