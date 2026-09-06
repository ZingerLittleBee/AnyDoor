# Raycast Clipboard History and Pro Retention Research

- **Research date:** 2026-07-29
- **Scope:** Current Raycast product behavior, with emphasis on Pro entitlement, retention, local storage, search, AI, downgrade behavior, and the macOS v1/v2 capture distinction
- **Sources:** Raycast's current official manual, pricing, billing, product pages, and changelog; a read-only inspection of the locally installed signed Raycast v1 application

## Executive Summary

Raycast Pro does not provide a separate clipboard search engine. It unlocks longer retention choices for the same Clipboard History feature:

- Free users can retain history for up to three months.
- Pro users can additionally choose six months, one year, or unlimited retention.
- Upgrading does not automatically change the active retention setting. The user must explicitly select a longer duration.
- "Unlimited" is defined as indefinite retention, not as a documented promise of unlimited item count, attachment size, or disk usage.
- Clipboard History remains local and is explicitly excluded from Raycast Cloud Sync, including for Pro users.
- Ordinary Clipboard History search is not AI-powered. Ask Clipboard only operates on the latest clipboard entry, while Send to AI Chat and Attach to AI Chat are explicit actions on a selected entry.

Raycast does not publicly document an item-count cap comparable to AnyDoor's current per-kind 100-item cap. Its product contract is time-based retention. The exact internal database, indexing, compaction, and storage-limit implementation is proprietary and undocumented.

## Product Logic

### Capture

Clipboard History records text, images, files, links, emails, colors, and the original clipboard formats supplied by the source. Multiple items copied together are represented as one history entry. Users can exclude applications such as password managers and banking apps.

Raycast for Mac v2 detects clipboard changes directly. Raycast says v1 polled every 0.75 seconds and could miss fast consecutive copies; the event-based v2 design is intended to eliminate that capture gap. This reliability change is independent of the user's Free or Pro entitlement.

### Search and retrieval

The current manual describes:

- search by entry name;
- filters for text, images, files, links, emails, and colors;
- optional on-device OCR so text found in images becomes searchable;
- rename and pin actions;
- restoration of original rich, plain-text, RTF, HTML, and other copied formats;
- an optional setting that moves an item to the top after it is copied or pasted.

Raycast does not publish its complete matching, tokenization, ranking, fuzzy-search, or indexing algorithm. The official documentation does not describe Pro as changing ordinary search quality.

### Retention and Pro entitlement

| Plan | Available retention choices |
|---|---|
| Free / Teams Free | 1 day, 1 week, 1 month, 3 months |
| Pro / Teams Pro | Free choices plus 6 months, 1 year, Unlimited |
| Enterprise | Pricing lists Unlimited Clipboard History; organization policy may control the setting |

Longer retention is not selected automatically after an upgrade. This prevents an entitlement change from silently opting the user into unbounded local storage.

Raycast's current pricing calls this field "Clipboard History Size," but the settings and launch materials define the options by duration. "Unlimited" therefore means no time-based expiration. Raycast publishes no numeric limit for records, bytes, or attachments and no storage-capacity service-level guarantee.

The official Clipboard History product page says pinned entries are not removed. This supports treating pins as exempt from normal retention cleanup. It does not establish that pins survive manual deletion, Delete All, uninstalling the app, or an undocumented subscription-downgrade cleanup path.

### Local storage, sync, and privacy

Raycast says Clipboard History is encrypted on the local disk and does not leave the computer under ordinary operation. The current Cloud Sync manual explicitly lists Clipboard History under "Not Synced," so a Pro subscription enables the retention entitlement on every signed-in platform but does not create one shared cross-device clipboard database.

Two explicit actions cross that local boundary:

- Send to AI Chat or Attach to AI Chat sends the selected entry into the AI workflow.
- Enabling visual information for links fetches remote social-card images and favicons.

An encrypted local export can include Clipboard History. Export is a user-initiated backup or transfer mechanism, not Cloud Sync.

### AI behavior

Ordinary Clipboard History search does not run Raycast AI in the background. Raycast states that AI only runs when explicitly invoked.

Ask Clipboard acts only on the most recently copied item, not on the entire history. Send to AI Chat and Attach to AI Chat operate on the selected entry. There is no official evidence of full-history semantic or AI retrieval for Pro users.

### Downgrade behavior

Raycast documents that cancelling Pro leaves benefits active until the renewal date, after which the account returns to Free. It does not document what happens to records older than three months at that transition:

- immediate deletion is not documented;
- hiding older entries is not documented;
- delayed cleanup is not documented;
- restoration after resubscribing is not documented.

The locally installed Raycast v1 binary contains a confirmation warning stating that reducing the configured history duration removes older entries. That supports destructive cleanup when a user explicitly shortens retention, but it does not prove what the subscription-expiry path does.

## Local Raycast v1 Evidence

A read-only inspection of `/Applications/Raycast.app` found version `1.104.23`, bundle identifier `com.raycast.macos`, signed by Raycast Technologies Inc. The application was not launched, and no Raycast database, account, preferences, clipboard history, or user defaults were read.

The signed executable contains product strings for:

- `Keep History For`;
- `Unlocked with Raycast Pro`;
- `Unlimited Clipboard History`;
- a warning that unlimited history continuously consumes more disk space;
- a confirmation that reducing history duration removes older entries;
- an organization-controlled history length that the user cannot change.

These strings corroborate the public product contract, but they do not expose the internal storage or search implementation.

## Implications for AnyDoor

If AnyDoor follows Raycast's model, the clean contract is:

1. Keep capture and search behavior identical across tiers.
2. Gate retention choices, not search quality, behind entitlement.
3. Treat Unlimited as disabling time-based expiry without a hidden small item-count cap.
4. Keep clipboard history local and outside configuration sync.
5. Exempt pinned items from ordinary retention cleanup.
6. Ask for explicit confirmation before a shorter policy physically deletes records.
7. Define and document downgrade behavior before shipping a paid retention tier. Raycast's public contract leaves this edge case ambiguous.
8. Surface disk usage and cleanup controls because indefinite image and file retention can grow without bound.
9. Prefer event-driven capture over polling so rapid consecutive copies are not silently missed.

## Official Sources

- [Clipboard History manual](https://manual.raycast.com/clipboard-history)
- [Raycast pricing](https://www.raycast.com/pricing)
- [Billing manual](https://manual.raycast.com/billing)
- [Cloud Sync manual](https://manual.raycast.com/cloud-sync)
- [What's New in Raycast for Mac v2](https://manual.raycast.com/new-in-v2)
- [Clipboard History product page](https://www.raycast.com/core-features/clipboard-history)
- [Raycast AI Privacy & Security](https://manual.raycast.com/ai/raycast-ai-privacy-security)
- [Introducing Raycast Pro](https://www.raycast.com/blog/introducing-raycast-pro)
- [Raycast Pro launch changelog](https://www.raycast.com/changelog/macos/1-51-0)
- [Import & Export manual](https://manual.raycast.com/import-export)

## Unknowns

The following are not publicly documented and should not be presented as confirmed:

- the exact database and index implementation;
- item-count, attachment-size, or total-disk hard limits;
- the full search matching and ranking algorithm;
- deduplication semantics across all current macOS versions;
- the scheduling and transaction model of retention cleanup;
- exact data handling when Pro expires and the account returns to Free.
