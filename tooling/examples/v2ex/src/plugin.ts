import { definePlugin, actions, type Row, type FetchFn, type Store } from "@anydoor/api";
import manifest from "./manifest.js";

// A real-world Script Plugin for V2EX (https://www.v2ex.com), shaped like the
// Raycast command it mirrors:
//   - the palette ROOT shows only command rows — 热门主题 / 最新主题 / 节点主题
//     and a pinned 设置 Token row — so opening V2EX is instant (no network),
//   - committing a topic command drills into a searchable second-level LIST of
//     topics built by `list(listId, query)`,
//   - a topic row there drills into a per-topic markdown Detail (content, plus
//     comments when a personal access token is stored),
//   - the token row stores an optional V2EX token, or opens the settings page.
//
// The public v1 feeds need no token, so the lists and Detail work anonymously;
// a stored token only enriches Detail with the v2 topic body and its comments.

const HOT_URL = "https://www.v2ex.com/api/topics/hot.json";
const LATEST_URL = "https://www.v2ex.com/api/topics/latest.json";
const V2_BASE = "https://www.v2ex.com/api/v2";
const TOKEN_SETTINGS_URL = "https://v2ex.com/settings/tokens";

// Public v1 endpoint for a single node's recent topics (no token required).
function nodeTopicsURL(node: string): string {
  return `https://www.v2ex.com/api/topics/show.json?node_name=${encodeURIComponent(node)}`;
}

// The list ids the root command rows commit to, matched in `list()`.
const LIST_HOT = "hot";
const LIST_LATEST = "latest";
const LIST_NODE = "node";

// Store keys + the sentinel token row id. A `__`-prefixed id cannot collide with
// a numeric topic id.
const TOKEN_KEY = "token";
const NODES_KEY = "nodes";
const TOKEN_ROW_ID = "__set_token__";

// The default node list mirrors the Raycast V2EX extension. Overridable through
// the `nodes` store key (a space-separated list); a set-nodes UI is a follow-up.
const DEFAULT_NODES = ["programmer", "create", "share", "ideas", "apple", "jobs", "all4all", "qna"];

// Cap topics per node so the merged 节点主题 list stays within the 30s watchdog.
const MAX_TOPICS_PER_NODE = 10;

// Cap the comments rendered into a Detail so a hot topic with hundreds of
// replies stays within the simple-markdown budget and the watchdog.
const MAX_REPLIES = 10;

// MARK: - V2EX API shapes (only the fields this plugin reads)

interface Member {
  username: string;
}

interface Node {
  name: string;
  title: string;
}

// A v1 topic. The hot/latest/node feeds return an array of these directly; the
// v2 topic endpoint returns one inside a `V2Response.result`.
interface Topic {
  id: number;
  title: string;
  url: string;
  content: string;
  replies: number;
  member?: Member;
  node?: Node;
}

interface Reply {
  content: string;
  member?: Member;
}

// The v2 API wraps its payload; v1 does not.
interface V2Response<T> {
  success: boolean;
  message?: string;
  result?: T;
}

// The context persists between invocations, so caching the last listed topics
// lets `detail` resolve a row id without refetching the feeds.
const topics = new Map<string, Topic>();

// MARK: - Helpers

/** GET `url` and parse the JSON body, throwing on a non-2xx status. */
async function fetchJSON<T>(
  fetch: FetchFn,
  url: string,
  headers?: Record<string, string>,
): Promise<T> {
  const response = await fetch(url, headers ? { headers } : undefined);
  if (!response.ok) {
    throw new Error(`V2EX request failed (${response.status}): ${url}`);
  }
  return JSON.parse(response.body) as T;
}

/** Read the stored token, treating an empty or non-string value as absent. */
async function readToken(store: Store): Promise<string | undefined> {
  const value = await store.get(TOKEN_KEY);
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

/** Read the configured node list, falling back to the Raycast default set. */
async function readNodes(store: Store): Promise<string[]> {
  const value = await store.get(NODES_KEY);
  if (typeof value !== "string") {
    return DEFAULT_NODES;
  }
  const nodes = value.split(/\s+/).filter((name) => name.length > 0);
  return nodes.length > 0 ? nodes : DEFAULT_NODES;
}

/** De-duplicate topics by id, keeping the first occurrence. */
function dedupe(list: Topic[]): Topic[] {
  const seen = new Set<string>();
  const merged: Topic[] = [];
  for (const topic of list) {
    const id = String(topic.id);
    if (seen.has(id)) {
      continue;
    }
    seen.add(id);
    merged.push(topic);
  }
  return merged;
}

function topicSubtitle(topic: Topic): string {
  const node = topic.node?.title ?? topic.node?.name ?? "";
  const author = topic.member?.username ?? "未知";
  return [node, `${topic.replies} 回复`, `by ${author}`]
    .filter((part) => part.length > 0)
    .join(" · ");
}

/** Cache the listed topics and map them to searchable palette rows. */
function toRows(list: Topic[], query: string): Row[] {
  topics.clear();
  for (const topic of list) {
    topics.set(String(topic.id), topic);
  }
  const needle = query.trim().toLowerCase();
  const rows: Row[] = [];
  for (const topic of list) {
    const subtitle = topicSubtitle(topic);
    if (needle.length > 0 && !`${topic.title} ${subtitle}`.toLowerCase().includes(needle)) {
      continue;
    }
    rows.push({
      id: String(topic.id),
      title: topic.title,
      subtitle,
      symbol: "text.bubble",
      actionLabel: "详情",
      action: actions.detail(),
    });
  }
  return rows;
}

// A bare image URL in plain V2EX text (the feeds are not markdown, so nothing
// autolinks). The lookbehind skips URLs already inside `![…](…)` / `[…](…)`.
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

function topicMarkdown(topic: Topic, replies: Reply[] | undefined): string {
  const node = topic.node?.title ?? topic.node?.name ?? "";
  const author = topic.member?.username ?? "未知";
  const meta = [node && `\`${node}\``, `**${author}**`, `${topic.replies} 回复`]
    .filter((part) => part.length > 0)
    .join(" · ");

  const lines: string[] = [`# ${topic.title}`, "", meta, "", `[在浏览器中打开原帖](${topic.url})`];

  if (topic.content.length > 0) {
    lines.push("", "---", "", withImagePreviews(topic.content));
  }

  // Comments render as one blockquote per reply — the host draws each quote
  // with a leading bar in secondary text, visually separating the comment
  // section from the plain-paragraph topic body and each comment from the next.
  if (replies === undefined) {
    lines.push("", "---", "", quoted("设置 V2EX Token 后可加载评论。"));
  } else if (replies.length === 0) {
    lines.push("", "---", "", "## 评论", "", quoted("暂无评论"));
  } else {
    lines.push("", "---", "", `## 评论 · 前 ${replies.length} 条`);
    replies.forEach((reply, index) => {
      const who = reply.member?.username ?? "匿名";
      lines.push("", quoted(`**${who}** · ${index + 1} 楼`, withImagePreviews(reply.content)));
    });
  }

  return lines.join("\n");
}

definePlugin(manifest, {
  async rows(query, api) {
    // The root is instant: only command rows and the token row, no network.
    // English subtitles keep the Raycast-style command names searchable.
    const token = await readToken(api.store);
    const commands: Row[] = [
      { id: LIST_HOT, title: "热门主题", subtitle: "View Hot Topics",
        symbol: "flame", actionLabel: "查看", action: actions.list(LIST_HOT) },
      { id: LIST_LATEST, title: "最新主题", subtitle: "View Latest Topics",
        symbol: "clock", actionLabel: "查看", action: actions.list(LIST_LATEST) },
      { id: LIST_NODE, title: "节点主题", subtitle: "View Topics By Node",
        symbol: "square.grid.2x2", actionLabel: "查看", action: actions.list(LIST_NODE) },
    ];

    const needle = query.trim().toLowerCase();
    const rows = needle.length > 0
      ? commands.filter((row) => `${row.title} ${row.subtitle ?? ""}`.toLowerCase().includes(needle))
      : commands;

    // The token row is pinned last and always present, regardless of the query.
    rows.push({
      id: TOKEN_ROW_ID,
      title: "设置 V2EX Token",
      subtitle: token ? "Token 已设置 · 详情将包含评论" : "可选 · 用于加载帖子正文与评论",
      symbol: "key",
      actionLabel: token ? "更新" : "设置",
      isChecked: token !== undefined,
      action: actions.argument(),
    });

    return rows;
  },

  async list(listId, query, api) {
    if (listId === LIST_HOT) {
      const hot = await fetchJSON<Topic[]>(api.fetch, HOT_URL);
      return toRows(dedupe(hot), query);
    }
    if (listId === LIST_LATEST) {
      const latest = await fetchJSON<Topic[]>(api.fetch, LATEST_URL);
      return toRows(dedupe(latest), query);
    }
    if (listId === LIST_NODE) {
      const nodes = await readNodes(api.store);
      const perNode = await Promise.all(
        nodes.map((node) => fetchJSON<Topic[]>(api.fetch, nodeTopicsURL(node))),
      );
      const merged = perNode.flatMap((list) => list.slice(0, MAX_TOPICS_PER_NODE));
      return toRows(dedupe(merged), query);
    }
    // An unknown list id: surface an empty list rather than throwing.
    return [];
  },

  async detail(rowId, api) {
    const topic = topics.get(rowId);
    if (topic === undefined) {
      return "# 未找到\n\n请返回列表重新载入帖子。";
    }

    const token = await readToken(api.store);
    if (token === undefined) {
      return topicMarkdown(topic, undefined);
    }

    // With a token, pull the v2 topic (fresher body/node/author) and its first
    // comments. A failed fetch throws, which the host surfaces inline.
    const headers = { Authorization: `Bearer ${token}` };
    const [detailResponse, repliesResponse] = await Promise.all([
      fetchJSON<V2Response<Topic>>(api.fetch, `${V2_BASE}/topics/${topic.id}`, headers),
      fetchJSON<V2Response<Reply[]>>(api.fetch, `${V2_BASE}/topics/${topic.id}/replies`, headers),
    ]);

    const enriched = detailResponse.result ?? topic;
    const replies = (repliesResponse.result ?? []).slice(0, MAX_REPLIES);
    return topicMarkdown(enriched, replies);
  },

  async action(rowId, _actionId, argument, api) {
    // Only the token row acts; topic and command rows drill in instead.
    if (rowId !== TOKEN_ROW_ID) {
      return;
    }

    const trimmed = (argument ?? "").trim();
    if (trimmed.length === 0) {
      // No token entered: open the settings page so the user can create one.
      await api.openURL(TOKEN_SETTINGS_URL);
      await api.toast("info", "已打开 V2EX Token 设置页");
      return;
    }

    await api.store.set(TOKEN_KEY, trimmed);
    await api.toast("success", "已保存 V2EX Token");
  },
});
