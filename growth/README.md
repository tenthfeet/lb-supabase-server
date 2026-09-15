# growth.lilbrahmas.org — deploy kit

**Status: git, DNS, cPanel and SSL are done. The Supabase stack is complete: running, isolated from enroll, registered as instance 2, and public at https://api.growth.lilbrahmas.org since 14 Sep 2026. Its database is empty. The serving design was decided on 14 Sep 2026 (step 1). Step 2, data route and scope, was done on 15 Sep 2026: the copy goes through Lovable Cloud's SQL editor as JSON (`MIGRATION-RECORD.md`). Step 3 closed Studio to every address on 15 Sep 2026.** Eight steps remain, one conversation each: see *Remaining steps*.

This folder is the deploy kit for the second app on the VPS. It is deliberately
thin right now — most of enroll's documents are records of a migration that has
already happened, and growth's has not. What exists here is what is true.

| File | What |
|---|---|
| `GIT-SETUP.md` | The completed git work: deploy key, ssh alias, clone. Also the template for instance 3. |
| `STACK-PROVISIONING.md` | The Supabase stack work: what is done, the baseline to verify against, and where the runbook diverges for growth. |
| `MIGRATION-RECORD.md` | Moving the data: route, scope, and later the import and cutover. Started by step 2. |
| `README.md` | This file. Where things stand and what the next decision is. |

Everything else — `OPERATIONS.md`, `deploy-growth`, the migration record — gets
written when the work it describes actually happens.

---

## Where things stand

| | |
|---|---|
| ✅ **Deploy key** | `/root/.ssh/growth_deploy`, read-only, on the new repo |
| ✅ **SSH alias** | `github-growth` in `/root/.ssh/config`; enroll moved to `github-enroll` |
| ✅ **Clone** | `/opt/apps/growth`, 13 MB, `--filter=blob:none` |
| ✅ **Enroll verified healthy** | after the ssh config change, via `ls-remote` |
| ✅ **cPanel** | one account `growthlilbrahmas` owns both hostnames, enroll's shape. `api.growth.lilbrahmas.com` was created by mistake and has been terminated |
| ✅ **DNS** | both names resolve to `184.168.122.104`, authoritatively and publicly |
| ✅ **SSL** | one Let's Encrypt SAN cert covers both hostnames, valid to 11 Dec 2026 |
| ✅ **Supabase stack** | running since ~07:05 UTC 13 Sep 2026 at `/opt/supabase/stacks/growth`: 11/11 healthy, ports 8010 / 5442 / 6553 on loopback only, keys and tokens proven isolated from enroll, enroll and coturn verified undisturbed. Empty database — no migrations applied. Registered as `growth = instance 2` in `/opt/supabase/README.md`. **Public since 14 Sep 2026** at `https://api.growth.lilbrahmas.org` through Apache (runbook §8–§9 verified): GoTrue, WebSocket and the ACME renewal path work through the proxy, Studio asked for its basic-auth login, and enroll and coturn were verified undisturbed. **Studio closed to every address since 15 Sep 2026** (step 3): Apache answers `403`, and the API paths and ACME stay public |
| 🟡 **`.env.production.local`** | decided in step 1 (open question 3): build-time `VITE_*` only, as enroll. Not created yet — step 6 |
| 🟡 **Serving** | ✅ design decided 14 Sep 2026 (step 1): bun build via `NITRO_PRESET`, port `3010` on loopback, enroll's env pattern, `pg_cron` enabled, AI features pending. Nothing built on the server yet — steps 6 and 7 |
| ✅ **Data route and scope** | decided 15 Sep 2026 (step 2): Lovable Cloud's SQL editor, one JSON document per table, keeping all 40 users' passwords. Scope snapshot: 180 tables (120 with rows), 11,980 rows, 40 users, 4 storage files, ~9.7 MB as JSON. Nothing imported yet — step 5 |

---

## Key facts

| | |
|---|---|
| GitHub repo | `librahmas-hue/learniverse-hub-442-dfdb7c25` |
| Clone address | `git@github-growth:librahmas-hue/learniverse-hub-442-dfdb7c25.git` |
| Lovable project | `f44cdfc8-b7a6-443d-b6a2-59b1ae8283f7` |
| Lovable Cloud ref | `hwchtywjbmcvpucidfmy` — the analogue of enroll's `pcuzksquykmyboxxrawb` |
| Current Lovable host | https://learniverse-hub-442.lovable.app |
| Intended hostnames | `growth.lilbrahmas.org`, `api.growth.lilbrahmas.org` |
| Instance number | 2 → Supabase ports **8010 / 5442 / 6553** |
| Local working copy | `D:\laragon\www\growth.lilbrahmas` |

**The app is "Team Ascent Portal"** — an internal HR and LMS system. 119 route
files, 111 of them behind `_authenticated`. Role-controlled, bilingual,
certification tests. Not a public marketing site like enroll, which matters for
how access is gated.

> The server checkout was taken at `c496de2` with 224 migrations. The local copy
> a few hours later was `abf109aa` with **226**. Lovable pushes frequently;
> re-check counts rather than trusting any written here.

---

## The finding that changed the plan

**Growth is not a static SPA.** It is TanStack Start on Nitro — server-rendered,
with `nitro@3.0.260603-beta` and **Cloudflare as the default build target**.
There is no `index.html` and no `src/main.tsx`.

The evidence that settles it:

- **36 modules of `createServerFn`** in `src/lib/*.functions.ts` — HR letters,
  payroll, attendance, DWR, onboarding, resignations, bulk user operations,
  tests, analytics. This is the business logic, not a few helpers.
- **A service-role Supabase client** (`src/integrations/supabase/client.server.ts`)
  that bypasses RLS, reading `SUPABASE_SERVICE_ROLE_KEY` from the process
  environment.
- **Two server routes under `src/routes/api/public/hooks/`** called by `pg_cron`
  every ~15 minutes.

So growth needs a **running process**, not a directory of files. Enroll's
publish path — `vite build` → `dist/` → rsync into `public_html`, with
`.htaccess` doing SPA routing — does not carry over at all.

### What still carries over from enroll

Roughly half of `deploy.sh`: stack provisioning per the adding-instance runbook,
the migration ledger and apply logic, the RLS and GRANT audits, the backup path,
and the git guards. There are **zero Supabase edge functions** — growth put that
logic in server functions instead — so the entire function sync and restart path
drops out.

### Two things to know before calling any migration "done"

**Growth depends on Lovable at runtime, not just for development.**
`LOVABLE_API_KEY` is used in `src/lib/ai.functions.ts` and
`src/lib/module-auto.functions.ts` — Lovable's AI gateway, powering ask-AI and
AI training. `src/integrations/lovable/index.ts` also wires OAuth sign-in through
`@lovable.dev/cloud-auth-js`. Enroll moved off Lovable Cloud completely; growth
cannot without replacing these. No hosting choice changes it.

**~~Postgres calls the app back over HTTP.~~ — this was wrong.** Checked against
all 226 migrations on 12 Sep 2026: there are **zero** `CREATE EXTENSION`
statements and **zero** `pg_net` / `net.http_post` references. The only
`cron.schedule` calls run plain SQL, and the whole block is guarded by
`IF EXISTS (… extname = 'pg_cron')`, so with the extension absent it schedules
nothing and still succeeds. No `pg_net`, no callback URL. The two hook routes are
orphans that nothing calls, and they are gated only by the publishable key —
which ships in the browser bundle. See `STACK-PROVISIONING.md` §§3.4–3.5.

**Update, 14 Sep 2026: at HEAD `4dc6623` pg_cron is required.** The repo now has
**246** migrations. Two added that morning, `20260914051218_*` and
`20260914051303_*`, read `cron.job` and call `cron.schedule` **without** the
`IF EXISTS` guard, to schedule a daily `renew-monthly-incentive-plans` job. With
the extension absent the `cron` schema does not exist, so under `ON_ERROR_STOP`
step 4 would stop at the first of them. Still no `CREATE EXTENSION`, no `pg_net`.

**Update, 15 Sep 2026: `pg_net` is used.** Migration `20260914120009_*`
schedules `attendance-roll-day` daily at 19:15 UTC as a `net.http_post` to the
**Lovable-hosted app's** hook URL, with Lovable Cloud's anon key. Applying it
needs only `pg_cron`. Left as it is on the VPS, it either calls Lovable's app
or fails nightly, depending on whether growth's stack has `pg_net` (unchecked).
A second HTTP job, `dwr-shift-cutoff-nudge` (every 15 minutes), exists **only in
Lovable Cloud**. No migration creates it, so DWR nudges stop at cutover unless
something replaces it. Step 4 handles both. Details in `MIGRATION-RECORD.md` §1.

The server needs four variables: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
`SUPABASE_PUBLISHABLE_KEY`, `LOVABLE_API_KEY`. **The last will not be available
at deployment** (open question 6): the three AI features are pending.

---

## The decision taken

**Run the app in a container on the VPS**, bound to loopback, with Apache
reverse-proxying to it — the same shape as the Supabase gateway proxy in
adding-instance runbook §8.

The deciding argument was the service-role key: on the VPS it never leaves the
box and the app can reach Supabase over loopback, where on Cloudflare an
RLS-bypassing credential would live off-box and cross the internet on every
admin operation. `pg_cron`'s callback stays local too.

**The cost, stated plainly:** this means supervising a long-lived process built
on beta software. Enroll only ever had to produce files Apache serves — if
enroll's build breaks, the previous files keep serving. If growth's process dies,
the site is down. It needs a healthcheck and a restart policy from the start, not
added later. The prep runbook's warning is directly on point: four services on
this box died silently because nothing watched them.

Cloudflare remains a defensible alternative if the beta runtime proves not worth
supervising.

---

## Hard constraints

**Do not disturb coturn or enroll.** Both are live. Four specific risks:

1. **Docker rewrites iptables when it creates a network.** Addendum §3.3 argues
   this is invisible to coturn, whose relay traffic never traverses `FORWARD` —
   verify anyway. It is also where WHM's SMTP restriction rules can be lost, and
   `nft list ruleset` silently omits them, so the check must use `iptables-save`.
2. **Port collision.** coturn relays on 49152–65535 and
   `net.ipv4.ip_local_port_range` is pinned to `32768 49151`. Growth's app port
   must sit below 32768, clear of the Supabase bands and cPanel's 2082–2096.
3. **Container, network or project-name collision with enroll.** Growth is its
   own compose project on its own network. Never joined to enroll's.
4. **Apache.** Config lives in a *new* cPanel include directory. Enroll's is not
   touched, and the vhost is never edited directly.

Note enroll's shape when reasoning about isolation: its **Supabase stack** runs
in Docker, but its **frontend** is static files in `/home/enroll/public_html`
served directly by Apache.

---

## Open questions, in the order they block things

1. **App server port scheme.** ✅ **Decided 14 Sep 2026: `3000 + 10(N-1)`, so
   growth is `3010`**, bound to `127.0.0.1` only. Re-checked free on the server
   at 07:16 UTC (`STACK-PROVISIONING.md` §5 item 4). Step 6 re-checks it
   immediately before the container binds it.
2. **Nitro preset.** Currently Cloudflare by default, and it is not set anywhere
   in the repo — it comes from `@lovable.dev/vite-tanstack-config@2.13.1`.
   Target **`bun`**, not `node-server`: Lovable's toolchain is bun and this
   server has no Node. Whether an env var can override the wrapper, or only
   editing `vite.config.ts` can, is the open part — and it decides whether this
   is maintainable, since Lovable owns that file. **Answerable off the server.**
   ✅ **Decided 14 Sep 2026: the environment variable, no Lovable change.**
   Proven on the working copy at `4dc6623`: `NITRO_PRESET=bun` alone gives
   `.output/nitro.json` → `"preset": "bun"`, and the output serves on loopback
   (`STACK-PROVISIONING.md` §5 item 1). `deploy-growth` sets `NITRO_PRESET=bun`
   and refuses to deploy unless `.output/nitro.json` says `"bun"`, so a wrapper
   update that stops honouring the variable fails the deploy instead of shipping
   a Cloudflare build. `vite.config.ts` stays untouched. Lovable's own builds
   are unaffected either way: inside its sandbox the wrapper deletes
   `NITRO_PRESET` and forces its own Cloudflare preset.
3. **Where the four environment variables live**, and how the service-role key is
   handled — stack `.env` is mode 600 for this reason. Note these are read from
   `process.env` at runtime, not baked at build time like enroll's `VITE_*`.
   **Answered 14 Sep 2026: follow enroll.** Build time, decided: growth's
   `VITE_SUPABASE_URL` (`https://api.growth.lilbrahmas.org`) and
   `VITE_SUPABASE_PUBLISHABLE_KEY` go in `/opt/apps/growth/.env.production.local`
   (gitignored), created once by hand as in enroll's `deploy.sh` setup step 5.
   `deploy-growth` refuses to build without it and, after the build, refuses if
   `hwchtywjbmcvpucidfmy` appears in `.output/public` **or** `.output/server`:
   growth's server-rendered code bakes the values too (`STACK-PROVISIONING.md`
   §5 item 5). ✅ **Runtime, decided 14 Sep 2026, enroll's secrets pattern:**
   growth's stack `.env` (mode 600) stays the only secrets file. The app
   container's compose file maps in, by name, only `SUPABASE_URL`,
   `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_PUBLISHABLE_KEY`, and
   `LOVABLE_API_KEY` wired empty (question 6) — enroll's "wired, empty —
   outstanding". No value is copied into another file, and the container never
   sees `JWT_SECRET`, `POSTGRES_PASSWORD` or the rest. Bun starts with
   `--no-env-file`, so the committed `.env` (Lovable Cloud) is never read. The
   exact values and the network path to Supabase are step 6's.
4. ~~`pg_cron` / `pg_net`~~ — **resolved, not required.** See above.
5. **Whether to enable `pg_cron` anyway.** Nothing needs it, but without it the
   two SQL jobs in `20260722071430_*` never run, and nothing reports that. The
   migration schedules them only if the extension already exists, so this has to
   be decided before the migrations are applied. **Since 14 Sep 2026 no longer
   optional:** two unguarded migrations fail without it — see the update under
   *Two things to know*. ✅ **Decided 14 Sep 2026: enable it.** Step 4's first
   action is `CREATE EXTENSION pg_cron`, before any migration. Growth's Postgres
   already preloads it with `cron.database_name: postgres`, so no config change
   or restart (`STACK-PROVISIONING.md` §3.4). Step 5 pauses the three jobs during
   the rehearsal import, because they write rows the counts would not expect.
6. **Whether `LOVABLE_API_KEY` works off Lovable.** ✅ **Decided 14 Sep 2026:
   it will not be available.** Lovable secrets are write-only and this one is
   Lovable-managed (`STACK-PROVISIONING.md` §5 item 8). The three AI features —
   **ask-AI, AI training and call audits — are pending**, to be handled after
   deployment. The app deploys without the key. What users see meanwhile: each
   server function checks the key first and throws a plain error —
   `AI is not configured` (`ai.functions.ts` ×2, `module-auto.functions.ts`) or
   `AI is not configured for this project.` (`call-audits.functions.ts` ×3) —
   so the features fail visibly and nothing else is affected.

✅ **All answered by step 1 on 14 Sep 2026.** No change was asked of Lovable.
The evidence is in `STACK-PROVISIONING.md` §5.

---

## Next step

**Steps 1, 2 and 3 are done** (14–15 Sep 2026). Next: step 4, whose
prerequisites (1 and 2) are met. Step 9 has none. Step 5 waits on 4.
The latest host snapshot is from **15 Sep 2026, 08:54 UTC**, re-checked unchanged
at 10:46 after step 3's reloads (`STACK-PROVISIONING.md` §6).
Nothing on the app side has been built on the server.

**The baseline below was captured on 12 Sep 2026** — recorded values are in
`STACK-PROVISIONING.md` §2, which also explains why the raw coturn capture is
unusable for comparison and which file to use instead.

**Since 13 Sep 2026 that baseline is superseded.** The stack was started at
~07:05 UTC that day. For anything after it, compare against the **pre-start
snapshot** (07:03 UTC) and use the **reusable checks** — both in
`STACK-PROVISIONING.md` §4, which ends with the list of what remains. Before the
Apache work on 14 Sep a fresh snapshot was taken (04:31 UTC) and the firewall
was saved again to `/root/growth-preproxy-iptables.txt`. From then on the
firewall is compared against that copy.

The capture commands that used to sit here were removed on purpose: they
**overwrite** the baseline files they write to, so re-running them "at the end"
destroys the thing being compared against — and the enroll health check among
them (`grep -vc healthy`) passes on unhealthy or exited containers.

---

## Remaining steps — one conversation each

Each step is done in its own conversation. Start it with the brief under
*Starting a step conversation*. A step is finished when its **Done when** is true
and recorded: in this README's status table, and in the step's own record
(`STACK-PROVISIONING.md`, or the `MIGRATION-RECORD.md` and `OPERATIONS.md` that
steps 2 and 6 start).

| # | Step | Needs | Where the work happens |
|---|---|---|---|
| 1 | ✅ Serving design decisions — done 14 Sep 2026 | — | workstation, Lovable |
| 2 | ✅ Data route and migration scope — done 15 Sep 2026 | — | Lovable Cloud, read-only |
| 3 | ✅ Restrict Studio — done 15 Sep 2026 | — | server, Apache |
| 4 | Apply the migrations | 1, 2 | server |
| 5 | Rehearsal data import | 2, 3, 4 | server |
| 6 | `deploy-growth` and the app container | 1, 4 | server |
| 7 | Apache proxy for growth.lilbrahmas.org | 6 | server, Apache |
| 8 | Postgres backups | 4 | server |
| 9 | SMTP | — | server, mail provider |
| 10 | Cutover | 5–9 | server, Lovable |
| 11 | Monitoring and a reboot test | 6 | server |

Two items sit earlier than the work they relate to. The `pg_cron` decision is in
step 1 because the migrations only schedule its jobs if the extension already
exists. Studio is restricted in step 3 because the rehearsal import in step 5
puts real HR data on the box.

### 1. Serving design decisions

Settle what gets built. Answers every item under *Open questions*.

- Prove the Nitro build can target `bun` instead of Cloudflare: install and build
  in `D:\laragon\www\growth.lilbrahmas` with the preset overridden, and check that
  `.output/server/index.mjs` appears. If only a `vite.config.ts` edit works, that
  change goes through Lovable.
- Sign off port 3010, re-checked free.
- Where the four runtime variables live, and whether the browser bundle also
  bakes in `VITE_*` values.
- Whether `LOVABLE_API_KEY` works off Lovable.
- Whether to enable `pg_cron`.

**Done when** each open question has a recorded answer.

✅ **Done 14 Sep 2026.** All six open questions answered; see *Open questions*.

### 2. Data route and migration scope

Know what moves and how, before anything is imported. Writes nothing anywhere.

- Find a read route out of Lovable Cloud `hwchtywjbmcvpucidfmy`: direct Postgres,
  then the service-role key, then the publishable key (enroll `00-PLAN.md`
  Phase 0.2). Most HR data sits behind RLS, so the publishable key alone is
  unlikely to reach it.
- Row counts per table, the number of auth users, storage buckets and object
  counts.
- Re-count the migrations at HEAD; there were 246 at `4dc6623` on 14 Sep 2026.

**Done when** the route and the scope table are recorded in a new
`MIGRATION-RECORD.md`.

✅ **Done 15 Sep 2026.** Route decided: **Lovable Cloud's SQL editor, one JSON
document per table**, for step 5 and again at step 10. *Export data* is not used,
because it leaves passwords out. What step 5 inherits, including keeping the
download's secrets off the screen, is in `MIGRATION-RECORD.md` §5. Scope snapshot: **180 tables** (120 with rows), **11,980 rows**,
**40 auth users**, **4 storage objects** (~3.4 MB) across 7 private buckets that no
migration creates. The repo at `63b7ca15` has **263** migrations, matching
Lovable's ledger, and its `types.ts` matches the tables name for name. All 40 users have a bcrypt hash the SQL
editor can read. Lovable's Export leaves passwords out. Five `pg_cron` jobs run
in the source. Two call the Lovable-hosted app, and one of those is not in any
migration (see *Two things to know*). All 30 `employee_documents` rows point at
files that do not exist, in production today. `escalate-stale-approvals` had failed 168 of 168 runs in
7 days on a bug in its own function (`change_requests` has no `user_id`). Lovable
fixed it on 15 Sep in migration `20260915081117_*`, which makes **264**
migrations. Confirmed working by its 08:15 UTC run, which flagged 108 stale
approvals once each. A JSON copy of everything is ~9.7 MB. Left: choose the
copy route. See `MIGRATION-RECORD.md`.

### 3. Restrict Studio

Studio at `https://api.growth.lilbrahmas.org/` is a full database admin UI behind
basic auth only. enroll has the same exposure.

- An address allow-list at Apache that restricts Studio while keeping the API
  paths (`/auth/v1/`, `/rest/v1/`, `/realtime/v1/`, `/storage/v1/`, …) public.

**Done when** Studio refuses a request from an address not on the list, and
steps 45–47 of the adding-instance runbook still pass.

✅ **Done 15 Sep 2026: Studio is closed to every address.** Four unrelated
addresses had tried its login on 14 Sep, and the operator's mobile hotspot
cannot go on an allow-list, so the list starts empty. A new
`studio-closed.conf` beside `supabase.conf` makes Apache answer `403` for
everything except `/auth/v1/`, `/rest/v1/`, `/realtime/v1/`, `/storage/v1/` and
`/.well-known/`.
- **What the first attempt showed:** it still returned Envoy's login prompt,
  because cPanel's global `ErrorDocument 403 /403.shtml` was forwarded through
  `ProxyPass /`. `ErrorDocument 403 default` fixed it.
- **Verified:** runbook steps 45–47, `/rest/v1/` and `/storage/v1/`, and seven
  attempts to get past the rule. Enroll and coturn are undisturbed.
- **Enroll's Studio is still public behind its login.** That is a separate
  decision (`enroll/LAUNCH-CHECKLIST.md` item 8).

Rollback, and how to allow one address later, are in
`STACK-PROVISIONING.md` §6.

### 4. Apply the migrations

Growth's schema on its stack, with a ledger. **Needs** 1 (the `pg_cron` decision)
and 2 (the migration count).

- First `CREATE EXTENSION pg_cron` (step 1, open question 5). Two migrations
  fail without it.
- From step 2: create the 7 storage buckets, which no migration creates. After
  the migrations, unschedule or repoint `attendance-roll-day`, which calls the
  Lovable-hosted app. Check whether growth's stack has `pg_net`, and compare its
  extensions with the source's seven. `dwr-shift-cutoff-nudge` is not in any
  migration; replace it (`MIGRATION-RECORD.md` §1).
- Reuse enroll's apply logic: a ledger, `ON_ERROR_STOP`, refusal to run against a
  non-empty `public`. enroll's `.applied-migrations` must not be imported
  (`STACK-PROVISIONING.md` §3.3).
- Compare the resulting schema with `types.ts`, then run the RLS and GRANT audits
  (enroll `OPERATIONS.md` §3).

**Done when** every migration is in the ledger, the schema matches `types.ts`, and
both audits pass or their exceptions are written down.

### 5. Rehearsal data import

Prove the import end to end on a copy. Cutover repeats it for real. **Needs** 2, 3
and 4.

- Pause every job in `cron.job` while importing (`cron.alter_job(…, active :=
  false)`): they write rows the counts would not expect.
- Users before data, keeping their original IDs (enroll `00-PLAN.md` Phase 2).
  Inserting users fires `on_auth_user_created_dev_roles`, which creates `profiles`
  rows and `trainee` roles that the imported data would duplicate.
- Tables parents first, by the foreign-key graph, IDs kept (enroll
  `MIGRATION-RECORD.md` §5). Storage objects too, if step 2 found any.
- Signups in both directions: public signup refused, admin-created users still
  work (`STACK-PROVISIONING.md` §3.7, never tested).

**Done when** row counts match step 2's scope and the import is a repeatable
script.

### 6. `deploy-growth` and the app container

The app running on the VPS. **Needs** 1 and 4.

- The script: git guards from enroll's `deploy.sh`, `bun install
  --frozen-lockfile` (two lockfiles exist), build.
- A container bound to `127.0.0.1:3010`, with a restart policy from the start and
  a healthcheck that calls a server function rather than fetching `/`.
- The runtime variables wired as step 1 decided. The service-role key never
  leaves the box.
- From step 1: the git guard runs **before** the build, which regenerates
  `src/routeTree.gen.ts`. Build with `NITRO_PRESET=bun`, then refuse unless
  `.output/nitro.json` says `"bun"`. Refuse without `.env.production.local`, and
  if `hwchtywjbmcvpucidfmy` is in `.output/public` or `.output/server`. Start Bun
  with `--no-env-file`. Re-check port 3010 is free just before binding it.

**Done when** the container comes back healthy after a restart, and a new
`OPERATIONS.md` describes deploying.

### 7. Apache proxy for growth.lilbrahmas.org

The frontend hostname serves the app. **Needs** 6.

- The adding-instance runbook's §8 procedure, steps 38a–41, with
  `ProxyPass /.well-known/ !` first: one certificate covers both hostnames.
- Block `/api/public/hooks/` from outside, and call the two hook routes from a
  host cron job over loopback (`STACK-PROVISIONING.md` §3.5).

**Done when** runbook step 48 shows the app's page title and the ACME probe passes
on both hostnames.

### 8. Postgres backups

A copy of the database that survives the box. **Needs** 4; **before** 10.

- A scheduled `pg_dump` through `docker compose exec -T db`, stored outside
  `/home`, with retention.

**Done when** the latest dump restores into a scratch database.

### 9. SMTP

Password reset works. **Before** 10.

- A real mail provider in the stack's `SMTP_*` settings.

**Done when** a reset email arrives and its link signs the user in.

### 10. Cutover

Users on growth.lilbrahmas.org instead of learniverse-hub-442.lovable.app.
**Needs** 5–9.

- Freeze changes in the Lovable-hosted app, clear the rehearsal data, repeat
  step 5 as the final copy, then move users over.
- From outside, with the publishable key taken from the deployed app: protected
  tables return `[]`, and the built app holds no trace of the Lovable project ID.
- No `cron.job` command on the VPS contains `lovable.app` (`MIGRATION-RECORD.md`
  §1).
- At the freeze, stop Lovable Cloud's own `pg_cron` jobs through Lovable. Two of
  them call the Lovable-hosted app, which writes to Lovable Cloud.

**Done when** users work on the VPS and nothing writes to Lovable Cloud any more.

Known at cutover (step 1): ask-AI, AI training and call audits answer
`AI is not configured` until the AI features are handled after deployment.

### 11. Monitoring and a reboot test

A stopped app or an expiring certificate gets noticed. **Needs** 6; before or
right after 10.

- Alerts for a stopped process and for certificate expiry.
- A reboot test with the app container in the boot path.

**Done when** each alert has fired once on purpose, and every service is back
after a reboot.

### Starting a step conversation

Open with this, filling in the step number:

> Read growth/README.md, growth/STACK-PROVISIONING.md and
> growth/MIGRATION-RECORD.md, then do step N of *Remaining steps*. Constraints that are load-bearing, not stylistic:
>
> - Root SSH is disabled. I run every command in WHM → Terminal and paste the
>   output back.
> - Every command is one line with literal values, never shell variables. The
>   terminal drops spaces and glues output lines, so a mangled command must error
>   or look wrong, never look like a pass.
> - Never let a secret reach the screen.
> - Health checks use `docker compose ps -a`, match the literal `(healthy)` and
>   print the total.
> - Do not disturb coturn or enroll. Verify with the reusable checks in
>   STACK-PROVISIONING.md §4.
> - Apache config only in cPanel's include directory; `apachectl configtest`
>   before `apachectl graceful`, and the reload affects every site.
> - Avoid working across 00:46 UTC (cPanel upcp). If the last snapshot is from an
>   earlier UTC day, take a fresh one before changing anything.
> - Changes to the growth app go through Lovable. Don't edit the app repo.
> - I'm a Laravel dev, not devops. One step at a time, the mechanism before the
>   command, verify the current state before changing it, short responses.
> - Update README.md and the step's record as work completes. Don't commit
>   unless I ask.

---

## Working notes

Root SSH is disabled — use **WHM → Terminal** for commands and cPanel File
Manager for transfers. **Every command must be a single line**; the terminal
silently drops multi-line pastes. Both rules are the same as enroll's, and both
are load-bearing rather than stylistic.
