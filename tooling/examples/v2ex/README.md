# V2EX

An AnyDoor Script Plugin that browses [V2EX](https://www.v2ex.com). The palette
root shows only command rows — **热门主题** / **最新主题** / **节点主题** — and
committing one drills into a searchable second-level list of topics. A topic
there drills into a per-topic markdown Detail (topic body, plus comments when a
token is set). It can store a personal access token to reach the token-gated v2
API.

It is a worked example of the authoring toolchain — see `../../README.md`, and
the Raycast-style nested command shape (`rows` -> `list` -> `detail`).

## Layout

```
src/manifest.ts   Plugin manifest (id "v2ex", capabilities, localized names).
                  Single source of truth for the declared capabilities.
src/plugin.ts     Entry points: rows() / list() / detail() / action().
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

The fast edit-to-palette loop uses **Dev Plugin** mode, which loads a package
directory in place and reloads it on change:

1. In AnyDoor, open **Settings -> Plugins** and enable **developer mode**.
2. Register this project's `dist/` directory as a Dev Plugin.
3. Run the watch build:

   ```bash
   pnpm dev
   ```

   Every save rebuilds `dist/`, and AnyDoor reloads the plugin automatically —
   your changed rows/Detail appear in the palette within seconds.

## Capabilities

Declared in `src/manifest.ts` as `capabilities`. This plugin uses:

- `fetch` — the public v1 topic feeds and the token-gated v2 topic/replies.
- `store` — persist the optional personal access token across invocations.
- `toast` — confirm token saves and settings-page opens.
- `openURL` — open the V2EX token settings page from the token row.
- `translate` — translate topic bodies and comments in Detail (opt-in row).

A capability you did not declare there is a compile-time error if you try to use
it in `plugin.ts` — the manifest is the security boundary.

## Usage (使用说明)

- 在命令面板中打开 **V2EX**，根层只显示命令行：**热门主题**、**最新主题**、
  **节点主题**，以及固定在最后的 **设置 V2EX Token**。命令名可按中英文搜索。
- 回车进入任意命令，即在第二层看到对应的主题列表，可按标题、节点、作者搜索
  （开启翻译后，列表标题自动翻译——整页标题合并为一次翻译调用并缓存，搜索
  同时匹配原文与译文）：
  - **热门主题** / **最新主题**：来自公开的 v1 热门 / 最新接口。
  - **节点主题**：合并去重存储配置中各节点的近期主题（默认节点沿用 Raycast
    版本：`programmer create share ideas apple jobs all4all qna`，可通过 `nodes`
    存储键覆盖；设置节点的界面为后续工作）。
- 在列表中选中任意主题回车，进入 **Detail** 查看正文；Detail 顶部提供
  「在浏览器中打开原帖」链接。列表 → Detail → 返回列表，逐级返回。
  - 正文与评论中的图片链接（`.png` / `.jpg` / `.gif` / `.webp`）会内联显示预览。
  - 设置 token 后，每条评论以引用块展示（作者 · 楼层），滚动到底部会自动加载
    下一页评论（每页 20 条），楼层号跨页连续。
- **设置 V2EX Token**（根层）：
  - 回车后进入参数输入模式，粘贴 token 并回车即可保存（保存后 Detail 会额外加载
    评论）。
  - 留空直接回车，则在浏览器中打开 V2EX 的 token 设置页
    （https://v2ex.com/settings/tokens），方便你生成 token。
- **翻译**：每篇帖子的 Detail 底部有「翻译 / 显示原文」按钮，可随时切换当前
  帖子的显示语言（标题、正文与评论都会翻译，元信息、评论昵称与楼层、链接
  保持原文，滚动加载的评论页沿用当前模式）。根层的
  **翻译帖子内容** 开关行决定新打开的帖子默认是否翻译，行尾的「开启 / 关闭」
  badge 显示当前状态，回车切换后立即更新。翻译走 AnyDoor 设置中
  的翻译服务与目标语言；失败时显示原文并提示。
- **无需 token 也能使用**：主题列表与正文均来自公开的 v1 接口；token 仅用于
  加载 v2 的评论内容。

## API version

Built against `apiVersion: 1`. During this milestone the API may change with the
host; there is no compatibility promise yet.
