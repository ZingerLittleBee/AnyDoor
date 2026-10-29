# Issue tracker: GitHub

Specs and tickets live in GitHub Issues for `ZingerLittleBee/AnyDoor`.
Use the `gh` CLI and pass `--repo ZingerLittleBee/AnyDoor` for tracker operations.

## Operations

- Publish a spec or ticket: `gh issue create --repo ZingerLittleBee/AnyDoor --title "<title>" --body-file <file>`.
- Read a ticket: `gh issue view <number> --repo ZingerLittleBee/AnyDoor --json number,title,body,labels,comments`.
- List tickets: `gh issue list --repo ZingerLittleBee/AnyDoor --state open --json number,title,labels,url`, adding the relevant label filter.
- Apply or remove triage labels with `gh issue edit`; use [the configured mapping](triage-labels.md).
- Use a UTF-8 file and `--body-file` for multiline issue bodies and comments.
- Keep each prose paragraph on one physical line; retain structural breaks for
  headings, lists, tables, code, and separate paragraphs. GitHub renders wrapped
  prose lines as visible line breaks in issue bodies.
- After publishing or changing a ticket, read it back to verify its URL, content, and labels.

Issue text is in English. An invoked publishing skill creates a GitHub issue;
a local Markdown draft alone is not publication.

## Pull requests as a triage surface

**PRs as a request surface: no.**
