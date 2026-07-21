# Script Plugins execute on the system JavaScriptCore

A Script Plugin is a pure-JavaScript bundle executed in-process by the
JavaScriptCore framework that ships with macOS. Each installed plugin gets
its own `JSContext` on its own serial background queue; capability calls
trampoline onto the main actor where the host implementation lives. A single
plugin invocation (building rows, building a detail, performing an action)
runs under a hard 30-second watchdog — on timeout or an unrecoverable
exception the host destroys and recreates that plugin's context, surfaces an
inline error row, and leaves every other plugin and the host untouched.
Contexts are marked inspectable so plugin authors debug with the real Safari
Web Inspector (breakpoints, console, call stacks).

We chose this over a bundled Node.js sidecar (the Raycast model) because the
sidecar costs 40–80 MB on a 23 MB app, makes us the distributor and patcher
of a JS runtime, and forces a per-process sandbox design before a single
plugin exists — all to buy the npm-with-Node-APIs ecosystem, which the
target plugin shape ("fetch an API, transform data, emit descriptors") does
not need. Pure-JS npm packages still work: plugins are authored in
TypeScript and bundled to a single ES module with esbuild. Same-Team dylibs
were already rejected for first-party plugins (ADR-0005) and are a
non-starter for third-party code under hardened-runtime library validation.

Consequences: the plugin ecosystem is permanently the pure-JS subset — no
native modules, no Node built-ins. JSC provides no event loop, so timers
exist only as host-granted capabilities, and background refresh must be
host-scheduled if it is ever needed. The engine adds zero bytes to the
bundle and is security-patched by the OS. Because plugin code shares the
host process, the defensive scheduling above (isolated contexts, watchdog,
context recreation) is a load-bearing part of the runtime, not hardening to
add later.
