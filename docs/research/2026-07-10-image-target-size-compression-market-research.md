# Target Size Compression: Product and Implementation Research

- **Research date:** 2026-07-10
- **Scope:** TinyPNG/Tinify, Squoosh, ImageOptim, Clop, JPEGmini, and Caesium
- **Question:** How do established image optimizers expose quality, dimensions, formats, and target bytes, and what should AnyDoor implement with macOS Image I/O?

## Executive Summary

The market does not use one consistent meaning of “image compression.” The six products fall into three distinct models:

1. **Automatic perceptual optimization:** TinyPNG, Clop's normal optimization, and JPEGmini select settings automatically and promise a favorable quality/size tradeoff.
2. **User-controlled quality or dimensions:** Squoosh, ImageOptim, Clop, JPEGmini, and Caesium expose some combination of quality tiers, encoder settings, and resizing.
3. **Target-byte optimization:** Clop and Caesium expose this outside their ordinary quality controls. Caesium exposes a Size mode in its desktop UI and `--max-size` in CaesiumCLT. Clop v3.2.3 exposes `targetSize(size)` through its pipeline/CLI surface; a direct result-card action is documented separately in the repository's 3.2.4 release notes.

Neither Clop nor Caesium treats a requested byte count as an unconditional guarantee. Clop bounds its attempts and may return an oversized result with a warning. Caesium searches encoder quality and, when the target is unattainable, returns the smallest result because its GUI invokes libcaesium with `return_smallest = true`. This distinction is important: a label such as “Fit under 500 KB” is not enough to define a reliable product contract.

For AnyDoor V1, the clean design is a two-stage, bounded search for lossy Image I/O outputs:

- first, search quality while retaining the original pixel dimensions;
- only if the user has explicitly allowed it, reduce dimensions and search quality again;
- retain the best qualifying candidate found, and report `targetUnattainable` when no candidate qualifies;
- never present an oversized file as a successful target-size result.

## Product Comparison

| Product | Product promise | Controls exposed | Target-byte surface and semantics | Batch, metadata, and source-file policy |
|---|---|---|---|---|
| **TinyPNG / Tinify** | Automatic content-aware optimization. The official site says the engine selects optimization levels from image colors, textures, and patterns; exact encoder and search details are proprietary. | The web compressor is mostly drop-and-run. Tinify's API supports AVIF/WebP/JPEG/PNG conversion and explicit `scale`, `fit`, `cover`, and `thumb` resizing. It does not expose a numeric quality control. | **None documented.** The API returns the resulting size but accepts no target-byte parameter. Resize is caller-selected, not an automatic fallback after failing a size target. | The free web tool accepts up to 20 images at once, each up to 5 MB. Web compression removes unnecessary metadata. The API can selectively retain copyright, creation time, and JPEG location. Results are downloaded or written by the caller; local originals are not modified. |
| **Squoosh** | Local, interactive comparison using multiple codecs; images are processed in the browser rather than uploaded. | Output codec and codec-specific quality/effort settings, plus resize and palette reduction. The web app is centered on one image and two comparison sides, not a conventional batch queue. | **Not exposed as a product control.** Squoosh's libwebp option type contains `target_size`, initialized to `0`, but the WebP UI does not render a target-size field. It must not be described as a general Squoosh capability. | The pipeline decodes to `ImageData`, processes pixels, and gives `ImageData` to an encoder. No general metadata-forwarding path is visible in this flow, so metadata preservation is not promised. The downloaded result is a new browser `File`; the source remains untouched. |
| **ImageOptim** | Lossless optimization by default, with optional lossy minification. It runs several optimizers and retains the smallest result. | JPEG maximum quality, per-optimizer effort/enablement, progressive/interlace controls, and an all-or-nothing metadata stripping preference. It is not a resize or format-conversion UI. | **None documented.** If no candidate is smaller, ImageOptim reports the file as already optimal and leaves it unchanged. | Supports dropping multiple files and directories. It optimizes in place, moving the prior original to Trash; an optional `~` backup can also be enabled. EXIF, embedded thumbnails, comments, and unnecessary color profiles are removed by default, with a setting to keep metadata. |
| **Clop v3.2.3** | Automatic clipboard/file optimization with ordinary, aggressive, adaptive, per-result compression, explicit conversion, and downscaling. Officially listed image tools include pngquant, jpegoptim, gifsicle, and libvips for resizing. | A compression scale, adaptive format selection, explicit dimensions/downscale, conversion, crop, pipeline automation, and output-location controls. | **Yes, but surface matters.** The tagged v3.2.3 pipeline/CLI documents `targetSize(size)` for iterative compression. The v3.2.3 image implementation first runs aggressive optimization, then performs at most five downscale passes using `max(0.2, sqrt(target/current) * 0.92)`. After the bounded loop, the common handler logs a warning if the output still exceeds the target and nevertheless continues with that result. The repository's 3.2.4 notes separately announce a GUI “Fit under size” result action; that should not be back-projected onto the v3.2.3 GUI. | Normal file optimization is in place, with originals retained in Clop's backup folder. Pipelines can choose in-place, same-folder, temporary, or templated locations. Metadata stripping is configurable and defaults to enabled in v3.2.3 source. |
| **JPEGmini** | Find the smallest JPEG that remains perceptually indistinguishable from the input. Its proprietary BQM compares increasingly compressed candidates and selects the smallest candidate without additional visible artifacts. | Desktop automation supports resize presets. The Server product exposes three quality tiers (`Best`, `High`, `Medium`), explicit resize, progressive JPEG behavior, highly-compressed-input skipping, and metadata removal. | **None documented.** JPEGmini optimizes under a perceptual-quality constraint, not under a byte constraint. If an image is already highly compressed and skip mode is enabled, the Server copies it to the output with `_copy.jpg`; it does not silently resize to meet an unspecified limit. | Processes folders and watch-folder automations. Server output is a separate `_mini.jpg` by default and preserves metadata by default unless `-rmt=1` is used. Current automations move originals into hidden retained storage, with configurable retention. |
| **Caesium 2.8.5 / CaesiumCLT 1.4.0** | Manual quality/lossless optimization, resizing, format conversion, metadata options, and explicit maximum-size compression. | The desktop UI has distinct **Quality** and **Size** modes. Size mode accepts bytes, KB, MB, or a percentage of the original. CaesiumCLT exposes quality, lossless, resize, metadata, format, recursion, output, and `--max-size`. | **Yes, as best effort.** CaesiumCLT 1.4.0 says `--max-size` attempts the nearest size without exceeding the limit and outputs the smallest possible result when the target is too small. Caesium 2.8.5 calls libcaesium's size function with `return_smallest = true`. libcaesium 0.17.4 starts at quality 80, performs a bounded binary search for up to 10 attempts with a 2% target tolerance, and returns the quality-1 result when it cannot get under the target. It does not automatically lower dimensions unless resize parameters were already supplied. TIFF is handled by trying lossless algorithms and selecting the smallest. | Desktop processing is batch-oriented. Metadata retention defaults to enabled in the 2.8.5 UI; folder structure and file dates are configurable. Output can be a separate folder or the input folder. Same-folder/no-suffix overwrite is explicitly warned as irreversible; originals may optionally be moved to Trash or deleted. “Skip if bigger” defaults to enabled. |

## Per-Product Evidence

### TinyPNG / Tinify

- The [TinyPNG web product and FAQ](https://tinypng.com/) describe automatic optimization, default metadata removal, and the free batch limits.
- The [Tinify API reference](https://tinify.com/developers/reference/http) lists compression, four resize methods, format conversion, and selective metadata preservation. Its request surface has no target-byte or numeric quality option.
- The implementation beyond the published content-aware behavior is **unknown**. In particular, the sources do not establish an encoder, quality-search algorithm, perceptual metric, retry count, or unattainable-target policy.

### Squoosh

- The [official repository README](https://github.com/GoogleChromeLabs/squoosh) states that compression is performed locally.
- The app's [options component](https://github.com/GoogleChromeLabs/squoosh/blob/dev/src/client/lazy-app/Compress/Options/index.tsx) exposes resize, palette reduction, encoder selection, and codec-specific settings.
- The [MozJPEG options](https://github.com/GoogleChromeLabs/squoosh/blob/dev/src/features/encoders/mozJPEG/client/index.tsx) expose a quality slider and advanced encoder controls.
- The [WebP defaults](https://github.com/GoogleChromeLabs/squoosh/blob/dev/src/features/encoders/webP/shared/meta.ts) include libwebp's `target_size`, while the [WebP UI](https://github.com/GoogleChromeLabs/squoosh/blob/dev/src/features/encoders/webP/client/index.tsx) never maps that field to a control.
- The [compression pipeline](https://github.com/GoogleChromeLabs/squoosh/blob/dev/src/client/lazy-app/Compress/index.tsx) encodes processed `ImageData` into a new `File`. Metadata loss is an inference from that source path, not an explicit product guarantee.

### ImageOptim

- The [product page](https://imageoptim.com/mac) identifies the multi-tool strategy and lists MozJPEG, pngquant, Pngcrush, 7zip, SVGO, and Zopfli.
- The [usage guide](https://imageoptim.com/howto.html) documents in-place replacement, originals in Trash, the “already optimal” state, and metadata behavior.
- The [preferences reference](https://imageoptim.com/help/prefs.html) documents JPEG maximum quality, optimizer effort, the optional backup copy, and metadata stripping.

### Clop

- The [product page](https://lowtechguys.com/clop) describes automatic clipboard optimization, explicit downscaling, drop-based batch workflows, and the public toolchain.
- The [v3.2.3 pipeline help](https://github.com/FuzzyIdeas/Clop/blob/v3.2.3/ClopCLI/main.swift#L2588-L2610) describes `targetSize(size)` as an iterative pipeline step.
- The [v3.2.3 target-size dispatcher](https://github.com/FuzzyIdeas/Clop/blob/v3.2.3/Clop/PipelineExecution.swift#L389-L417) preserves an oversized best-effort result and logs a warning.
- The [v3.2.3 image strategy](https://github.com/FuzzyIdeas/Clop/blob/v3.2.3/Clop/PipelineExecution.swift#L1322-L1348) performs aggressive optimization followed by at most five proportional downscales.
- The [v3.2.3 README](https://github.com/FuzzyIdeas/Clop/blob/v3.2.3/README.md) documents the backup-folder policy.
- The [v3.2.3 settings source](https://github.com/FuzzyIdeas/Clop/blob/v3.2.3/Clop/Settings.swift#L91) makes metadata stripping configurable and enabled by default.
- The [3.2.4 release notes in the repository](https://github.com/FuzzyIdeas/Clop/blob/main/ReleaseNotes/3.2.4.md) announce the direct GUI “Fit under size” action. This is separate evidence from the tagged v3.2.3 pipeline capability.

### JPEGmini

- The [technology overview](https://www.jpegmini.com/technology) describes its quality detector and adaptive JPEG encoder.
- The [official explanation of the candidate process](https://help.jpegmini.com/help/how-does-jpegmini-optimization-work) says JPEGmini creates multiple candidates and selects the smallest one without additional visible artifacts under BQM.
- The [Server documentation](https://jpegmini.com/products/developers/server/docs) documents output naming, quality tiers, resizing, metadata behavior, batch folders, and skip behavior.
- The [automation guide](https://help.jpegmini.com/help/getting-started-with-automations) documents watch folders, multiple output dimensions, and original-file retention.
- Candidate count, BQM scoring details, codec internals, and thresholds remain **unknown** because they are proprietary.

### Caesium

- The [Caesium 2.8.5 UI source](https://github.com/Lymphatus/caesium-image-compressor/blob/v2.8.5/views/MainWindow.ui#L249-L274) defines distinct Quality and Size modes; the same file defines maximum output size units and metadata controls.
- The [desktop call site](https://github.com/Lymphatus/caesium-image-compressor/blob/v2.8.5/src/models/CImage.cpp#L218-L229) invokes `c_compress_to_size(..., true)`, explicitly selecting the “return smallest if unattainable” behavior. Its [settings initialization](https://github.com/Lymphatus/caesium-image-compressor/blob/v2.8.5/src/MainWindow.cpp#L391-L424) establishes the metadata, skip-if-bigger, and original-file defaults.
- [CaesiumCLT 1.4.0 usage](https://github.com/Lymphatus/caesium-clt/blob/v1.4.0/docs/USAGE.md) defines `--max-size`, explicit resize options, metadata controls, recursive batches, and overwrite policy.
- The desktop release pins [libcaesium 0.17.4](https://github.com/Lymphatus/caesium-image-compressor/blob/v2.8.5/libcaesium.conf). Its [target-size implementation](https://github.com/Lymphatus/libcaesium/blob/0.17.4/src/lib.rs#L120-L221) shows the 80 starting quality, 10-attempt bounded binary search, 2% tolerance, and `return_smallest` behavior.
- The [libcaesium 0.17.4 dependencies](https://github.com/Lymphatus/libcaesium/blob/0.17.4/Cargo.toml) identify MozJPEG, oxipng, imagequant, gifsicle, libwebp, and Rust `image`/TIFF support.

## Implications for AnyDoor's Image I/O V1

### What Image I/O provides

Apple documents [`kCGImageDestinationLossyCompressionQuality`](https://developer.apple.com/documentation/imageio/kcgimagedestinationlossycompressionquality) as a `0.0...1.0` desired-quality value. Apple also exposes [`kCGImageDestinationImageMaxPixelSize`](https://developer.apple.com/documentation/imageio/cgimagedestination) for dimension limits and [`CGImageDestinationCreateWithData`](https://developer.apple.com/documentation/imageio/cgimagedestinationcreatewithdata(_:_:_:_:)) for encoding into memory. The documented destination controls do not include a target byte count. A target-size feature therefore requires application-level candidate generation and measurement.

AnyDoor already writes through `CGImageDestinationAddImageFromSource` in [ImageConverter.swift](../../Sources/AnyDoor/Services/ImageConversion/ImageConverter.swift). Apple states that this call inherits source properties unless the properties dictionary modifies or removes them. Consequently, metadata is part of every candidate's measured size unless AnyDoor adopts a different explicit policy.

### Lossless metadata-rewrite probe

A throwaway probe on the development machine (macOS 26.5) exercised
`CGImageDestinationCopyImageSource` against generated JPEG, HEIC, and AVIF
files containing GPS metadata. This API is documented in the local SDK headers
as copying image data without recompression while allowing metadata changes,
but the same headers warn that not every image format supports the operation.

- **JPEG:** the copy succeeded, decoded pixels matched, and GPS was removed.
  The rewritten container was larger in the probe, so a pass-through result
  must still be measured against its byte limit.
- **HEIC:** the copy succeeded and decoded pixels matched, but neither the GPS
  exclusion flag nor replacement with an empty metadata collection removed the
  test GPS dictionary.
- **AVIF:** Image I/O returned `kCFErrorDomainCGImageMetadata` and reported that
  `public.avif` does not support lossless metadata modification.

This is empirical capability evidence, not a cross-version guarantee. It means
AnyDoor cannot promise both lossless pass-through and uniform ancillary-metadata
removal for every Lossy Target. A consistent removal policy requires a normal
re-encode fallback when lossless metadata rewriting is unsupported or
ineffective.

### Alpha-channel encoding probe

A second throwaway probe on macOS 26.5.2 with the macOS 26.5 SDK encoded a
generated PNG containing opaque, translucent, and transparent pixels through
the same `CGImageDestinationAddImageFromSource` path AnyDoor uses. In-memory and
URL destinations produced the same behavior:

- **JPEG:** encoding succeeded without alpha. The default output composited
  transparent pixels over white; an explicit magenta background produced the
  expected magenta composite.
- **HEIC and AVIF:** encoding succeeded with alpha. The tested alpha values were
  preserved, and supplying white or magenta destination backgrounds did not
  affect the encoded outputs.

This matches Apple's documented
[`kCGImageDestinationBackgroundColor`](https://developer.apple.com/documentation/imageio/kcgimagedestinationbackgroundcolor)
contract: a destination that cannot encode alpha composites against the supplied
background, defaulting to white when none is supplied. The HEIC and AVIF results
are runtime evidence, not a guarantee for every supported macOS version. AnyDoor
must continue filtering encoders at runtime and verify alpha round-trips on the
minimum supported macOS release.

### Recommended engine contract

Use a format-scoped engine API whose result makes the target contract explicit:

```swift
enum TargetSizeCompressionOutcome: Sendable {
    case reached(data: Data, quality: Double, pixelSize: CGSize)
    case targetUnattainable(bestEffort: Data, quality: Double, pixelSize: CGSize)
}
```

The V1 algorithm should:

1. Encode candidates to `CFMutableData`, not temporary output URLs.
2. Test the highest quality first. If it already fits, return it without needless degradation.
3. Search quality with a strict iteration cap, always retaining the highest-quality candidate that is at or below the target and the smallest best-effort candidate overall.
4. Treat encoded-size monotonicity as an empirical optimization, not a public Image I/O guarantee. Never discard the best measured candidate merely because a later probe is surprising.
5. If the lowest permitted quality remains oversized and resizing is authorized, estimate a new linear scale from `sqrt(targetBytes / currentBytes)` with headroom, resize proportionally, and repeat under a second strict iteration cap.
6. If resizing is not authorized, or the bounded resize phase still cannot qualify, return `targetUnattainable` and make the UI say exactly how large the best effort is.
7. Write the selected in-memory candidate to the final collision-safe output URL only once. Keep AnyDoor's additive policy: never modify or delete the source.

### Scope and product decisions that must remain explicit

- **Formats:** The quality-search model naturally fits AnyDoor's lossy Image I/O formats (JPEG, HEIC, AVIF). PNG/TIFF/GIF/BMP/PDF/ICO do not become meaningfully target-size controllable merely by passing a quality key. V1 should not silently change format or quantize palettes without a separate decision.
- **Dimensions:** Automatic downscaling materially changes the image. It must be an explicit user choice, not an invisible recovery step.
- **Metadata:** The existing Image Conversion PRD says metadata should be preserved where supported. Preserved metadata can make very small targets unattainable. Target-size compression must either honor that rule and report failure or introduce an explicit metadata policy.
- **Batch meaning:** A target should apply per output image, not to the sum of the batch, unless the UI explicitly says otherwise.
- **Success language:** “Compressed to 500 KB” must mean the result is `<= 500 KB`. A best-effort oversized output is useful, but it is not success.

## Proposed design direction

The proposed design following this research selects the explicit-policy route:

- Target Size supports runtime-available JPEG, HEIC, and AVIF through Image I/O.
- Resize Fallback is visible, disabled on first use, and never triggered without
  the user's choice.
- An unattainable target produces a clearly labeled, saved Best-Effort Result;
  it is not success and is not copied to the pasteboard automatically.
- Target Size strips ancillary metadata while preserving and auditing
  display-critical information.
- A selected image receives an exact full-resolution preview from the same
  candidate pipeline used for final output.

The complete contract and bounded-search policy live in
[the Target Size Compression PRD](../prds/2026-07-10-image-target-size-compression.md).
