# Native Plugins ship in the binary; install is a logical state

A Native Plugin (first pilots: Hosts, Image Conversion) compiles into the
main binary as its own SPM target that touches the host only through the
plugin interface. "Install" flips a state flag; "uninstall" runs the plugin's
deactivate hook (revert system side effects — deactivate hosts profiles, and
unregister the privileged helper unless another consumer such as forced
Scheduled Shutdown still needs it — and cancel in-flight work) and unregisters
every surface, while SwiftData rows are retained so a reinstall restores the
user's data intact. Uninstall is transactional: reverting hosts profiles is a
privileged `/etc/hosts` write that can fail or be cancelled at the auth
prompt, so a failed deactivate leaves the plugin installed rather than
half-removed.

We chose this over physically distributing plugins as downloads because the
alternative — same-Team-ID-signed dylibs, which hardened-runtime library
validation does permit — costs a stable ABI boundary, a per-plugin
sign/notarize/release pipeline, and a plugin updater, for a binary-size win
that is negligible at this app's scale. The hard SPM target boundary is kept
precisely so that upgrading to physical distribution later only changes the
loading mechanism, not the plugin code.

Consequences: an "uninstalled" plugin's code and `@Model` classes still exist
in the process (the ModelContainer schema is static), so "does not exist" is
enforced at the registration layer, not the linker; and existing users are
migrated by usage trace (Hosts: `HostProfile` rows exist OR the privileged
helper is registered — the helper check prevents a ghost daemon with no
managing UI; Image Conversion: `ImageConversionRecord` rows exist; everyone
else, including fresh installs, starts uninstalled).
