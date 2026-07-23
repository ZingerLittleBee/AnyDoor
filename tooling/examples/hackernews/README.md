# Hacker News

An AnyDoor Script Plugin that browses [Hacker News](https://news.ycombinator.com).
The palette root shows only command rows — **热门** / **最新** / **最佳** /
**Ask HN** / **Show HN** — and committing one drills into a searchable
second-level list of stories. A story there drills into a per-story markdown
Detail (the Ask/Show text body when present, plus the comment thread).

Everything is public — **no token, no account**: story feeds come from the
official Firebase API, and the Algolia item API returns the full comment tree
in one request. It mirrors the shape of `../v2ex` (`rows` -> `list` ->
`detail`), minus the token machinery.

## Layout

```
src/manifest.ts   Plugin manifest (id "hackernews", capabilities, localized names).
                  Single source of truth for the declared capabilities.
src/plugin.ts     Entry points: rows() / list() / detail() / detailAction() / action().
build.mjs         Bundles src/plugin.ts -> dist/bundle.js and emits
                  dist/manifest.json.
dist/             Build output. This directory is the loadable plugin package.
```

## Build

```bash
pnpm install
pnpm build
```

`dist/` now holds `manifest.json` + `bundle.js` — a valid Script Plugin package.

This example lives inside the tooling tree but is **not** a member of its pnpm
workspace (the workspace only globs `packages/*`). Its own `pnpm-workspace.yaml`
sentinel keeps `pnpm install` local to this directory, and it wires `@anydoor-dev/api`
through a `file:` dependency at `../../packages/api`, so the two build in the same
tree without a published registry.

## Develop (the Dev Plugin loop)

1. In AnyDoor, open **Settings -> Plugins** and enable **developer mode**.
2. Register this project's `dist/` directory as a Dev Plugin.
3. Run the watch build:

   ```bash
   pnpm dev
   ```

   Every save rebuilds `dist/`, and AnyDoor reloads the plugin automatically.

## Capabilities

Declared in `src/manifest.ts` as `capabilities`. This plugin uses:

- `fetch` — the Firebase story feeds and the Algolia item (comment tree) API.
- `store` — persist the Detail-translation toggle across invocations.
- `toast` — surface translation failures without breaking the Detail.
- `translate` — translate story bodies and comments in Detail (opt-in row).

No `openURL`: the Detail's 阅读原文 / 在 HN 中查看讨论 links are plain markdown
links, opened by the host under the same http/https guard.

## Usage (使用说明)

- 在命令面板中打开 **Hacker News**，根层只显示命令行：**热门文章**、
  **最新文章**、**最佳文章**、**问答 Ask HN**、**作品 Show HN**，以及固定在
  最后的 **翻译帖子内容** 开关。命令名可按中英文搜索。
- 回车进入任意命令，即在第二层看到对应的文章列表（每页 25 篇），滚动到底部
  自动加载下一页，直到该 feed 的 id 用尽（如热门最多 500 篇）。可按标题、
  分数、作者搜索（搜索时只过滤已加载的行，不会触发翻页）。开启翻译后，列表
  标题自动翻译（整页标题合并为一次翻译调用并缓存；搜索同时匹配原文与译文）。
- 在列表中选中任意文章回车，进入 **Detail**：
  - 顶部提供「阅读原文」（外链文章）与「在 HN 中查看讨论」链接。
  - Ask HN / Show HN 的正文（若有）渲染在链接下方；HN 的 HTML 文本会转换为
    markdown（段落、斜体、链接、代码块），裸图片链接内联显示预览。
  - 评论树来自 Algolia 的单次请求，按引用块逐条展示（`↳` 数量表示楼中楼
    层级），每页 20 条，滚动到底部自动加载下一页（整树至多展示 200 条）。
- **翻译**：每篇文章的 Detail 底部有「翻译 / 显示原文」按钮，可随时切换当前
  文章的显示语言（标题、正文与评论都会翻译，元信息行、评论昵称与层级标记、
  链接保持原文，滚动加载的评论页沿用当前模式）。根层的
  **翻译帖子内容** 开关行决定新打开的文章默认是否翻译，行尾的「开启 / 关闭」
  badge 显示当前状态，回车切换后立即更新。翻译走 AnyDoor 设置中的翻译服务与
  目标语言；失败时显示原文并提示。

## API version

Built against `apiVersion: 1`. During this milestone the API may change with the
host; there is no compatibility promise yet.
