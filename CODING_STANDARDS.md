# Review standards

Read this when reviewing a change. Use [task routes](docs/agents/navigation.md)
to reach the relevant [architecture reference](docs/agents/architecture.md),
current contract, and acceptance procedure. Automated checks enforce syntax,
compiler diagnostics, contract fixtures, attribution, and navigation paths;
review supplies the cross-file judgment they cannot replace.

- Follow the behavior through its actual callers, ownership boundary,
  persistence, and failure presentation. A local implementation improvement
  must preserve the surrounding feature's user-visible semantics.
- Compare changed behavior with the current contract and amended decisions.
  Update active documentation and caller assumptions in the same logical
  change. Preserve historical records with a current-decision pointer rather
  than silently rewriting the original decision.
- Keep module interfaces small and capability-driven. Assess whether ownership,
  lifecycle, cancellation, and recovery remain consistent across the boundary,
  including uninstall/reinstall and partial failure.
- Check that a verification claim measures the behavior it names. Distinguish
  source inspection, compilation, executed tests, native UI, live-service checks,
  and publication. Record the tested commit, compiler, and material limitations.
- Evaluate resource lifetimes across early returns and throwing paths. Test
  fixtures must keep backing files alive until their asynchronous store teardown
  completes; reopening tests may still need an explicit earlier close.
- For deployment changes, inspect [every deployment entry point](docs/deployment.md)
  and live account-side settings. Workflow YAML alone cannot establish whether
  a push or merge publishes.
- For user-facing changes, assess the existing design system, accessibility,
  localization, and surrounding interaction behavior. Use the relevant design
  reference rather than adding universal visual rules to the implementation
  agent's always-loaded instructions.

Report unrelated pre-existing inconsistencies separately. Review the complete
candidate within its agreed scope; a fixed-diff review is not evidence that all
older documentation or runtime paths are current.
