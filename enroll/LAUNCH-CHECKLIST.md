# Launch checklist — enroll.lilbrahmas.org

The VPS migration is complete and the site is live at
https://enroll.lilbrahmas.org. Everything below was deferred by decision, not
missed.

**What these items have in common: none of them fail visibly.** The site looks
healthy with every one of them outstanding. That is why they are written down
rather than remembered.

Last updated 2026-08-22, at HEAD `32831837`.

---

## Blockers — before real visitors reach the enrolment flow

### 1. Laravel points at QA, not production

`LARAVEL_API_BASE_URL=https://qa.lilbrahmas.org` in
`/opt/supabase/stacks/enroll/.env`.

Deliberate: QA is the only Laravel environment live as of 2026-08-22, pending a
pilot check. `laravel-api` handles `catalog | slots | reserve | extend |
confirm | release`, so while this stands:

- visitors see QA's catalog and pricing
- slot availability comes from QA
- **`reserve` and `confirm` write real enrolments into QA**, where nobody is
  looking for them

QA answers healthily, so nothing surfaces. To cut over:

```
cd /opt/supabase/stacks/enroll && sed -i 's|^LARAVEL_API_BASE_URL=.*|LARAVEL_API_BASE_URL=https://PROD_HOST|' .env && docker compose up -d functions
```

Then re-run the catalog probe and confirm `branch_id` / course set differ from
QA. **The OAuth credentials may be environment-specific** — if production
rejects the current `LARAVEL_CLIENT_ID` / `LARAVEL_CLIENT_SECRET`, you get
`ok:false` with an upstream 401 and those need swapping too.

### 2. OTP is bypassable with `000000`

`supabase/functions/otp-request/index.ts`. `sendWhatsAppOtp()` returns
`{ok:true, channel:"stub"}` without sending; `resolveSettings()` falls back to
`test_mode:true, dev_bypass_code:"000000"` when no settings row matches — and
`admin_lead_gate_settings` holds **0 rows**, so that fallback always wins.

Deferred because the OTP module is unfinished. Needs **both**:

- a `site`-scope row in `admin_lead_gate_settings` with `test_mode = false`
- a real WhatsApp/SMS provider in `sendWhatsAppOtp()`

Doing only the first makes the gate impassable rather than safe. Worth also
changing the hardcoded fallback to `test_mode: false` so a missing row can
never silently reopen it.

### 3. No Postgres backups

Nothing is configured. There is now real content in this database and no copy
of it anywhere. The migration files rebuild the *schema*; they do not rebuild
397 rows of content, nor anything the client enters from here on.

`pg_dump` via `docker compose exec -T db`, stored **outside `/home`** so cPanel's
backup sweep does not touch it, with a retention policy.

---

## Should do

### 4. `LOVABLE_API_KEY` not set

Five functions are inert: `ai-translate`, `faq-assistant`,
`translate-templates`, `video-transcribe`, `diagram-refresh`. The public AI FAQ
assistant is among them.

The compose wiring is already in place with a `${LOVABLE_API_KEY:-}` default, so
this is one line plus a restart — no YAML edit:

```
echo 'LOVABLE_API_KEY=...' >> /opt/supabase/stacks/enroll/.env && cd /opt/supabase/stacks/enroll && docker compose up -d functions
```

Test whether the key even works off-Lovable before assuming it does:

```
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H "Authorization: Bearer $LOVABLE_API_KEY" -H 'Content-Type: application/json' -d '{"model":"google/gemini-2.5-flash","messages":[{"role":"user","content":"ping"}]}' https://ai.gateway.lovable.dev/v1/chat/completions
```

`401`/`403` means it is bound to Lovable-hosted execution and those five need a
direct provider instead.

### 5. `coupon_configs` and `xsell_mappings` hold migration defaults

Both are admin-editable configuration, and `anon` cannot read them — so the
Route C export could not capture them. The VPS has whatever the migrations
seeded (10 rows and 0 rows), **not** whatever the client has since tuned in
Lovable.

`coupon_configs` drives coupon percentages, validity windows and code prefixes.
If those were adjusted in Lovable's admin panel, this instance is running stale
values and will issue different coupons.

Retrieving them needs Lovable's **service-role** key, then the same
export/import path used for the other 22 tables.

### 6. Admin-only edge functions do not verify the caller

`ai-translate`, `translate-templates`, `video-transcribe`, `diagram-refresh`
read no `Authorization` header and check no role. Self-hosted, they are
reachable without authentication, and all four spend AI credits per call.

Moot while item 4 stands — with no key they fail anyway. Fix before adding the
key. The guard is short; `public.is_admin()` already exists. Full snippet in
`LOVABLE-CHANGES.md` (D2).

`faq-assistant` is deliberately excluded: it is called by ordinary visitors from
`AiFaqAssistant.tsx`, so an admin check would break the public FAQ. It needs
rate limiting instead.

### 7. SMTP unconfigured — password reset cannot work

`SMTP_HOST=supabase-mail` names a service that does not exist in this compose
file. `ENABLE_EMAIL_AUTOCONFIRM=true` covers signup, but reset emails have
nowhere to go.

**Consequence today: if the admin password is lost, recovery means editing
`auth.users` directly.** Keep it somewhere safe until SMTP exists.

### 8. Studio is internet-facing

Reachable at `https://api.enroll.lilbrahmas.org/` behind only
`DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` basic auth. It is a full database
admin surface, and the database now holds real content. An IP allow-list at the
Apache layer is the straightforward fix.

---

## Carried from the server runbooks

Unchanged by this migration, but the database now holds data that did not exist
when they were written.

- **Prometheus alert on `up == 0`.** Four services on this box have died
  silently. Still the highest-value monitoring item.
- **Certificate expiry alert** (`blackbox_exporter`,
  `probe_ssl_earliest_cert_expiry`, fire at 14 days). The coturn outage was
  visible 30 days ahead and nothing was watching. Current certs expire
  **10 Nov 2026**; ACME validation is verified working on both hostnames.
- **Reboot test.** Now has more boot-path dependencies than ever: docker,
  containerd, 11 containers, the certbot timer, and this stack.
- **Close port 3000** — Grafana over plain HTTP. The Supabase vhost is a working
  template for proxying it.
- **Monitor `/var/lib/containerd`**, not `/var/lib/docker`.

---

## Verified working — do not re-litigate

Recorded so nobody spends time re-checking these.

- Schema is **md5-identical** to Lovable's live schema (650 columns).
- 397 content rows across 22 tables, confirmed through the public API.
- RLS: content readable by `anon`; `leads` and `otp_challenges` return `[]`.
- `otp_challenges` and `slot_holds` appear in the RLS audit with **0 policies by
  design** — both are reached only via service-role or `SECURITY DEFINER` RPCs.
  Two rows is the pass condition; a **third** would be a real finding.
- ACME validated on **both** hostnames with distinct probe bodies.
- SPA deep links resolve; hashed assets `immutable`, `index.html` `no-cache`.
- `deploy-enroll` runs the whole release: pull, build in `node:22-alpine`,
  publish, sync functions, port gate, verify.
