# Migration Record — enroll.lilbrahmas.org onto the VPS

**Completed:** 22 August 2026
**Server:** `184.168.122.104` · AlmaLinux 9.8 · WHM/cPanel · EasyApache 4
**Live at:** https://enroll.lilbrahmas.org · **API:** https://api.enroll.lilbrahmas.org
**Repo HEAD at completion:** `32831837`

Companion documents:

- `OPERATIONS.md` — day-to-day: secrets, deploys, migrations, rollback
- `LAUNCH-CHECKLIST.md` — what is deliberately deferred, and why none of it fails visibly
- `LOVABLE-CHANGES.md` — changes made, and still pending, in Lovable

Server-level runbooks (Docker, coturn, firewall, Apache) live separately in
`Downloads/` and remain the authority on the box itself. This document covers
only moving *this application* onto it.

---

## 1. What this migration was

The app was built by the client in Lovable and ran entirely on Lovable Cloud: a
hosted Supabase project (`pcuzksquykmyboxxrawb`) plus a Lovable-hosted frontend.

It now runs on our own VPS against self-hosted Supabase, while **the client
continues editing code in Lovable**.

### The topology decision

**VPS is production. Lovable Cloud is the dev environment. Lovable is for code only.**

The consequence, which needs repeating to the client periodically:

> Content edited inside the Lovable preview goes to the *Lovable Cloud* database
> and **will not appear on the live site.** Production content is edited at
> https://enroll.lilbrahmas.org/admin-control.

The release flow is: client edits in Lovable → Lovable pushes to GitHub → we run
`deploy-enroll` on the VPS.

Two alternatives were rejected. Repointing Lovable's frontend at the VPS would
give a single database but break Lovable Cloud's backend UI, turning every schema
change into hand-written SQL. Running prod and staging as two VPS instances was
more control than the project needs today.

---

## 2. Where everything lives

| Path | What |
|---|---|
| `/opt/apps/enroll` | Git clone of the app. Build workspace. **Never edit here.** |
| `/opt/apps/kit/` | Helper scripts staged on the server (`apply-migrations.sh`, `htaccess-*`) |
| `/usr/local/sbin/deploy-enroll` | The deploy script. On root's PATH. |
| `/opt/supabase/stacks/enroll/` | The Supabase stack (instance 1 — ports 8000 / 5432 / 6543) |
| `/opt/supabase/stacks/enroll/.env` | **All stack secrets.** Mode 600. |
| `…/docker-compose.override.yml` | Port bindings and edge-function env wiring |
| `…/volumes/functions/` | Edge function source (bind mount) |
| `…/.applied-migrations` | Migration ledger, one filename per line |
| `/opt/apps/enroll/.env.production.local` | Build-time frontend vars. Gitignored. Mode 600. |
| `/home/enroll/public_html/` | Served frontend (owned by cPanel user `enroll`) |
| `…/public_html/api.enroll.lilbrahmas.org/` | API vhost docroot — **inside** the frontend docroot |
| `/root/.ssh/enroll_deploy` | Read-only GitHub deploy key |
| `/root/.ssh/config` | Per-app ssh aliases (`github-enroll`, `github-growth`). Mode 600. |

Backups taken during this work: `/root/htaccess-enroll.backup`,
`/root/override.yml.backup`.

### Why the repo is at `/opt/apps/enroll` and not in `/home`

Two hard constraints and one convention.

**Not `/home/enroll`** — cPanel's backup process sweeps the cPanel user's home
directory and it counts against quota. A checkout plus `node_modules` is
500 MB–1 GB and churns on every build. The Supabase stack was kept out of `/home`
for the same reason (deployment runbook §4.1).

**Not inside `/opt/supabase/stacks/enroll/`** — that directory *is* the stack,
and the adding-instance runbook creates instance 2 by `rsync`-ing the whole tree.
App source living there would be copied into every new instance.

**`/opt/apps/` over `/opt/deploy/` or `/opt/repos/`** is convention: FHS puts
add-on software in `/opt`, it matches the existing `/opt/supabase`, and the
directory is source *plus* build workspace — `node_modules` and `dist` sit oddly
in something called "repos".

Because it is outside `/home`, the repo is **not** in cPanel's backups — and does
not need to be, since GitHub is the source of truth. The Postgres data directory
is the opposite case: nothing backs it up and no remote holds a copy.

---

## 3. Access model — read this before touching the server

**Root SSH is disabled** (`PermitRootLogin no`). This is deliberate cPanel
posture and was not changed.

Consequences that cost time to discover:

- `ssh root@…` and `scp … root@…` will **always** fail, regardless of keys.
  Public-key auth is enabled and a valid key is installed; root simply is not
  permitted in by any method. The symptom is a password prompt that can never
  succeed.
- Server work is done through **WHM's browser Terminal**.
- File transfer uses **cPanel File Manager**: upload to `/home/enroll/` (the
  account home, *not* `public_html`, which is web-served), then `install` into
  place as root and delete the upload.

An scp path exists if File Manager becomes tedious: `turnlilbrahmas` is in the
`wheel` group with `/bin/bash` and `%wheel ALL=(ALL) ALL`, and sshd has no
`AllowUsers` restriction. Add the workstation public key to
`/home/turnlilbrahmas/.ssh/authorized_keys`, scp there, then `install` as root
from WHM Terminal.

> **Cleanup owed:** `/root/.ssh/authorized_keys` holds two keys, both labelled
> `tenthfeet-windows`. Only `SHA256:N4zEihu…` has a matching private key; the
> other is stale. Both are inert while root login is disabled, but an
> unaccountable key in root's file is unpleasant to find later.

**The terminal drops multi-line pastes.** Every command in these documents is a
single line for that reason. Where a multi-line file is needed, it is produced by
one `printf` containing `\n`, or transferred as a file.

Windows-side work uses **Git Bash**, not cmder/CMD — `~`, `$(…)`, `&&` chains and
`grep -oE` all behave differently there.

---

## 4. How each step was done

### 4.1 Git onto the server

A **read-only GitHub deploy key**, generated on the server:

```bash
ssh-keygen -t ed25519 -C 'enroll-vps-deploy' -f /root/.ssh/enroll_deploy -N ""
```

The public half was added at **repo → Settings → Deploy keys**, with *"Allow
write access" left OFF* — read-only is all the server needs, and it means a
compromised VPS cannot push to the repo or rewrite history.

`/root/.ssh/config` (mode 600) scopes it to GitHub:

```
Host github.com
  IdentityFile /root/.ssh/enroll_deploy
  IdentitiesOnly yes
```

Then `git clone git@github.com:lilbrahmas-hue/lil-brahmas-pathfinder-fa3abdd4.git /opt/apps/enroll`.

> **Superseded 12 Sep 2026.** Adding the `growth` app replaced this block with
> one alias per app — enroll now reaches GitHub as `github-enroll`, and the
> checkout's remote was repointed to match. A deploy key is registered against
> one repository, so a second app cannot reuse this key, and a second
> `IdentityFile` under one `github.com` block makes ssh offer the wrong one.
> The block above is what was configured in August and stays as the record;
> current procedure is in `OPERATIONS.md` §0.

> **The repo moved on 12 Sep 2026.** Lovable hit sync trouble with `fa3abdd4`
> and re-created the same project as
> `librahmas-hue/lil-brahmas-pathfinder-67845d9c`. The history came across
> intact, so the checkout was repointed with `git remote set-url` rather than
> re-cloned, and the deploy key was moved between repos — a key can only be
> registered on one. The URL above is what was actually run in August and stays
> as the record. Note the account also reads `librahmas-hue` now;
> `lilbrahmas-hue` resolves only because GitHub redirects the former name.
> Current procedure is in `OPERATIONS.md` §6.

> The clone is **538 MB**, but not for the reason it first appears. Ten videos
> (349 MB) were deleted from `public/videos/` in commit `ba9a1890` and are **not
> present at HEAD** — they remain reachable in history, and git clones all of it.
> The result is 575 MB of `.git` against a 311 MB working tree.
>
> `git rev-list --objects --all` walks every commit ever made, so it reports
> those blobs as present. **`git ls-files` is the check that reflects HEAD.**
> Confusing the two led to an incorrect assumption that the videos shipped with
> the app; see §5 and `OPERATIONS.md` §3b.
>
> `git clone --filter=blob:none` — which deployment runbook §4.1 already uses for
> the Supabase repo — fetches blobs on demand and would roughly halve this.

**cPanel's own Git Version Control was rejected.** Its `.cpanel.yml` tasks run as
the cPanel user, which cannot write to `/opt/supabase/…/volumes/functions/`
(root-owned) or run `docker compose`. It covers the frontend only, would put the
repo inside `/home/enroll`, and does not auto-sync anyway — there is no webhook
receiver, so it is two clicks in the UI.

### 4.2 Schema — 43 migrations

Applied by `/opt/apps/kit/apply-migrations.sh`, which:

- refuses to run if `public` already has tables. These migrations are **not
  idempotent as a set**; replaying them over an existing schema fails partway and
  leaves it inconsistent.
- runs each file with `ON_ERROR_STOP=1`, stopping at the first failure
- writes `.applied-migrations` as it goes, so `deploy-enroll --with-migrations`
  later applies only genuinely new files

Result: **43 applied, 47 tables.**

### 4.3 Proving the schema matched Lovable

The risk was schema changes made through Lovable's UI that never landed in a
migration file. `src/integrations/supabase/types.ts` is generated by Lovable
*from its live database*, so it is an independent witness.

Both sides were reduced to a sorted `table.column` list and checksummed:

```
Lovable (from types.ts via schema-fingerprint.sh):  650 columns  md5 db8438f97181afe4a0661110aae3800d
VPS (from pg_attribute):                            650 columns  md5 db8438f97181afe4a0661110aae3800d
```

Identical. `LC_ALL=C` is pinned on both sides — Postgres `ORDER BY` and shell
`sort` use different collations and will otherwise produce a false mismatch.

This replaced the originally planned `supabase gen types` over an SSH tunnel,
which is impossible here: root SSH is disabled and the server has no Node.

### 4.4 Content — 397 rows

**Route C** was used: the publishable key alone. Migration `20260630090539`
grants `public can SELECT` on every `admin_*` table, so all site content is
readable with the key already committed in `.env` — no service-role key or
database password needed from Lovable.

Exported to JSON with `export-content.sh`, imported over PostgREST with
`import-content.sh`. **22 tables, 397 rows**, verified afterwards through the
public API.

What Route C **cannot** reach: `leads`, `enrollments`, `coupons`,
`coupon_configs`, `xsell_mappings`, and the operational tables. Most start empty
legitimately. `coupon_configs` and `xsell_mappings` are admin-editable
configuration and remain an open gap — `LAUNCH-CHECKLIST.md` item 5.

### 4.5 Edge functions — 17

`rsync -a --delete --exclude 'main/'` from the repo into `volumes/functions/`.
That directory is a **bind mount**, so new code is picked up without recreating
the container.

> **`--exclude 'main/'` is essential.** The stack ships its own dispatch router at
> `volumes/functions/main/index.ts`. Overwriting it breaks all 17 functions at once.

`_shared/` copies across as an ordinary directory; the relative import
`../_shared/phoneValidation.ts` resolves because the whole tree is mounted.

A single `otp-request` call returning its own zod validation error — rather than a
boot failure — proved four things at once: gateway routing, that an anonymous
`apikey`-only call is not blocked, that `npm:` specifiers resolve inside the edge
runtime, and that `_shared` imports load.

### 4.6 Frontend

Built **on the server, inside `node:22-alpine`**, because the box has no Node and
installing `ea-nodejs` would add a package for cPanel's nightly updater to break.
`package-lock.json` carries `@swc/core-linux-x64-musl` and
`@rollup/rollup-linux-x64-musl`, so an Alpine build is sound.

`npm ci` uses a named volume (`enroll_npm_cache`), so repeat builds are fast —
the first deploy took minutes, subsequent builds ~40 s.

Published with `rsync -a --delete` into `/home/enroll/public_html`, then
`chown -R enroll:enroll`.

> **The `--exclude` entries are not optional.** `api.enroll.lilbrahmas.org`'s
> docroot lives *inside* `public_html`. A `--delete` sync without excluding it
> destroys the API vhost's docroot and its ACME challenge path.

### 4.7 `.htaccess` — SPA routing without breaking AutoSSL

A cPanel-generated `.htaccess` already existed (MultiPHP INI directives and the
PHP handler, both marked *"do not edit"*). Our rules were **appended**, not
substituted, after a backup to `/root/htaccess-enroll.backup`.

The rewrite carries two exclusions that look redundant and are not:

```apache
RewriteRule ^\.well-known/ - [L]
RewriteRule ^api\.enroll\.lilbrahmas\.org/ - [L]
```

cPanel applies a parent `.htaccess` to nested subdomain docroots. Without these,
the SPA catch-all swallows Let's Encrypt's validation fetch for **both**
hostnames, AutoSSL fails, and the certificates expire ~90 days later with no
warning — the same silent-delayed-total shape as the coturn certificate incident.

A second `.htaccess` containing only `RewriteEngine Off` sits in the API docroot
as belt and braces.

Caching: hashed assets `immutable` for a year; `index.html` `no-cache`; video
`max-age=604800` — deliberately *not* immutable, because files in `public/` are
copied through without a content hash, so the filename does not change when the
file does.

**Verified** by placing probe files with distinct contents in each docroot and
fetching both over plain HTTP from outside the network. `probe-frontend` and
`probe-api` each returned 200 with the correct body — proving each vhost serves
its own docroot, the SPA rewrite excludes `/.well-known/`, and
`ProxyPass /.well-known/ !` keeps Envoy out of the way.

### 4.8 Admin bootstrap

`ENABLE_EMAIL_AUTOCONFIRM=true`, and `SMTP_HOST` names a service that does not
exist — so signup works but **password reset cannot**.

Sign up at `/admin-login` → sign in → click the amber **claim admin** button.
Signup alone does not grant admin: `claim_first_admin()` is a separate explicit
RPC that succeeds only while `user_roles` holds no admin.

Then `DISABLE_SIGNUP=true` immediately — that page exposes a public signup form
on a live site.

---

## 5. Things that cost time — read before repeating this

**The migrations seed rows.** Six tables (`admin_pricing_plans`,
`admin_contact_info`, `admin_i18n_templates`, `admin_coupon_settings`,
`price_list_periods`, `price_courses`) are populated by migration `INSERT`s with
**different UUIDs** from the source database. A PostgREST upsert with
`Prefer: resolution=merge-duplicates` resolves on the *primary key*, so it never
matches those rows and instead collides on the natural unique key with a 23505.
Fix: `TRUNCATE … CASCADE` the content tables, then insert the source rows
verbatim, IDs included — other tables reference them by UUID, so upserting on the
natural key would leave silently broken relationships.

**Import order must follow the FK graph.** Derive it from the database, not from
intuition:

```sql
SELECT c.conrelid::regclass AS child, c.confrelid::regclass AS parent
FROM pg_constraint c JOIN pg_namespace n ON n.oid=c.connamespace
WHERE c.contype='f' AND n.nspname='public' ORDER BY 2,1;
```

For this app the only dependencies are
`admin_course_categories → admin_courses → admin_course_levels` and
`price_courses` / `price_list_periods → price_slabs`.

**`CREATE OR REPLACE` means the last definition wins.** Grepping migrations for a
function's security context finds the *first* match and can be flatly wrong:
`claim_slot_hold` reads `SECURITY INVOKER` in an early migration and
`SECURITY DEFINER` in the one that actually applies. Ask the database.

**The RLS audit's pass condition here is two rows, not zero.** `otp_challenges`
and `slot_holds` have RLS on with no policies **by design** — both are reached
only via service-role or `SECURITY DEFINER` RPCs, and deny-all is the safe
direction. A *third* table appearing is a real finding.

**Table names can contain digits.** `admin_i18n_templates` broke a `[a-zA-Z_]+`
regex and produced a phantom missing-table report. Use `[a-zA-Z0-9_]`.

**The build regenerates a tracked file.** `public/sitemap.xml` was committed and
rewritten by every `prebuild`, so a clean-tree guard trips on the previous
deploy's own output. Fixed at source (gitignored *and* deleted in Lovable) and
defensively in `deploy.sh`, which restores known-generated tracked files before
checking.

> Adding a file to `.gitignore` does **not** untrack it. It must also be deleted
> from the repo in the same change.

**`node:22-alpine` was not on the box**, despite the runbook implying the
key-generation scripts leave it behind. `deploy.sh` now pulls on demand.

**Assets can live outside the repo.** Ten videos (349 MB) were deleted from
`public/videos/` in commit `ba9a1890` and replaced with `.asset.json` manifests
pointing at root-relative Lovable CDN paths. Unmirrored, those requests hit the
SPA rewrite and return `index.html` with HTTP 200 — the player fails silently.
Fixed by mirroring Lovable's path structure under the docroot, which needs no
code change. **Check `git ls-files '*.mp4'`, not git history:** `git rev-list
--objects --all` finds blobs from deleted files and will tell you the assets are
present when they are not at HEAD.

**A clone carries deleted files.** This repo is 575 MB of `.git` against a
311 MB working tree, because those removed videos remain reachable in history.
`git clone --filter=blob:none` — which the deployment runbook §4.1 already uses
for the Supabase repo — fetches blobs on demand and would have roughly halved it.

**Key formats differ.** This stack issues both styles:
`SUPABASE_PUBLISHABLE_KEY=sb_publishable_…` and `SUPABASE_SECRET_KEY=sb_secret_…`
(new, opaque) alongside legacy `ANON_KEY` / `SERVICE_ROLE_KEY=eyJ…` (JWTs).
`src/integrations/supabase/client.ts` **strips the `Authorization` header** for
opaque keys and sends `apikey` only. Scripts talking to PostgREST must do the
same — sending an opaque key as a Bearer token is invalid, since it is not a JWT.

**`LARAVEL_API_KEY` turned out to be unnecessary.** Its only consumer,
`laravel-catalog`, is reached through `src/lib/catalogApi.ts`, which nothing in
`src/` imports. The live enrollment flow uses `laravel-api` with OAuth client
credentials. Check what is actually wired before hunting for a credential.

---

## 6. Doing this again for another Lovable app

The generalisable recipe, in order. Most of the work is verification, not
configuration.

1. **Provision the stack** per the adding-instance runbook — ports
   `8000+10(N-1)` / `5432+10(N-1)` / `6543+10(N-1)`, DNS at GoDaddy, a cPanel
   subdomain with its own docroot, and an Apache vhost include carrying the
   `/.well-known/` exclusion.
2. **Find the data route.** Try direct Postgres, then the service-role key, then
   the publishable key. Route C works for any table `anon` can SELECT — for a
   Lovable app with a public-read content model, that is usually all the content.
   Record row counts per table; that list *is* the migration scope.
3. **Deploy key + clone to `/opt/apps/<name>`.** Read-only key.
4. **Replay migrations** with `ON_ERROR_STOP=1`, one file at a time, writing a
   ledger, refusing to run against a non-empty `public`.
5. **Checksum the schema** against the repo's generated `types.ts` *before*
   loading data. Cheapest possible check for UI-made schema drift, and it needs
   no server tooling.
6. **Derive the FK graph from the database**, truncate target tables with
   `CASCADE`, then import parents-first with IDs preserved.
7. **Copy functions excluding `main/`**; wire non-Supabase secrets into the
   `functions.environment` mapping in the override file.
8. **Build on the server in a Node container**; publish with `--delete` plus
   exclusions for any nested docroot and `.htaccess`.
9. **Append** SPA rules to the existing `.htaccess`; exclude `/.well-known/` and
   any nested docroot; verify ACME on **every** hostname with distinct probe
   bodies, from outside the network.
10. **Bootstrap the admin, then close signup.**
11. **Verify from outside** using the publishable key lifted from the deployed
    bundle: content tables return rows, protected tables return `[]`.

### Checks worth carrying into any future run

- The **port gate** before every `docker compose up` — published count must equal
  loopback count, or something is exposed to the internet
- The **RLS audit** after every migration, with known-good exceptions written down
- A grep of the built bundle for the **old project ref** — catches a wrong or
  missing `.env.production.local` before users see it
- A grep of the built HTML for surviving **`%VITE_` placeholders** — Vite only
  warns about an undefined variable and still ships the literal text
- The **ACME probe on every hostname**, from outside, with distinct bodies
