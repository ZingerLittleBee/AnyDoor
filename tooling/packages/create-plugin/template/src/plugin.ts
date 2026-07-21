import { definePlugin, actions, type Row } from "@anydoor/api";
import manifest from "./manifest.js";

// A working miniature of the target plugin shape:
//   - fetch a JSON endpoint (the Hacker News front page via the Algolia API),
//   - list the results as searchable palette rows,
//   - drill into a per-row markdown Detail,
//   - and open a story in the browser through the openURL capability.
//
// Edit `rows`/`detail`/`action` below, run `pnpm dev`, and the Dev Plugin loop
// reloads the palette on save.

const FRONT_PAGE_URL = "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=30";

interface Story {
  id: string;
  title: string;
  url: string;
  author: string;
  points: number;
  comments: number;
}

// The context persists between invocations, so caching the last fetched stories
// lets `detail`/`action` resolve a row id without refetching.
const stories = new Map<string, Story>();

interface AlgoliaHit {
  objectID: string;
  title?: string;
  url?: string;
  author?: string;
  points?: number;
  num_comments?: number;
}

function parseStories(body: string): Story[] {
  const payload = JSON.parse(body) as { hits?: AlgoliaHit[] };
  const hits = payload.hits ?? [];
  return hits
    .filter((hit): hit is AlgoliaHit & { title: string } => typeof hit.title === "string")
    .map((hit) => ({
      id: hit.objectID,
      title: hit.title,
      url: hit.url ?? `https://news.ycombinator.com/item?id=${hit.objectID}`,
      author: hit.author ?? "unknown",
      points: hit.points ?? 0,
      comments: hit.num_comments ?? 0,
    }));
}

function commentsURL(id: string): string {
  return `https://news.ycombinator.com/item?id=${id}`;
}

definePlugin(manifest, {
  async rows(query, api) {
    const response = await api.fetch(FRONT_PAGE_URL);
    if (!response.ok) {
      throw new Error(`Hacker News request failed with status ${response.status}`);
    }
    const parsed = parseStories(response.body);
    stories.clear();
    for (const story of parsed) {
      stories.set(story.id, story);
    }

    const needle = query.trim().toLowerCase();
    const matches = needle
      ? parsed.filter((story) => story.title.toLowerCase().includes(needle))
      : parsed;

    return matches.map<Row>((story) => ({
      id: story.id,
      title: story.title,
      subtitle: `${story.points} points · by ${story.author} · ${story.comments} comments`,
      symbol: "newspaper",
      actionLabel: "Details",
      // Commit pushes the markdown Detail below. Swap for `actions.openURL(story.url)`
      // to open the article directly, or `actions.run()` to invoke `action`.
      action: actions.detail(),
    }));
  },

  detail(rowId) {
    const story = stories.get(rowId);
    if (!story) {
      return "# Not found\n\nOpen the list again to refresh the stories.";
    }
    return [
      `# ${story.title}`,
      "",
      `**${story.points}** points · by **${story.author}** · **${story.comments}** comments`,
      "",
      `- [Read the article](${story.url})`,
      `- [Open Hacker News comments](${commentsURL(story.id)})`,
    ].join("\n");
  },

  async action(rowId, _actionId, _argument, api) {
    const story = stories.get(rowId);
    if (!story) {
      return "no such story";
    }
    await api.openURL(story.url);
    return `opened ${story.url}`;
  },
});
