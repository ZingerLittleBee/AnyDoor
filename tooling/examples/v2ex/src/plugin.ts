import { definePlugin, actions, type Row, type FetchFn, type Store } from "@anydoor/api";
import manifest from "./manifest.js";

// A real-world Script Plugin for V2EX (https://www.v2ex.com):
//   - fetch the public v1 hot + latest topic feeds and merge them into one
//     searchable palette list,
//   - drill into a per-topic markdown Detail (content, plus comments when a
//     personal access token is stored),
//   - store an optional V2EX token so the token-gated v2 API can be used,
//   - and open the token settings page in the browser through openURL.
//
// The public v1 feeds need no token, so the whole list and Detail work
// anonymously; a stored token only enriches Detail with the v2 topic body and
// its first comments.

const HOT_URL = "https://www.v2ex.com/api/topics/hot.json";
const LATEST_URL = "https://www.v2ex.com/api/topics/latest.json";
const V2_BASE = "https://www.v2ex.com/api/v2";
const TOKEN_SETTINGS_URL = "https://v2ex.com/settings/tokens";

// Store key for the personal access token and the sentinel row id the token
// row commits to. A `__`-prefixed id cannot collide with a numeric topic id.
const TOKEN_KEY = "token";
const TOKEN_ROW_ID = "__set_token__";

// Cap the comments rendered into a Detail so a hot topic with hundreds of
// replies stays within the simple-markdown budget and the 30s watchdog.
const MAX_REPLIES = 10;

// MARK: - V2EX API shapes (only the fields this plugin reads)

interface Member {
  username: string;
}

interface Node {
  name: string;
  title: string;
}

// A v1 topic. The hot/latest feeds return an array of these directly; the v2
// topic endpoint returns one inside a `V2Response.result`.
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

type TopicSource = "hot" | "latest";

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

/** Merge hot then latest, de-duplicating by topic id and keeping the source. */
function mergeFeeds(hot: Topic[], latest: Topic[]): { topic: Topic; source: TopicSource }[] {
  const seen = new Set<string>();
  const merged: { topic: Topic; source: TopicSource }[] = [];
  const push = (list: Topic[], source: TopicSource) => {
    for (const topic of list) {
      const id = String(topic.id);
      if (seen.has(id)) {
        continue;
      }
      seen.add(id);
      merged.push({ topic, source });
    }
  };
  push(hot, "hot");
  push(latest, "latest");
  return merged;
}

function topicSubtitle(topic: Topic, source: TopicSource): string {
  const sourceLabel = source === "hot" ? "热门" : "最新";
  const node = topic.node?.title ?? topic.node?.name ?? "";
  const author = topic.member?.username ?? "未知";
  return [sourceLabel, node, `${topic.replies} 回复`, `by ${author}`]
    .filter((part) => part.length > 0)
    .join(" · ");
}

function topicMarkdown(topic: Topic, replies: Reply[] | undefined): string {
  const node = topic.node?.title ?? topic.node?.name ?? "";
  const author = topic.member?.username ?? "未知";
  const meta = [node && `\`${node}\``, `**${author}**`, `${topic.replies} 回复`]
    .filter((part) => part.length > 0)
    .join(" · ");

  const lines: string[] = [`# ${topic.title}`, "", meta, "", `[在浏览器中打开原帖](${topic.url})`];

  if (topic.content.length > 0) {
    lines.push("", "---", "", topic.content);
  }

  if (replies === undefined) {
    lines.push("", "> 设置 V2EX Token 后可加载评论。");
  } else if (replies.length === 0) {
    lines.push("", "---", "", "> 暂无评论");
  } else {
    lines.push("", "---", "", `## 评论（前 ${replies.length} 条）`);
    for (const reply of replies) {
      const who = reply.member?.username ?? "匿名";
      lines.push("", `**${who}**`, "", reply.content);
    }
  }

  return lines.join("\n");
}

definePlugin(manifest, {
  async rows(query, api) {
    const [hot, latest] = await Promise.all([
      fetchJSON<Topic[]>(api.fetch, HOT_URL),
      fetchJSON<Topic[]>(api.fetch, LATEST_URL),
    ]);

    const merged = mergeFeeds(hot, latest);
    topics.clear();
    for (const { topic } of merged) {
      topics.set(String(topic.id), topic);
    }

    const token = await readToken(api.store);
    const needle = query.trim().toLowerCase();

    const rows: Row[] = [];
    for (const { topic, source } of merged) {
      const subtitle = topicSubtitle(topic, source);
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

    // The token row is pinned last and always present, regardless of the query,
    // so the token can be set even while the list is filtered.
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
    // Only the token row acts; topic rows drill into Detail instead.
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
