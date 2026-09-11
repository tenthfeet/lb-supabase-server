# Deploy enroll.lilbrahmas to the VPS — execution guide

**Server:** `184.168.122.104` · **Stack:** `/opt/supabase/stacks/enroll` (instance 1)
**API:** `https://api.enroll.lilbrahmas.org` · **Frontend:** `https://enroll.lilbrahmas.org`

Every server command below is **one line**. Your runbook records that this
terminal silently drops multi-line pastes — that is why nothing here spans
lines, and why the longer work ships as script files you transfer rather than
paste.

Run steps in order. Each has an expected result; if you don't get it, stop.

---

## Already done (2026-08-20)

- ✅ **Phase 0** — access route determined: **Route C** (publishable key) works.
      No direct Postgres or service-role access needed for content.
- ✅ **Content exported** — 397 rows across 22 tables, in `content-export/`.
- ⬜ `leads` and `enrollments` were NOT exported (Route C can't read them).
      Decide whether to chase Route A/B access for them. Not launch-blocking.

---

## Step 1 — Wire git to the server

A **root-owned clone at `/opt/apps/enroll` with a GitHub deploy key.**

> **Not cPanel's Git Version Control.** Its `.cpanel.yml` tasks run as the
> cPanel user `enroll`, which cannot write to
> `/opt/supabase/stacks/enroll/volumes/functions/` (root-owned) and cannot run
> `docker compose`. That covers the frontend only — you'd still need a
> root-side mechanism for edge functions and migrations, and maintaining two is
> worse than one. It would also put the repo, and ~500 MB of `node_modules`,
> inside `/home/enroll` — which addendum §4.1 deliberately avoids because
> cPanel backups sweep that tree and it counts against quota. And it does not
> auto-sync anyway: there is no webhook receiver, so it is two clicks in the UI.

Generate a deploy key on the server:

```bash
ssh root@184.168.122.104 "ssh-keygen -t ed25519 -C 'enroll-vps-deploy' -f /root/.ssh/enroll_deploy -N ''"
```

```bash
ssh root@184.168.122.104 "cat /root/.ssh/enroll_deploy.pub"
```

Add that key to GitHub: **repo → Settings → Deploy keys → Add deploy key**.
Leave **"Allow write access" OFF** — read-only means a compromised server cannot
push to your repo.

Point ssh at it:

```bash
ssh root@184.168.122.104 "printf 'Host github.com\n  IdentityFile /root/.ssh/enroll_deploy\n  IdentitiesOnly yes\n' >> /root/.ssh/config && chmod 600 /root/.ssh/config"
```

```bash
ssh root@184.168.122.104 "ssh -o StrictHostKeyChecking=accept-new -T git@github.com"
```

**Expect:** `Hi lilbrahmas-hue/lil-brahmas-pathfinder-fa3abdd4! You've successfully
authenticated, but GitHub does not provide shell access.` That message *is*
success — GitHub always closes the connection.

Clone:

```bash
ssh root@184.168.122.104 "git clone git@github.com:lilbrahmas-hue/lil-brahmas-pathfinder-fa3abdd4.git /opt/apps/enroll"
```

Verify — expect `17` (or `18` incl. `_shared`) and `43`:

```bash
ssh root@184.168.122.104 "ls -d /opt/apps/enroll/supabase/functions/*/ | wc -l; ls /opt/apps/enroll/supabase/migrations/*.sql | wc -l"
```

Install the deploy script:

```bash
scp deploy.sh root@184.168.122.104:/usr/local/sbin/deploy-enroll
```

```bash
ssh root@184.168.122.104 "chmod +x /usr/local/sbin/deploy-enroll"
```

Create the build env file on the server. It is gitignored by the `*.local` rule
at `.gitignore:13`, so pulls never clobber it. Get the key first:

```bash
ssh root@184.168.122.104 "grep '^SUPABASE_PUBLISHABLE_KEY=' /opt/supabase/stacks/enroll/.env"
```

```bash
ssh root@184.168.122.104 "printf 'VITE_SUPABASE_URL=https://api.enroll.lilbrahmas.org\nVITE_SUPABASE_PUBLISHABLE_KEY=PASTE_KEY_HERE\n' > /opt/apps/enroll/.env.production.local"
```

> With git on the server, **Step 6 (frontend) becomes automatic** — `deploy-enroll`
> builds inside the `node:22-alpine` image already on the box, so no `ea-nodejs`
> package is installed on a production server. `package-lock.json` carries the
> musl variants of `@swc/core` and `@rollup`, so an Alpine build is sound.

---

## Step 2 — Build the schema

Transfer the migration script, then run it **on the server**:

```bash
scp apply-migrations.sh root@184.168.122.104:/root/
```

```bash
ssh root@184.168.122.104 "bash /root/apply-migrations.sh"
```

**Expect:** 43 × `ok`, then the RLS audit showing **exactly these two rows**, then `47`:

```
    relname     | rls_on | rls_forced | policies
----------------+--------+------------+----------
 otp_challenges | t      | f          |        0
 slot_holds     | t      | f          |        0
```

### Why two rows is the pass condition, not zero

The audit flags "RLS on with no policies". For most tables that is a bug — it
means nobody can read them. For these two it is **the intended design**, because
neither is ever touched directly by a client:

- **`slot_holds`** — migration `20260630101851` drops every policy on purpose.
  Its own first line reads *"Lock down slot_holds direct table access. All
  reads/writes must go through SECURITY DEFINER RPCs."* Access is via
  `claim_slot_hold`, `extend_slot_hold`, `release_slot_hold` and
  `list_busy_slots`, all `SECURITY DEFINER` and granted to `anon, authenticated`.
- **`otp_challenges`** — written and read only by the `otp-request` and
  `otp-verify` edge functions using the service role key, which bypasses RLS.
  A browser must never read OTP challenge rows.

RLS on + zero policies = deny-all, which is the *safe* failure direction. The
dangerous state is `rls_on = f`, and no table is in it.

> **If a THIRD table ever appears in this audit, that is a real finding.**
> Investigate it — do not assume it belongs with these two.
>
> Careful with `CREATE OR REPLACE` when checking a function's security context:
> several of these RPCs are redefined across multiple migrations, and only the
> last definition is live. Grepping for the first match reports the wrong answer
> — `claim_slot_hold` looks like `SECURITY INVOKER` in an early migration and is
> `SECURITY DEFINER` in the one that actually applies.

The script refuses to run if `public` already has tables — these migrations are
not idempotent as a set, and replaying them over an existing schema fails
partway and leaves it inconsistent.

**If a migration fails:** it stops and prints the error. The schema is now
partially built. Fix the file, drop and recreate `public`, and start over — do
not try to resume mid-way.

---

## Step 3 — Prove the schema matches Lovable's live one

The risk this catches: **schema changes Lovable made through its UI that never
landed in a migration file.** `src/integrations/supabase/types.ts` is generated
by Lovable *from the live hosted database*, so it is an independent witness.

### Already checked (2026-08-20) — migrations vs. Lovable

Comparing the 43 migration files against `types.ts` found **no drift in either
direction**: 47 tables in both, nothing Lovable has that the migrations lack.
So the migrations are a complete account of the live schema, and Step 2 should
reproduce it exactly.

### Still worth running — VPS vs. Lovable

That earlier check compared *migration files* to Lovable. This one compares what
actually landed **in the VPS database** to Lovable, which also catches a
migration that ran but did less than it appeared to.

Open a tunnel, leave it running in its own terminal:

```bash
ssh -L 55432:127.0.0.1:5432 root@184.168.122.104
```

Get the Postgres password (in another terminal):

```bash
ssh root@184.168.122.104 "grep '^POSTGRES_PASSWORD=' /opt/supabase/stacks/enroll/.env"
```

Generate types from the VPS:

```bash
npx supabase gen types typescript --db-url "postgresql://postgres:PASSWORD@127.0.0.1:55432/postgres" > /tmp/types.vps.ts
```

Compare, column by column, using the fingerprint script:

```bash
diff <(bash schema-fingerprint.sh /tmp/types.vps.ts) <(bash schema-fingerprint.sh src/integrations/supabase/types.ts)
```

**Expect:** no output. Lines prefixed `>` are things Lovable has that the VPS
does not — close those before loading data.

Sanity-check the fingerprint isn't silently matching nothing — expect
`tables: 47   columns: 650   funcs: 21` for the repo's types.ts:

```bash
bash schema-fingerprint.sh src/integrations/supabase/types.ts | awk '{c[$1]++} END {printf "tables: %d   columns: %d   funcs: %d\n", c["table"], c["col"], c["func"]}'
```

> The character classes in that script are `[a-zA-Z0-9_]`, not `[a-zA-Z_]`, on
> purpose. Table names here contain digits — `admin_i18n_templates` — and a
> letters-only class drops it and reports a phantom missing table.

---

## Step 4 — Load the content

Get the VPS secret key:

```bash
ssh root@184.168.122.104 "grep -E '^(SUPABASE_SECRET_KEY|SERVICE_ROLE_KEY)=' /opt/supabase/stacks/enroll/.env"
```

Then from the project root:

```bash
SERVICE_ROLE=<that key> bash import-content.sh ./content-export
```

**Expect:** 22 lines ending `rows OK`, 397 rows total.

Safe to re-run — it upserts on the primary key. Every PK in this schema is
`uuid DEFAULT gen_random_uuid()`, so there are no sequences to reset afterwards.

---

## Step 5 — Edge functions

Copy the functions into the stack. **The `--exclude 'main/'` is essential** —
the stack ships its own router at `volumes/functions/main/index.ts` and
overwriting it breaks dispatch for all 17 functions:

```bash
ssh root@184.168.122.104 "rsync -a --exclude 'main/' /opt/apps/enroll/supabase/functions/ /opt/supabase/stacks/enroll/volumes/functions/"
```

```bash
ssh root@184.168.122.104 "ls /opt/supabase/stacks/enroll/volumes/functions/"
```

**Expect:** the 17 function directories, plus `_shared` and `main`.

### 5a — Secrets

Collect these five from the Lovable project's edge-function secrets:
`LOVABLE_API_KEY`, `LARAVEL_API_BASE_URL`, `LARAVEL_API_KEY`,
`LARAVEL_CLIENT_ID`, `LARAVEL_CLIENT_SECRET`.

> `LARAVEL_API_BASE_URL` defaults to `https://qa.lilbrahmas.org` in code.
> Confirm the **production** value — don't inherit QA by accident.

Append them to `/opt/supabase/stacks/enroll/.env` (keep it mode 600), then merge
the block from `functions-env-snippet.yml` into
`/opt/supabase/stacks/enroll/docker-compose.override.yml` under the existing
`services:` key.

Verify the merge kept the injected vars:

```bash
ssh root@184.168.122.104 "cd /opt/supabase/stacks/enroll && docker compose config | grep -E 'SUPABASE_URL|SERVICE_ROLE_KEY|LOVABLE_API_KEY|LARAVEL_'"
```

**Expect:** both the Supabase-injected vars *and* your five. If the Supabase ones
vanished, you used `!override` on `environment:` — remove it; mappings merge,
lists replace.

Port gate, then start:

```bash
ssh root@184.168.122.104 "cd /opt/supabase/stacks/enroll && test \$(docker compose config | grep -c 'published:') -eq \$(docker compose config | grep -c 'host_ip: 127.0.0.1') && echo 'ALL PORTS LOOPBACK' || echo 'MISMATCH - DO NOT START'"
```

```bash
ssh root@184.168.122.104 "cd /opt/supabase/stacks/enroll && docker compose up -d functions"
```

### 5b — Can a logged-out visitor reach a function?

```bash
curl -s -X POST -H "apikey: PUBLISHABLE_KEY" -H 'Content-Type: application/json' -d '{"phone":"+919999999999","session_id":"probe-12345678"}' https://api.enroll.lilbrahmas.org/functions/v1/otp-request
```

A **401** means `FUNCTIONS_VERIFY_JWT` is rejecting it — set it `false` in `.env`
and restart `functions`. This matters because
`src/integrations/supabase/client.ts` *deletes* the `Authorization` header when
the key is a new-style opaque `sb_publishable_…` key, sending only `apikey`.

### 5c — Does the Lovable AI gateway still answer from off-Lovable?

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer LOVABLE_API_KEY" -H 'Content-Type: application/json' -d '{"model":"google/gemini-2.5-flash","messages":[{"role":"user","content":"ping"}]}' https://ai.gateway.lovable.dev/v1/chat/completions
```

`200` → keep it. `401`/`403` → those 5 AI functions need a direct provider.
The other 12 are unaffected, so this does not block launch.

---

## Step 6 — Frontend

Get the publishable key:

```bash
ssh root@184.168.122.104 "grep '^SUPABASE_PUBLISHABLE_KEY=' /opt/supabase/stacks/enroll/.env"
```

Create `.env.production.local` in the project root (gitignored by the existing
`*.local` rule at `.gitignore:13`, so Lovable never sees it and `git pull` never
clobbers it):

```
VITE_SUPABASE_URL=https://api.enroll.lilbrahmas.org
VITE_SUPABASE_PUBLISHABLE_KEY=<that key>
```

```bash
npm ci && npm run build
```

Confirm the build points at the VPS and **not** at Lovable — expect a hit for
the first, nothing for the second:

```bash
grep -rl "api.enroll.lilbrahmas.org" dist/assets/ | head -1; grep -rl "pcuzksquykmyboxxrawb" dist/assets/ | head -1
```

Upload. The `--exclude` is **not optional**: the API subdomain's docroot lives
*inside* `public_html`, and `--delete` without it destroys that directory:

```bash
rsync -av --delete --exclude 'api.enroll.lilbrahmas.org/' --exclude '.well-known/' --exclude '.htaccess' dist/ root@184.168.122.104:/home/enroll/public_html/
```

Then the two `.htaccess` files, and fix ownership (uploaded as root, must be
owned by the cPanel user):

```bash
scp htaccess-frontend root@184.168.122.104:/home/enroll/public_html/.htaccess
```

```bash
scp htaccess-api root@184.168.122.104:/home/enroll/public_html/api.enroll.lilbrahmas.org/.htaccess
```

```bash
ssh root@184.168.122.104 "chown -R enroll:enroll /home/enroll/public_html && find /home/enroll/public_html -type f -exec chmod 644 {} + && find /home/enroll/public_html -type d -exec chmod 755 {} +"
```

---

## Step 7 — Admin account, then close the door

1. Open `https://enroll.lilbrahmas.org/admin-login`
2. **Sign up** with the admin email. First signup calls
   `public.claim_first_admin()`, which grants `admin` only while `user_roles`
   holds no admin.
3. Confirm `/admin-control` loads.

Then **close registration immediately**. `AdminLogin.tsx` exposes a public
signup form and the stack runs `ENABLE_EMAIL_AUTOCONFIRM=true` — together that
is open registration on a public site:

```bash
ssh root@184.168.122.104 "cd /opt/supabase/stacks/enroll && sed -i 's|^DISABLE_SIGNUP=.*|DISABLE_SIGNUP=true|' .env && grep '^DISABLE_SIGNUP=' .env && docker compose up -d auth"
```

The signup form will now error. That is the intended state.

---

## Step 8 — Verification

ACME on **both** hostnames — this is the check that catches the silent
certificate death 90 days out. Four separate one-liners:

```bash
ssh root@184.168.122.104 "mkdir -p /home/enroll/public_html/.well-known/acme-challenge && echo probe > /home/enroll/public_html/.well-known/acme-challenge/probe && chown -R enroll:enroll /home/enroll/public_html/.well-known"
```

```bash
curl -sL http://enroll.lilbrahmas.org/.well-known/acme-challenge/probe
```

```bash
curl -sL http://api.enroll.lilbrahmas.org/.well-known/acme-challenge/probe
```

**Both must print `probe`.** HTML instead means the SPA rewrite captured it —
fix the exclusions before going further.

```bash
ssh root@184.168.122.104 "rm -f /home/enroll/public_html/.well-known/acme-challenge/probe"
```

Then:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://enroll.lilbrahmas.org/admin-login
```
→ `200` (not 404 — proves SPA routing)

```bash
curl -s -H "apikey: PUBLISHABLE_KEY" https://api.enroll.lilbrahmas.org/auth/v1/health
```

```bash
curl -s -H "apikey: PUBLISHABLE_KEY" "https://api.enroll.lilbrahmas.org/rest/v1/admin_faqs?select=id&limit=1"
```
→ one row (proves PostgREST + RLS + data)

```bash
curl -s -H "apikey: PUBLISHABLE_KEY" "https://api.enroll.lilbrahmas.org/rest/v1/leads?select=id&limit=1"
```
→ `[]` or an error — **never rows.** Rows here means RLS is not protecting leads.

Then the stack and host checks from your existing runbooks: addendum §8 in full,
and adding-instance steps 50–55 (coturn PID unchanged, instance 1 healthy,
relay range still pinned).

### Browser, end to end

1. Home page — courses and pricing populate
2. `/admin-login` → sign in → `/admin-control` loads
3. Lead-gate modal → phone → OTP
4. Coupon validate on a course page
5. Course catalog from Laravel
6. **Console clean.** A CORS error means `SITE_URL` in the stack `.env` is not
   `https://enroll.lilbrahmas.org`.

---

## Before you announce it live

**The OTP gate is currently bypassable with `000000`.** Confirmed, not
theoretical: `admin_lead_gate_settings` has 0 rows, so
`otp-request/index.ts:32-38` falls back to `test_mode: true`,
`dev_bypass_code: "000000"`. And `sendWhatsAppOtp()` is a stub that returns
success without sending anything.

Fixing needs **both**: a `site`-scope settings row with `test_mode = false`,
*and* a real SMS/WhatsApp provider wired in. Setting `test_mode = false` alone
makes the gate impassable rather than open.

See the plan's "Changes you need to make in Lovable" for the other four items.

---

## Every release after this one

Once Step 1 is done, the whole release is one command. The client edits in
Lovable, Lovable pushes to GitHub, then:

```bash
ssh root@184.168.122.104 "deploy-enroll"
```

That pulls, rebuilds the frontend in a container, republishes to `public_html`
with the right ownership, syncs the edge functions, restarts the `functions`
service, and runs the port gate plus four verification checks.

When the pull brings schema changes:

```bash
ssh root@184.168.122.104 "deploy-enroll --with-migrations"
```

Also `--frontend-only`, `--functions-only`, `--skip-pull`.

> **Migrations are opt-in on purpose.** A schema change should be a decision,
> not a side effect of pulling code. If a pull contains new migration files and
> you didn't pass the flag, the script says so loudly and applies nothing.
>
> It tracks what it has run in `/opt/supabase/stacks/enroll/.applied-migrations`
> — one filename per line — so only genuinely new files are applied. If you ever
> apply something by hand, append its filename there or the next run retries it.

The script refuses to continue if the port gate fails, if `main/` is missing
from `volumes/functions`, or if the built bundle still references the Lovable
Cloud project — that last one catches a missing `.env.production.local` before
it reaches users rather than after.

Don't deploy across **00:46 UTC** — cPanel's `upcp --cron` restarts firewalld
and Apache.

**Remember:** content the client edits in the *Lovable preview* goes to the
Lovable Cloud database and will not appear on the live site. Production content
is edited at `https://enroll.lilbrahmas.org/admin-control`.
