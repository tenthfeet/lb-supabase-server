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
| ✅ Stack | running at `/opt/supabase/stacks/growth` since ~07:05 UTC 13 Sep 2026 — 11/11 healthy, ports on loopback only, keys and tokens proven isolated from enroll, enroll and coturn verified undisturbed. See §4. Empty database, no migrations applied |
| ✅ Apache reverse proxy | `https://api.growth.lilbrahmas.org` → `127.0.0.1:8010` since 14 Sep 2026. Verified through the proxy at 05:19 UTC: GoTrue `200` with the key, WebSocket `101` after 5 s, ACME probe `200` over HTTP and HTTPS, Studio `401` asking for basic auth. enroll and coturn verified undisturbed. See §4 |
| ✅ Serving design for the app | decided 14 Sep 2026 (README step 1) — see `README.md` *Open questions*; evidence in §5 |

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

> **Re-capture immediately before `docker compose up`.** These values were taken
> on 12 Sep 2026. cPanel's `upcp` has run since — 00:46 UTC on 13 Sep — and it
> has restarted coturn before. Compared against this table, a changed PID at the
> end could be cPanel's doing rather than the stack start, and the two cannot be
> told apart afterwards. The comparison that proves anything is against a
> snapshot taken minutes before the start.

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
**42 lines, 11 resets**. Confirmed 13 Sep 2026 with `cat -n`:

| Lines | Content |
|---|---|
| 1–26 | template, unchanged |
| **27–35** | `environment:` + 8 × `${VAR:-}` under `functions:` — `LARAVEL_API_BASE_URL`, `LARAVEL_CLIENT_ID`, `LARAVEL_CLIENT_SECRET`, `LARAVEL_WEBHOOK_SECRET`, `LARAVEL_API_KEY`, `LOVABLE_API_KEY`, `TELECRM_WEBHOOK_URL`, `TELECRM_ACCESS_TOKEN` |
| 36–42 | template, unchanged |

Backups: `bak-2026-08-31` is 39 lines, `bak-2026-09-10` is 41. The diff from
31 Aug adds only `LARAVEL_WEBHOOK_SECRET` and the two `TELECRM_*` lines.

**Decision: delete lines 27–35 from growth's copy.** They feed only enroll's edge
functions; growth's functions container runs `main` alone, so nothing would read
them, and they invite putting Laravel/TeleCRM secrets into growth's `.env`.
Growth's `LOVABLE_API_KEY` belongs to the app process, not the stack.
Removing exactly those 9 lines restores the runbook's **33 lines / 11 resets**,
so step 11's original expectation holds for growth.

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

Confirmed from the app side, 13 Sep 2026: growth's `src/` contains no
`functions.invoke`, no `/functions/v1` URL and no `.schema(` call. Nothing in the
app calls an edge function or a non-`public` PostgREST schema.

### 3.3 Enroll state that must not ride along

| Path | Why it must not be copied |
|---|---|
| `.applied-migrations` | enroll's migration ledger mirror. A stack built from `apply-migrations.sh` imports this file **once, automatically**, on the first `--with-migrations` — which would record *enroll's* filenames as applied against growth's 226 different migrations |
| `.migrations.lock` | enroll's lock state |
| ~~`volumes/storage/**`~~ | **Not needed.** Sized 13 Sep 2026: 0 bytes, only an empty `stub` tenant folder. No enroll objects; copied as-is |
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

**Superseded 14 Sep 2026, HEAD `4dc6623`, 246 migrations.** `20260914051218_*`
(line 195) and `20260914051303_*` (line 78) each run an **unguarded** `DO` block:
`SELECT jobid … FROM cron.job`, then `cron.schedule('renew-monthly-incentive-plans',
'35 0 * * *', …)`. Without the extension that is `relation "cron.job" does not
exist`, so the migrations cannot apply unless `pg_cron` is created first. They
passed on Lovable Cloud, which means `pg_cron` is enabled there and all three jobs
run in production today. Still zero `CREATE EXTENSION` and zero `pg_net`.

**Growth's database, 14 Sep 2026 07:16 UTC:** `preload has pg_cron: true`,
`pg_cron available versions: 7`, `pg_cron installed: 0`,
`cron.database_name: postgres`. The image already preloads the library and
points it at the app's database, so enabling it is `CREATE EXTENSION` alone: no
config change, no Postgres restart.

**Superseded again 15 Sep 2026, HEAD `63b7ca15`, 263 migrations.**
`20260914120009_*` schedules `attendance-roll-day` as a `net.http_post` to the
Lovable-hosted app. `pg_net` is now referenced, though only inside a stored job
command, so it is not needed to apply the migration. See
`MIGRATION-RECORD.md` §1.

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

**15 Sep 2026: `attendance-roll-day` is no longer an orphan.** Lovable Cloud's
`pg_cron` calls it daily over HTTP at its `lovable.app` URL
(`MIGRATION-RECORD.md` §1). A fifth job, `dwr-shift-cutoff-nudge`, created
in Lovable Cloud without any migration, calls a `lovable.app` URL every 15
minutes, at `/api/public/hooks/dwr-nudge` (confirmed 15 Sep). So neither
route is an orphan in production. The code comments were right, but the
migrations show only one of the two callers. The recommended shape above is
unchanged, and it now also replaces a job that replaying the migrations would
lose.

### 3.6 Runbook §5 on a *copied* `.env`

Read from the upstream scripts at pin `4760c1af77` on 13 Sep 2026 — not yet run.

- **Both key scripts print every secret they generate to the terminal,
  unconditionally** — `JWT_SECRET`, `POSTGRES_PASSWORD`, `SUPABASE_SECRET_KEY`,
  and `JWT_KEYS`, which contains the ES256 **private** key. Run both with
  `> /dev/null`. Their output must never be pasted anywhere.
- **`--update-env` skips the `(y/N)` prompt.** Both write with `sed -i.old`, so
  each leaves `.env.old` holding the previous values — straight after
  `generate-keys.sh` that is **enroll's** secrets. Step 14's delete matters.
- **Step 16 cannot fail on a copy.** It greps for upstream placeholder strings.
  Enroll's `.env` has none, so it prints `0` even while growth's copy still holds
  every one of enroll's secrets. The instrument that *can* fail is a comparison
  of values against enroll's file, printing names only — run once before the
  scripts to prove it detects sameness, and again after.
- **Neither script touches** `SMTP_*`, `OPENAI_API_KEY`, `DASHBOARD_USERNAME`,
  `POOLER_TENANT_ID`, or anything enroll added for its own functions. Whatever
  enroll set there survives §5 and is a §6 decision.

The comparison, names only, never values:

```
awk -F= 'NR==FNR{if($1~/^[A-Z_][A-Z0-9_]*$/)e[$1]=substr($0,index($0,"=")+1);next}$1~/^[A-Z_][A-Z0-9_]*$/&&e[$1]!=""&&e[$1]==substr($0,index($0,"=")+1){s=s" "$1;n++}END{print n+0" identical:"s}' /opt/supabase/stacks/enroll/.env /opt/supabase/stacks/growth/.env
```

**Baseline, 13 Sep 2026, before either script:** `77 identical`, including all
20 variables the two scripts regenerate — so it does detect sharing. Of the 57
no script touches, six are enroll's own function credentials with no consumer in
growth after the §3.1 trim:

`LARAVEL_API_BASE_URL` `LARAVEL_CLIENT_ID` `LARAVEL_CLIENT_SECRET`
`LARAVEL_WEBHOOK_SECRET` `TELECRM_WEBHOOK_URL` `TELECRM_ACCESS_TOKEN`

→ **delete those six lines from growth's `.env` in §6.** `LARAVEL_API_KEY` and
`LOVABLE_API_KEY` are empty or absent in enroll's file. `SMTP_*` and
`OPENAI_API_KEY` are non-empty — §6 must establish whether they are upstream
placeholders or real credentials, without printing them.

Expected count after `generate-keys.sh`: **63**. After `add-new-auth-keys.sh`:
**57** — exactly the untouched set, with `COMPOSE_FILE` and
`COMPOSE_PROJECT_NAME` still in it.

### 3.7 Signups must stay disabled — a trigger makes every new user a trainee

Growth has no signup UI. Users are created by admins through
`auth.admin.createUser` with `email_confirm: true` (`admin-users.functions.ts`,
`bulk-users.functions.ts`) and sign in with `signInWithPassword`. The Lovable
OAuth wrapper `src/integrations/lovable/index.ts` is generated but imported
nowhere, so no OAuth provider needs configuring.

Migration `20260705120628_*` attaches `on_auth_user_created_dev_roles` to
`auth.users`: **every** new user gets a `profiles` row and the `trainee` role
(`counsellor@lilbrahmas.com` also gets `member` and the Sales department). With
signups open, anyone holding the publishable key — which ships in the browser
bundle — could `POST /auth/v1/signup` and become a trainee in the HR system.

**§6: confirm `DISABLE_SIGNUP=true`.** Enroll set it on its own stack
(`enroll/EXECUTE.md`), so the copy probably carries it — verify, do not assume.
Expected but not yet tested: the admin API does not consult `DISABLE_SIGNUP`, so
admin-created users keep working. Test both directions after start.

---

## 4. Copy the stack — ✅ done 13 Sep 2026

**Copy `stacks/enroll/`, not `upstream/docker/`.** Enroll carries the local-JWKS
commit that uncomments `GOTRUE_JWT_KEYS`, `API_JWT_JWKS`, `JWT_JWKS` and
`SUPABASE_JWKS`. Without them ES256 tokens fail verification and logins break.
`upstream/` exists only to diff against at upgrade time.

### Checked before copying

| Check | Result |
|---|---|
| `du -sh` + `ls -A` of `volumes/storage` | 0 bytes, only an empty `stub` tenant folder |
| `wc -l` of override + backups, `diff bak-2026-08-31 live` | lines 27–35 are enroll's functions secret wiring — §3.1 |
| `ls -la` of stack root, `volumes/`, `volumes/functions/main/` | no state files beyond §3.3's list; `.env.old` absent; `.env` mode 600; `main/index.ts` present |
| `du -sh volumes/*` | `db` 109M (i.e. `db/data`), everything else under 1 MB |

### The copy

The exclusions live in a rules file, written once and checked (`cat -A`, and
`wc -l` must be 7). Seven inline `--exclude` options would let one dropped space
silently merge two patterns into a nonsense one:

```
printf '%s\n' '+ /volumes/functions/main/' '- /volumes/functions/*' '- /volumes/db/data' '- /.env.old' '- /.applied-migrations' '- /.migrations.lock' '- /docker-compose.override.yml.bak-*' > /root/growth-stack-copy.filter
```

First match wins, so `main/` is let through before the functions wildcard. A
leading `/` anchors a rule to the stack root; `*` does not cross `/`.

Dry run (`-an --stats --out-format='%n'`) was read line by line, then the real
copy. Both summaries identical: **81 created (62 files, 19 dirs), 578,646 bytes,
0 deleted.**

```
rsync -a --stats --filter='merge /root/growth-stack-copy.filter' /opt/supabase/stacks/enroll/ /opt/supabase/stacks/growth/
```

### Runbook steps 8–11, adapted

| Step | What | Result |
|---|---|---|
| 8–9 | `mkdir` (no `-p`) the data mount `&&` count its contents | `0` |
| — | `cmp` enroll's override against growth's `&&` `sed --in-place '27,35d'` | ran |
| 11 | lines · `!reset null` count · `LARAVEL\|LOVABLE\|TELECRM` count | `33` · `11` · `0` |

`cmp` is what makes the line-number delete safe: the numbers were read from
enroll's file, so the delete only runs if growth's copy is still byte-identical to
it. `--in-place` is spelled out because a dropped space next to short `-i` turns
the script into a backup suffix instead of failing.

### The secret window — do not start anything yet

The copy brings enroll's `.env`, including its `JWT_SECRET` and
`POSTGRES_PASSWORD`. Runbook §5 replaces them afterwards. Until it has:

> **No `docker compose up` of any kind.** A stack booted in that window shares
> credentials with enroll, and a shared `JWT_SECRET` means a token minted by one
> instance validates against the other.

Order is: copy ✅ → regenerate secrets (§5) → rewrite `.env` (§6) → gates (§7) →
**then** start.

**It is not only secrets.** Until runbook step 19, growth's `.env` carries
enroll's `COMPOSE_PROJECT_NAME` (confirmed identical, 13 Sep 2026). Compose takes
the project name from that file, so any `docker compose` command run in growth's
folder addresses **enroll's live project** — an `up` would recreate enroll's
containers against growth's empty data mount. Plain `docker run`, as step 13's
node container uses, is unaffected.

### Runbook §5 progress

| Step | What | Result |
|---|---|---|
| baseline | value comparison against enroll (§3.6) | `77 identical` — all 20 regenerated variables present |
| 12 | `(cd … && sh utils/generate-keys.sh --update-env > /dev/null)` | `63 identical` — exactly the 14 expected names gone; `COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` intact |
| 13 | `(cd … && sh utils/add-new-auth-keys.sh --update-env > /dev/null)` | `57 identical` — exactly the 6 expected names gone; the remaining 57 are the untouched set |

**`57` proves the values changed, not that they are valid.** The comparison skips
values that differ — and an *empty* value differs from enroll's too. If `openssl`
or the node container had failed silently, the count would look identical. So a
shape check follows: each of the 20 exactly once, non-empty, the right kind
(JWT, `sb_publishable_`, `sb_secret_`, JSON), and `JWT_KEYS` / `JWT_JWKS` valid
JSON. This also covers runbook steps 17–18.

| Step | What | Result |
|---|---|---|
| 17–18 + shape | name · length · kind for all 20, then `python3 -m json.tool` on `JWT_KEYS` and `JWT_JWKS` | ✅ `20 checked`. `REALTIME_DB_ENC_KEY:16`, `VAULT_ENC_KEY:32`. `ANON_KEY` 169 / `SERVICE_ROLE_KEY` 180 / `*_ASYMMETRIC` 272 and 283 — all `jwt`. `SUPABASE_PUBLISHABLE_KEY:46:publishable`, `SUPABASE_SECRET_KEY:41:secret`. `JWT_KEYS:377`, `JWT_JWKS:329`, both valid JSON. Every `plain` value non-empty (32–64) |
| 14–15 | `ls` both files `&&` `rm -f .env.old` `&&` `chmod 600 .env` `&&` `ls .env*` | ✅ `.env.old` gone; `.env` `-rw-------` 13749 bytes; `.env.example` 644 is the upstream template, no secrets |
| 16 | placeholder grep | skipped — cannot fail on a copy (§3.6); superseded by the comparison and shape check |

**§5 complete, 13 Sep 2026.** Growth's `.env` holds no secret shared with enroll —
but it still carries enroll's project name, ports, URLs and the six function
credentials until §6.

**Port scheme checked against upstream `docker-compose.yml` at the pin** — the
server's copy is checked by the §7 gates. `db` sets `PGPORT: ${POSTGRES_PORT}`,
so Postgres *inside its container* listens on 5442 and every service reaches it
at `db:5442` through the same variable — consistent. Supavisor's container ports
are fixed at `5432`/`6543`; only the host side moves, via the override's
`!override` list. The `api-gw` base mapping falls back through
`${API_GW_HTTP_PORT:-${KONG_HTTP_PORT:-8000}}`, and the override drops the
`KONG_HTTP_PORT` layer — which is why runbook step 20 is mandatory.

`db` also mounts a **named** volume, `db-config`, which Compose prefixes with the
project name. Under enroll's project name that resolves to enroll's own
`enroll_db-config` — one more reason step 19 must precede any Compose command.

### Runbook §6 — rewrite `.env`

What enroll customised, found by comparing growth's `.env` with `.env.example`
in the same folder — the 20 regenerated secrets skipped, other sensitive values
masked. Result: **`16 settings differ from the upstream template`**.

| Line | Setting | Enroll's value | Growth |
|---|---|---|---|
| 11 | `COMPOSE_FILE` | `docker-compose.yml:docker-compose.override.yml` | keep — step 26 requires exactly this |
| 97 | `SUPABASE_PUBLIC_URL` | `https://api.enroll.lilbrahmas.org` | `https://api.growth.lilbrahmas.org` |
| 101 | `API_EXTERNAL_URL` | `https://api.enroll.lilbrahmas.org/auth/v1` | `https://api.growth.lilbrahmas.org/auth/v1` |
| 140 | `POOLER_TENANT_ID` | `enroll` | `growth` |
| 166 | `SITE_URL` | `https://enroll.lilbrahmas.org` | `https://growth.lilbrahmas.org` |
| 170 | `DISABLE_SIGNUP` | `true` | keep — §3.7 |
| 180 | `ENABLE_EMAIL_AUTOCONFIRM` | `true` | **proposed `false`** — see below |
| 190–191 | `ENABLE_PHONE_SIGNUP` / `ENABLE_PHONE_AUTOCONFIRM` | `false` / `false` | keep — step 25 |
| 385 | `COMPOSE_PROJECT_NAME` | `enroll` | `growth` — step 19 |
| 386–391 | `LARAVEL_API_BASE_URL`, `LARAVEL_CLIENT_ID`, `LARAVEL_CLIENT_SECRET`, `TELECRM_WEBHOOK_URL`, `TELECRM_ACCESS_TOKEN`, `LARAVEL_WEBHOOK_SECRET` | masked | delete — §3.6 |

Not listed, so still at template values: the three ports, which steps 20–22 set
to **8010 / 5442 / 6553**. `SMTP_*` and `OPENAI_API_KEY` match the template —
upstream placeholders, so enroll carried **no real SMTP or OpenAI credential**
into the copy. `JWT_EXPIRY`, `PGRST_DB_SCHEMAS` and `FUNCTIONS_VERIFY_JWT` are
the template's too.

**Why `ENABLE_EMAIL_AUTOCONFIRM=false`.** Enroll runs `true` because it has no
SMTP and once took signups. Growth takes none: `DISABLE_SIGNUP=true`, and every
user is created through the admin API with `email_confirm: true`, which this
setting does not affect. It only matters if signups are ever reopened — and then
`false` means a new address must confirm by email before it can sign in. With no
SMTP configured here, such a signup errors instead of producing a usable
§3.7 trainee account. That is the runbook's step 25 default.

| Step | What | Result |
|---|---|---|
| 19 | exact-match `sed`: `COMPOSE_PROJECT_NAME=enroll` → `growth`, then print the line | ✅ `385:COMPOSE_PROJECT_NAME=growth`. From here Compose in growth's folder addresses project `growth`, not enroll — the hazard in *It is not only secrets* is closed |
| 20–25 + delete | one exact-match `sed` script — 8 substitutions, 6 deletes, no spaces inside — then the comparison again | ✅ `12 settings differ`: `API_GW_HTTP_PORT=8010` (line 345), `POSTGRES_PORT=5442` (118), `POOLER_PROXY_PORT_TRANSACTION=6553` (129), `POOLER_TENANT_ID=growth`, the three `growth` URLs, `DISABLE_SIGNUP=true`, both phone settings `false`, `COMPOSE_PROJECT_NAME=growth`. `ENABLE_EMAIL_AUTOCONFIRM` back at the template's `false`; no `LARAVEL_` or `TELECRM_` line remains |
| 26 | `COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` present and correct | ✅ same output: `docker-compose.yml:docker-compose.override.yml` and `growth` |

The terminal dropped a space in that paste — inside the `" [not in example]"`
label string, where it can only change how a line looks. That is the reason every
program here keeps its spaces inside quoted labels and nowhere else.

**§6 complete, 13 Sep 2026.**

### Runbook §7 — gates, then start

| Step | What | Result |
|---|---|---|
| 27–32 | one `docker compose config` render piped straight into a filter that prints only names, counts, mount paths and ports | ✅ `name: growth` · `container_name lines: 0` · `GOTRUE_JWT_KEYS`, `API_JWT_JWKS`, `JWT_JWKS`, `SUPABASE_JWKS` x1 each · 16 bind mounts, every one under `/opt/supabase/stacks/growth/`, plus named volumes `db-config` and `deno-cache` (Compose prefixes them `growth_`) · `published: 8010 5442 6553` · `ALL PORTS LOOPBACK` |

**Never run `docker compose config` unfiltered** — the render contains every
secret in `.env`.

**The runbook's health check can pass on a broken stack.**
`docker compose ps --format '{{.Service}} {{.Status}}' | grep -vc healthy`
(steps 35 and 50, and the README baseline) has three holes:

- `(unhealthy)` contains the substring `healthy`, so an unhealthy container is
  counted as healthy
- `ps` without `-a` omits containers that have exited
- an empty listing — wrong directory, Compose error — also prints `0`

Growth's checks use `ps -a`, match the literal `(healthy)`, and print the total
beside it, so a failure reads `11 … healthy: 10` or `0 … healthy: 0` rather than a
pass.

**Pre-start snapshot, 13 Sep 2026 07:03 UTC** — the instrument for "nothing
disturbed", replacing §2 for that purpose. Also covers runbook §3 steps 3–4
(disk, RAM), which had not been recorded.

| Item | Value |
|---|---|
| coturn `MainPID` | `1911360` — unchanged since 12 Sep, so `upcp` did not restart it overnight |
| coturn `ActiveEnterTimestamp` | `Wed 2026-08-26 00:46:34 UTC` |
| coturn ports missing vs `/root/coturn-ports-pre-docker.txt` | `0` |
| relay range | `32768 49151` |
| NAT `REDIRECT` rules | `1` |
| `iptables-save` | 74 lines, saved to `/root/growth-prestart-iptables.txt` |
| Docker networks | `bridge`, `enroll_default`, `host`, `none` |
| enroll containers | `11`, all `(healthy)` |
| enroll `/auth/v1/health`, no key | `401` |
| ports 3010 / 8010 / 5442 / 6553 | free |
| memory | 31,835 MiB total, 25,885 available; swap 4,095 MiB, 0 used |
| disk `/` (holds `/opt` and `/var/lib/containerd`) | 368 G free of 399 G |

| Step | What | Result |
|---|---|---|
| 32–33 | port gate evaluated **inside** the start command — the filter's exit status gates `&& docker compose up -d`, so there is no window between check and start | ✅ `ALL PORTS LOOPBACK`, then `up 14/14`: network `growth_default`, volumes `growth_db-config` and `growth_deno-cache`, 11 containers `growth-<service>-1`. `db` healthy in 7.1 s, `studio` and `api-gw` healthy, the rest started. ~07:05 UTC 13 Sep 2026 |
| 34 | `sleep 90` | not needed as a command — the next check runs later than that anyway |
| 50–55 + firewall | same probes as the pre-start snapshot, plus `diff` of the full `iptables-save` against the saved copy | ✅ 07:09 UTC. coturn `MainPID` `1911360`, start time unchanged; ports missing `0`; relay range `32768 49151`; NAT `REDIRECT` `1`; networks now `bridge,enroll_default,growth_default,host,none`; enroll `11 healthy: 11`, API `401`. Firewall: **removed 0**, added 25 — 22 naming growth's bridge `br-f8aacf2a3643`, and 3 that do not (below) |

**The 3 rules that do not name the bridge are growth's, and they restrict.**

```
-A PREROUTING -d 127.0.0.1/32 ! -i lo -p tcp -m tcp --dport 8010 -j DROP
-A PREROUTING -d 127.0.0.1/32 ! -i lo -p tcp -m tcp --dport 5442 -j DROP
-A PREROUTING -d 127.0.0.1/32 ! -i lo -p tcp -m tcp --dport 6553 -j DROP
```

They are exactly growth's three published ports, and they **drop** any packet
addressed to `127.0.0.1:<port>` that arrives on an interface other than `lo` —
Docker's guard against other machines reaching a port published on loopback. They
are keyed on address and port rather than on the bridge, which is why the
"names the bridge" criterion missed them: the criterion was too narrow, not the
rules wrong. Enroll's ports should carry the same three rules in the pre-start
copy — checked next.

The pasted-back command read `docker networkls`, yet it printed the network list —
so that dropped space was in the copy of the screen, not in what ran. Not every
mangle is that benign: the earlier `-servername` one changed what executed.

| Step | What | Result |
|---|---|---|
| precedent | loopback `DROP` rules in the **pre-start** firewall copy | ✅ the same three already existed for enroll's `8000`, `5432`, `6543`. Docker server `29.7.2`. The 3 "not on the bridge" rules are Docker's standard guard, now for growth's ports — firewall fully accounted for |
| 35 (fixed) | `ps -a`, literal `(healthy)`, total beside it | ✅ `growth containers: 11 healthy: 11` |
| 36 | roles in growth's database | ✅ 12: `anon`, `authenticated`, `service_role`, and nine `supabase_*` — `admin`, `auth_admin`, `etl_admin`, `functions_admin`, `privileged_role`, `read_only_user`, `realtime_admin`, `replication_admin`, `storage_admin`. Postgres initialised fresh |
| 43–44 | listening sockets on 8010 / 5442 / 6553 | ✅ exactly `127.0.0.1:8010`, `127.0.0.1:5442`, `127.0.0.1:6553` — nothing on `0.0.0.0`, `*` or `[::]` |
| 56 | growth's subnet against the host's routes | ✅ `172.19.0.0/16`. Routes: `default`, `172.17.0.0/16` (docker0), `172.18.0.0/16` (enroll), `172.19.0.0/16` (growth), host route `184.168.120.57` — no overlap |
| key isolation, API-key layer | three GETs to growth's `/auth/v1/health` on `127.0.0.1:8010`: growth's publishable key, enroll's, none | 1 ✅ `{"version":"v2.189.0","name":"GoTrue",…} [200]`. 2 and 3 both `Unauthorized [401]` — **identical bodies**, so this alone cannot tell "enroll's key refused" from "enroll's key never read". Needs a positive control: the same extraction of enroll's key, sent to enroll's own gateway, must return 200 |

**How the gateway behaves** — Envoy config at the pin,
`volumes/api/envoy/lds.template.yaml`. A Lua filter compares `apikey` with the
stack's own `ANON_KEY`, `SERVICE_ROLE_KEY`, `SUPABASE_PUBLISHABLE_KEY` and
`SUPABASE_SECRET_KEY`, and answers a plain-text `Unauthorized` 401 for a missing
**or** wrong key — which is why tests 2 and 3 cannot be told apart. It does
**not** validate JWTs: a request's own `Authorization: Bearer` passes straight
through to the service; a Bearer is synthesised from the apikey only when none is
sent. The exact path `/rest/v1/` (the OpenAPI root) is RBAC-restricted to
secret / service-role keys, so a token test aimed there is refused for the wrong
reason. Token tests use a table path, `/rest/v1/isolation_probe`: PostgREST
verifies the JWT first and only then looks for the table, so a good token gets
"table not found" and a bad one gets a JWT error — bodies that differ, unlike the
gateway's.

**Isolation, completed 13 Sep 2026** — one command, five requests, all ✅:

| Test | Sent | Result | Proves |
|---|---|---|---|
| A1 | enroll's publishable key → **enroll's** gateway, `127.0.0.1:8000/auth/v1/health` | `GoTrue v2.189.0 … [200]` | the extraction reads enroll's key correctly — so the earlier refusal at growth was a genuine wrong-key refusal |
| T1 | growth's HS256 `ANON_KEY` → growth | `PGRST205` "Could not find the table" `[404]` | growth accepts its own `JWT_SECRET` tokens |
| T2 | **enroll's** HS256 `ANON_KEY` → growth | `PGRST301` "None of the keys was able to decode the JWT" `[401]` | a token signed with enroll's `JWT_SECRET` is rejected |
| T3 | growth's ES256 `ANON_KEY_ASYMMETRIC` → growth | `PGRST205` `[404]` | the local-JWKS wiring works — ES256 login tokens verify |
| T4 | **enroll's** ES256 `ANON_KEY_ASYMMETRIC` → growth | `PGRST301` "No suitable key was found to decode the JWT" `[401]` | enroll's signing key is unknown to growth |

T2 and T4 fail differently, and meaningfully: the HS256 token is tried against
growth's keys and none verifies it; the ES256 token names a signing key (`kid`)
that growth's JWKS does not contain at all.

**The shared-secret risk from the task brief is closed by observation, not
inference.** Growth's stack is running, healthy, loopback-only, and isolated
from enroll. Runbook §8 (Apache proxy for `api.growth.lilbrahmas.org`), §9
through it, and steps 57–58 followed on 13–14 Sep: see *Step 58, §8 and §9*
below. Step 48 cannot pass until the app is served.

### Facts gathered for the remaining steps — 13 Sep 2026, ~07:20 UTC

| Check | Result |
|---|---|
| 57 `docker compose ls` | ✅ `enroll running(11)` and `growth running(11)`, each listing only its own `docker-compose.yml` + override |
| `/opt/supabase/README.md` | enroll's entry is `enroll = instance 1: 8000 / 5432 / 6543`, mid-file, above the upstream-branch note. Growth's step 58 entry: ✅ written 14 Sep 2026, see *Step 58, §8 and §9* below |
| `/etc/apache2/conf.d/userdata/ssl/2_4/` | holds only `enroll/` — growth's `growthlilbrahmas/` does not exist yet. `userdata/std/2_4/` does not exist at all: enroll has no port-80 include |
| enroll's API include, `ssl/2_4/enroll/api.enroll.lilbrahmas.org/*.conf` | exactly runbook step 38's five lines with `8000`. Growth's differs only in `8010`. The filename was matched by glob — confirm it (runbook says `supabase.conf`) |
| `/home/growthlilbrahmas/public_html/.htaccess` | cPanel-generated only: MultiPHP INI directives and the `ea-php82` handler. **No `RewriteEngine`, no rewrites** — nothing can capture `/.well-known/` today |
| API docroot `public_html/api.growth.lilbrahmas.org/` | `cgi-bin/`, `.htaccess` (908 bytes, byte-identical to the parent's cPanel file: read 14 Sep, no rewrites), `php.ini`, `.user.ini`, `.well-known/`. Enroll's API-docroot `.htaccess` is `RewriteEngine Off` only, belt and braces against an inherited rewrite; growth's has no such line |
| frontend docroot | no index file. **Correction, 14 Sep 2026:** it answers `200` with Apache's `Index of /` listing, not cPanel's default or `403`. So step 48's bare "frontend 200" passes without the app and proves nothing; once the app is served it must check content. That is the serving design's business, not the stack's |

### Remaining

1. **Decided 14 Sep 2026, ~04:20 UTC: runbook §8 now**, so an Apache or cPanel
   problem is not coupled to the first app deploy. `upcp` ran at ~00:46 UTC that
   day, so a fresh snapshot replaces 13 Sep's before Apache is touched.
   §8 touches Apache for **every** site
   (`apachectl configtest`, then `apachectl graceful`), makes
   `https://api.growth.lilbrahmas.org` public (empty database, signups off) along
   with Studio's basic-auth login — the same exposure enroll has — and does not
   touch `growth.lilbrahmas.org`.
2. ~~**Step 58** — add growth's entry to `/opt/supabase/README.md`.~~ ✅ 14 Sep 2026.
3. ✅ **§8 steps 37–42**, 14 Sep 2026. The include was syntax-tested before it
   was installed, wired with `ensure_vhost_includes --no-restart`, and loaded by
   a gated `configtest && graceful`.
4. ✅ **§9 steps 43–47** through the proxy, 14 Sep 2026, with literal paths.
5. ✅ **Host checks re-run** after the reload: nothing disturbed.
6. When the app's own proxy is eventually written for `growth.lilbrahmas.org`,
   it must carry `ProxyPass /.well-known/ !` too — one SAN certificate covers
   both names (§1).
7. Not this runbook: step 49's RLS audit only means something after growth's
   226 migrations are applied — deploy-kit work.
8. ✅ **Decided 14 Sep 2026: the API docroot `.htaccess` gets `RewriteEngine Off`**,
   appended below cPanel's marked blocks at 04:59 UTC. The parent `.htaccess`
   has no rewrites today, so this changes nothing now. It stops any rewrite later
   added to `public_html/.htaccess`, such as a cPanel Redirect or an HTTPS rule,
   from capturing `/.well-known/` on the API name and breaking renewal of the
   shared certificate.
9. ✅ **The runbook corrections found on 14 Sep are applied** to
   `supabase-adding-instance-runbook.md`: steps 38–41, 47, 48, 58 and §10. See
   *Runbook corrections found on 14 Sep* below.

**If this resumes on a later UTC day**, cPanel's `upcp` will have run again at
~00:46. Take a fresh snapshot before touching Apache rather than comparing
against 13 Sep's.

### Reusable checks — proven on 13 Sep 2026

Nothing disturbed. Expect: coturn `MainPID=1911360` and its start time unchanged,
`missing 0`, relay `32768 49151`, `REDIRECT 1`,
`removed: 0 added: 25 added-not-on-growth-bridge: 3` with **exactly** the three
loopback `DROP` lines for 8010 / 5442 / 6553 printed above it, networks including
`growth_default`, enroll `11 healthy: 11`, enroll API `401`.

```
date -u; systemctl show coturn --property=MainPID,ActiveEnterTimestamp; echo "coturn ports missing vs 17 Aug: $(comm -13 <(ss -tulnp | grep turnserver | awk '{print $1, $5}' | sort -u) /root/coturn-ports-pre-docker.txt | wc -l)"; echo "relay range: $(sysctl -n net.ipv4.ip_local_port_range)"; echo "nat REDIRECT: $(iptables-save -t nat | grep -c REDIRECT)"; awk 'FILENAME==ARGV[1]{if($1!="")b="br-"substr($1,1,12);next}/^</{r++;print}/^>/{a++;if(b==""||index($0,b)==0){o++;print}}END{print("bridge "b" iptables removed: "r+0" added: "a+0" added-not-on-growth-bridge: "o+0)}' <(docker network inspect growth_default -f '{{.Id}}') <(diff <(grep -v '^#' /root/growth-prestart-iptables.txt | sed 's/\[[0-9]*:[0-9]*\]//') <(iptables-save | grep -v '^#' | sed 's/\[[0-9]*:[0-9]*\]//')); echo "networks: $(docker network ls --format '{{.Name}}' | sort | tr '\n' ,)"; (cd /opt/supabase/stacks/enroll && docker compose ps -a --format '{{.Status}}') | awk '{t++}/\(healthy\)/{ok++}END{print("enroll containers: "t+0" healthy: "ok+0)}'; echo "enroll api: $(curl -s -o /dev/null -m 10 -w '%{http_code}' https://api.enroll.lilbrahmas.org/auth/v1/health)"
```

Growth's containers. Expect `growth containers: 11 healthy: 11` and no
`NOT HEALTHY` lines.

```
(cd /opt/supabase/stacks/growth && docker compose ps -a --format '{{.Service}}:{{.Status}}') | awk '{t++}/\(healthy\)/{ok++;next}{print("NOT HEALTHY "$0)}END{print("growth containers: "t+0" healthy: "ok+0)}'
```

**Through the proxy, from 14 Sep 2026.** Expect GoTrue's JSON with `[200]`,
`websocket: 101 after 5.0…s` (fast means broken), and a `401` with
`www-authenticate: Basic`, so `studio header lines: 2`.

```
date -u; curl -s -m 10 -w ' [%{http_code}]\n' -H "apikey: $(awk -F= '$1=="SUPABASE_PUBLISHABLE_KEY"{print(substr($0,index($0,"=")+1))}' /opt/supabase/stacks/growth/.env)" https://api.growth.lilbrahmas.org/auth/v1/health; curl -s -m 5 -o /dev/null -w 'websocket: %{http_code} after %{time_total}s\n' --http1.1 -H "apikey: $(awk -F= '$1=="SUPABASE_PUBLISHABLE_KEY"{print(substr($0,index($0,"=")+1))}' /opt/supabase/stacks/growth/.env)" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' 'https://api.growth.lilbrahmas.org/realtime/v1/websocket?vsn=1.0.0'; curl -s -m 10 -o /dev/null -D - https://api.growth.lilbrahmas.org/ | awk 'NR==1||tolower($1)=="www-authenticate:"{n++;print}END{print("studio header lines: "n+0)}'
```

**Firewall against the newer copy.** `/root/growth-preproxy-iptables.txt` (99
lines, 14 Sep 04:31 UTC) holds the rules with growth running. Expect
`iptables changes since the preproxy copy: 0` and `growth listeners: 3 of 3`,
all on `127.0.0.1`.

```
diff <(grep -v '^#' /root/growth-preproxy-iptables.txt | sed 's/\[[0-9]*:[0-9]*\]//') <(iptables-save | grep -v '^#' | sed 's/\[[0-9]*:[0-9]*\]//') | awk '/^[<>]/{n++;print}END{print("iptables changes since the preproxy copy: "n+0)}'; ss -tln | awk '$4~/:(8010|5442|6553)$/{n++;print($4)}END{print("growth listeners: "n+0" of 3")}'
```

Every `sed` in §6 matches the **full current value** (`=enroll$`, `=8000$`, …),
not `=.*`. The match doubles as the verify-before-change: if a value is not what
the comparison showed, that edit is a no-op and the check after it shows the old
value instead of silently overwriting something unexpected.

### Step 58, §8 and §9 — 14 Sep 2026

Server time at the start: 04:26 UTC, well clear of `upcp`'s 00:46 window.

| Step | What | Result |
|---|---|---|
| 58 | growth's entry inserted directly **under enroll's** by an exact-match `sed --in-place '/^enroll.=.instance.1:…$/a …'`, not the runbook's `>>`, which would have put it below the upstream-branch note | ✅ line 9 `enroll = instance 1: 8000 / 5432 / 6543`, line 10 `growth = instance 2: 8010 / 5442 / 6553`, then the blank line and the note. 14 → 15 lines |
| fresh snapshot | the reusable host check below, unchanged, against the 13 Sep pre-start copy · growth health · today's `iptables-save` saved to `/root/growth-preproxy-iptables.txt` inside `(set -C && …)`, so a re-run cannot overwrite it | ✅ 04:31 UTC. coturn `MainPID` `1911360`, start `Wed 2026-08-26 00:46:34 UTC`, so `upcp` did not restart it. Missing `0`; relay `32768 49151`; `REDIRECT` `1`. Firewall `removed: 0 added: 25 added-not-on-growth-bridge: 3`, the 3 being the loopback `DROP` rules for 8010 / 5442 / 6553, so `upcp` changed nothing since the start. Networks `bridge,enroll_default,growth_default,host,none`; enroll `11 healthy: 11`, API `401`; growth `11 healthy: 11`. Saved copy 99 lines = 74 + 25 |

The pasted command read `docker networkls` again yet printed the list: the same
copy-only mangle as on 13 Sep.

| Step | What | Result |
|---|---|---|
| Apache before | `apachectl configtest` · one `CODE` line per site from a single `curl` · `httpd.conf` include lines for both accounts · `ls -laR` of `ssl/2_4/` · enroll's include through `cat -A` and `sha256sum` | ✅ 04:39 UTC. `Syntax OK`. enroll `200`, api.enroll `401`, growth frontend **`200`**, not the `403` §4 expected. api.growth `404` because there is no proxy yet. `httpd.conf` is 1861 lines. api.enroll has an active `Include` (line 1088) **and** cPanel's commented hint (1099), because the hint stays after an include is activated. Enroll's frontend (902) and both growth vhosts (1277, 1545) have only the commented hint. `ssl/2_4/` holds only `enroll/`, root 755. Enroll's file is `supabase.conf`, root 644, 186 bytes, and exactly step 38's five lines: sha256 `9efe890f…04d05dd` equals a local `printf` of step 38 with `8000` |
| `ensure_vhost_includes` | its source read, not run: `file -L`, then lines matching restart / dry / getoptions / `=item` | Perl, 365 lines. **It reloads Apache itself** through `Cpanel::HttpUtils::ApRestart::BgSafe::restart()` (line 363) whenever it updates a vhost, unless given `--no-restart` (line 356). `--skip-conf-rebuild` implies `--no-restart`. There is no dry-run option |

**Runbook step 39 reloads every site before step 40 tests the config.** Run as
written, `ensure_vhost_includes` rebuilds `httpd.conf` with the new include and
reloads Apache in the background, so `apachectl configtest` comes after the
reload it was meant to guard. Growth's order is therefore: syntax-test the file
before it is installed, `ensure_vhost_includes --no-restart`, then
`apachectl configtest && apachectl graceful`. The runbook itself still has the
old order.

| Step | What | Result |
|---|---|---|
| 38, staged | `sed 's\|127\.0\.0\.1:8000/\|127.0.0.1:8010/\|g'` on enroll's file into `/root/growth-api-supabase.conf`, `sha256sum`, `diff` against enroll's. Then `httpd -t`; `httpd -t -c 'Include /root/growth-no-such-file.conf'` as a control that must fail; `httpd -t -c 'Include /root/growth-api-supabase.conf'` | ✅ sha256 `78266462…a2ace3`, equal to a local `printf` of step 38 with `8010`. `diff` is exactly `3,4c3,4`, the two port lines. `Syntax OK`. The control failed as it must (`Syntax error in -C/-c directive: Could not open configuration file …`), which proves `-c` reads the file. The staged file: `Syntax OK` |
| growth frontend `200` | `ls -la` of `public_html`, `<title>` of the page | No index file. The page is Apache's own **`Index of /`** listing of `public_html`: not cPanel's default page, not the app. `.well-known` there is owned by `growthlilbrahmas` |

`-c` adds a directive after the live config is read, and `-t` parses without
applying anything, so this tests the file before it goes near cPanel's include
directory. The pasted command read `httpd-t` in its last clause, yet three
results came back and no `command not found`: copy-only again.

| Step | What | Result |
|---|---|---|
| 37–38 | `mkdir` twice, no `-p`, `&&` `cp` of the tested file `&&` `ls -laR` `&&` `sha256sum` | ✅ 04:50 UTC. `growthlilbrahmas/` and `api.growth.lilbrahmas.org/` are `drwxr-xr-x root root`; `supabase.conf` is `-rw-r--r-- root root 186`, like enroll's; sha256 `78266462…a2ace3` again. Inert until `httpd.conf` has an active `Include` and Apache reloads |
| API docroot, for step 47 | `ls -laR` · `cmp` against the parent `.htaccess` · `cat -n` | Everything is owned by `growthlilbrahmas`; the docroot is `drwxr-x---`, group `nobody`. `.well-known/acme-challenge/` **already exists**, owned by `growthlilbrahmas`, empty, modified **02:57 UTC 14 Sep**. So something wrote and removed a file there overnight, most likely AutoSSL's daily run. The `.htaccess` is byte-identical to the parent's: cPanel's MultiPHP `error_log` / `log_errors` block and the `ea-php82` handler, **no rewrite directives** |

Step 47 must therefore write only a probe **file** into the existing
`acme-challenge/` and delete it. The runbook's `mkdir -p` run as root is harmless
here only because the folder exists. On a fresh docroot it would create a
root-owned folder that AutoSSL, writing as the account, cannot use.

| Step | What | Result |
|---|---|---|
| 39, no reload | `(set -C && cat httpd.conf > /root/growth-preproxy-httpd.conf) && /scripts/ensure_vhost_includes --user=growthlilbrahmas --no-restart && diff …`, then growth's include lines, then api.growth's code after `sleep 10` | Include wired: active line 1267, api.growth's hint 1278, growth frontend's hint 1446 still commented. `api.growth now: 404` after 10 s, so `--no-restart` held and the running Apache still has the old config. **The `diff` was not one line.** 1861 → 1862 lines, but cPanel re-emitted growth's four vhost blocks with api.growth's first, and growth's SSL `ServerAlias` has its nine names in a different order. Every hunk is inside growth's section (old lines 1115–1549; enroll's lines end at 1099). Checked before any reload, below |
| `.htaccess` | `printf` append `&&` exact-line count `&&` `ls -la` `&&` api.growth's code | ✅ 04:59 UTC. `RewriteEngine Off lines: 1 of 24`; `-rw-r--r-- growthlilbrahmas growthlilbrahmas 1029` (908 + 121); `404`, so the file parses. A broken `.htaccess` would give `500` |

Rollback for the `.htaccess` line: delete the last three lines (blank, comment,
`RewriteEngine Off`); the other 21 are byte-identical to `public_html/.htaccess`.

| Step | What | Result |
|---|---|---|
| 39, checked | One `awk` over both files: each site's block keyed by `<VirtualHost>` address + `ServerName` and compared in order, with `ServerAlias` words sorted, and the new include skipped and counted only inside api.growth's `:443` block. Tested locally first on a mock `httpd.conf`, which accepted the swap and flagged each of six planted faults: a changed enroll line, a reordered directive, an include added to the frontend, a renamed alias, a removed global line, the include in the wrong site. Then `httpd -S` on the old copy (`-f`) and on the new file, default servers only | ✅ `site blocks compared: 18 differing: 0 new api.growth include lines: 1`. Default servers unchanged: `104.122.168.184.host.secureserver.net` at 328 and 307, `turn.lilbrahmas.org` at 618, and the hostname again at 1667 → 1668, one line later because it sits after growth's section. None is a growth site |

**`ensure_vhost_includes` re-emits the account's vhost blocks, and not
necessarily in the same order.** A plain `diff` of `httpd.conf` then shows
hundreds of changed lines for a one-line change, and reading it by eye proves
nothing. The per-site comparison is what separates reordering from change. Order
between vhosts with distinct names matters only for which one is an address's
default, and `httpd -S` shows that.

The check, as run (old copy first, new file second):

```
awk 'FNR==1{f++;k="GLOBAL";h=""}/^[[:space:]]*<VirtualHost/{h=$2;k=h;next}/^[[:space:]]*<\/VirtualHost>/{k="GLOBAL";next}/^[[:space:]]*ServerName/{k=h"|"$2}$1=="ServerAlias"{n=split($0,w);asort(w);s="";for(j=1;j<=n;j++)s=s" "w[j];$0=s}f==2&&k~/:443.*\|api\.growth\.lilbrahmas\.org$/&&/^[[:space:]]*Include.*userdata\/ssl\/2_4\/growthlilbrahmas\/api\.growth\.lilbrahmas\.org\//{inc++;next}{b[f,k]=b[f,k]"\n"$0;K[k]=1}END{for(k in K)if(b[1,k]!=b[2,k]){d++;print("DIFFERS "k)}print("site blocks compared: "length(K)" differing: "d+0" new api.growth include lines: "inc+0)}' /root/growth-preproxy-httpd.conf /etc/apache2/conf/httpd.conf
```

It does not check *where* inside api.growth's block the include sits; the plain
`diff` showed that: `1266a1267`, 11 lines above its commented hint, the same
spacing as enroll's 1088 / 1099.

| Step | What | Result |
|---|---|---|
| pending changes | `systemctl show httpd --property=ExecMainStartTimestamp`, the last `resuming normal operations` in `error_log`, files under `/etc/apache2` changed since 13 Sep 00:00 | Apache started `Thu 2026-09-10 00:46:22 UTC`. 79 reloads in the log, **the last at Sat 12 Sep 13:03:17** (`Apache/2.4.68 (cPanel) OpenSSL/3.5.5`), so neither night's `upcp` reloaded it. Changed since 13 Sep: only ours, `supabase.conf` at 04:50 and `httpd.conf` + `httpd.conf.datastore` at 04:58 (the datastore is cPanel's cache, written by the same `ensure_vhost_includes` run). The window from 12 Sep 13:03 to 13 Sep 00:00 was not covered, so the reload command gates on it itself |

**A reload applies everything on disk, not just the change in hand.** Apache had
not reloaded since 12 Sep, so anything cPanel wrote after that would have gone
live with growth's proxy and looked like its fault. The reload is therefore
gated on the full list of Apache config and certificate files changed since the
last reload being exactly the three above.

| Step | What | Result |
|---|---|---|
| 40–41 | one chain: `find /etc/apache2 /var/cpanel/ssl/apache_tls -type f -newermt '2026-09-12 13:03:17'` must be exactly the three files (an `awk` gate that also closes on empty output; tested locally on four cases) `&&` `apachectl configtest` `&&` `apachectl graceful` `&&` `sleep 5` `&&` one `CODE` line per site | ✅ `changed since last reload: ours 3 of 3, other 0`, `Syntax OK`, graceful ran. enroll `200`, api.enroll `401`, growth frontend `200`, all as before. api.growth **`404 → 401`**: the proxy is live, and Envoy refuses a request without a key |
| 42 | active `Include` for api.growth in `httpd.conf` | ✅ already shown at step 39: line 1267 |

The pasted command read `&&apachectl`; bash parses `&&` the same with or
without the space.

| Step | What | Result |
|---|---|---|
| 45 | GoTrue health through the proxy, with growth's publishable key read from `.env` straight into the header by `awk -F= '$1=="SUPABASE_PUBLISHABLE_KEY"{…}'` | ✅ 05:19 UTC. `{"version":"v2.189.0","name":"GoTrue",…} [200]`. Without a key the same URL gave `401` at step 41 |
| 46 | WebSocket upgrade, `--http1.1`, `-m 5` | ✅ `websocket: 101 after 5.001073s`: upgraded, then held open until the time limit |
| Studio | response headers of `https://api.growth.lilbrahmas.org/` | ✅ `HTTP/2 401` with `www-authenticate: Basic realm="http://api.growth.lilbrahmas.org/"`: the now-public dashboard asks for its login |
| 47 | probe file written into the existing `acme-challenge/`, fetched over HTTP with `-L` and over HTTPS, deleted, folder listed | ✅ `probe-growth-api-14sep [200]` both ways. The HTTP fetch stayed on `http://`, so port 80 does not redirect this path. The HTTPS fetch is the one that exercises `ProxyPass /.well-known/ !`, and it served the file rather than Envoy's `Unauthorized`. Afterwards `acme-challenge/` held only `.` and `..`, still owned by `growthlilbrahmas` |
| 50–55 | the reusable host check, unchanged | ✅ 05:19 UTC, identical to the 04:31 snapshot: coturn `1911360` since `2026-08-26 00:46:34`, missing `0`, relay `32768 49151`, `REDIRECT 1`, `removed: 0 added: 25 added-not-on-growth-bridge: 3` with the three loopback `DROP` lines, networks unchanged, enroll `11 healthy: 11`, API `401` |
| 43–44 + firewall | growth health · `diff` against `/root/growth-preproxy-iptables.txt` · `ss -tln` for 8010 / 5442 / 6553 | ✅ growth `11 healthy: 11`; `iptables changes since the preproxy copy: 0`; `growth listeners: 3 of 3`, exactly `127.0.0.1:8010`, `127.0.0.1:5442`, `127.0.0.1:6553` |
| 48 | frontend `200` | not a pass: the `200` is Apache's `Index of /`, not the app. Open until the app is served |
| 49 | RLS audit | not applicable to an empty database; it belongs after the migrations |

**Runbook §8 and §9 are complete for growth, 14 Sep 2026.**
`https://api.growth.lilbrahmas.org` serves growth's stack: empty database,
signups disabled, Studio behind basic auth. enroll, coturn and growth's frontend
answer exactly as they did before the reload.

Files left in `/root` on purpose: `growth-preproxy-iptables.txt` (the firewall
baseline from here on), `growth-preproxy-httpd.conf` (the config before step 39)
and `growth-api-supabase.conf` (the tested copy of the include).

#### Rolling §8 back

Not tested. **Do not follow runbook §10's order**, which removes `supabase.conf`
first. The active `Include ".../api.growth.lilbrahmas.org/*.conf"` would then
match no file, which Apache 2.4 documents as an error for `Include` (unlike
`IncludeOptional`). `configtest` would fail, `graceful` would be refused, and a
full restart or reboot would leave Apache down. An order that never leaves a
broken config on disk:

1. Empty the include to a comment, then reload. The proxy is off and the glob
   still matches.

   ```
   printf '%s\n' '# growth proxy rolled back' > /etc/apache2/conf.d/userdata/ssl/2_4/growthlilbrahmas/api.growth.lilbrahmas.org/supabase.conf && apachectl configtest && apachectl graceful
   ```

2. Later, un-wire it: remove the file and both directories, let
   `ensure_vhost_includes --user=growthlilbrahmas --no-restart` comment the
   `Include` out again, then `apachectl configtest && apachectl graceful`, all in
   one chain so the broken window lasts seconds with no reload inside it.

The `.htaccess` line can stay: it affects nothing but `/.well-known/`.

#### Runbook corrections found on 14 Sep

Applied to `supabase-adding-instance-runbook.md` the same day: new steps 38a–38c
and 39a–39b, rewritten steps 38–41, 47, 48 and 58, and §10's rollback. The step
numbers below are the runbook's numbers from before that change.

1. **Step 39 reloads Apache before step 40 tests the config.**
   `ensure_vhost_includes` restarts Apache itself unless given `--no-restart`.
2. **Step 38 does not test the file before it is live.**
   `httpd -t -c 'Include <file>'` parses it on top of the running config, with a
   missing-file control proving that `-c` reads the file.
3. **A plain `diff` of `httpd.conf` cannot review step 39**: cPanel re-emits the
   account's vhost blocks in a new order. Use the per-site comparison, and
   `httpd -S` for default servers.
4. **A reload applies everything on disk.** Gate step 41 on the files changed
   since the last `resuming normal operations` being only this instance's.
5. **Step 47's `mkdir -p`, run as root, creates a root-owned `acme-challenge/`**
   on a fresh docroot, which AutoSSL, writing as the account, cannot use. Write
   only a file into the account-owned folder.
6. **Step 47 over plain HTTP does not test `ProxyPass /.well-known/ !`** when
   port 80 does not redirect, as here, because the include is on the SSL vhost
   only. Fetch over HTTPS as well.
7. **Step 48's `200` can come from Apache's directory listing** of an empty
   docroot. Check content, not the code.
8. **Step 58's `>>` lands below the upstream-branch note** in
   `/opt/supabase/README.md`. Insert under the last instance line instead.
9. **§10 removes the include before un-wiring it.** See *Rolling §8 back*.

---

## 5. Still open

These are scheduled as steps in `README.md` under *Remaining steps*. The notes
here are the detail behind them.

**Answered by step 1 on 14 Sep 2026.** The decisions are recorded in `README.md`
*Open questions*; what follows is the evidence they rest on.

1. **Nitro preset** — the gate on everything container-shaped. Not in the repo at
   all; it comes from `@lovable.dev/vite-tanstack-config@2.13.1`, whose own
   comment says *"nitro (build-only using cloudflare as a default target)"*. A
   Cloudflare bundle has nothing listening on a port, so `ProxyPass` to 3010
   would reach nothing. Whether an env var overrides it, or only editing
   `vite.config.ts` does, decides whether this is maintainable — Lovable owns
   that file and `deploy.sh` refuses a dirty checkout. **Answerable entirely off
   the server:** install deps in `D:\laragon\www\growth.lilbrahmas`, build with
   the preset overridden, check whether `.output/server/index.mjs` appears.

   **Proven 14 Sep 2026 — the environment variable is enough.** Working copy
   at `4dc6623`, equal to GitHub `main`. The wrapper's `dist/index.js` sets only
   `defaultPreset: "cloudflare-module"`; it deletes `NITRO_PRESET` /
   `SERVER_PRESET` only inside Lovable's sandbox (`LOVABLE_SANDBOX=1` or
   `DEV_SERVER__PROJECT_PATH` set). Built with bun 1.4.2 on Windows:
   `NITRO_PRESET=bun bun --bun run build`, exit 0. `.output/server/index.mjs`
   alone proves nothing — `cloudflare-module` writes the same filename — so the
   evidence is `.output/nitro.json` → `"preset": "bun"`, `"preview": "bun run
   ./server/index.mjs"`, no `wrangler*` file anywhere. Run from a folder with no
   `.env` as `NITRO_HOST=127.0.0.1 NITRO_PORT=3999 bun .output/server/index.mjs`:
   `Listening on: http://127.0.0.1:3999/`, only on loopback; a static asset
   `200`; `POST /api/public/hooks/dwr-nudge` without a key → the route's own
   `Unauthorized [401]`, so server routes run in the bun process. Stopped, port
   released. The runtime reads `NITRO_PORT`/`PORT` and `NITRO_HOST`/`HOST`.
2. **Target the `bun` preset, not `node-server`.** Lovable's toolchain is bun
   (`bunfig.toml`, `bun.lock` kept current) and **this server has no Node** —
   enroll already builds in `oven/bun:1-alpine`. The bun preset lets one image
   both build and run, introducing no new runtime to the box. Nitro 3 depends on
   `srvx`, which serves a `{ fetch }` handler natively on node/deno/bun, so
   `src/server.ts` needs no change either way.
3. **Two lockfiles are present** — `bun.lock` (220 KB) and `package-lock.json`
   (320 KB), same timestamp. They can resolve differently. Pin the build to bun
   with `--frozen-lockfile`, as enroll's deploy already does.
   14 Sep 2026: `bun install --frozen-lockfile` → 553 packages, `bun.lock`
   sha256 identical before and after.

   **The build regenerates `src/routeTree.gen.ts`.** Locally it showed as
   modified: the committed blob is LF, the Windows checkout (`core.autocrlf=true`)
   is CRLF, the build writes LF. Content identical ignoring CR; restored with
   `git checkout --`, status clean. On Linux the checkout is LF, so it matches —
   but if Lovable ever pushes a stale `routeTree.gen.ts`, `deploy-growth`'s
   dirty-checkout guard trips *after* the build. The guard must run before it.
4. **App server port 3010** — verified free. Below 32768, clear of the Supabase
   bands and cPanel's 2082–2096. **Re-checked 14 Sep 2026 07:16 UTC:**
   `sockets seen: 68 listening on 3010: 0`; `apache files scanned: 3` (`httpd.conf`
   and both `supabase.conf` includes) `lines with :3010: 0`; relay range
   `32768 49151`.
5. **Where the four runtime variables live** — `SUPABASE_URL`,
   `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_PUBLISHABLE_KEY`, `LOVABLE_API_KEY`.
   Note these are read from `process.env` at **runtime**, not baked at build
   time like enroll's `VITE_*` values. Two different mechanisms in one app.

   **Checked against the bun build, 14 Sep 2026.** Both mechanisms are live:
   - **Build time:** the wrapper runs Vite's `loadEnv(mode, cwd, "VITE_")` and
     `define`s each value. The repo **commits `.env`** with `VITE_SUPABASE_URL`
     = `https://hwchtywjbmcvpucidfmy.supabase.co` (Lovable Cloud) and its
     publishable key. Both are baked into 2 browser files
     (`assets/index-*.js`, `assets/supabase-browser-*.js`) **and** 2 SSR files
     (`_ssr/client-*.mjs`, `_ssr/supabase-browser-*.mjs`): `client.ts` prefers
     `import.meta.env.VITE_*` over `process.env`, so runtime values do not
     override them. A VPS build must supply growth's values at build time.
   - **Runtime:** `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
     `SUPABASE_PUBLISHABLE_KEY` (server client, auth middleware, hook routes)
     and `LOVABLE_API_KEY` from `process.env`. `LOVABLE_API_KEY` is named in 3
     server files and 0 browser files; `SUPABASE_SERVICE_ROLE_KEY` in 0 browser
     files.
   - **Bun auto-loads `.env` from the current directory at runtime** (tested
     with bun 1.4.2): a real environment variable wins over the file, a variable
     only in the file is used, `--no-env-file` or another directory loads
     nothing. So a process started in the checkout, missing any variable, would
     silently fall back to the committed **Lovable Cloud** values.
   - A third `LOVABLE_API_KEY` consumer exists now: `call-audits.functions.ts`
     (call transcription via `/v1/audio/transcriptions`, model
     `google/gemini-3.5-transcribe`, then scoring).
6. **Only ~9 routes are server-rendered.** `src/routes/_authenticated/route.tsx`
   sets `ssr: false`, so all 111 authenticated routes render client-side. The
   process exists for **server functions**, not rendering — so a healthcheck must
   call a server function, not just fetch `/`.
7. **Until the app is served, `https://growth.lilbrahmas.org/` is a public
   directory listing** of `public_html` (Apache's `Index of /`, `200`; seen
   14 Sep 2026). The app's own `ProxyPass /` will replace it. Until then, a `200`
   there is no evidence of anything.
8. **`LOVABLE_API_KEY` cannot be carried off Lovable** — from Lovable's docs,
   read 14 Sep 2026 (`docs.lovable.dev/features/secrets`): secrets are
   write-only, *"its value can never be viewed again in Lovable, only replaced
   or deleted"*; `LOVABLE_` is reserved for Lovable-managed values; this key has
   a Rotate action and cannot be deleted. No Lovable page says whether the
   gateway accepts calls from an app hosted elsewhere, and without the value it
   cannot be tested. Three consumers at `4dc6623`: `ai.functions.ts` (ask-AI,
   `google/gemini-3-flash-preview`), `module-auto.functions.ts` (AI training),
   `call-audits.functions.ts` (`/v1/audio/transcriptions` with
   `google/gemini-3.5-transcribe`, scoring with `google/gemini-3.8-flash`).
   The gateway URL and model names are hard-coded.
