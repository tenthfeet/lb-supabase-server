# Changes to make in Lovable — enroll.lilbrahmas VPS migration

Verified against `9cee5917` (2026-08-22).

**Scope of this round:** items 1–3 only. Two further items are deferred by
decision and recorded at the end so they are not lost.

The theme throughout: **no environment-specific value stays hardcoded.** Every
URL that differs between Lovable preview and the VPS comes from `.env`.

---

## 1. Add `VITE_SITE_URL` to `.env`

**File:** `.env`

This is the foundation for items 2 and 3. Add:

```
VITE_SITE_URL="https://enroll.lilbrahmas.org"
```

**No trailing slash** — the templates below append `/` where they need one, and
a double slash in a canonical URL is a different URL to search engines.

> **This must live in the committed `.env`, not only in a local override.**
> Vite leaves the literal text `%VITE_SITE_URL%` in the output HTML when the
> variable is undefined — it warns in the build log but still ships. A canonical
> tag reading `%VITE_SITE_URL%/` in production is worse than the hardcoded value
> it replaced. The committed `.env` guarantees a baseline; the VPS overrides it
> from `.env.production.local`.

---

## 2. `index.html` — drive every environment-specific URL from env

**File:** `index.html`

Vite substitutes `%VITE_*%` placeholders anywhere in `index.html` at build time,
including inside `<script type="application/ld+json">` blocks. No plugin needed.

### 2a. Supabase preconnect — line 18

```html
<!-- was: https://pcuzksquykmyboxxrawb.supabase.co -->
<link rel="preconnect" href="%VITE_SUPABASE_URL%" crossorigin />
```

`VITE_SUPABASE_URL` already exists in `.env`, so this works immediately.

### 2b. Site URL — six occurrences

`https://www.lilbrahmas.com/` is hardcoded at lines **14, 21, 40, 54, 72, 73**.
Replace each with `%VITE_SITE_URL%`:

| Line | What it is | Becomes |
|---|---|---|
| 14 | `<link rel="canonical">` | `href="%VITE_SITE_URL%/"` |
| 21 | `<meta property="og:url">` | `content="%VITE_SITE_URL%/"` |
| 40 | schema.org `"url"` | `"%VITE_SITE_URL%/"` |
| 54 | schema.org `"sameAs"` | `"%VITE_SITE_URL%/"` |
| 72 | schema.org `"url"` | `"%VITE_SITE_URL%/"` |
| 73 | schema.org `"image"` | `"%VITE_SITE_URL%/favicon.ico"` |

> ⚠ **Lines 14 and 21 are a real decision, not a mechanical swap.**
>
> Today the page tells search engines "don't index me, index
> `www.lilbrahmas.com` instead." That directly contradicts
> `scripts/generate-sitemap.ts`, which submits this site's own pages for
> indexing. Both cannot be right.
>
> Setting `VITE_SITE_URL=https://enroll.lilbrahmas.org` makes the site
> self-canonical and consistent with its sitemap — correct if
> `enroll.lilbrahmas.org` is the public production home, which is the plan of
> record. If instead this app is meant to stay out of search as a satellite of
> the main marketing site, then the *sitemap* is the thing that should go, not
> the canonical. Decide which, then apply it consistently.
>
> Line 54 (`sameAs`) is different — it legitimately points at the *organisation's*
> main site. If `www.lilbrahmas.com` is a genuinely separate marketing site,
> leave line 54 hardcoded and change only the other five.

### 2c. Social preview image — lines 83, 84

```html
<meta property="og:image" content="https://pub-bb2e103a32db4e198524a2e9ed8f35b4.r2.dev/…lovable.app-….png">
<meta name="twitter:image" content="…same URL…">
```

**This is a live dependency on Lovable's CDN.** It survives the migration
silently and keeps working right up until that asset expires or is cleaned up —
at which point every WhatsApp, Facebook and X share preview breaks, with nothing
in the app to indicate why.

Fix: download that image, commit it as `public/og-image.png`, and reference it
locally:

```html
<meta property="og:image" content="%VITE_SITE_URL%/og-image.png">
<meta name="twitter:image" content="%VITE_SITE_URL%/og-image.png">
```

Social scrapers require **absolute** URLs here — a relative `/og-image.png` is
ignored by most of them, which is why this uses the variable rather than a plain
path.

---

## 3. Sitemap: hardcoded URL, and a generated file tracked in git

**Files:** `scripts/generate-sitemap.ts`, `.gitignore`, `public/sitemap.xml`

### 3a. Make the URL configurable

Currently pinned to the old preview domain, so every build writes that into
`public/sitemap.xml` and production would advertise the Lovable URL to search
engines:

```ts
const BASE_URL = "https://lil-brahmas-pathfinder.lovable.app";
```

Replace with:

```ts
import { writeFileSync } from "fs";
import { resolve } from "path";
import { loadEnv } from "vite";

// This script runs under Node via tsx (the predev/prebuild hooks), NOT through
// Vite — so `import.meta.env` does not exist here and reading it yields
// undefined. loadEnv reads the same .env chain Vite itself uses, with the same
// precedence (.env -> .env.production -> .env.production.local), and adds no
// dependency: vite is already in devDependencies.
const env = loadEnv("production", process.cwd());
const BASE_URL = env.VITE_SITE_URL || "https://enroll.lilbrahmas.org";
```

Two details that matter:

- **`||`, not `??`.** `loadEnv` returns `""` for a variable that is present but
  empty. `??` passes an empty string through and emits `<loc></loc>`.
- **Mode is fixed to `"production"`.** A sitemap only ever describes the public
  site, so there is no dev variant worth generating.

### 3b. Stop tracking the generated file

Add to `.gitignore`:

```
# generated by scripts/generate-sitemap.ts on predev/prebuild
public/sitemap.xml
```

> **`.gitignore` alone will not work here.** Git ignores only *untracked* files.
> `public/sitemap.xml` is already in the index, so it stays tracked and keeps
> showing as modified after every build.
>
> **The file must also be deleted from the repo** in the same change. Once it is
> out of the index, `.gitignore` stops it returning, and the build regenerates
> it locally as an untracked file.

---

## Deferred — agreed to skip in this round

Recorded so they are not lost. Neither blocks the VPS migration; both matter
before the site is public.

### D1. OTP verification is bypassable with `000000`

**File:** `supabase/functions/otp-request/index.ts`

`sendWhatsAppOtp()` (line ~44) returns `{ ok: true, channel: "stub" }` without
sending anything, and `resolveSettings()` (lines 32–38) falls back to
`test_mode: true`, `dev_bypass_code: "000000"` whenever no settings row matches.

`admin_lead_gate_settings` currently holds **0 rows**, so that fallback is what
runs. Anyone can pass the lead gate by typing `000000`.

**Deferred because the OTP module is not finished.** That is reasonable — but
the moment the lead gate is shown to real visitors, this is an open door. Two
things are then needed together: a `site`-scope row with `test_mode = false`,
**and** a real provider wired in. Doing only the first makes the gate
impassable rather than safe.

Worth doing cheaply whenever the module is picked up: change the fallback itself
to `test_mode: false` so a missing settings row can never silently reopen this.

### D2. Admin-only edge functions don't verify the caller

**Files:** `ai-translate`, `translate-templates`, `video-transcribe`,
`diagram-refresh`

None read the `Authorization` header or check a role, and all four spend AI
credits per call. Self-hosted, they are reachable without authentication, so
anyone who learns a URL can run up the bill.

Low risk while the site is unlaunched; real once it is public. The guard is
short — `public.is_admin()` already exists, is `SECURITY DEFINER`, and resolves
`auth.uid()`:

```ts
const authHeader = req.headers.get("Authorization");
if (!authHeader) return new Response(JSON.stringify({ error: "unauthorized" }), {
  status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });

const caller = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_ANON_KEY")!,
  { global: { headers: { Authorization: authHeader } } },
);

const { data: isAdmin, error } = await caller.rpc("is_admin");
if (error || !isAdmin) return new Response(JSON.stringify({ error: "forbidden" }), {
  status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
```

> `faq-assistant` is deliberately **not** in this list. It is called from
> `AiFaqAssistant.tsx` by ordinary site visitors, so an `is_admin()` guard would
> break the public FAQ. It needs rate limiting or a per-session cap instead.

---

## Note on the deploy pipeline

Item 3b interacts with the server-side deploy script. Until `public/sitemap.xml`
is untracked, every build dirties the checkout, and `deploy-enroll` refuses to
run on a dirty tree.

`deploy.sh` already handles this — it restores known-generated tracked files
before the check. Once 3b lands, that restore matches nothing and becomes a
no-op. No follow-up change is needed on the server either way.
