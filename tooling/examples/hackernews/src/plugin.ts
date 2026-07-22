import {
  definePlugin,
  actions,
  type Row,
  type DetailAction,
  type DetailResult,
  type FetchFn,
  type Store,
  type ToastFn,
  type TranslateFn,
} from "@anydoor/api";
import manifest from "./manifest.js";

// A real-world Script Plugin for Hacker News (https://news.ycombinator.com),
// shaped like the v2ex example next door:
//   - the palette ROOT shows only command rows — 热门 / 最新 / 最佳 / Ask HN /
//     Show HN — so opening Hacker News is instant (no network),
//   - committing a feed command drills into a searchable second-level LIST of
//     stories built by `list(listId, query)`,
//   - a story row there drills into a per-story markdown Detail (the Ask/Show
//     text body when present, plus the comment thread).
//
// Everything is public: story feeds come from the official Firebase API, and
// the Algolia item API returns the FULL comment tree in one request — so unlike
// V2EX there is no token row anywhere. Comments paginate client-side from that
// one response as the user scrolls.

const FIREBASE_BASE = "https://hacker-news.firebaseio.com/v0";
const ALGOLIA_ITEM_BASE = "https://hn.algolia.com/api/v1/items";
const HN_ITEM_URL = "https://news.ycombinator.com/item?id=";

// The list ids the root command rows commit to, matched in `list()`. Each maps
// to a Firebase feed of story ids.
const FEEDS: Record<string, string> = {
  top: `${FIREBASE_BASE}/topstories.json`,
  new: `${FIREBASE_BASE}/newstories.json`,
  best: `${FIREBASE_BASE}/beststories.json`,
  ask: `${FIREBASE_BASE}/askstories.json`,
  show: `${FIREBASE_BASE}/showstories.json`,
};

// Store key + the sentinel row id. A `__`-prefixed id cannot collide with a
// numeric story id.
const TRANSLATE_KEY = "translateDetail";
const TRANSLATE_ROW_ID = "__translate__";

// Cap the per-feed item fetches (one Firebase request per story) so a list
// build stays well within the 30s watchdog.
const MAX_STORIES = 25;

// Comments render 20 per Detail chunk, paginated client-side from the cached
// Algolia tree; the flattened thread is capped so a 1000-comment thread cannot
// balloon the document.
const COMMENTS_PAGE_SIZE = 20;
const MAX_COMMENTS = 200;

// MARK: - API shapes (only the fields this plugin reads)

/** A Firebase item — the feeds resolve to arrays of ids pointing at these. */
interface HNItem {
  id: number;
  by?: string;
  title?: string;
  url?: string;
  text?: string;
  score?: number;
  descendants?: number;
  type?: string;
  dead?: boolean;
  deleted?: boolean;
}

/** An Algolia item: the same story, but carrying its whole comment tree. */
interface AlgoliaItem {
  text?: string | null;
  children?: AlgoliaComment[];
}

interface AlgoliaComment {
  author?: string | null;
  text?: string | null;
  children?: AlgoliaComment[];
}

/** One flattened comment, depth preserved for the thread markers. */
interface CommentNode {
  author: string;
  text: string;
  depth: number;
}

// The context persists between invocations, so caching the last listed stories
// and each opened story's flattened comment thread lets `detail` resolve a row
// id — and page comments — without refetching.
const stories = new Map<string, HNItem>();
const commentCache = new Map<string, CommentNode[]>();

// MARK: - Helpers

/** GET `url` and parse the JSON body, throwing on a non-2xx status. */
async function fetchJSON<T>(fetch: FetchFn, url: string): Promise<T> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Hacker News request failed (${response.status}): ${url}`);
  }
  return JSON.parse(response.body) as T;
}

/** Read the Detail-translation toggle (off unless explicitly enabled). */
async function readTranslateEnabled(store: Store): Promise<boolean> {
  return (await store.get(TRANSLATE_KEY)) === true;
}

/** Decode the HTML entities HN text uses (`&#x27;`, `&quot;`, …). */
function decodeEntities(text: string): string {
  return text
    .replace(/&#x([0-9a-fA-F]+);/g, (_, hex: string) => String.fromCodePoint(Number.parseInt(hex, 16)))
    .replace(/&#(\d+);/g, (_, dec: string) => String.fromCodePoint(Number.parseInt(dec, 10)))
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

/**
 * Convert an HN HTML fragment (`<p>`, `<i>`, `<a>`, `<pre><code>`) into the
 * markdown subset the host renders. Structure first, then a single entity
 * decode at the end — decoding once keeps `&amp;lt;` inside code samples from
 * collapsing twice.
 */
function htmlToMarkdown(html: string): string {
  const structured = html
    .replace(/<pre><code>([\s\S]*?)<\/code><\/pre>/g, (_, code: string) => `\n\`\`\`\n${code}\n\`\`\`\n`)
    .replace(/<a[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g, (_, href: string, label: string) => `[${label}](${href})`)
    .replace(/<i>([\s\S]*?)<\/i>/g, "*$1*")
    .replace(/<b>([\s\S]*?)<\/b>/g, "**$1**")
    .replace(/<code>([\s\S]*?)<\/code>/g, (_, code: string) => `\`${code}\``)
    .replace(/<p>/g, "\n\n")
    .replace(/<br\s*\/?>/g, "\n")
    .replace(/<[^>]+>/g, "");
  return decodeEntities(structured).trim();
}

// A bare image URL in converted text. The lookbehind skips URLs already inside
// `![…](…)` / `[…](…)` markdown produced by the HTML conversion.
const BARE_IMAGE_URL = /(?<![([])\bhttps?:\/\/\S+\.(?:png|jpe?g|gif|webp)(?:\?\S*)?/gi;

/** Turn bare image URLs into markdown images so the host renders previews. */
function withImagePreviews(text: string): string {
  return text.replace(BARE_IMAGE_URL, (url) => `![](${url})`);
}

/** Wrap `paragraphs` into one markdown blockquote (every line `>`-prefixed). */
function quoted(...paragraphs: string[]): string {
  return paragraphs
    .flatMap((paragraph) => ["", ...paragraph.split("\n")])
    .slice(1)
    .map((line) => (line.length > 0 ? `> ${line}` : ">"))
    .join("\n");
}

function storySubtitle(story: HNItem): string {
  const author = story.by ?? "未知";
  return [`${story.score ?? 0} 分`, `${story.descendants ?? 0} 评论`, `by ${author}`].join(" · ");
}

/** Cache the listed stories and map them to searchable palette rows. */
function toRows(list: HNItem[], query: string): Row[] {
  stories.clear();
  for (const story of list) {
    stories.set(String(story.id), story);
  }
  const needle = query.trim().toLowerCase();
  const rows: Row[] = [];
  for (const story of list) {
    const title = story.title ?? `#${story.id}`;
    const subtitle = storySubtitle(story);
    if (needle.length > 0 && !`${title} ${subtitle}`.toLowerCase().includes(needle)) {
      continue;
    }
    rows.push({
      id: String(story.id),
      title,
      subtitle,
      symbol: "newspaper",
      actionLabel: "详情",
      action: actions.detail(),
    });
  }
  return rows;
}

/**
 * Depth-first flatten of the Algolia comment tree, capped at `MAX_COMMENTS`.
 * A deleted comment (null text) contributes nothing itself but its children
 * stay, promoted to its depth so the thread does not dangle.
 */
function flattenComments(children: AlgoliaComment[], depth = 0, out: CommentNode[] = []): CommentNode[] {
  for (const child of children) {
    if (out.length >= MAX_COMMENTS) {
      break;
    }
    if (typeof child.text === "string" && child.text.length > 0) {
      out.push({ author: child.author ?? "匿名", text: child.text, depth });
      flattenComments(child.children ?? [], depth + 1, out);
    } else {
      flattenComments(child.children ?? [], depth, out);
    }
  }
  return out;
}

/** Render one page of comments as per-comment blockquotes; `↳` marks depth. */
function commentsMarkdown(comments: CommentNode[]): string {
  return comments
    .map((comment) => {
      const marker = comment.depth > 0 ? `${"↳".repeat(comment.depth)} ` : "";
      return quoted(`${marker}**${comment.author}**`, withImagePreviews(htmlToMarkdown(comment.text)));
    })
    .join("\n\n");
}

/// Assemble the initial Detail document. `body` is the already-rendered (and
/// possibly translated) Ask/Show text body, empty when the story has none;
/// `comments` is the rendered first comment page. The title, meta line, and
/// links deliberately stay untranslated.
function storyMarkdown(story: HNItem, body: string, comments: string): string {
  const title = story.title ?? `#${story.id}`;
  const meta = [`**${story.by ?? "未知"}**`, `${story.score ?? 0} 分`, `${story.descendants ?? 0} 评论`].join(" · ");
  const discussion = `${HN_ITEM_URL}${story.id}`;
  const links = [
    story.url !== undefined && `[阅读原文](${story.url})`,
    `[在 HN 中查看讨论](${discussion})`,
  ]
    .filter((part): part is string => typeof part === "string")
    .join(" · ");

  const lines: string[] = [`# ${title}`, "", meta, "", links];

  if (body.length > 0) {
    lines.push("", "---", "", body);
  }

  lines.push("", "---", "", "## 评论", "", comments);
  return lines.join("\n");
}

/**
 * Build the Detail translator: identity when translation is off, otherwise one
 * `api.translate` call per rendered chunk (body, or a whole comment page —
 * never one call per comment, which would multiply quota spend by 20). A
 * failed translation toasts once and falls back to the original text, so a
 * broken service degrades the Detail instead of breaking it.
 */
function makeTranslator(
  api: { translate: TranslateFn; toast: ToastFn },
  enabled: boolean,
): (text: string) => Promise<string> {
  return async (text) => {
    if (!enabled || text.length === 0) {
      return text;
    }
    try {
      return await api.translate(text);
    } catch (error) {
      await api.toast("failure", `翻译失败：${error instanceof Error ? error.message : String(error)}`);
      return text;
    }
  };
}

// The subset of the declared capability API the Detail builders need.
type DetailAPI = { fetch: FetchFn; store: Store; toast: ToastFn; translate: TranslateFn };

// Detail footer-action ids: each rebuilds the document in the other mode.
const ACTION_TRANSLATE = "translate";
const ACTION_ORIGINAL = "original";
// A pagination cursor issued by a translated document carries this prefix so
// scroll-loaded comment pages keep the mode the reader chose.
const TRANSLATED_CURSOR_PREFIX = "t:";

function detailCursor(page: number, translated: boolean): string {
  return translated ? `${TRANSLATED_CURSOR_PREFIX}${page}` : String(page);
}

function parseDetailCursor(cursor: string): { page: number; translated: boolean } {
  const translated = cursor.startsWith(TRANSLATED_CURSOR_PREFIX);
  const raw = translated ? cursor.slice(TRANSLATED_CURSOR_PREFIX.length) : cursor;
  return { page: Number.parseInt(raw, 10), translated };
}

/** The footer offers the switch to the mode the document is not in. */
function detailActionsFor(translated: boolean): DetailAction[] {
  return [
    translated
      ? { id: ACTION_ORIGINAL, label: "显示原文" }
      : { id: ACTION_TRANSLATE, label: "翻译" },
  ];
}

/** Fetch the story's whole comment tree from Algolia, flatten, and cache it. */
async function loadComments(storyId: string, fetch: FetchFn): Promise<CommentNode[]> {
  const item = await fetchJSON<AlgoliaItem>(fetch, `${ALGOLIA_ITEM_BASE}/${storyId}`);
  const flattened = flattenComments(item.children ?? []);
  commentCache.set(storyId, flattened);
  return flattened;
}

/** The cursor for the page after `page`, if the thread extends past it. */
function nextCursor(total: number, page: number, translated: boolean): string | undefined {
  return total > page * COMMENTS_PAGE_SIZE ? detailCursor(page + 1, translated) : undefined;
}

/** Build the full Detail document (initial load or a footer-action rebuild). */
async function buildStoryDocument(
  story: HNItem,
  translated: boolean,
  api: DetailAPI,
): Promise<DetailResult> {
  const translate = makeTranslator(api, translated);
  const comments = await loadComments(String(story.id), api.fetch);

  const body = typeof story.text === "string" && story.text.length > 0
    ? await translate(withImagePreviews(htmlToMarkdown(story.text)))
    : "";
  const firstPage = comments.slice(0, COMMENTS_PAGE_SIZE);
  const rendered = firstPage.length === 0
    ? quoted("暂无评论")
    : await translate(commentsMarkdown(firstPage));

  return {
    markdown: storyMarkdown(story, body, rendered),
    more: nextCursor(comments.length, 1, translated),
    actions: detailActionsFor(translated),
  };
}

/** Build one scroll-loaded comment page, keeping the document's mode. */
async function buildCommentsChunk(
  storyId: string,
  page: number,
  translated: boolean,
  api: DetailAPI,
): Promise<DetailResult> {
  // The cache normally holds the tree from the initial document build; a miss
  // (context recreated between chunks) refetches it.
  const comments = commentCache.get(storyId) ?? (await loadComments(storyId, api.fetch));
  const slice = comments.slice((page - 1) * COMMENTS_PAGE_SIZE, page * COMMENTS_PAGE_SIZE);
  if (slice.length === 0) {
    return { markdown: "" };
  }
  const translate = makeTranslator(api, translated);
  return {
    markdown: await translate(commentsMarkdown(slice)),
    more: nextCursor(comments.length, page, translated),
  };
}

definePlugin(manifest, {
  async rows(query, api) {
    // The root is instant: only command rows and the pinned translate toggle,
    // no network. English subtitles keep the feed names searchable both ways.
    const translateOn = await readTranslateEnabled(api.store);
    const commands: Row[] = [
      { id: "top", title: "热门文章", subtitle: "Top Stories",
        symbol: "flame", actionLabel: "查看", action: actions.list("top") },
      { id: "new", title: "最新文章", subtitle: "New Stories",
        symbol: "clock", actionLabel: "查看", action: actions.list("new") },
      { id: "best", title: "最佳文章", subtitle: "Best Stories",
        symbol: "star", actionLabel: "查看", action: actions.list("best") },
      { id: "ask", title: "问答 Ask HN", subtitle: "Ask HN",
        symbol: "questionmark.bubble", actionLabel: "查看", action: actions.list("ask") },
      { id: "show", title: "作品 Show HN", subtitle: "Show HN",
        symbol: "hammer", actionLabel: "查看", action: actions.list("show") },
    ];

    const needle = query.trim().toLowerCase();
    const rows = needle.length > 0
      ? commands.filter((row) => `${row.title} ${row.subtitle ?? ""}`.toLowerCase().includes(needle))
      : commands;

    // The translate toggle is pinned last and always present, regardless of
    // the query. It flips a store flag; Detail reads it per open.
    rows.push({
      id: TRANSLATE_ROW_ID,
      title: "翻译帖子内容",
      subtitle: translateOn ? "已开启 · Detail 将翻译正文与评论" : "使用设置中的翻译服务与目标语言",
      symbol: "character.bubble",
      actionLabel: translateOn ? "关闭" : "开启",
      badge: translateOn ? "开启" : "关闭",
      action: actions.run(false),
    });

    return rows;
  },

  async list(listId, query, api) {
    const feedURL = FEEDS[listId];
    if (feedURL === undefined) {
      // An unknown list id: surface an empty list rather than throwing.
      return [];
    }
    const ids = await fetchJSON<number[]>(api.fetch, feedURL);
    // One Firebase request per story; a single dead/deleted item must not sink
    // the whole list, so per-item failures drop to undefined and are filtered.
    const items = await Promise.all(
      ids.slice(0, MAX_STORIES).map((id) =>
        fetchJSON<HNItem>(api.fetch, `${FIREBASE_BASE}/item/${id}.json`).catch(() => undefined),
      ),
    );
    const alive = items.filter(
      (item): item is HNItem => item !== undefined && item !== null && item.dead !== true && item.deleted !== true,
    );
    return toRows(alive, query);
  },

  async detail(rowId, api, cursor) {
    const story = stories.get(rowId);
    if (story === undefined) {
      return "# 未找到\n\n请返回列表重新载入文章。";
    }

    // A cursor requests one further page of comments in the mode the cursor
    // encodes; the host appends the chunk below the rendered document.
    if (cursor !== undefined) {
      const { page, translated } = parseDetailCursor(cursor);
      return buildCommentsChunk(rowId, page, translated, api);
    }

    // Initial document: the root toggle sets the default mode; the footer
    // action rebuilds this one document in the other mode.
    return buildStoryDocument(story, await readTranslateEnabled(api.store), api);
  },

  async detailAction(rowId, actionId, api) {
    const story = stories.get(rowId);
    if (story === undefined) {
      return "# 未找到\n\n请返回列表重新载入文章。";
    }
    return buildStoryDocument(story, actionId === ACTION_TRANSLATE, api);
  },

  async action(rowId, _actionId, _argument, api) {
    // The translate row toggles the Detail-translation store flag in place;
    // feed and story rows drill in instead of acting.
    if (rowId !== TRANSLATE_ROW_ID) {
      return;
    }
    const next = !(await readTranslateEnabled(api.store));
    await api.store.set(TRANSLATE_KEY, next);
    await api.toast("success", next ? "已开启帖子翻译" : "已关闭帖子翻译");
  },
});
