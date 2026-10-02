# Documentation Index

Start with [code navigation](agents/navigation.md) for a task's source files and tests, or
[development](development.md) for build and check commands. Consult only the subsystem references
that the task reaches.

## Current references

| Question | Reference |
| --- | --- |
| Where does behavior live, and which target owns it? | [Navigation map](agents/navigation.md), [Package.swift](../Package.swift) |
| What must a subsystem change preserve? | [Architecture reference](agents/architecture.md) |
| How do I build, run, or reproduce CI checks? | [Development](development.md), [CONTRIBUTING.md](../CONTRIBUTING.md) |
| What can automated checks prove, and what needs native validation? | [Testing index](testing/README.md) |
| What should a reviewer enforce? | [Coding standards](../CODING_STANDARDS.md) |
| How do I add or modify a Native Plugin? | [Native Plugin playbook](agents/native-plugins.md) |
| How do users install plugins or authors build Script Plugins? | [Plugins](plugins.md), [author toolchain](../tooling/README.md) |
| How do automatic sync and manual backup differ? | [Config Sync](config-sync.md), [backup and sync internals](agents/architecture.md#backup-and-sync) |
| How are Stable/Beta releases and the independent feed deployed? | [Deployment](deployment.md), [Beta Updates](beta-updates.md) |
| What vocabulary does the codebase use? | [CONTEXT.md](../CONTEXT.md) |

## Documentation authority

- Source code and executable configuration describe implemented behavior. Check them when a
  reference conflicts with the current checkout; update the affected reference with the change.
- Current PRDs and [technical designs](designs/) describe intended contracts and acceptance details.
  Accepted ADRs explain decisions and their constraints;
  follow their current-decision summary and later amendments when older text is superseded.
- Agent playbooks and runbooks describe current procedures. Keep their source paths, commands,
  ownership boundaries, and verification prerequisites aligned with the checkout.
- [Implementation tickets](issues/) record bounded work and acceptance criteria. Their original
  file lists can predate module extraction or later changes; use the navigation map for current paths.
- [Historical specs](superpowers/specs/), [historical plans](superpowers/plans/), and
  [research](research/) preserve earlier reasoning. An old `Approved` marker records the approval
  at that time; it does not make the document a current implementation map. Read these for history
  after the current contract, and follow any replacement link at the top.

For a discrepancy, report both the implemented behavior and the intended contract instead of silently
choosing one. A source comment describing a platform workaround is evidence of the project's decision,
not fresh runtime verification of the operating system.

## Feature contracts

| Feature | Current contract and decisions |
| --- | --- |
| Clipboard History v2 | [PRD](prds/2026-07-29-clipboard-history-v2.md), [storage boundary and relocation](adr/0011-isolate-clipboard-history-storage.md), [module boundary](adr/0025-encapsulate-clipboard-history-as-a-deep-module.md), [manual acceptance](testing/clipboard-history-v2-manual-test-plan.md) |
| Native Plugins | [PRD](prds/2026-07-16-native-plugin-architecture.md), [logical install](adr/0005-native-plugins-logical-install.md), [command claims](adr/0006-plugin-commands-claim-enum-cases.md), [row descriptors](adr/0007-plugin-rows-are-descriptors.md) |
| Script Plugins | [PRD](prds/2026-07-21-script-plugin-runtime.md), [JavaScriptCore runtime](adr/0008-script-plugins-run-on-javascriptcore.md), [capability sandbox](adr/0009-capabilities-are-the-script-plugin-sandbox.md) |
| Quicklinks | [PRD](prds/2026-07-09-quicklinks.md), [template semantics](adr/0001-untyped-quicklink-template.md) |
| Image Conversion | [PRD](prds/2026-07-06-image-conversion.md), [target size](prds/2026-07-10-image-target-size-compression.md), [technical design](designs/2026-07-10-image-target-size-compression.md), [ImageIO](adr/0002-imageio-for-target-size-compression.md), [metadata policy](adr/0003-target-size-metadata-policy.md), [preview reuse](adr/0004-exact-preview-reuses-final-candidate.md) |
| Config Sync | [User guide](config-sync.md), [CRDT decision](adr/0010-crdt-sync-over-dumb-storage.md) |

The [ADR directory](adr/) contains the remaining decisions. The indexes link current references without
copying their full contracts; update the owning document rather than adding another parallel summary.

## Search

From the repository root, use `scripts/search.py PATTERN` for current first-party source, tests, and
references. Use `scripts/search.py PATTERN --files` to locate files. Default content searches exclude
`docs/issues/`, `docs/research/`, and `docs/superpowers/`, released version sections of `CHANGELOG.md`,
and the `Original decision` portion of amended ADRs. `CHANGELOG.md`'s `[Unreleased]` section and an
amended ADR's `Current decision` remain current. Add `--history` to include the excluded historical
documents and sections when the task needs their earlier reasoning. The search helper avoids generated
output and dependency trees. See [development](development.md) for its exact scope and the
documentation check entry point.
