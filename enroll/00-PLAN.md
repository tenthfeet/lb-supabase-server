# Deploying enroll.lilbrahmas to the VPS

## Context

The app currently runs entirely on Lovable Cloud: a hosted Supabase project
(`pcuzksquykmyboxxrawb`) plus a Lovable-hosted frontend. The VPS at
`184.168.122.104` already has a working self-hosted Supabase instance — the
`enroll` stack, instance 1, ports 8000/5432/6543, reverse-proxied at
`https://api.enroll.lilbrahmas.org` — but its `public` schema is **empty**. The
deployment runbook records it as "RLS pattern established, no application tables
yet."

So the server work is done. What remains is moving *this application* onto it:
schema, data, 17 edge functions, secrets, and a static frontend build.

**Decisions taken (2026-08-20):**

| | |
|---|---|
| Topology | VPS = production. Lovable Cloud stays the dev environment. |
| Frontend host | `https://enroll.lilbrahmas.org` |
| AI gateway | Keep `ai.gateway.lovable.dev` + `LOVABLE_API_KEY` for now; verify it works off-Lovable. |
| Data migration | Route unknown — Phase 0 determines it. |

**The consequence to internalise before starting:** once the VPS is production,
content the client edits inside the Lovable preview goes to the *Lovable Cloud*
database and **will not appear on the live site**. Production content is edited
at `https://enroll.lilbrahmas.org/admin-control`. Lovable is for code only.

---

## What the app actually needs

Established by reading the repo — this is what shapes every phase below.

- **Static SPA.** Vite 5 + React 18, no SSR. `npm run build` → `dist/`. Server
  needs no Node at runtime.
- **47 tables**, 141 `CREATE POLICY`, 48 `ENABLE ROW LEVEL SECURITY` across 43
  migration files in `supabase/migrations/`. RLS is already the design, not an
  afterthought — the addendum §6 warning is largely pre-answered by this codebase.
- **17 edge functions** in `supabase/functions/`, plus a `_shared/` helper.
  Called via `supabase.functions.invoke(...)` from 22 call sites.
- **Auth: admin only.** `signUp` / `signInWithPassword` / `getSession` /
  `signOut`. First signup claims admin via `public.claim_first_admin()`.
  Public visitors are `anon`.
- **No Storage, no Realtime.** Confirmed by grep — nothing calls
  `supabase.storage` or `.channel(`. Simplifies the proxy and the migration.
- **External secrets needed by functions:** `LOVABLE_API_KEY`,
  `LARAVEL_API_BASE_URL`, `LARAVEL_API_KEY`, `LARAVEL_CLIENT_ID`,
  `LARAVEL_CLIENT_SECRET`. (`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are
  injected by the stack automatically.)
- **Frontend build vars:** `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`,
  optional `VITE_ADMISSION_API_BASE`. (`VITE_SUPABASE_PROJECT_ID` is in `.env`
  but unused in `src/`.)

---

## Phase 0 — Open an SSH tunnel, and find out what DB access you have

Everything downstream depends on this.

### 0.1 Tunnel (do this first — you'll use it in every later phase)

Postgres on the VPS is loopback-only by design. From Windows:

```bash
ssh -L 55432:127.0.0.1:5432 root@184.168.122.104
```

Leave it open. `postgresql://postgres:<POSTGRES_PASSWORD>@127.0.0.1:55432/postgres`
now reaches the VPS database from your workstation, from psql, DBeaver, or
`npx supabase`. Password is in `/opt/supabase/stacks/enroll/.env`.

### 0.2 Determine the source-database route

Try in order; stop at the first that works.

**Route A — direct Postgres (best).** In Lovable, open the project's Cloud /
Backend panel and look for a database connection string. If Lovable exposes the
underlying Supabase dashboard, it's under Project Settings → Database.

```bash
psql "postgresql://postgres.pcuzksquykmyboxxrawb:<PW>@aws-0-<region>.pooler.supabase.com:5432/postgres" -c '\dt public.*'
```

> ⚠ Do **not** reset the Supabase database password to obtain one — Lovable
> Cloud holds that credential internally and a reset may break the client's
> Lovable environment. If no password is retrievable, use Route B.

**Route B — service-role key over PostgREST.** Check whether Lovable's backend
settings reveal the service role key. If yes, every table is readable:

```bash
curl -s -H "apikey: $SERVICE_ROLE" -H "Authorization: Bearer $SERVICE_ROLE" \
  "https://pcuzksquykmyboxxrawb.supabase.co/rest/v1/leads?select=*"
```

**Route C — publishable key only (guaranteed to work).** Migration
`20260630090539_*.sql` grants `public can SELECT` on every `admin_*` table. With
just the key already in `.env` you can pull all **content** tables (courses,
pricing, FAQs, syllabus, videos, locales, i18n templates, content blocks…):

```bash
curl -s -H "apikey: $VITE_SUPABASE_PUBLISHABLE_KEY" \
  "https://pcuzksquykmyboxxrawb.supabase.co/rest/v1/admin_courses?select=*"
```

What Route C **cannot** reach: `leads`, `enrollments`, `coupons`,
`coupon_reveals`, `admission_events`, `admission_attempts`, `otp_challenges`,
`payment_locks`, `slot_holds`, `user_roles`, `user_accounts`, `xsell_*`,
`publish_requests`, `faq_unknown_questions`. Most are operational and can start
empty. `leads` and `enrollments` are the two with real business value — decide
then whether they're worth chasing Route A/B for.

**Deliverable of Phase 0:** which route, and a written list of which tables
carry data across.

---

## Phase 1 — Build the schema on the VPS

### 1.1 Apply the migrations

Route A gives the option of `pg_dump --schema=public`, but **replaying the
migration files is preferable even when a dump is available** — it produces a
schema whose provenance is the repo, so future Lovable migrations stack cleanly
on top.

From the workstation, through the tunnel, in filename order:

```bash
for f in $(ls supabase/migrations/*.sql | sort); do echo "== $f"; psql "postgresql://postgres:<PW>@127.0.0.1:55432/postgres" -v ON_ERROR_STOP=1 -f "$f" || break; done
```

`ON_ERROR_STOP=1` and `|| break` matter — these migrations are not idempotent as
a set, and a silent mid-file failure leaves a half-built schema that is worse
than none.

### 1.2 Verify the migrations actually match the live schema

This is the step that catches the real risk: **Lovable may have made schema
changes through its UI that never landed in a migration file.**

`src/integrations/supabase/types.ts` is auto-generated by Lovable *from the live
hosted database*, so it is an independent record of the true schema.

**Pre-checked, re-confirmed at HEAD 9cee5917 (2026-08-22) — no drift.** Comparing the 43
migration files to `types.ts` gives 47 tables on both sides, with both diff
directions empty. Nothing exists in Lovable that the migrations don't create.
The migrations are a complete account of the live schema.

Still run the VPS-vs-Lovable comparison after applying them — that catches a
migration that ran but did less than it appeared to:

```bash
npx supabase gen types typescript --db-url "postgresql://postgres:<PW>@127.0.0.1:55432/postgres" > /tmp/types.vps.ts
diff <(bash schema-fingerprint.sh /tmp/types.vps.ts) <(bash schema-fingerprint.sh src/integrations/supabase/types.ts)
```

`schema-fingerprint.sh` reduces a `types.ts` to sorted `table`/`col`/`func`
lines so the diff is meaningful rather than formatting noise. Baseline for the
repo's file: **47 tables, 650 columns, 21 RPC functions.**

> Its character classes are `[a-zA-Z0-9_]`, not `[a-zA-Z_]`. Table names here
> contain digits (`admin_i18n_templates`); a letters-only class silently drops
> that table and reports a phantom gap. Cost an investigation to find — don't
> "simplify" it back.

(21 RPC functions vs. 24 `CREATE FUNCTION` in the migrations is expected, not
drift: trigger functions like `touch_updated_at`, `ensure_user_account` and
`_i18n_obj` are not RPC-exposed and so never appear in generated types.)

### 1.3 RLS audit

Non-negotiable, and the addendum already gives the query (§6). Run it after
1.1 and after every future migration:

```bash
docker compose exec -T db psql -U postgres -c "SELECT c.relname, c.relrowsecurity AS rls_on, c.relforcerowsecurity AS rls_forced, count(p.polname) AS policies FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_policy p ON p.polrelid=c.oid WHERE n.nspname='public' AND c.relkind='r' GROUP BY 1,2,3 HAVING NOT c.relrowsecurity OR count(p.polname)=0 ORDER BY 1;"
```

`(0 rows)` is the pass condition. Expect it to pass — but confirm, don't assume;
48 `ENABLE` statements against 47 tables leaves no margin for one that was
missed.

---

## Phase 2 — Admin accounts, before any data

Order matters. Do this **before** loading data, because of one trap:

> Nine tables carry FKs to `auth.users(id)` — `user_roles`, `user_accounts`,
> `publish_requests`, `admin_revisions`, `admin_diagrams.updated_by`,
> `admin_offers.created_by` and others. If you load `public` data referencing the
> old Lovable UUIDs while the VPS auth users have fresh UUIDs, every one of those
> inserts fails on a foreign key violation.

**Recommended:** preserve the original UUIDs. Insert the handful of admin rows
straight into `auth.users` on the VPS with the source `id`, `email`,
`encrypted_password` (bcrypt, copies across unchanged), `email_confirmed_at`,
`aud`, `role`, plus a matching `auth.identities` row. Selecting columns
explicitly — rather than dumping the whole `auth` schema — is what makes this
survive the GoTrue version difference between hosted and self-hosted.

**If you can't read `auth.users` (Route C):** register the admins fresh at
`/admin-login`, then `UPDATE` the new UUIDs into the FK columns before loading
the referencing tables, or simply null those audit columns out. With one or two
admins this is the lower-effort path.

**Then bootstrap the first admin.** `public.claim_first_admin()` inserts an
`admin` row into `user_roles` for the caller — but only while `user_roles` holds
no admin, and only for an `authenticated` caller. So: sign up at
`https://enroll.lilbrahmas.org/admin-login`, then the app calls it.

**Then close signup.** `AdminLogin.tsx` exposes a public `signUp` form, and the
stack currently runs `ENABLE_EMAIL_AUTOCONFIRM=true` (addendum §4.7). Together
that is an open registration endpoint on a public site. Once admins exist, set
`DISABLE_SIGNUP=true` in `/opt/supabase/stacks/enroll/.env` and restart `auth`.
The signup form will then error — that is the intended state.

---

## Phase 3 — Move the data

Whatever route Phase 0 produced, the mechanics are the same: read from the
source, write to `https://api.enroll.lilbrahmas.org/rest/v1/<table>` with the
VPS **service role** key, or `\copy` through the tunnel for Route A.

Order by dependency — parents before children:

1. `admin_locales`, `admin_course_categories`, `admin_course_levels`
2. `admin_courses`, `admin_course_paths`, `admin_syllabus`, `admin_pricing_plans`
3. remaining `admin_*` (content blocks, FAQs, videos, offers, feature flags, settings, i18n templates)
4. `price_list_periods` → `price_courses` → `price_slabs`
5. `coupon_configs` → `coupons` → `coupon_reveals`
6. `xsell_mappings`, then `leads` / `enrollments` if you're carrying them

Leave empty: `otp_challenges`, `slot_holds`, `payment_locks`,
`admission_events`, `admission_attempts`, `faq_unknown_questions`,
`publish_requests`, `admin_revisions`. All are ephemeral or regenerable.

**No sequence resets needed.** Verified 2026-08-20: every primary key in these
migrations is `uuid DEFAULT gen_random_uuid()` — there is not one
`serial`/`identity` column in the schema. Explicit ids can be inserted freely
with no counter to fix up afterwards.

### Measured inventory (probe run 2026-08-20, Route C)

22 content tables hold data, ~400 rows total — small enough to move in one pass:

```
admin_faqs             103    admin_content_blocks    66    admin_i18n_templates  58
admin_pricing_plans     21    price_slabs             45    admin_feature_flags   40
admin_student_works     14    admin_reasons           12    admin_syllabus         7
admin_course_levels      5    price_courses            5    admin_rule_cards       4
admin_exit_popup_settings 3   admin_contact_info       2    admin_courses          2
admin_course_categories  2    admin_locales            2    admin_offers           2
admin_coupon_settings    1    admin_payment_lock_settings 1 admin_sibling_settings 1
price_list_periods       1
```

Already empty on Lovable, so nothing to move: `admin_course_paths`,
`admin_custom_sections`, `admin_diagrams`, `admin_lead_gate_settings`,
`admin_reason_options`, `admin_reason_sets`, `admin_revisions`, `admin_settings`,
`admin_videos`.

---

## Phase 4 — Edge functions

### 4.1 Get the code onto the server

Clone the GitHub repo the Lovable project syncs to — this makes every future
update a `git pull`:

```bash
git clone https://github.com/lilbrahmas-hue/lil-brahmas-pathfinder-fa3abdd4.git /opt/apps/enroll
```

Then sync the functions into the stack, **excluding `main/`** — the stack ships
its own router at `volumes/functions/main/index.ts` and overwriting it breaks
dispatch for every function:

```bash
rsync -a --exclude 'main/' /opt/apps/enroll/supabase/functions/ /opt/supabase/stacks/enroll/volumes/functions/
```

`_shared/` copies across as an ordinary directory; the relative import
`../_shared/phoneValidation.ts` resolves because the whole tree is mounted.

### 4.2 Secrets

The `functions` service in the stock compose file passes only the Supabase-
injected variables. The five app secrets must be added. Put the values in
`/opt/supabase/stacks/enroll/.env` (mode 600, alongside the existing secrets),
and reference them from `docker-compose.override.yml`:

```yaml
services:
  functions:
    environment:
      LOVABLE_API_KEY: ${LOVABLE_API_KEY}
      LARAVEL_API_BASE_URL: ${LARAVEL_API_BASE_URL}
      LARAVEL_API_KEY: ${LARAVEL_API_KEY}
      LARAVEL_CLIENT_ID: ${LARAVEL_CLIENT_ID}
      LARAVEL_CLIENT_SECRET: ${LARAVEL_CLIENT_SECRET}
```

> **Use plain merge here — not `!override`.** Compose merges mappings and
> replaces lists. `environment:` is a mapping in the base file, so these are
> additive. The `!override` tag used on `ports:` exists precisely because lists
> behave differently; applying it here would delete the injected `SUPABASE_URL`
> and `SUPABASE_SERVICE_ROLE_KEY` and break every function.

Values come from the Lovable project's edge-function secrets. The Laravel base
URL defaults to `https://qa.lilbrahmas.org` in code — confirm the production
value with the Laravel side rather than inheriting the QA default.

> **Runbook note:** the adding-instance runbook step 11 asserts
> `docker-compose.override.yml` is 33 lines with 11 `!reset null` entries. This
> edit changes the line count. Update that expectation, or the next instance
> build will read as a failure.

### 4.3 Restart and check JWT verification

```bash
cd /opt/supabase/stacks/enroll && docker compose up -d functions
```

Then test the one function a logged-out visitor must reach:

```bash
curl -s -X POST -H "apikey: $KEY" -H 'Content-Type: application/json' \
  -d '{"phone":"+919999999999","session_id":"probe-12345678"}' \
  https://api.enroll.lilbrahmas.org/functions/v1/otp-request
```

A `401` means `FUNCTIONS_VERIFY_JWT` is rejecting the call — set it to `false`
in `.env` and restart. This interacts with `src/integrations/supabase/client.ts`,
which **deletes** the `Authorization` header when the key is a new-style opaque
`sb_publishable_…` key and sends only `apikey`. Check which format the VPS
issued: `grep '^SUPABASE_PUBLISHABLE_KEY=' .env`. Either format is handled by
the client, but it decides whether a JWT reaches the function.

### 4.4 Verify the Lovable AI gateway still answers

The open question from the decisions above. Five functions depend on it:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H "Authorization: Bearer $LOVABLE_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"google/gemini-2.5-flash","messages":[{"role":"user","content":"ping"}]}' \
  https://ai.gateway.lovable.dev/v1/chat/completions
```

`200` → keep it, revisit later. `401`/`403` → the key is bound to Lovable-hosted
execution, and `ai-translate`, `faq-assistant`, `video-transcribe`,
`translate-templates`, `diagram-refresh` need repointing at a direct provider.
The other 12 functions are unaffected either way, so this does not block launch.

---

## Phase 5 — Frontend build and deploy

### 5.1 Build against the VPS

Create `.env.production.local` in the project root. It is **gitignored** by the
existing `*.local` rule, so Lovable never sees it and `git pull` never clobbers
it — this is why it's the right file rather than editing the committed `.env`:

```
VITE_SUPABASE_URL=https://api.enroll.lilbrahmas.org
VITE_SUPABASE_PUBLISHABLE_KEY=<SUPABASE_PUBLISHABLE_KEY from the VPS .env>
```

```bash
npm ci && npm run build
```

Vite loads `.env.production.local` last in production mode, so it wins over the
committed Lovable values.

### 5.2 Upload

`/home/enroll/public_html` is the frontend docroot — and
`/home/enroll/public_html/api.enroll.lilbrahmas.org` sits **inside** it. A
`--delete` sync that doesn't exclude that directory destroys the API subdomain's
docroot and its ACME challenge path.

Upload as the cPanel user `enroll`, not root, or cPanel/Apache will refuse to
serve files it doesn't own:

```bash
rsync -av --delete --exclude 'api.enroll.lilbrahmas.org/' --exclude '.well-known/' --exclude '.htaccess' dist/ enroll@184.168.122.104:/home/enroll/public_html/
```

### 5.3 `.htaccess` — SPA routing without breaking AutoSSL

React Router serves `/courses`, `/admin-control`, `/admin-login` and others from
`index.html`. Without a rewrite every deep link and every refresh is a 404.

`/home/enroll/public_html/.htaccess`:

```apache
<IfModule mod_rewrite.c>
  RewriteEngine On
  RewriteBase /
  RewriteRule ^\.well-known/ - [L]
  RewriteRule ^api\.enroll\.lilbrahmas\.org/ - [L]
  RewriteCond %{REQUEST_FILENAME} -f [OR]
  RewriteCond %{REQUEST_FILENAME} -d
  RewriteRule ^ - [L]
  RewriteRule . /index.html [L]
</IfModule>

<IfModule mod_headers.c>
  <FilesMatch "\.(js|css|woff2|png|jpg|svg|webp)$">
    Header set Cache-Control "public, max-age=31536000, immutable"
  </FilesMatch>
  <FilesMatch "^(index\.html|manifest\.webmanifest|sitemap\.xml)$">
    Header set Cache-Control "no-cache"
  </FilesMatch>
</IfModule>
```

> **The two `RewriteRule … - [L]` exclusions are the load-bearing lines**, for
> the same reason `ProxyPass /.well-known/ !` is in the vhost. cPanel applies a
> parent `.htaccess` to nested subdomain docroots. Without them, this SPA
> rewrite catches AutoSSL's validation fetch for *both* hostnames, hands Let's
> Encrypt an HTML page instead of the token, and the certificates expire ~90
> days later with no warning. Same failure mode as the coturn certificate
> incident in addendum §7 — silent, delayed, and total.

Belt and braces — `/home/enroll/public_html/api.enroll.lilbrahmas.org/.htaccess`:

```apache
RewriteEngine Off
```

Long-cache on hashed assets is safe: `vite.config.ts` emits content-hashed
filenames. `index.html` must not be cached or clients pin to a stale bundle.

---

## Phase 6 — Verification

Run the existing gates from the runbooks first — addendum §8 in full, and
adding-instance steps 50–55 to confirm coturn and instance health are
undisturbed. Then these, specific to this app:

```bash
# ACME still works on BOTH hostnames — run after .htaccess is in place
mkdir -p /home/enroll/public_html/.well-known/acme-challenge
echo probe > /home/enroll/public_html/.well-known/acme-challenge/probe
curl -sL http://enroll.lilbrahmas.org/.well-known/acme-challenge/probe        # must print: probe
curl -sL http://api.enroll.lilbrahmas.org/.well-known/acme-challenge/probe    # must print: probe (per addendum §8)
rm -f /home/enroll/public_html/.well-known/acme-challenge/probe

# SPA deep link resolves rather than 404s
curl -s -o /dev/null -w '%{http_code}\n' https://enroll.lilbrahmas.org/admin-login   # → 200

# Auth reachable through the proxy
curl -s -H "apikey: $KEY" https://api.enroll.lilbrahmas.org/auth/v1/health

# A public content table reads as anon — proves RLS + PostgREST + data together
curl -s -H "apikey: $KEY" "https://api.enroll.lilbrahmas.org/rest/v1/admin_courses?select=id&limit=1"

# A protected table must NOT read as anon
curl -s -H "apikey: $KEY" "https://api.enroll.lilbrahmas.org/rest/v1/leads?select=id&limit=1"   # → [] or error, never rows
```

Then in a browser, end to end:

1. Home page renders, courses and pricing populate (proves PostgREST + data).
2. `/admin-login` → sign in → `/admin-control` loads (proves auth + `is_admin`).
3. Lead-gate modal → phone → OTP (proves `otp-request` / `otp-verify`).
4. Coupon validate on a course page (proves `coupon-validate`).
5. Course catalog from Laravel (proves `laravel-catalog` + its secrets).
6. Browser console clean — no CORS errors. A CORS failure means `SITE_URL` in
   the stack `.env` doesn't match `https://enroll.lilbrahmas.org`.

---

## Changes you need to make in Lovable

None of these block the deploy, but items 1 and 2 are production correctness
issues and item 3 is a security hole that ships with the current code.

**1. `scripts/generate-sitemap.ts` line 6 — wrong domain.**
`BASE_URL = "https://lil-brahmas-pathfinder.lovable.app"`. This script runs on
every `prebuild`, so today's `public/sitemap.xml` advertises the Lovable preview
URL to search engines. Change to `https://enroll.lilbrahmas.org`.

**2. `index.html` — stale preconnect and inconsistent canonical.**
Line 18 preconnects to `https://pcuzksquykmyboxxrawb.supabase.co`, which after
cutover is a DNS lookup and TLS handshake to a host the app never contacts →
change to `https://api.enroll.lilbrahmas.org`. Separately, `canonical` and
`og:url` both point at `https://www.lilbrahmas.com/` while the site will serve
from `enroll.lilbrahmas.org` — pick one and make it consistent, or search
engines will index neither cleanly.

**3. `supabase/functions/otp-request/index.ts` — the OTP bypass is live today.**
`sendWhatsAppOtp()` returns `{ ok: true, channel: "stub" }` without sending
anything, and `resolveSettings()` falls back to `test_mode: true` with
`dev_bypass_code: "000000"` whenever no settings row matches.

This is **not hypothetical**. The Phase 0 probe confirmed
`admin_lead_gate_settings` currently holds **0 rows**, so the fallback at
`index.ts:32-38` is what production is running right now — **anyone can pass the
lead gate and phone verification by typing 000000.**

Two things are required, not one:
- Insert a `site`-scope row in `admin_lead_gate_settings` with
  `test_mode = false`. An empty table means the hardcoded defaults win.
- Wire a real WhatsApp/SMS provider into `sendWhatsAppOtp()`. With
  `test_mode = false` and the stub still in place, no code is ever delivered and
  the gate becomes impassable instead of wide open.

Treat as launch-blocking.

**4. Admin-only edge functions don't check the caller.**
`ai-translate`, `translate-templates`, `video-transcribe`, `diagram-refresh` and
`faq-assistant` read no `Authorization` header and verify no role. On Lovable
this was already weak (the anon key is public), but self-hosted with
`FUNCTIONS_VERIFY_JWT=false` they become freely callable, and four of them spend
AI credits per call. Add a guard: read the caller's JWT, create a client with
it, and require `public.is_admin()` — the function already exists and is used by
141 policies.

**5. Optional — `VITE_ADMISSION_API_BASE`.** Defaults to `""` in
`src/lib/admissionApi.ts`. If admission tracking should post somewhere in
production, set it; otherwise no action.

---

## Ongoing release process

With VPS as production and Lovable Cloud as dev, each release is four steps:

```bash
git pull                                   # workstation: pick up Lovable's changes
```

1. **New migrations?** Apply through the tunnel and let the Supabase CLI track
   them, so the VPS keeps a real migration ledger rather than a hand-maintained
   list:
   ```bash
   npx supabase migration up --db-url "postgresql://postgres:<PW>@127.0.0.1:55432/postgres"
   ```
   Then re-run the RLS audit (Phase 1.3). Every new table in `public` is granted
   full read/write to `anon` by default — this is the moment of highest risk.
2. **Edge functions changed?** On the VPS: `git -C /opt/apps/enroll pull`,
   re-run the Phase 4.1 rsync, then `docker compose up -d functions`.
3. **Frontend:** `npm ci && npm run build`, then the Phase 5.2 rsync.
4. **Smoke test** the six browser checks in Phase 6.

Two standing cautions carried from the runbooks: cPanel's `upcp --cron` runs
around 00:46 UTC and restarts firewalld and Apache — don't deploy across it. And
Docker is version-locked, so security updates for it are a manual, watched task.

---

## Known risks

| Risk | Handling |
|---|---|
| Migrations don't match live schema (Lovable UI edits) | Phase 1.2 types.ts diff — catches it before data load |
| FK violations from `auth.users` UUID mismatch | Phase 2 runs before Phase 3, preserving UUIDs |
| SPA rewrite swallows ACME → certs die silently in ~90 days | Explicit exclusions + probe both hostnames in Phase 6 |
| `LOVABLE_API_KEY` rejected off-Lovable | Phase 4.4 tests it in isolation; 12 of 17 functions unaffected |
| Open signup on a public site | `DISABLE_SIGNUP=true` immediately after Phase 2 |
| OTP bypass code `000000` live | Lovable change #3 — treat as launch-blocking |
| Client edits content in Lovable preview, expects it live | Process, not technical: production content is edited on the VPS admin panel |

## Outstanding from the runbooks that this deploy makes urgent

The addendum §10 list still stands. Two items move up now that real data lands
on the box: **Postgres backups** (none configured — `pg_dump` via
`docker compose exec -T db`, stored outside `/home` so cPanel's backup sweep
doesn't touch it) and **SMTP** (without it password reset does not work, so a
locked-out admin needs manual intervention through Studio).
