# Operations — enroll.lilbrahmas.org

Day-to-day running of the app on the VPS: deploying changes, managing secrets,
applying schema updates, rolling back, and diagnosing failures.

**Server:** `184.168.122.104` · **Live:** https://enroll.lilbrahmas.org
**API:** https://api.enroll.lilbrahmas.org
**Upstream:** `librahmas-hue/lil-brahmas-pathfinder-67845d9c`, branch `main`

Background on how it was built: `MIGRATION-RECORD.md`.
Outstanding items: `LAUNCH-CHECKLIST.md`.

---

## 0. How to reach the server

**Root SSH is disabled.** `ssh root@…` and `scp … root@…` will always fail — a
password prompt that can never succeed. This is deliberate and was not changed.

- **Run commands:** WHM → **Terminal** (browser-based, root shell)
- **Transfer files:** cPanel File Manager → upload to `/home/enroll/`, then
  `install` into place as root and delete the upload
- **Never upload to `public_html`** — it is web-served, so a script there is
  downloadable by anyone who guesses the name

**Every command below is a single line.** The terminal silently drops multi-line
pastes; this is not a formatting preference.

Windows-side commands assume **Git Bash**, not cmder/CMD.

### How the server reaches GitHub

Every app on this box has its own read-only deploy key **and its own ssh alias**.
Enroll's, in `/root/.ssh/config` (mode 600):

```
Host github-enroll
  HostName github.com
  User git
  IdentityFile /root/.ssh/enroll_deploy
  IdentitiesOnly yes
```

So the checkout's remote reads `git@github-enroll:…`, never `git@github.com:…`.

**There is deliberately no plain `Host github.com` block.** A GitHub deploy key
is registered against a single repository, so two apps cannot share one — and
two `IdentityFile` lines under one `github.com` block make ssh offer whichever
matches first. GitHub authenticates the connection, then refuses the repository
with `Repository not found`, which reads like a typo in the URL and is not one.
Keeping the bare block out means anything still naming `github.com` fails
immediately rather than silently borrowing another app's key.

To check a key, ask GitHub which repo it is bound to:

```bash
ssh -T git@github-enroll
```

Expect `Hi librahmas-hue/lil-brahmas-pathfinder-67845d9c! You've successfully
authenticated, but GitHub does not provide shell access.` The second half is not
an error — GitHub gives nobody shell access. **This command exits `1` even on
success**, so read the message, not the status. A person's username in place of
`owner/repo` means the key was added to their account rather than as a deploy
key, and the server now has everything they can reach.

Adding an app means a new keypair, a new alias block, and a clone through the
alias. `deploy.sh` needs no change — it runs `git pull` against whatever address
the clone was made with.

---

## 1. Deploying a change

The client edits in Lovable, Lovable pushes to GitHub, you deploy.

```bash
deploy-enroll
```

That is the whole release. In order it: refuses to run on a dirty checkout,
pulls, says what the database is still missing, syncs the 21 edge functions,
runs the port gate, restarts `functions` **only if their code changed**, builds
the frontend with bun inside
`oven/bun:1-alpine`, verifies the output, publishes to `public_html` with
correct ownership, mirrors the videos, and runs four end-state checks.

The build image is bun, not Node: this server has no Node, and the lockfile
Lovable keeps current is `bun.lock`. `deploy.sh` explains why at length.

### Flags

| Flag | Effect |
|---|---|
| *(none)* | Frontend + edge functions |
| `--with-migrations` | Also applies new migration files |
| `--frontend-only` | Skips edge functions |
| `--functions-only` | Skips the frontend build |
| `--skip-pull` | Deploy what is already checked out |
| `--migrations-only` | Schema only. Nothing is built or published |
| `--list-migrations` | Prints what `--with-migrations` would run. Changes nothing |
| `--baseline-migrations` | Records every migration as applied **without running any**. Only for adopting a schema that has no record at all |
| `--mark-applied=<file>` | Records one migration as applied without running it, for one you ran by hand |
| `--skip-backup` | Skips the pre-migration dump. Only when you just took one by hand |

The last four never pull — they answer a question about the database as it
stands, and moving the checkout underneath the answer would change the
question.

### What it prints, and what to look for

```
=== Pulling latest ===       old → new SHA, plus the commit list
=== Pending migrations ===   only when the schema is behind and you did not ask
=== Edge functions ===       directory count, port gate, and whether anything changed
=== Frontend build ===       bun install --frozen-lockfile, sitemap, vite build
=== Publishing ===           rsync to public_html
=== Video assets ===         downloads only what is missing; usually silent
=== Verification ===         four checks, all must be as noted below
=== Done ===                 the commit that was deployed
```

With `--with-migrations` three more appear, after the pull: `=== Migrations ===`,
`=== PostgREST schema cache ===` and `=== RLS audit ===`.

The edge-function count is derived from the repo, not hardcoded — it prints
`expect <n>: <n-2> functions + _shared + main`, and **stops the deploy** if the
directories in `volumes/functions` do not match. A mismatch means the rsync did
not land, which used to show up later as one function 404ing.

```
frontend deep link      : 200   (expect 200)
auth health             : 401   (expected — Envoy requires an apikey)
unhealthy containers    : 0     (expect 0)
exposed supabase ports  : 0     (expect 0 — non-zero aborts)
```

`auth health : 401` is **correct**, not a failure. Envoy rejects unauthenticated
requests; a proxy failure would be 502 or 503.

### Guards that will stop a deploy

These exist because each one previously shipped, or nearly shipped, a broken
state:

- **Dirty checkout.** `/opt/apps/enroll` is a deployment checkout, not a place to
  edit. `git pull --ff-only` does *not* fail when a locally modified file is
  untouched by incoming commits — the edit survives and deploys silently,
  forever. To discard: `git -C /opt/apps/enroll checkout -- .`
- **Port gate mismatch.** Published ports must all bind `127.0.0.1`. Docker
  publishes through `nat/PREROUTING`, which runs *before* firewalld — a container
  on `0.0.0.0:5432` is reachable from the internet with no firewall rule allowing
  it.
- **`main/` missing** from `volumes/functions` — the stack's dispatch router.
- **Build still references the Lovable project.** Means `.env.production.local`
  is wrong or missing; the live site would talk to the dev database.
- **Surviving `%VITE_` placeholders** in the built HTML. Vite only *warns* about
  an undefined variable and ships the literal text — a canonical tag reading
  `%VITE_SITE_URL%/` is worse than the hardcoded value it replaced.

### After deploying

Hard-refresh the site. `index.html` is served `no-cache` and assets are
content-hashed, so a normal reload is enough for users — but your own browser may
hold an old service worker or memory cache.

Avoid deploying across **00:46 UTC**: cPanel's `upcp --cron` restarts firewalld
and Apache around then.

---

## 2. Secrets

### Where they live, and why two places

**Values** go in `/opt/supabase/stacks/enroll/.env` (mode 600).

**Wiring** goes in `/opt/supabase/stacks/enroll/docker-compose.override.yml`,
under `functions:` → `environment:`.

Both are needed. The stock compose file passes only the `SUPABASE_*` variables
into the `functions` container. Anything else in `.env` is invisible to your
function code unless it is declared — so `.env` alone looks correct while
`Deno.env.get("YOUR_KEY")` returns `undefined`.

> **There is no secrets dashboard.** Supabase's Dashboard → Edge Functions →
> Secrets, and `supabase secrets set`, belong to their hosted *platform* layer,
> which the self-host bundle does not include. Likewise
> `supabase functions deploy` — it has no control plane to talk to here. Docker
> Compose is the mechanism.

### Adding a secret

**Step 1 — check for a trailing newline.** Without one, `>>` glues your new
variable onto the last existing one and produces a silently corrupt value:

```bash
tail -c1 /opt/supabase/stacks/enroll/.env | od -c | head -1
```

If that does not show `\n`:

```bash
echo >> /opt/supabase/stacks/enroll/.env
```

**Step 2 — append the value.** One line per secret, **single quotes** — secrets
often contain `$`, backticks or `!`, which the shell would otherwise expand
before the value reaches the file:

```bash
echo 'MY_SECRET=value-here' >> /opt/supabase/stacks/enroll/.env
```

**Step 3 — confirm it landed, masked:**

```bash
grep -nE '^(MY_SECRET|LOVABLE_API_KEY|LARAVEL_)' /opt/supabase/stacks/enroll/.env | sed -E 's/=(.{0,6}).*/=\1…/'
```

**Step 4 — wire it in**, if the variable is new. Edit the `functions:` →
`environment:` block in `docker-compose.override.yml` and add
`MY_SECRET: ${MY_SECRET:-}`.

> Use a plain mapping. **Do not add `!override`.** Compose merges mappings but
> *replaces* lists — that tag exists on `ports:` for a reason, and copying the
> habit here wipes the injected `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
> and breaks all 21 functions at once.
>
> The `:-` default means an unset variable substitutes empty instead of warning,
> so a placeholder can be wired before its value exists.

**Step 5 — verify the merge kept the injected variables.** This is the step that
catches a bad edit:

```bash
cd /opt/supabase/stacks/enroll && docker compose config | grep -A 30 '^  functions:' | grep -E 'SUPABASE_URL|SERVICE_ROLE_KEY|JWT_SECRET|LARAVEL_|LOVABLE_|TELECRM_'
```

You must see **both** the `SUPABASE_*` / `JWT_SECRET` entries *and* yours.

**Step 6 — port gate, then restart:**

```bash
cd /opt/supabase/stacks/enroll && test $(docker compose config | grep -c 'published:') -eq $(docker compose config | grep -c 'host_ip: 127.0.0.1') && echo "ALL PORTS LOOPBACK" || echo "MISMATCH - DO NOT START"
```

```bash
cd /opt/supabase/stacks/enroll && docker compose up -d functions
```

A value-only change (`.env` edited, YAML untouched) still needs the restart —
container environment is fixed at creation.

### Currently wired

| Variable | Status | Used by |
|---|---|---|
| `LARAVEL_API_BASE_URL` | set — **points at QA** | `laravel-api`, `laravel-catalog` |
| `LARAVEL_CLIENT_ID` / `_SECRET` | set | `laravel-api` (OAuth) |
| `LARAVEL_WEBHOOK_SECRET` | **outstanding** — hard gate | `laravel-admission-webhook` (HMAC) |
| `LARAVEL_API_KEY` | wired, empty, **not needed** | `laravel-catalog` (dead code) |
| `LOVABLE_API_KEY` | wired, empty — **outstanding** | the 5 AI functions |
| `TELECRM_WEBHOOK_URL` | set 31 Aug 2026 — **gates delivery** | `crm-lead` |
| `TELECRM_ACCESS_TOKEN` | set 31 Aug 2026 | `crm-lead` (Bearer) |

`LARAVEL_WEBHOOK_SECRET` is unlike the other blanks: `laravel-admission-webhook`
answers **500 `Webhook secret not configured`** to every call while it is unset,
rather than degrading quietly. The same value must be set on the API side, where
it is named `PUBLIC_ENROLLMENT_WEBHOOK_SECRET` — Laravel skips the webhook in
silence if its copy is missing, so confirm both ends, not just ours.

`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`,
`SUPABASE_DB_URL` and `JWT_SECRET` are injected by the base compose file. Never
add them to the override.

### Key formats — this matters for any script

The stack issues both styles:

| Variable | Format | How to send it |
|---|---|---|
| `SUPABASE_PUBLISHABLE_KEY` | `sb_publishable_…` opaque | `apikey` header **only** |
| `SUPABASE_SECRET_KEY` | `sb_secret_…` opaque | `apikey` header **only** |
| `ANON_KEY`, `SERVICE_ROLE_KEY` | `eyJ…` legacy JWT | `apikey` + `Authorization: Bearer` |

An opaque key is not a JWT, so sending it as a Bearer token is invalid.
`src/integrations/supabase/client.ts` implements exactly this rule, and
`import-content.sh` mirrors it.

**The publishable key is public by design** — it ships in the JavaScript bundle
every visitor downloads. It is not a secret; RLS is what protects the data. You
can always recover it from the live site:

```bash
curl -s https://enroll.lilbrahmas.org/ | grep -oE '/assets/index-[A-Za-z0-9_-]+\.js' | head -1
```

then grep that file for `sb_publishable_`.

---

## 3. Schema changes

When Lovable adds migration files:

```bash
deploy-enroll --with-migrations
```

**Migrations are opt-in deliberately** — a schema change should be a decision,
not a side effect of pulling code. If a pull brings new migration files without
the flag, the deploy says so loudly and applies nothing.

Applying them is safe to repeat. Deploy ten times in a row and the tenth
applies nothing: what has run is recorded in the database itself, in
`supabase_migrations.schema_migrations` — the same table the Supabase CLI uses —
and each file is applied and recorded **in one transaction**. Either the schema
moved and the ledger says so, or neither happened and the file is still pending.

`/opt/supabase/stacks/enroll/.applied-migrations` is still written, one filename
per line, but it is now only a readable mirror. Nothing decides anything from
it. The ledger belongs in the database because that is the only place it stays
in step with the schema it describes: restore a backup and the record of what
built it is restored at the same instant.

### What happens around an apply

**A dump is taken first.** Immediately before the first migration of a run, and
only when something is actually about to change, the deploy writes
`/opt/backups/enroll/enroll-<timestamp>.dump` (`pg_dump -Fc`, run inside the db
container so the versions always match). It keeps the last 10 and prunes the
rest. If the dump fails, or lands under 1 KB, **nothing is applied** — a backup
you cannot restore is worse than none, because you will act as though you have
one. `--skip-backup` overrides this and says so loudly.

Restore a table out of one with:

```bash
docker compose exec -T db pg_restore -U postgres -d postgres --data-only -t <table> < /opt/backups/enroll/enroll-<stamp>.dump
```

**PostgREST is told about the new schema.** After anything applies, the deploy
sends `NOTIFY pgrst, 'reload schema'`. Without this, a new table exists in psql
and returns `PGRST205 Could not find the table` through the API — the most
confusing state this stack produces, and the reason that line is in the triage
table below.

It restarts the `rest` container **only if it has to**. This stack carries
Supabase's `pgrst_ddl_watch` and `pgrst_drop_watch` event triggers, which NOTIFY
on every DDL command from inside the migration transaction — so the cache is
already current and a restart would be downtime for nothing. The deploy checks
for both triggers and restarts only when one is missing, or when the NOTIFY
itself failed. Check them by hand with:

```bash
cd /opt/supabase/stacks/enroll && docker compose exec -T db psql -U postgres -c "select evtname from pg_event_trigger where evtname like 'pgrst%';"
```

To see what is pending without touching anything:

```bash
deploy-enroll --list-migrations
```

That also reports two things worth knowing: an already-applied file whose
contents have since changed (editing history does not reach a database — it
needs a new migration), and a pending file older than one already applied,
which usually means a rebase.

> If you apply a migration by hand, record it — do not edit the text file:
> ```bash
> deploy-enroll --mark-applied=20260824072043_85b041dc.sql
> ```

### Two situations the deploy will refuse

**A schema with no record at all.** A database that already has tables but no
ledger — rebuilt by hand, restored from somewhere else — stops the deploy. It
will not guess. If the schema is genuinely current, adopt it with
`deploy-enroll --baseline-migrations`, which records every file as applied
without running one of them. If it is not current, restore from backup or
rebuild from empty with `apply-migrations.sh`.

A stack built by `apply-migrations.sh` needs none of this: the first
`--with-migrations` after it imports that script's `.applied-migrations` file
automatically, once, and says so.

**Two files sharing a timestamp prefix.** The ledger keys on that prefix, so one
of them would be skipped in silence. The deploy names both and stops.

### The RLS audit — run after every migration

`--with-migrations` runs it automatically. The **pass condition is three rows**,
verified 25 Aug 2026 after the campaign-analytics migrations landed:

```
 otp_challenges | t | f | 0
 slot_cache     | t | f | 0
 slot_holds     | t | f | 0
```

All three have RLS enabled with zero policies **by design** — each is reached
only through the service role or a `SECURITY DEFINER` RPC, so deny-all is
correct and is the safe failure direction. (`slot_cache` is written and read
solely by the `laravel-api` function using `SERVICE_ROLE_KEY`; the migration
grants it to `service_role` and nobody else.)

**Read the `rls_on` column, not the row count.** A row with `rls_on = f` is the
finding: every new table in `public` is granted full read/write to `anon` by
default, and the publishable key ships in the JavaScript bundle — so a table
with RLS off is world-readable and usually world-writable.

A **fourth** row with `rls_on = t` is a new deny-all table. Confirm it was meant
to be one, then add it to the expected set here and in `deploy.sh`, so the list
stays a real assertion rather than a number people learn to skim past.

Manually:

```bash
cd /opt/supabase/stacks/enroll && docker compose exec -T db psql -U postgres -c "SELECT c.relname, c.relrowsecurity AS rls_on, c.relforcerowsecurity AS rls_forced, count(p.polname) AS policies FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_policy p ON p.polrelid=c.oid WHERE n.nspname='public' AND c.relkind='r' GROUP BY 1,2,3 HAVING NOT c.relrowsecurity OR count(p.polname)=0 ORDER BY 1;"
```

### The GRANT audit — the other half of the same question

RLS decides which **rows** a role may see. GRANTs decide whether it may touch
the table at all, and they fail separately: the table is there, the RLS is
right, and every request still returns `permission denied for table x` or
`PGRST205`. A new table takes its privileges from `ALTER DEFAULT PRIVILEGES`, so
one created by a migration running as the wrong owner arrives with none.

`--with-migrations` runs this too. **Pass condition is 0 rows.** It tests
`service_role`, because every edge function authenticates as it, and a table
must reach it even when `anon` and `authenticated` are deliberately shut out —
`slot_cache` is exactly that case, granted to `service_role` and nobody else.

A row here is fixed with:

```sql
GRANT SELECT ON public.your_table TO service_role;
```

Manually:

```bash
cd /opt/supabase/stacks/enroll && docker compose exec -T db psql -U postgres -c "SELECT c.relname AS tbl, has_table_privilege('anon', c.oid, 'SELECT') AS anon, has_table_privilege('authenticated', c.oid, 'SELECT') AS auth, has_table_privilege('service_role', c.oid, 'SELECT') AS service_role FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind='r' AND NOT has_table_privilege('service_role', c.oid, 'SELECT') ORDER BY 1;"
```

### Pattern for any new table

```sql
ALTER TABLE public.your_table ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.your_table FORCE ROW LEVEL SECURITY;
CREATE POLICY "read own rows" ON public.your_table
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
```

Use `TO authenticated`, never `TO public` — in Postgres, `public` means every
role, including `anon`.

---

## 3b. Video assets

**The video originals are not in the repo.** Commit `ba9a1890` removed all ten
from `public/videos/`; what remains is a manifest per video at
`src/assets/videos/<name>.mp4.asset.json`, whose `url` is a root-relative
Lovable path:

```
/__l5e/assets-v1/<asset_id>/<original_filename>
```

Nothing on this server would serve that path, so the SPA rewrite catches it and
returns `index.html` with **HTTP 200**. The `<video>` element receives HTML and
fails silently — no console error, no broken-media icon, just a player that
never plays.

The fix mirrors Lovable's own path structure under the docroot, so the existing
URLs resolve locally and **no Lovable code change is needed**. 10 files, 349 MB.

`deploy-enroll` runs the sync automatically after publishing. Present files are
skipped on a size check, so it costs nothing after the first run. To run it
alone:

```bash
bash /opt/apps/kit/sync-videos.sh
```

Verify one end to end — `video/mp4` means fixed, `text/html` means still broken:

```bash
curl -sI https://enroll.lilbrahmas.org/__l5e/assets-v1/d7379e44-1a27-4ad8-b210-7e76befea095/handwriting-english.mp4 | head -4
```

> `__l5e/` is excluded from the publish `rsync` for the same reason `.htaccess`
> is: `--delete` would otherwise remove all 349 MB on every deploy.

After the first sync the site does not depend on Lovable for playback. The only
residual dependency is fetching a *newly added* video, which fails loudly in the
deploy log rather than silently in a browser.

**Still Lovable-hosted, and not covered by the sync:**
`src/components/art/WhyChooseSection.tsx:105` hardcodes an HLS stream at
`https://lil-brahmas-future-craft.lovable.app/videos/hls/...` — an absolute URL
to a *different* Lovable project. It works today and will fail the same silent
way if that project is removed.

---

## 4. Health checks

**Everything at once:**

```bash
cd /opt/supabase/stacks/enroll && docker compose ps --format '{{.Service}} {{.Status}}' | grep -vc healthy
```

Expect `0`.

**Nothing exposed** (the check that matters most):

```bash
ss -tln | grep -cE '(0\.0\.0\.0|\*):(8000|5432|6543)'
```

Expect `0`. Non-zero → `cd /opt/supabase/stacks/enroll && docker compose down`
immediately, then fix the override before restarting.

**Frontend and API from outside:**

```bash
for u in / /courses /admin-login; do printf '%-16s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' https://enroll.lilbrahmas.org$u)"; done
```

**Content is being served** (substitute the publishable key):

```bash
curl -s -H "apikey: KEY" -D - -o /dev/null -H 'Range: 0-0' -H 'Prefer: count=exact' "https://api.enroll.lilbrahmas.org/rest/v1/admin_faqs?select=*" | grep -i content-range
```

**Protected data is NOT** — must return `[]`, never rows:

```bash
curl -s -H "apikey: KEY" "https://api.enroll.lilbrahmas.org/rest/v1/leads?select=id&limit=1"
```

**ACME still works** — run after any `.htaccess` or vhost change, and at least
quarterly. Certificates die silently ~90 days after this breaks:

```bash
mkdir -p /home/enroll/public_html/.well-known/acme-challenge /home/enroll/public_html/api.enroll.lilbrahmas.org/.well-known/acme-challenge && echo probe-frontend > /home/enroll/public_html/.well-known/acme-challenge/probe && echo probe-api > /home/enroll/public_html/api.enroll.lilbrahmas.org/.well-known/acme-challenge/probe && chown -R enroll:enroll /home/enroll/public_html/.well-known /home/enroll/public_html/api.enroll.lilbrahmas.org/.well-known
```

```bash
curl -sL http://enroll.lilbrahmas.org/.well-known/acme-challenge/probe; curl -sL http://api.enroll.lilbrahmas.org/.well-known/acme-challenge/probe
```

Must print `probe-frontend` then `probe-api`. Anything else — HTML, a 401, the
wrong body — means the SPA rewrite or Envoy is intercepting, and AutoSSL will
fail at renewal. Then clean up:

```bash
rm -f /home/enroll/public_html/.well-known/acme-challenge/probe /home/enroll/public_html/api.enroll.lilbrahmas.org/.well-known/acme-challenge/probe
```

**Certificate expiry:**

```bash
echo | openssl s_client -servername api.enroll.lilbrahmas.org -connect api.enroll.lilbrahmas.org:443 2>/dev/null | openssl x509 -noout -dates
```

---

## 5. Rollback

| Situation | Action |
|---|---|
| Bad frontend | `git -C /opt/apps/enroll checkout <good-sha>` then `deploy-enroll --skip-pull --frontend-only`. Return to the branch afterwards with `git -C /opt/apps/enroll checkout main`. |
| Bad edge function | Same checkout, then `deploy-enroll --skip-pull --functions-only` |
| Bad `.htaccess` | `cp /root/htaccess-enroll.backup /home/enroll/public_html/.htaccess && chown enroll:enroll /home/enroll/public_html/.htaccess` |
| Bad compose override | `cp /root/override.yml.backup /opt/supabase/stacks/enroll/docker-compose.override.yml` then port gate, then `docker compose up -d` |
| Stack misbehaving | `cd /opt/supabase/stacks/enroll && docker compose restart` |
| Ports exposed | `cd /opt/supabase/stacks/enroll && docker compose down` — **first**, then diagnose |

**A migration that fails is rolled back. One that succeeds is not.** The deploy
wraps each file in a transaction, so a file that errors leaves the database
exactly as it was and stays pending — retry it as often as you like. That is no
help at all against a migration that runs perfectly and drops the wrong column:
these files have no down-step, and recovery is a restore from backup, which is
why backups are the top item in `LAUNCH-CHECKLIST.md`. Read the SQL before
running `--with-migrations` on anything that drops or alters a column.

The exception is a file Postgres refuses to run inside a transaction — one using
`CREATE INDEX CONCURRENTLY`, or `ALTER TYPE ... ADD VALUE`. Those are applied
statement by statement, with no rollback, and the deploy marks them `ok (not
atomic)` so the difference is visible in the log.

---

## 6. Troubleshooting

**`git pull failed`, or `Permission denied (publickey)`** — the checkout is
naming `github.com` rather than its alias. There is no `Host github.com` block on
this server, so ssh has no key to offer and GitHub rejects the connection. Check
what the remote says:

```bash
git -C /opt/apps/enroll remote -v
```

It must begin `git@github-enroll:`. If it begins `git@github.com:`, repoint it —
this swaps only the host part and leaves the repo path alone:

```bash
git -C /opt/apps/enroll remote set-url origin "$(git -C /opt/apps/enroll remote get-url origin | sed 's|git@github\.com:|git@github-enroll:|')"
```

If the remote was already correct, the key is the problem rather than the
address. Use the `ssh -T git@github-enroll` check in §0.

**Deploy refuses: "has uncommitted changes"** — someone edited the checkout.
`git -C /opt/apps/enroll status` to see what, then
`git -C /opt/apps/enroll checkout -- .` to discard. Edits belong in Lovable.

**Deploy refuses: "still references the Lovable Cloud project"** —
`/opt/apps/enroll/.env.production.local` is missing or wrong. It must contain
`VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY` and `VITE_SITE_URL`. It is
gitignored, so a pull never restores it.

**Deploy refuses: "unsubstituted placeholders"** — a `%VITE_X%` in `index.html`
has no matching variable. It must exist in the committed `.env` as a baseline;
`.env.production.local` only overrides.

**Site loads but shows no content** — check the browser console. CORS errors mean
`SITE_URL` in the stack `.env` does not exactly match
`https://enroll.lilbrahmas.org`. Restart `auth` after changing it.

**Deep links 404** — the `.htaccess` in `public_html` lost its SPA rules. cPanel
regenerates its own delimited blocks; if it ever clobbers ours, re-append from
`/opt/apps/kit/htaccess-frontend`.

**An edge function 500s** — check its logs:

```bash
cd /opt/supabase/stacks/enroll && docker compose logs --tail 50 functions
```

A missing environment variable usually surfaces as a boot failure rather than a
handled error, because most functions build their Supabase client at module load.

**A function says credentials are not configured** — the value is in `.env` but
not wired into the override, or the container was not recreated after the change.

**`docker compose` says a variable is not set** — it is referenced in the
override but absent from `.env`. Either add it, or give it a `:-` default.

**"git pull failed" after Lovable moved the project to a new repo** — Lovable
re-creates the project against a fresh GitHub repo when its sync breaks. Nothing
in `deploy.sh` names a repository; the only pointer is the checkout's own remote:

```bash
git -C /opt/apps/enroll remote -v
```

A deploy key can live on only one repository across all of GitHub, so delete the
server key from the **old** repo's Settings → Deploy keys first, then add
`/root/.ssh/enroll_deploy.pub` to the new one with write access OFF. Confirm the
key reaches it before changing anything:

```bash
git -C /opt/apps/enroll ls-remote git@github-enroll:<owner>/<new-repo>.git
```

Then repoint, and prove a fast-forward is possible — `deploy.sh` pulls with
`--ff-only` and will refuse anything else:

```bash
git -C /opt/apps/enroll remote set-url origin git@github-enroll:<owner>/<new-repo>.git
```

```bash
git -C /opt/apps/enroll fetch origin && git -C /opt/apps/enroll merge-base --is-ancestor HEAD origin/main && echo FF-OK || echo NOT-FF
```

`FF-OK` means a normal `deploy-enroll` finishes the job. `NOT-FF` means the new
repo does not share history, and the fix is a fresh clone with
`.env.production.local` carried across — not a merge. That file is gitignored, so
a repoint leaves it untouched either way.

Check whether the incoming commits touch schema before choosing deploy flags:

```bash
git -C /opt/apps/enroll diff --name-only HEAD origin/main -- supabase/migrations supabase/functions
```

---

## 7. Routine maintenance

| Cadence | Task |
|---|---|
| Every deploy | Watch the four verification lines; hard-refresh; smoke-test the enrolment flow |
| After every migration | RLS audit — two rows expected, a third is a finding |
| Monthly | ACME probe on both hostnames; check certificate dates |
| Monthly | `df -h /opt /var/lib/containerd` — **not** `/var/lib/docker`; this Docker uses the containerd image store |
| Quarterly | Review Docker and coturn release notes. Both are version-locked, so **no automatic security updates apply.** |
| Ongoing | Remind the client that content edited in the Lovable preview does not reach the live site |

**Disk:** the repo carries ~230 MB of committed video, `node_modules` adds
~500 MB, and `dist/` duplicates the video again. Budget ~1.5 GB for
`/opt/apps/enroll` alone.

**Container logs** are capped at 30 MB each (`max-size 10m`, `max-file 3`) by
`/etc/docker/daemon.json`. Do not switch the log driver to `journald` on this
box — journald restarting has already killed two services here.
