# Target Size Compression strips ancillary metadata consistently

- **Status:** accepted

Target Size Compression preserves display-critical metadata such as
orientation, color profiles, and supported HDR data, while removing GPS,
capture details, embedded thumbnails, and comments. This policy takes priority
over lossless pass-through: Image I/O may copy compressed image data only when
it can also apply the metadata policy and keep the result within the byte limit;
otherwise AnyDoor falls back to the bounded re-encoding search, which may yield
either a qualifying output or a clearly labeled Best-Effort Result.

When the selected target cannot preserve source HDR/gain-map content, AnyDoor
may still convert to SDR only after surfacing a persistent Display Downgrade
warning. The exact preview shows the downgraded result, and the Conversion
Record retains the downgrade fact. Failure to preserve orientation or intended
color is a policy failure rather than another downgrade category in V1.

This deliberately differs from ordinary Quality mode because ancillary
metadata consumes the byte budget, and a privacy policy that silently changes
by output format would be misleading.
