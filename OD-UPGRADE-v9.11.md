# Coral Talk upgrade to v9.11.8 — runbook

**Status: DONE 2026-09-29.** Production runs `opendemocracy/coral-talk:v9.11.8-6f5eba7`; PR #14 merged
(`621216cd5`). See "Deploy results" below. The setup section describes the system as found before the upgrade.

## Production setup (as found)

- **Host:** CapRover on a DigitalOcean droplet (lon1). The hostname says 1 GB, but it has 3.9 GB RAM and no swap. Dashboard: https://captain.comment.opendemocracy.net
- **Apps:**
  - Production: `comment-talk`, `comment-mongo`, `comment-redis`, `comment-fake-site`, `comment-x`
  - Staging: `staging-talk-talk`, `staging-talk-mongo`, `staging-talk-redis`, `staging-fake-site`, `staging-comment-x`
- **Running image:** `opendemocracy/coral-talk:production`
  (digest `sha256:bf738ad63143440615ad0baeee637955c525bfff329d7afd4b432fe5c7a11e34`),
  CapRover deploy version 57, 2 May 2023.
- **MongoDB:** 4.2.24. Mongo and Redis are not published on host ports.
- **Deploys are manual.** The image is built and pushed to Docker Hub by hand and deployed via CapRover.
  GitHub Actions has never run on this repo.
- **Memory (2026-09-23):** 3.9 GB total, ~1.6 GB used, ~2.1 GB available, **no swap**.
  Largest users: `comment-mongo` 427 MB, `comment-talk` 194 MB, `staging-talk-talk` 183 MB,
  `staging-talk-mongo` 103 MB, `captain` 89 MB; everything else under 40 MB.
  v9.11 idles at ~196 MB locally, so the upgrade shouldn't change memory use.
- CapRover containers are named `srv-captain--<app>.<n>.<id>`, not `<app>`. Find one with:
  `docker ps -q -f name=srv-captain--<app>`

## Services that depend on Coral

| Dependency | How it depends on Coral | Affected by v9.11? |
|---|---|---|
| **opendemocracy.net article pages** (Ghost theme) | Load `/assets/js/embed.js` and call `Coral.createStreamEmbed({ storyURL })` | No. The standard embed API is unchanged. v9 draws the comments into the page instead of an iframe. |
| **Slack `#new-comments` channel** | Coral posts every new comment through a Slack webhook (tenant setting "To Slack", trigger: all comments) | No. The webhook settings live in the DB, and v9.11 reads them with the same field names. |
| **[coral-comment-from-slack-widget](../../od-tools/cloudflare-workers/coral-comment-from-slack-widget)** (Cloudflare Worker, `coral-comment-from-slack-widget.opendemocracy.workers.dev`) | Parses Coral's Slack messages by `block_id` (`title-block`, `body-block`, `footer-block`) and the exact footer text `Authored by *Name* \| <…\|Go to Moderation> \| <…\|See Comment>`. Serves `/api/featured` to the homepage widget. | No. v9.11's `publishEvent.ts` is identical, except that it truncates comment bodies to 2,999 characters (previously a longer comment would exceed Slack's limit). Verified by a contract test in the worker repo (`npm test`). |
| **`comment-x` / `staging-comment-x`** (CapRover apps) and the **`gfw-service` DB** in `comment-mongo` | Share the droplet, and possibly the Mongo instance | Down during server work. Point them at the new Mongo in the Mongo 8 move. |

## Post-upgrade checks

**Automated** (read-only; run against staging first, then production):

```sh
scripts/od-post-upgrade-check.sh                                   # production
CORAL_URL=https://<staging-host> scripts/od-post-upgrade-check.sh  # staging
```

This checks health, `embed.js`, the embed bootstrap and AMP embed for a real article, the admin
and moderation pages, and the Slack widget's `/api/featured`. It passed against current production
and against local v9.11 on 2026-09-23.

Also run the worker's contract test whenever Coral changes version:
`cd od-tools/cloudflare-workers/coral-comment-from-slack-widget && npm test`
(if Coral's `publishEvent.ts` changed, update the fixture in `test/parse-comment.test.ts` first).

**Manual** (in a browser):

1. Open a live article and confirm the comments load and look right (v9 no longer uses an iframe,
   so check the site's CSS doesn't clash).
2. Log in as a reader, post a test comment, and confirm it appears.
3. Confirm the comment shows up in the admin moderation queue and can be approved or rejected.
4. **Slack pipeline end to end:** confirm the test comment appears in `#new-comments`. React 👍,
   then check it appears at `/api/featured` and on the homepage widget. Remove the reaction and
   delete the test comment.
5. Compare record counts with the pre-upgrade numbers above (they should only go up).

## Rollback kit

| Layer | Backup | Restore |
|---|---|---|
| Code | git tag `pre-v9.11-upgrade-backup` (148ddc57b) | `git checkout pre-v9.11-upgrade-backup` |
| Image | `opendemocracy/coral-talk:pre-v9.11` (same digest as `:production`, verified on Docker Hub) | CapRover → `comment-talk` → Deployment → Deploy via ImageName |
| Data | `~/Backups/coral-talk/talk-pre-deploy-2026-09-29.archive.gz` (6.1 MB, taken just before the production deploy; gzip-verified) | see below |
| Data (older) | `~/Backups/coral-talk/talk-pre-v9.11-2026-09-23.archive.gz` (6.1 MB, gzip-verified; contains `coral` and `gfw-service` DBs) | see below |

Restoring the data (only needed if data is damaged — v9.11 runs no schema migrations on this DB):

```sh
# on the droplet, after copying the archive up with scp
docker cp talk-pre-v9.11-2026-09-23.archive.gz $(docker ps -q -f name=srv-captain--comment-mongo):/tmp/d.gz
docker exec $(docker ps -q -f name=srv-captain--comment-mongo) mongorestore --archive=/tmp/d.gz --gzip --drop
```

**Do not overwrite** `:pre-v9.11`. Push new builds under their own tag (e.g. `:v9.11.8`), not `:production`.

## Local test results (2026-09-23)

Tested against `mongo:4.2.24` + `redis:6` with the production dump restored:

- Server boots, connects, loads tenant `comment-talk.comment.opendemocracy.net`.
- **No pending migrations.** v9.11 ships the same 4 migrations prod already has
  (latest `1582929716101_sso_secrets`), so starting v9.11 does not alter the DB schema.
- Old data reads correctly via GraphQL (stories, comments, authors).
- `/api/health`, `/admin`, `/admin/moderate`, `/assets/js/embed.js`, `/embed/bootstrap`,
  `/embed/stream/amp`, `/embed/auth` all return 200.
- v9 removed the `/embed/stream` iframe page. The site uses `embed.js` +
  `Coral.createStreamEmbed({...})`, which still works.

Login, posting and moderation were then tested in a browser on staging and production (2026-09-29).

Pre-upgrade counts, for comparison after deploy: comments 4057, users 2479, stories 14939,
commentActions 1647, commentModerationActions 3145.

## Build fixes on the upgrade branch (commit 01bc4456e)

1. `ENV REDISMS_DISABLE_POSTINSTALL=1` in `Dockerfile`: `redis-memory-server` (test-only)
   compiles the latest Redis from source on install; Redis 8 needs bash, which alpine lacks.
2. `--max-old-space-size=8192` added to `client/package.json` `build:client`: the script
   overwrites `NODE_OPTIONS`, so the client build OOMed at Node's default ~2 GB heap.

The build takes ~25 min natively and needs several GB of RAM, so it **cannot be built on the droplet** (no swap, ~2 GB free).

## Deploy results (2026-09-29)

Image `opendemocracy/coral-talk:v9.11.8-6f5eba7` (amd64), built by `.github/workflows/od-build-image.yml`
on the upgrade branch, deployed via CapRover → Deploy via ImageName.

1. **Staging** (`staging-talk-talk`): `/api/version` 8.0.2 → 9.11.8, ~10 s of CapRover 502 during the swap.
   Automated checks passed; browser test on https://staging-fake-site.comment.opendemocracy.net/ passed.
2. **Fresh dump** of `comment-mongo`: `~/Backups/coral-talk/talk-pre-deploy-2026-09-29.archive.gz`.
3. **Production** (`comment-talk`): `/api/version` 8.0.4 → 9.11.8. Automated and manual checks
   (including the Slack pipeline) passed. Counts unchanged: comments 4057, users 2479, stories 14955,
   commentActions 1647, commentModerationActions 3145. Memory: `comment-talk` 266 MB, 1.9 GB available.
4. **PR #14 merged** (merge commit `621216cd5`). The push to `main` triggered `docker-image.yml`, which
   fails at "Set up job" (`stardustventures/caprover-deploy` no longer exists), so nothing auto-deploys.

Known log noise on v9.11, harmless: `failed to set logging project id`, `MaxListenersExceededWarning`
on Redis, `DEP0152`.

## Follow-ups (separate from this upgrade)

- **TOP PRIORITY NEXT SESSION: comments hidden since the Ghost migration (April 2026).**
  The embed passes `storyURL` as `/en/<slug>/`, but older stories are stored as
  `/en/<section>/<slug>/`. Coral creates a new empty story for each new URL, so the old story and its
  comments are never shown. The comments are still in the DB.
  - 2026-09-23 (broad count): 784 of 836 older commented stories shadowed, 1,783 comments.
  - 2026-09-29 (approved comments only, old story whose `/en/<slug>/` twin already exists):
    523 stories, 1,311 approved comments. Grows as older articles get visited.
  - Largest: 5050/nhs-pulls-trans-conference-after-speakers-links-exposed (55),
    oureconomy/conspiracy-theories-aside-there-something-fishy-about-great-reset (47),
    opendemocracyuk/why-is-support-for-nuclear-power-noisiest-… (34),
    north-africa-west-asia/the-us-is-tying-the-hands-of-a-un-agency-for-palestine-refugees (28),
    ournhs/weve-won-our-lawsuit-over-matt-hancocks-23m-nhs-data-deal-with-palantir (24).
  - Fix options: (a) one-off script merging each old story into its new twin (move comments,
    recount), rehearsed on a dump locally first; (b) change the site embed to pass a stable `storyID`.
- **Slack widget `/api/featured-movements` returns 404** on the deployed worker (2026-09-23).
  The Media for Movements box looks undeployed; see the worker's `HANDOFF-movements-comments-box.md`.
- **Slack widget contract test is stranded on a feature branch.** Commit `8105a96` in the worker repo
  (`od-tools/cloudflare-workers/coral-comment-from-slack-widget`: `test/parse-comment.test.ts` +
  `package.json` test script) exists only on `feature/movements-comments-box`. It guards the worker's
  parsing of Coral's Slack messages, unrelated to the movements box. Cherry-pick it onto the worker's
  main (shelved 2026-09-29).
- **MongoDB 4.2 is EOL (April 2023).** Coral now targets MongoDB 8. Upgrade path is stepwise:
  4.2 → 4.4 → 5.0 → 6.0 → 7.0 → 8.0, bumping `featureCompatibilityVersion` at each step.
  Rehearse locally against the dump first.
- **Server follow-ups from 2026-09-29:** ~~SSH root password login~~ done 2026-09-29 (keys only; was `PermitRootLogin yes`,
  `PasswordAuthentication yes`) and bots are trying it — switch to keys only. `apt autoremove` the ~82
  18.04/20.04 leftovers. Decide later whether to unhold Docker for 29.x (check CapRover support first).
- ~~No swap on the droplet~~ Done 2026-09-29: 2 GB `/swapfile`, `vm.swappiness=10`. `apt autoremove` also done.
- **CapRover dashboard exposed on port 3000** over plain HTTP (Swarm ports 2377/7946 are open too). Use a
  DigitalOcean Cloud Firewall allowing only TCP 22/80/443 + ICMP; `ufw` won't work because Docker bypasses it.

## Server upgrade: OS, Docker, CapRover (done 2026-09-29)

### Current state (2026-09-23)

| Component | Installed | Status |
|---|---|---|
| Ubuntu | 18.04.5 LTS | Standard support ended May 2023 |
| Kernel | 4.15.0-197 | Original 18.04 kernel |
| Docker | 19.03.12 (API 1.40) | End of life since 2021 |
| CapRover | 1.10.1 (Oct 2021) | Latest is 1.15.4 (Aug 2026) |

- CapRover 1.12.0+ requires Docker API ≥ 1.43 (Docker Engine 24+), so Docker must be upgraded first,
  and a current Docker needs a newer Ubuntu.
- CapRover 1.13.3 has critical security patches; 1.14.2 has an nginx security fix.
- The GitHub release notes for 1.12–1.15.0 mention no required intermediate versions
  (1.11 and 1.15.x patch notes not fully checked).

### Approach

Upgrade in place, with a DigitalOcean snapshot as a full-machine rollback. This is quicker than
migrating to a fresh droplet. Estimated time is 2–3 hours, including 1–2 hours of downtime.

Do this **after** Coral v9.11 is live and stable, and **before** the MongoDB upgrade.

### Steps

1. **Back up:**
   - Take a fresh Mongo dump and copy it off the server (same method as the rollback kit).
   - Download a CapRover backup (dashboard → Settings → Backup), or copy `/captain/data`.
   - Power the droplet off and take a DO snapshot. A live snapshot can catch Mongo mid-write.
     Power it back on.
2. **Ubuntu 18.04 → 20.04:** `apt update && apt full-upgrade`, reboot, `do-release-upgrade`, reboot.
   Check that all CapRover apps come back (`docker service ls`, and the site loads).
3. **Ubuntu 20.04 → 22.04:** `do-release-upgrade`, reboot, and check again.
4. **Docker:** remove the old `docker-ce` 19.03 packages, add Docker's apt repository for 22.04 (jammy),
   and install current `docker-ce`. Swarm and app data live in `/var/lib/docker` and should survive.
   Confirm with `docker info` (Swarm: active) and `docker service ls` (all services running).
5. **CapRover:** upgrade to 1.15.4 from the dashboard, then check every app, SSL, and the comments
   on a live article.
6. **Clean up:** add a swap file (see Follow-ups) and consider blocking port 3000.

**If anything fails:** restore the DO snapshot. It keeps the same droplet and IP, and takes minutes.

**Optional rehearsal:** create a droplet from the snapshot and run steps 2–5 on it first. It gets a
new IP, which Docker swarm still associates with the old one, so its swarm may need resetting
before CapRover starts. It's only a practice box, so that's acceptable.

### Results (2026-09-29)

Now running: **Ubuntu 22.04.5** (kernel 5.15), **Docker 28.5.2** + containerd.io 1.7.29, **CapRover 1.15.4**
(it also moved itself to nginx 1.31 and certbot v2.11.0). All apps 1/1, Coral checks pass, SSL certs valid,
data unchanged (4059 comments, 2479 users). Memory after restart: ~2.1 GB used, ~1.5 GB available.

Backups taken first: `~/Backups/coral-talk/{prod,staging}-pre-server-2026-09-29-1723.archive.gz`,
`captain-pre-server-2026-09-29-1723.tar.gz`, `captain-pre-caprover-2026-09-29-*.tar.gz`, and a DO snapshot
(droplet powered off).

What actually happened, and what to do differently next time:

1. **First reboot in 1,272 days.** Some services exit once at boot (Mongo not ready yet) and Swarm
   restarts them. Coral answers ~1 minute after boot.
2. **Docker hold blocks `do-release-upgrade`** ("Please install all available updates"): held packages
   with a newer candidate count as pending. Fix: comment out `/etc/apt/sources.list.d/docker.list`, `apt update`.
3. **DigitalOcean's mirror no longer carries focal**, so the upgrader disabled every
   `mirrors.digitalocean.com` entry ("no Release file") and failed on `ubuntu-minimal`. Fix: point
   `sources.list` at `archive.ubuntu.com` (old copy in `/root/sources.list.pre-archive`).
4. Prompts: LXD snap track → `4.0`; `/boot/grub/menu.lst` modified → keep local; remove 82 obsolete
   packages → **No** (would likely remove Docker). Still to clean up with `apt autoremove`.
5. **SSH connection resets after the 20.04 reboot for ~1 h** while sshd itself was fine (other IPs
   reached it). Most likely throttling triggered by polling SSH every 5 s. Don't poll; wait, try once.
   The DO **Recovery Console** (root password) worked as the way in.
6. **22.04 uses cgroup v2; Docker 19.03 can't start any container on it** ("cgroup mountpoint does not
   exist"). ~10 min comments outage until Docker was upgraded. Next time: upgrade Docker immediately
   after the 22.04 reboot (or before, on 20.04).
7. Docker installed from the jammy repo (`/etc/apt/keyrings/docker.asc`), pinned to **28.x** and held:
   Docker 29 raises the minimum API version to 1.44, which older clients may not speak.
8. CapRover: `docker service update --image caprover/caprover:1.15.4 captain-captain` (rollback: same
   with `1.10.1`). Apps kept running.

## Local test environment

The upgrade branch was checked out in a temporary worktree; if that directory is gone, run
`git worktree prune`. Containers `ct-mongo`, `ct-redis`, `ct-talk` (on `localhost:5055`),
network `coraltest`. Clean up with:

```sh
docker rm -f ct-talk ct-mongo ct-redis && docker network rm coraltest
```
