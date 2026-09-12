# Supabase stack — growth (instance 2)

Live working document for provisioning growth's Supabase stack. Updated as work
happens; what is written here has been run and verified unless marked otherwise.

**Server:** `184.168.122.104` · root SSH disabled, use **WHM → Terminal**
**Every command is a single line.** The terminal drops multi-line pastes.

**Instance 2 → ports 8010 / 5442 / 6553.** Re-derived, not taken from the table:
`8000+10(2-1)`, `5432+10`, `6543+10`. All below 32768, clear of coturn's
49152–65535 relay range and the pinned ephemeral range `32768 49151`.

---

## 1. Done and verified

| | Evidence |
|---|---|
| ✅ Baseline captured | see §2 |
| ✅ cPanel: one account, both hostnames | `growth.lilbrahmas.org` and `api.growth.lilbrahmas.org` both → `growthlilbrahmas` |
| ✅ Wrong account removed | `api.growth.lilbrahmas.com` / user `apigrowth` terminated; `/home/apigrowth` gone |
| ✅ API docroot matches enroll's shape | `/home/growthlilbrahmas/public_html/api.growth.lilbrahmas.org` |
| ✅ GoDaddy DNS | both names resolve to `184.168.122.104` authoritatively **and** publicly |
| ✅ ACME path proven | probe files fetched over plain HTTP from both hostnames |
| ✅ SSL issued | Let's Encrypt, `ssl_verify=0` on both, valid to **11 Dec 2026** |
| ❌ Stack | not created — `/opt/supabase/stacks/` holds only `enroll` |
| ❌ Apache reverse proxy | not written |
| ❌ Serving design for the app | still open — see `README.md` |

### The `.com` mistake, for the record

`api.growth.lilbrahmas.com` was created instead of `.org`. Two separate
problems, not one typo: the wrong TLD, **and** `lilbrahmas.com` sits on
`ns.nocdirect.com` nameservers rather than GoDaddy's `ns13/ns14.domaincontrol.com`.
So DNS for anything under `.com` is not even a GoDaddy task. The `.org` path is
the only workable one.

### One certificate covers both hostnames

AutoSSL issued a single SAN certificate:
`DNS:api.growth.lilbrahmas.org, DNS:growth.lilbrahmas.org`.

**Consequence for the proxy work:** at renewal Let's Encrypt re-validates *both*
names, so `ProxyPass /.well-known/ !` must go on **both** vhosts. Omitting it on
the API vhost can take the frontend's certificate down with it. The runbook says
that line looks redundant — it is not.

AutoSSL will log ~10 `does not resolve` DCV errors on every run, for cPanel's
auto-created service subdomains (`www`, `mail`, `cpanel`, `webmail`, `webdisk`,
`autoconfig`, `autodiscover`, `cpcontacts`, `cpcalendars`). Harmless — they have
no DNS and were skipped. **Leave them unresolved**: every name added to the
shared certificate is another name that must pass validation at renewal.

---

## 2. Baseline — compare against these at the end

| Item | Value |
|---|---|
| coturn `MainPID` | `1911360` |
| coturn `ActiveEnterTimestamp` | `Wed 2026-08-26 00:46:34 UTC` |
| NAT `REDIRECT` rules | `1` |
| Docker networks | `bridge`, `enroll_default`, `host`, `none` |
| enroll unhealthy containers | `0` |
| Ports 3010 / 8010 / 5442 / 6553 | free |

Files on the server: `/root/growth-baseline-coturn-static.txt`,
`/root/growth-baseline-coturn-pid.txt`, `/root/growth-baseline-nat-redirects.txt`,
`/root/growth-baseline-networks.txt`.

### Use the *static* coturn baseline, not the raw capture

`/root/growth-baseline-coturn.txt` has **59 lines** and is unusable for
comparison: `ss | grep turnserver` includes coturn's **live relay allocations**,
which come and go with call traffic. Comparing against it later reports dozens
of phantom "missing" entries.

`/root/growth-baseline-coturn-static.txt` filters to ports below 49152 and holds
**5 lines**, byte-identical to `/root/coturn-ports-pre-docker.txt` captured
17 Aug. That is the instrument to use:

```
comm -13 <(sort -u /root/growth-baseline-coturn-static.txt) <(sort -u /root/coturn-ports-pre-docker.txt)
```

No output is the pass condition.

### coturn restarts in the upcp window

coturn's start time is `00:46:34 UTC` — precisely cPanel's `upcp --cron` window.
That job has restarted it at least once. So a PID change observed across that
window may be cPanel rather than your work, and the two cannot be told apart
afterwards. Do not work across 00:46 UTC.

---

## 3. Divergences from the adding-instance runbook

The runbook assumes the new instance resembles enroll. Growth does not.

### 3.1 The override is 42 lines, not 33

Runbook §4 step 11 expects `lines: 33  resets: 11`. Enroll's actual override is
**42 lines, 11 resets**, with backups `docker-compose.override.yml.bak-2026-08-31`
and `bak-2026-09-10` beside it. The template has been edited twice since the
runbook was written; the 9 extra lines are most likely the secret wiring in
OPERATIONS.md §2 (`LARAVEL_*`, `LOVABLE_API_KEY`, `TELECRM_*`).

**Expect 42/11 after the copy.** Not yet confirmed what the extra lines contain —
check before deciding whether to trim enroll's secret wiring out of growth's copy.

### 3.2 Growth has zero edge functions

Enroll's `volumes/functions/` holds 24 entries — 22 functions plus `_shared` and
`main`:

```
admission-track  ai-translate  coupon-issue  coupon-issue-sibling
coupon-issue-xsell  coupon-validate  crm-lead  crm-push  diagram-refresh
enrollment-guard  laravel-admission-webhook  laravel-api  laravel-catalog
laravel-payment-return  lead-capture  log-ingest  otp-request  otp-verify
payment-success  translate-templates  video-transcribe  visit-track
main  _shared
```

The runbook's rsync excludes only `volumes/db/data` and `.env.old`, so all of
this would land in growth's stack — mounted into growth's functions container,
reachable at `https://api.growth.lilbrahmas.org/functions/v1/<name>`, running
against **growth's** database with **growth's** service-role key.
`laravel-admission-webhook` and `crm-lead` would be publicly callable.

Growth puts this logic in `createServerFn` inside the app instead, so **strip
`volumes/functions/` down to `main/` alone.** `main` is the stack's dispatch
router and is required — OPERATIONS.md lists a missing `main/` as a deploy guard.
`_shared` exists only for enroll's functions and goes with them.

### 3.3 Enroll state that must not ride along

| Path | Why it must not be copied |
|---|---|
| `.applied-migrations` | enroll's migration ledger mirror. A stack built from `apply-migrations.sh` imports this file **once, automatically**, on the first `--with-migrations` — which would record *enroll's* filenames as applied against growth's 226 different migrations |
| `.migrations.lock` | enroll's lock state |
| `volumes/storage/**` | enroll's uploaded objects. Contents not yet sized — **check before copying** |
| `docker-compose.override.yml.bak-*` | stale backups of enroll's override |
| `.env.old` | superseded secrets, mode 644, not gitignored (addendum §4.5) |

### 3.4 `pg_cron` / `pg_net` are NOT required

`README.md` states the stack needs `pg_cron` and `pg_net` able to reach the app
over HTTP. **That is wrong.** Across all 226 migrations:

- **zero** `CREATE EXTENSION` statements
- **zero** `pg_net` / `net.http_post` / `net.http_get` references
- the only `cron.schedule` calls, in `20260722071430_*.sql`, run **plain SQL** —
  `SELECT public.escalate_stale_approvals();` and
  `SELECT public.auto_generate_leave_delegations();`
- that whole block is wrapped in
  `IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')`, so with the
  extension absent it **schedules nothing and still succeeds**

So no extension work, and no callback URL. What remains is smaller and different:
those two SQL jobs will silently never run unless `pg_cron` is deliberately
enabled, and nothing will report that they aren't running.

### 3.5 The two hook routes are orphans, and effectively public

`src/routes/api/public/hooks/attendance-roll-day.ts` and `dwr-nudge.ts` carry
comments claiming pg_cron calls them. **Nothing calls them** — the only
references anywhere in the repo are in the generated `src/routeTree.gen.ts`.

Both gate on:

```
if (!apiKey || apiKey !== process.env.SUPABASE_PUBLISHABLE_KEY) return 401
```

The publishable key **ships in the browser bundle** (OPERATIONS.md §2 gives the
recipe for extracting it from a live site), so that is not a secret.
`attendance-roll-day` upserts an attendance row for every active user through
`supabaseAdmin`, which bypasses RLS, and both sit under `/api/public/` with no
auth middleware.

**Recommended shape:** block `/api/public/hooks/` at Apache from outside and
drive them from a host cron over loopback. No extension needed, no database→app
HTTP path, and failures land in a cron log rather than nowhere.

---

## 4. Next step — copy the stack

Nothing below has been run.

**Copy `stacks/enroll/`, not `upstream/docker/`.** Enroll carries the local-JWKS
commit that uncomments `GOTRUE_JWT_KEYS`, `API_JWT_JWKS`, `JWT_JWKS` and
`SUPABASE_JWKS`. Without them ES256 tokens fail verification and logins break.
`upstream/` exists only to diff against at upgrade time.

Source is 110 MB. Two checks to run first:

```
du -sh /opt/supabase/stacks/enroll/volumes/storage; ls -A /opt/supabase/stacks/enroll/volumes/storage | head
```

```
diff /opt/supabase/stacks/enroll/docker-compose.override.yml /opt/supabase/stacks/enroll/docker-compose.override.yml.bak-2026-08-31
```

The first sizes enroll's uploaded objects; the second reveals what the 9 extra
override lines are, and therefore whether growth's copy should keep them.

Then the copy, with the §3.2 and §3.3 exclusions folded in so growth's stack never
holds enroll's functions or ledger even briefly — followed by runbook §4 steps
8–11 (create the empty data mount, confirm it is empty, confirm the override).

### The secret window — do not start anything yet

The copy brings enroll's `.env`, including its `JWT_SECRET` and
`POSTGRES_PASSWORD`. Runbook §5 replaces them afterwards. Until it has:

> **No `docker compose up` of any kind.** A stack booted in that window shares
> credentials with enroll, and a shared `JWT_SECRET` means a token minted by one
> instance validates against the other.

Order is: copy → regenerate secrets (§5) → rewrite `.env` (§6) → gates (§7) →
**then** start.

---

## 5. Still open

1. **Nitro preset** — the gate on everything container-shaped. Not in the repo at
   all; it comes from `@lovable.dev/vite-tanstack-config@2.13.1`, whose own
   comment says *"nitro (build-only using cloudflare as a default target)"*. A
   Cloudflare bundle has nothing listening on a port, so `ProxyPass` to 3010
   would reach nothing. Whether an env var overrides it, or only editing
   `vite.config.ts` does, decides whether this is maintainable — Lovable owns
   that file and `deploy.sh` refuses a dirty checkout. **Answerable entirely off
   the server:** install deps in `D:\laragon\www\growth.lilbrahmas`, build with
   the preset overridden, check whether `.output/server/index.mjs` appears.
2. **Target the `bun` preset, not `node-server`.** Lovable's toolchain is bun
   (`bunfig.toml`, `bun.lock` kept current) and **this server has no Node** —
   enroll already builds in `oven/bun:1-alpine`. The bun preset lets one image
   both build and run, introducing no new runtime to the box. Nitro 3 depends on
   `srvx`, which serves a `{ fetch }` handler natively on node/deno/bun, so
   `src/server.ts` needs no change either way.
3. **Two lockfiles are present** — `bun.lock` (220 KB) and `package-lock.json`
   (320 KB), same timestamp. They can resolve differently. Pin the build to bun
   with `--frozen-lockfile`, as enroll's deploy already does.
4. **App server port 3010** — verified free. Below 32768, clear of the Supabase
   bands and cPanel's 2082–2096.
5. **Where the four runtime variables live** — `SUPABASE_URL`,
   `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_PUBLISHABLE_KEY`, `LOVABLE_API_KEY`.
   Note these are read from `process.env` at **runtime**, not baked at build
   time like enroll's `VITE_*` values. Two different mechanisms in one app.
6. **Only ~9 routes are server-rendered.** `src/routes/_authenticated/route.tsx`
   sets `ssr: false`, so all 111 authenticated routes render client-side. The
   process exists for **server functions**, not rendering — so a healthcheck must
   call a server function, not just fetch `/`.
