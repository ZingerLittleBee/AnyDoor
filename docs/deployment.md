# Deployment entry points

Read this before editing or merging `landing/`, publishing a release, or changing
an update-feed workflow. A GitHub workflow describes only its own deployment
path; account-side Git integrations can deploy the same Worker independently.

| Surface | Entry point | Trigger and verification |
| --- | --- | --- |
| macOS app | [Releasing on GitHub Actions](releasing.md), [Beta Updates](beta-updates.md) | `make release` after `make release-dryrun` pushes a tag; [`release.yml`](../.github/workflows/release.yml) builds, signs after approval, publishes, and deploys. It runs only while the `RELEASE_PIPELINE` repository variable is `actions`. The run's `verify` job checks the Release, feed, and landing site. |
| Marketing Worker `anydoor` | [Landing workflow](../.github/workflows/deploy-landing.yml), [Worker config](../landing/wrangler.jsonc) | Pull requests build without deploying. Each Stable release deploys through `release.yml`; manual `workflow_dispatch` also deploys. Both use the `landing-production` environment. |
| Marketing Worker `anydoor` | Cloudflare Workers Builds Git integration | Disconnected on 2026-10-04 (see [repository setup](releasing.md#repository-setup)). The setting lives outside this repository, so inspect the live Worker settings and deployment history before assuming a merge is release-only. If it is ever reconnected, its production branch and watch paths determine push-triggered builds and deployments. |
| Update-feed Worker `anydoor-feed` | [Feed workflow](../.github/workflows/deploy-feed.yml), [Worker config](../feed/wrangler.jsonc) | Every release, including Beta, deploys its Release's `appcast.xml` asset through `release.yml` (`feed-production`). A manual dispatch redeploys a published Release's feed after approval (`feed-manual`). |

## Cloudflare Git integration: observed state and live checks

On 2026-10-01, merging [PR #130](https://github.com/ZingerLittleBee/AnyDoor/pull/130)
into `main` triggered a production Workers Build for `anydoor` after a `landing/`
change. This established a second deployment path alongside GitHub Actions.
The integration was disconnected on 2026-10-04 during the release-pipeline
cutover. Its configuration is not stored in this repository, so treat that as
the last recorded state and still run the checks below.

Before a `landing/` merge that could reach production:

1. Open Cloudflare Workers & Pages, select `anydoor`, and inspect Settings → Build.
   Record the connected repository, production branch, build/deploy commands,
   root directory, and included/excluded watch paths with the verification date.
2. Inspect the latest builds and deployments, including their source commit.
   Confirm whether the Git integration and GitHub Actions can both publish.
3. Treat an enabled production-branch integration as a deployment trigger when
   requesting authorization for a push or merge. A push that previously skipped
   a build is not evidence that a different path will also skip.
4. After the authorized mutation, verify the resulting source commit and live
   page. Record an unchanged deployment explicitly when no deployment occurred.

Cloudflare documents [production branches](https://developers.cloudflare.com/workers/ci-cd/builds/build-branches/)
and [build watch paths](https://developers.cloudflare.com/workers/ci-cd/builds/build-watch-paths/)
separately. Check both. Changes to Cloudflare settings, workflow dispatches,
rollbacks, pushes, merges, releases, and deployments require explicit user
authorization; this runbook itself performs none of them.

For a release-only policy, the Git integration's automatic production deployment
must be disabled or otherwise reconciled with the Actions path. Prepare and
review that settings change before requesting authorization; changing the YAML
alone does not change the account-side integration.
