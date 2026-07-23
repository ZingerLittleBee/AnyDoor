# Capabilities are the Script Plugin sandbox; the milestone-A list is closed

A Script Plugin can only do what the host injects into its `JSContext`: an
API that is not injected does not exist, so the capability list *is* the
security model. Milestone A grants exactly six capabilities — network
`fetch`, a plugin-private key-value store, toasts, pasteboard writes routed
through the host's self-write funnel, a one-shot delay timer, and opening a
URL in the default browser. A plugin must declare the capabilities it uses
in its manifest; undeclared capabilities are not injected. Refused for
milestone A: shell execution, AppleScript, filesystem access, and pasteboard
*reading* (a privacy-sensitive read surface with no milestone-A use case).

We chose a closed minimal list over Raycast-style breadth (which includes
shell access) because capabilities are one-way doors: once a plugin uses
one, withdrawing it breaks that plugin, so every grant made during the
sideload milestone silently becomes a store-era security commitment.
Shell access is the sharpest case — it is the shortcut every author
(including us) would reach for, and shipping it without a review pipeline
leads straight to the store-launch deadlock of either breaking existing
plugins or opening the store with arbitrary command execution. Raycast can
afford shell because human review backstops it; milestone A has no review
of anything.

Consequences: some plugins are simply not expressible in milestone A, and
that is the intended trade. The manifest declaration is redundant today (no
consent UI exists) but is deliberately required from the first plugin so the
store milestone can render install-time permission prompts without a
manifest-format migration. Widening the list is a per-capability decision
with ADR-level scrutiny, not a default.

## Amendment: `translate` (2026-07-22)

A seventh capability, `translate`, grants translation of plugin-supplied
text into the user's Settings target language through the user's own
configured translation services. It went through the per-capability
scrutiny this ADR requires: it is declared (it can spend the user's paid
third-party API quota, which install-time consent must surface), the
plugin cannot choose the language direction or the service (first enabled
non-manual service, no fallback — manual-mode services exist precisely to
prevent unattended spending), input is capped at 10,000 characters
runtime-side, and API keys never cross into the `JSContext` — the plugin
sees only text in, text out.
