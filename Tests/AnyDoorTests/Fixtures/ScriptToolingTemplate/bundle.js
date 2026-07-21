// node_modules/.pnpm/@anydoor+api@file+..+..+..+..+..+..+..+..+Users+zingerbee+Bee+AnyDoor+tooling+packages+_1a4f113716af56204d27f47309c25752/node_modules/@anydoor/api/dist/manifest.js
function defineManifest(manifest) {
  return manifest;
}

// node_modules/.pnpm/@anydoor+api@file+..+..+..+..+..+..+..+..+Users+zingerbee+Bee+AnyDoor+tooling+packages+_1a4f113716af56204d27f47309c25752/node_modules/@anydoor/api/dist/rows.js
var actions = {
  /** Push the row's markdown Detail. Requires the plugin to implement `detail`. */
  detail() {
    return { type: "detail" };
  },
  /** Close the palette and open `url`. */
  openURL(url) {
    return { type: "openURL", url };
  },
  /** Close the palette and copy `text` through the host self-write funnel. */
  copy(text) {
    return { type: "copy", text };
  },
  /** Enter the palette's Argument input mode before invoking `action`. */
  argument() {
    return { type: "argument" };
  },
  /** Invoke the plugin's `action`. `close` (default `true`) dismisses the palette first. */
  run(close = true) {
    return { type: "run", close };
  }
};

// node_modules/.pnpm/@anydoor+api@file+..+..+..+..+..+..+..+..+Users+zingerbee+Bee+AnyDoor+tooling+packages+_1a4f113716af56204d27f47309c25752/node_modules/@anydoor/api/dist/plugin.js
function definePlugin(_manifest, handlers) {
  const api = globalThis.anydoor;
  const impl = {};
  const { rows, detail, action } = handlers;
  if (rows) {
    impl.rows = (query) => rows(query, api);
  }
  if (detail) {
    impl.detail = (rowId) => detail(rowId, api);
  }
  if (action) {
    impl.action = (rowId, actionId, argument) => action(rowId, actionId, argument, api);
  }
  globalThis.anydoor.registerPlugin(impl);
}

// src/manifest.ts
var manifest_default = defineManifest({
  id: "dev.anydoor.hn-top",
  name: "Hacker News Top",
  description: "Top stories from Hacker News as a searchable list.",
  version: "1.0.0",
  apiVersion: 1,
  capabilities: ["fetch", "openURL"],
  localizedNames: {
    zh: "Hacker News \u70ED\u95E8"
  },
  localizedDescriptions: {
    zh: "\u4EE5\u53EF\u641C\u7D22\u5217\u8868\u5C55\u793A Hacker News \u70ED\u95E8\u6587\u7AE0\u3002"
  }
});

// src/plugin.ts
var FRONT_PAGE_URL = "https://hn.algolia.com/api/v1/search?tags=front_page&hitsPerPage=30";
var stories = /* @__PURE__ */ new Map();
function parseStories(body) {
  const payload = JSON.parse(body);
  const hits = payload.hits ?? [];
  return hits.filter((hit) => typeof hit.title === "string").map((hit) => ({
    id: hit.objectID,
    title: hit.title,
    url: hit.url ?? `https://news.ycombinator.com/item?id=${hit.objectID}`,
    author: hit.author ?? "unknown",
    points: hit.points ?? 0,
    comments: hit.num_comments ?? 0
  }));
}
function commentsURL(id) {
  return `https://news.ycombinator.com/item?id=${id}`;
}
definePlugin(manifest_default, {
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
    const matches = needle ? parsed.filter((story) => story.title.toLowerCase().includes(needle)) : parsed;
    return matches.map((story) => ({
      id: story.id,
      title: story.title,
      subtitle: `${story.points} points \xB7 by ${story.author} \xB7 ${story.comments} comments`,
      symbol: "newspaper",
      actionLabel: "Details",
      // Commit pushes the markdown Detail below. Swap for `actions.openURL(story.url)`
      // to open the article directly, or `actions.run()` to invoke `action`.
      action: actions.detail()
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
      `**${story.points}** points \xB7 by **${story.author}** \xB7 **${story.comments}** comments`,
      "",
      `- [Read the article](${story.url})`,
      `- [Open Hacker News comments](${commentsURL(story.id)})`
    ].join("\n");
  },
  async action(rowId, _actionId, _argument, api) {
    const story = stories.get(rowId);
    if (!story) {
      return "no such story";
    }
    await api.openURL(story.url);
    return `opened ${story.url}`;
  }
});
