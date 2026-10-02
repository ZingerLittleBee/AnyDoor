# Testing

Choose the lane that answers the change. Build and unit-test results do not
establish native UI behavior or the permissions of an installed app.

| Task | Entry point | Completion evidence |
| --- | --- | --- |
| Swift build, warnings, and tests | `make check`; runner and toolchain details in [Development](../development.md) | First-party warning check and executed-test counts. Record the active toolchain and any difference from CI's pin. |
| Script Plugin author tooling and contract fixtures | `pnpm -C tooling verify` | The workspace verification completes; Swift tests alone cannot detect stale generated contract fixtures. |
| Agent navigation and documentation paths | `make docs-check` | The documented path checks pass. |
| Find an implementation or its history | `python3 scripts/search.py PATTERN`, with `--files` or `--history` when needed | A real source entry point or a historical change, not a guessed directory. |
| Native UI, hotkeys, permissions, or a GUI test handoff | [Native UI testing](native-ui.md) | Preflight complete, actual app identity recorded, and each case has native evidence. |
| Clipboard capture, migration, recovery, search, or performance | [Clipboard History v2 plan](clipboard-history-v2-manual-test-plan.md) | Named case results and measurement timing. Use its disposable-account procedure for destructive cases. |
| Disposable legacy history fixture | [Fixture command](clipboard-history-v2-manual-test-plan.md#03-building-a-large-history) | The selected fixture test executes without skipping and prints `CLIPBOARD_HISTORY_GUI_FIXTURE_ROOT` for the intended profile. A zero exit status alone is insufficient. |
| Clipboard Keychain identity boundary | [Cross-identity Keychain verification](clipboard-history-keychain-integration.md) | Deterministic pre-prompt result; interactive authorization is a separate result. |
| Pinned images | [Pinned-image plan](pinned-image-manual-test-plan.md) | Results for the requested window behavior and display setup. |

For a handoff, record the candidate SHA, app path, build command, toolchain,
account/isolation mode, selected cases, and artifact paths. Label each case
`PASS`, `FAIL`, `BLOCKED`, or `SKIPPED`; explain failures and missing coverage.
Keep reproduction findings in the relevant plan when they change how a future
run must measure or drive a case. A desktop report or a session scratchpad is
evidence for that run, not the repository's next-run procedure.

## Encrypted-store fixtures

XCTest store tests use the [shared asynchronous teardown support](../../Tests/ClipboardHistoryTestSupport/ClipboardHistoryTestSupport.swift)
through the small [ClipboardHistoryTests adapter](../../Tests/ClipboardHistoryTests/ClipboardHistoryModuleFixture.swift)
or [AnyDoorTests adapter](../../Tests/AnyDoorTests/ClipboardHistoryModuleFixture.swift).
Register a temporary directory's removal first, then create each module through
`trackClipboardHistoryModule`. XCTest runs teardown blocks in reverse order,
so the stores close before their backing files are removed. Keep an explicit
mid-test close when a case intentionally reopens the same store.

Register monitor/lifecycle shutdown after tracking its module so it stops first.
For a test-controlled suspended recognizer, pass its release operation as
`beforeClosing`; cancellation alone cannot resume an arbitrary test continuation.
Teardown owns cleanup after early returns, failed assertions, and thrown errors.
Direct GRDB readers also need their own close registered before directory removal.
Swift Testing cases use an asynchronous scoped factory with cleanup on both the
normal and throwing paths; see [catalog invariant tests](../../Tests/AnyDoorTests/BuiltinCatalogInvariantTests.swift).

The [fixture lifecycle regression](../../Tests/ClipboardHistoryTests/ClipboardHistoryFixtureLifecycleTests.swift)
opens two real encrypted databases, suspends a Vision job, throws during setup,
and verifies that teardown releases the job, closes both databases, and removes
their directory. A report where assertions pass but xctest exits with `SIGSEGV`
is a failed test run. Inspect the process exit and crash report as well as the
test count; past failures reached SQLCipher process shutdown with stores still
open. This fixture prevents that lifetime gap rather than treating a successful
assertion summary as completion.
