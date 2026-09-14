# growth.lilbrahmas.org — deploy kit

**Status: git, DNS, cPanel and SSL are done. The Supabase stack is complete: running, isolated from enroll, registered as instance 2, and public at https://api.growth.lilbrahmas.org since 14 Sep 2026. Its database is empty. Serving the app is not designed yet.**

This folder is the deploy kit for the second app on the VPS. It is deliberately
thin right now — most of enroll's documents are records of a migration that has
already happened, and growth's has not. What exists here is what is true.

| File | What |
|---|---|
| `GIT-SETUP.md` | The completed git work: deploy key, ssh alias, clone. Also the template for instance 3. |
| `STACK-PROVISIONING.md` | The Supabase stack work: what is done, the baseline to verify against, and where the runbook diverges for growth. |
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
| ✅ **Supabase stack** | running since ~07:05 UTC 13 Sep 2026 at `/opt/supabase/stacks/growth`: 11/11 healthy, ports 8010 / 5442 / 6553 on loopback only, keys and tokens proven isolated from enroll, enroll and coturn verified undisturbed. Empty database — no migrations applied. Registered as `growth = instance 2` in `/opt/supabase/README.md`. **Public since 14 Sep 2026** at `https://api.growth.lilbrahmas.org` through Apache (runbook §8–§9 verified): GoTrue, WebSocket and the ACME renewal path work through the proxy, Studio asks for its basic-auth login, and enroll and coturn were verified undisturbed |
| 🟡 **`.env.production.local`** | no longer blocked on the stack — growth's publishable key now exists in the stack `.env`. Where the app's runtime variables live is still part of the open serving design |
| ❌ **Serving** | design not started. See *The finding that changed the plan*. |

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

The server needs four variables: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
`SUPABASE_PUBLISHABLE_KEY`, `LOVABLE_API_KEY`.

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

1. **App server port scheme.** Proposed: `3000 + 10(N-1)`, so growth is **3010**.
   This extends a documented convention and needs sign-off. The runbook's own
   rule applies — re-derive and check rather than trusting the formula.
2. **Nitro preset.** Currently Cloudflare by default, and it is not set anywhere
   in the repo — it comes from `@lovable.dev/vite-tanstack-config@2.13.1`.
   Target **`bun`**, not `node-server`: Lovable's toolchain is bun and this
   server has no Node. Whether an env var can override the wrapper, or only
   editing `vite.config.ts` can, is the open part — and it decides whether this
   is maintainable, since Lovable owns that file. **Answerable off the server.**
3. **Where the four environment variables live**, and how the service-role key is
   handled — stack `.env` is mode 600 for this reason. Note these are read from
   `process.env` at runtime, not baked at build time like enroll's `VITE_*`.
4. ~~`pg_cron` / `pg_net`~~ — **resolved, not required.** See above.

---

## Next step

**The Supabase stack is finished as of 14 Sep 2026.** Next comes the serving
design, starting with the open questions above, and after it growth's 226
migrations. Neither has started.

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

## Working notes

Root SSH is disabled — use **WHM → Terminal** for commands and cPanel File
Manager for transfers. **Every command must be a single line**; the terminal
silently drops multi-line pastes. Both rules are the same as enroll's, and both
are load-bearing rather than stylistic.
