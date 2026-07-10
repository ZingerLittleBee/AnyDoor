# Target Size Compression remains on Image I/O

- **Status:** accepted

Target Size Compression will use the existing Image I/O backend for JPEG,
HEIC, and AVIF. We are not bundling format-specific encoders in V1 because
the target-size mechanism can be implemented through bounded candidate search
on the current backend. V1 accepts Image I/O's output-quality ceiling in
exchange for preserving runtime availability, sandboxing, and distribution
without new binary, licensing, or maintenance obligations.

The deep conversion-engine boundary must still allow a format-specific backend
to replace Image I/O later if measured output quality justifies the added
dependency. V1 does not introduce a public encoder protocol for a single
implementation; the second backend, not speculation, will define that seam.
