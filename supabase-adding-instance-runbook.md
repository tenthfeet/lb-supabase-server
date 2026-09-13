# Adding a Supabase Instance — Runbook

**Server:** `184.168.122.104` · AlmaLinux 9.8 · WHM/cPanel · EasyApache 4
**Written:** 19 August 2026, after the multi-instance restructure
**Companion to:** *Server Preparation Runbook* (§ refs) and *Deployment Runbook — Docker & Supabase (Addendum)* (§§ refs)

Follow this top to bottom. Nothing here needs re-deriving.

---

## 1. Layout

```
/opt/supabase/
├── README.md          ← layout + port scheme + divergence note
├── upstream/          ← git clone, pinned. NEVER runs anything. No .env by design.
└── stacks/
    └── enroll/        ← instance 1: 8000 / 5432 / 6543, project name "enroll"
```

**Copy `stacks/enroll/`, not `upstream/docker/`.** Enroll is a verified-working
configuration carrying both the local JWKS commit and the correct
`docker-compose.override.yml`. Upstream exists only to diff against at upgrade
time.

**Upstream is on branch `local-jwks-enabled`**, one commit (`5e5b15246b`) ahead
of pin `4760c1af77`. That commit uncomments `GOTRUE_JWT_KEYS`, `API_JWT_JWKS`,
`JWT_JWKS` and `SUPABASE_JWKS` for `auth`, `realtime`, `storage` and
`functions`. Without it ES256 tokens fail verification and logins break.
**Never `git checkout` over it.**

---

## 2. Port scheme

```
gateway        = 8000 + 10(N-1)
session pooler = 5432 + 10(N-1)
txn pooler     = 6543 + 10(N-1)
```

| Instance | Gateway | Session | Transaction |
|---|---|---|---|
| 1 `enroll` | 8000 | 5432 | 6543 |
| 2 | 8010 | 5442 | 6553 |
| 3 | 8020 | 5452 | 6563 |
| 4 | 8030 | 5462 | 6573 |
| 5 | 8040 | 5472 | 6583 |

All below 32768, clear of coturn's 49152–65535 relay range (prep §4.4).

**Skip and re-derive if the formula lands on a used port.** The 8000 series
hits 8080 at N=9 and 8443 at N=45. Always run the step 1 check below rather
than trusting the table.

---

## 3. Before you start

Set `INST` and `N` once; every command below uses them.

```
INST=stack2
```
```
N=2
```

**1.** Confirm the three ports are free. Expect `PORTS FREE`.

```
ss -tln | grep -E ":($((8000+10*(N-1)))|$((5432+10*(N-1)))|$((6543+10*(N-1))))\b" || echo "PORTS FREE"
```

**2.** Confirm the name is unused.

```
ls /opt/supabase/stacks/
```

**3.** Confirm disk. Each instance needs ~70 MB plus its database; images are
shared via `/var/lib/containerd`.

```
df -h /opt /var/lib/containerd
```

**4.** Confirm RAM. Each stack idles around 1.13 GiB.

```
free -h
```

**5.** Add the DNS record **at GoDaddy**, not on this server (prep §7).
Nameservers are `ns13/ns14.domaincontrol.com`; PowerDNS here is not
authoritative. In GoDaddy's "Name" field enter only the subdomain part.

**6.** Create the subdomain in cPanel so it gets its own DocumentRoot and its
own include directory. An alias will not work.

---

## 4. Copy the stack

**7.** Copy the template, excluding runtime state.

```
rsync -a --exclude 'volumes/db/data' --exclude '.env.old' /opt/supabase/stacks/enroll/ /opt/supabase/stacks/$INST/
```

**8.** Create the empty data mount point.

```
mkdir -p /opt/supabase/stacks/$INST/volumes/db/data
```

**9.** Confirm it is empty. **Must print 0.** A non-zero result means Postgres
will skip `docker-entrypoint-initdb.d` and never run `roles.sql`.

```
ls -A /opt/supabase/stacks/$INST/volumes/db/data | wc -l
```

**10.** Move in. Everything below runs from here.

```
cd /opt/supabase/stacks/$INST
```

**11.** Confirm the override copied intact. Expect **33** and **11**.

```
echo "lines: $(wc -l < docker-compose.override.yml)  resets: $(grep -c 'container_name: !reset null' docker-compose.override.yml)"
```

The override needs **no edits**. `container_name: !reset null` prevents
collisions with instance 1's names, and the `realtime` network aliases are
scoped to this instance's own network (`${INST}_default`), so they cannot
collide either.

---

## 5. Fresh secrets

**Do not reuse enroll's secrets.** Shared `JWT_SECRET` means a token minted by
one instance validates against the other; shared `POSTGRES_PASSWORD` means one
credential opens both databases.

> ⚠ **No `docker compose` command of any kind in this folder until step 19.**
> The copied `.env` still carries enroll's `COMPOSE_PROJECT_NAME`, and Compose
> takes the project name from that file. Until step 19 changes it, every Compose
> command run here addresses **enroll's live project**: `up` would recreate
> enroll's containers against this folder's empty data mount, `down` would stop
> enroll, and `ps` or `logs` would show enroll's containers as this instance's.
> Step 13's `docker run` is not a Compose command and is unaffected.

**11a.** Record what is still shared with enroll. Prints the **names** — never
the values — of every non-empty variable whose value is identical in both files.

```
awk -F= 'NR==FNR{if($1~/^[A-Z_][A-Z0-9_]*$/)e[$1]=substr($0,index($0,"=")+1);next}$1~/^[A-Z_][A-Z0-9_]*$/&&e[$1]!=""&&e[$1]==substr($0,index($0,"=")+1){s=s" "$1;n++}END{print(n+0" identical:"s)}' /opt/supabase/stacks/enroll/.env .env
```

Straight after the copy **every non-empty variable** is listed, including all 20
that steps 12–13 regenerate. That is why it runs now: it proves the comparison
detects sharing before step 13a relies on it to show the sharing is gone.

> ⚠ **Both key scripts print every secret they generate to the terminal** —
> `JWT_SECRET`, `POSTGRES_PASSWORD`, `SUPABASE_SECRET_KEY`, and in step 13
> `JWT_KEYS`, which contains the ES256 **private** key. Run them only with
> `> /dev/null`, and never paste their output anywhere. Discarding the output
> also hides the scripts' own messages; step 13a is how you know they worked.

**12.** Symmetric secrets, Postgres and dashboard passwords.

```
sh utils/generate-keys.sh --update-env > /dev/null
```

Straight after this step `.env.old` holds **enroll's** secrets: `sed -i.old`
keeps the pre-edit file beside the new one. Step 13 rewrites it again, and it
still holds superseded secrets until step 14 deletes it.

**13.** EC P-256 pair and opaque API keys. Must run **after** step 12 — it reads
the `JWT_SECRET` that step produces. No node on this server, so it pulls
`node:22-alpine`.

```
sh utils/add-new-auth-keys.sh --update-env > /dev/null
```

**13a.** Run step 11a's comparison again. **None of these 20 may be listed:**

- from step 12: `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`, `SECRET_KEY_BASE`,
  `REALTIME_DB_ENC_KEY`, `VAULT_ENC_KEY`, `PG_META_CRYPTO_KEY`,
  `LOGFLARE_PUBLIC_ACCESS_TOKEN`, `LOGFLARE_PRIVATE_ACCESS_TOKEN`,
  `S3_PROTOCOL_ACCESS_KEY_ID`, `S3_PROTOCOL_ACCESS_KEY_SECRET`,
  `MINIO_ROOT_PASSWORD`, `POSTGRES_PASSWORD`, `DASHBOARD_PASSWORD`
- from step 13: `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY`,
  `ANON_KEY_ASYMMETRIC`, `SERVICE_ROLE_KEY_ASYMMETRIC`, `JWT_KEYS`, `JWT_JWKS`

`COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` must still be listed — the scripts
left them alone (step 26 checks their values). Everything else still listed is
what no script touches: the ports, URLs and `POOLER_TENANT_ID` that §6 rewrites,
and anything enroll added for its own edge functions, which §6 does not cover.

A name dropping off the list proves its value changed, not that the new value is
valid — an empty value differs too. Steps 17–18 check the shape of three of them.

**14.** Delete the leftover. It holds superseded secrets and is not gitignored
(addendum §4.5). Its mode is whatever `.env` had when the scripts ran — 644 for a
`.env` made from `.env.example`, 600 for one copied from enroll.

```
rm -f .env.old
```

**15.** Restore mode 600. The scripts can leave it world-readable, and this box
has cPanel user accounts.

```
chmod 600 .env
```
```
ls -la .env
```

**16.** No placeholders left. **Must print 0.**

```
grep -cE 'your-super-secret|this_password_is_insecure|your-32-character|supabaserealtime|your-encryption-key' .env
```

**On a copied stack this step cannot fail.** It looks for upstream's placeholder
strings, and enroll's `.env` — the one step 7 copied — contains none, so it
prints `0` even if steps 12–13 never ran. It only guards a `.env` built from
`.env.example`. Steps 11a and 13a are the check that can fail.

**17.** Exact lengths — Realtime requires exactly 16, Vault exactly 32. This
catches a dropped newline merging two variables, which a visual scan does not.

```
awk -F= '/^(REALTIME_DB_ENC_KEY|VAULT_ENC_KEY)=/{print $1, length($2)}' .env
```

**18.** Valid JSON. No output means valid.

```
grep '^JWT_KEYS=' .env | cut -d= -f2- | python3 -m json.tool > /dev/null
```

---

## 6. Rewrite `.env`

> **The key scripts rewrite `.env` with `sed`.** `COMPOSE_FILE` and
> `COMPOSE_PROJECT_NAME` are ordinary variables in that file and can be
> disturbed. Step 26 re-checks both — do not skip it.

**19.** Project name. Beats the `name: supabase` field at line 11 of
`docker-compose.yml`. Until this runs, Compose in this folder addresses enroll's
project — see the warning at the top of §5.

```
sed -i "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=$INST|" .env
```

**20.** Gateway port. Must be set explicitly — the override's `!override`
replaces the base list and drops its `KONG_HTTP_PORT` fallback.

```
sed -i "s|^API_GW_HTTP_PORT=.*|API_GW_HTTP_PORT=$((8000+10*(N-1)))|" .env
```

**21.** Session pooler port.

```
sed -i "s|^POSTGRES_PORT=.*|POSTGRES_PORT=$((5432+10*(N-1)))|" .env
```

**22.** Transaction pooler port.

```
sed -i "s|^POOLER_PROXY_PORT_TRANSACTION=.*|POOLER_PROXY_PORT_TRANSACTION=$((6543+10*(N-1)))|" .env
```

**23.** Supavisor tenant. Must be unique per instance.

```
sed -i "s|^POOLER_TENANT_ID=.*|POOLER_TENANT_ID=$INST|" .env
```

**24.** URLs. Edit these three by hand for the new hostnames — `SITE_URL` is the
**frontend**, not the API, and drives CORS.

```
grep -nE '^(SUPABASE_PUBLIC_URL|API_EXTERNAL_URL|SITE_URL)=' .env
```

Set to:

```
SUPABASE_PUBLIC_URL=https://api.<new>.lilbrahmas.org
API_EXTERNAL_URL=https://api.<new>.lilbrahmas.org/auth/v1
SITE_URL=https://<new>.lilbrahmas.org
```

**25.** Leave `ENABLE_PHONE_SIGNUP=false` and `ENABLE_PHONE_AUTOCONFIRM=false`.
Shipping `true` with no SMS provider is an open account-creation endpoint
(addendum §4.6). Set `ENABLE_EMAIL_AUTOCONFIRM=false` unless SMTP is still
unconfigured — and if you set it `true`, record the date; accounts created in
that window keep unverified addresses permanently (§4.7).

**26.** Confirm the scripts did not disturb the two Compose variables. Both
lines must be present and correct.

```
grep -nE '^(COMPOSE_FILE|COMPOSE_PROJECT_NAME)=' .env
```

`COMPOSE_FILE` must read `docker-compose.yml:docker-compose.override.yml`. If
it names only the base file, the override is silently ignored, all three ports
bind `0.0.0.0`, and `docker compose config --quiet` still returns valid
(addendum §4.3).

---

## 7. Gates, then start

**27.** Project name resolves. Must print `name: <INST>`.

```
docker compose config | grep -m1 '^name:'
```

**28.** All container names reset. **Must print 0.**

```
docker compose config | grep -c 'container_name:'
```

**29.** All four JWKS variables reach the config. Expect four lines, count 1 each.

```
docker compose config | grep -oE '(GOTRUE_JWT_KEYS|API_JWT_JWKS|JWT_JWKS|SUPABASE_JWKS):' | sort | uniq -c
```

**30.** Bind mounts point at this instance. Every source must start
`/opt/supabase/stacks/$INST/`.

```
docker compose config | grep 'source:' | sort -u
```

**31.** Ports resolve to the new triple, all loopback.

```
docker compose config | grep -E 'host_ip:|published:'
```

**32. The port gate.** Mandatory before every `up`. Must print
`ALL PORTS LOOPBACK`.

```
test $(docker compose config | grep -c 'published:') -eq $(docker compose config | grep -c 'host_ip: 127.0.0.1') && echo "ALL PORTS LOOPBACK" || echo "MISMATCH - DO NOT START"
```

> ⚠ **This step creates a new bridge network and rewrites Docker's iptables
> rules.** Per addendum §3.3 that is invisible to coturn, which is a userspace
> relay whose traffic never traverses `FORWARD`. Verified in §9 below regardless.

**33.** Start.

```
docker compose up -d
```

**34.** Wait for Postgres init.

```
sleep 90
```

**35.** Health. **Expect `containers: 11 healthy: 11`** and no `NOT HEALTHY`
lines. A container still in `(health: starting)` counts as not healthy — wait,
then re-run.

```
docker compose ps -a --format '{{.Service}}:{{.Status}}' | awk '{t++}/\(healthy\)/{ok++;next}{print("NOT HEALTHY "$0)}END{print("containers: "t+0" healthy: "ok+0)}'
```

The earlier form of this check, `grep -vc healthy`, could pass on a broken
stack: `(unhealthy)` contains the substring `healthy`, `ps` without `-a` omits
containers that have exited, and an empty listing — wrong folder, Compose error
— printed `0` as well.

**36.** Confirm Postgres actually re-initialised. Expect `anon`,
`authenticated`, `service_role` and nine `supabase_*` roles.

```
docker compose exec -T db psql -U postgres -tAc "select rolname from pg_roles where rolname like 'supabase%' or rolname in ('anon','authenticated','service_role') order by 1;"
```

---

## 8. Apache reverse proxy

> ⚠ **This section touches Apache.** Config must live in cPanel's include
> directory or `upcp`/`rebuildhttpdconf` erases it (prep §3.1). Never edit the
> vhost directly.

**37.** Create the include directory.

```
mkdir -p /etc/apache2/conf.d/userdata/ssl/2_4/<cpuser>/api.<new>.lilbrahmas.org
```

**38.** Write the config, one line at a time, to
`.../api.<new>.lilbrahmas.org/supabase.conf`, substituting this instance's
gateway port:

```
ProxyPreserveHost On
ProxyPass /.well-known/ !
ProxyPass / http://127.0.0.1:<GATEWAY>/ upgrade=websocket
ProxyPassReverse / http://127.0.0.1:<GATEWAY>/
RequestHeader set X-Forwarded-Proto "https"
```

- **`ProxyPass /.well-known/ !` must come first.** ProxyPass matches in order,
  first match wins. Without it AutoSSL's validation fetch reaches Envoy, gets a
  401, and the certificate expires ~90 days later with no warning. **This line
  looks redundant. Do not delete it.**
- **`upgrade=websocket`, not `mod_proxy_wstunnel`.** That module is deprecated
  as of Apache 2.4.47 (addendum §1).
- **`127.0.0.1`, never `localhost`** (prep §4.3c).

**39.** Register the include.

```
/scripts/ensure_vhost_includes --user=<cpuser>
```

**40.** Test before applying.

```
apachectl configtest
```

**41.** Apply. Graceful, not restart.

```
apachectl graceful
```

**42.** Confirm it is wired. cPanel references the directory as a glob, so
grepping for the filename returns nothing even when correct.

```
grep -nE '^[[:space:]]*Include.*userdata/ssl/2_4/<cpuser>/api\.<new>' /etc/apache2/conf/httpd.conf
```

---

## 9. Verification

**43.** Nothing exposed.

```
test $(ss -tln | grep -cE "(0\.0\.0\.0|\*):($((8000+10*(N-1)))|$((5432+10*(N-1)))|$((6543+10*(N-1))))") -eq 0 && echo "NOTHING EXPOSED" || echo "EXPOSED - RUN: docker compose down"
```

**44.** Three loopback sockets.

```
ss -tln | grep -E ":($((8000+10*(N-1)))|$((5432+10*(N-1)))|$((6543+10*(N-1))))\b"
```

**45.** GoTrue health through the proxy.

```
curl -s -H "apikey: $(grep '^SUPABASE_PUBLISHABLE_KEY=' .env | cut -d= -f2-)" https://api.<new>.lilbrahmas.org/auth/v1/health
```

**46.** WebSocket. **Expect `101`, taking ~5 seconds.** `--http1.1` is required:
HTTP/2 strips the Upgrade headers and Realtime correctly returns 400, which
looks exactly like a broken proxy. **Fast is broken, slow is working.**

```
curl -s -m 5 -o /dev/null -w '%{http_code}\n' --http1.1 -H "apikey: $(grep '^SUPABASE_PUBLISHABLE_KEY=' .env | cut -d= -f2-)" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' 'https://api.<new>.lilbrahmas.org/realtime/v1/websocket?vsn=1.0.0'
```

**47.** ACME probe — write the file, fetch it, delete it. Middle command **must
print `probe`**. Three separate commands; skipping the first gives a 404 that
looks like failure.

```
mkdir -p /home/<cpuser>/public_html/api.<new>.lilbrahmas.org/.well-known/acme-challenge
```
```
echo probe > /home/<cpuser>/public_html/api.<new>.lilbrahmas.org/.well-known/acme-challenge/probe
```
```
curl -sL http://api.<new>.lilbrahmas.org/.well-known/acme-challenge/probe
```
```
rm -f /home/<cpuser>/public_html/api.<new>.lilbrahmas.org/.well-known/acme-challenge/probe
```

**48.** Frontend. Expect `200`.

```
curl -s -o /dev/null -w '%{http_code}\n' https://<new>.lilbrahmas.org/
```

**49.** RLS audit. `(0 rows)` is the pass condition.

```
docker compose exec -T db psql -U postgres -c "SELECT c.relname, c.relrowsecurity AS rls_on, c.relforcerowsecurity AS rls_forced, count(p.polname) AS policies FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_policy p ON p.polrelid=c.oid WHERE n.nspname='public' AND c.relkind='r' GROUP BY 1,2,3 HAVING NOT c.relrowsecurity OR count(p.polname)=0 ORDER BY 1;"
```

### The existing instance and the host

**50.** Instance 1 still healthy. **Expect `containers: 11 healthy: 11`** and no
`NOT HEALTHY` lines — step 35's check, run in a subshell so the terminal stays in
this instance's folder.

```
(cd /opt/supabase/stacks/enroll && docker compose ps -a --format '{{.Service}}:{{.Status}}') | awk '{t++}/\(healthy\)/{ok++;next}{print("NOT HEALTHY "$0)}END{print("containers: "t+0" healthy: "ok+0)}'
```

**51.** Instance 1's API still answering.

```
curl -s -o /dev/null -w '%{http_code}\n' https://api.enroll.lilbrahmas.org/auth/v1/health
```

**52.** coturn PID and start time — must be unchanged.

```
systemctl show coturn --property=MainPID --property=ActiveEnterTimestamp
```

**53.** Nothing missing from the coturn baseline. **Expect no output.** Use
`comm`, not `diff` — live relay allocations legitimately appear as additions
and make a plain diff look alarming.

```
comm -13 <(ss -tulnp | grep turnserver | awk '{print $1, $5}' | sort -u) <(sort -u /root/coturn-ports-pre-docker.txt)
```

**54.** Relay range still pinned. Must be `32768 49151`.

```
sysctl net.ipv4.ip_local_port_range
```

**55.** WHM's SMTP restriction rules survived the netfilter rewrite. Use
`iptables-save`; `nft list ruleset` silently omits them (addendum §3.3).

```
iptables-save -t nat | grep -c 'REDIRECT'
```

**56.** New bridge subnet — confirm no collision with a host route.

```
docker network inspect ${INST}_default -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

**57.** All instances accounted for.

```
docker compose ls
```

**58.** Record the instance.

```
echo "$INST = instance $N: $((8000+10*(N-1))) / $((5432+10*(N-1))) / $((6543+10*(N-1)))" >> /opt/supabase/README.md
```

---

## 10. Rollback

Instance 1 is unaffected throughout — separate project, network, volumes and
ports.

| Step reached | To undo |
|---|---|
| Copied only | `rm -rf /opt/supabase/stacks/$INST` |
| Started | `cd /opt/supabase/stacks/$INST && docker compose down -v` then `rm -rf` |
| Apache configured | `rm /etc/apache2/conf.d/userdata/ssl/2_4/<cpuser>/api.<new>.lilbrahmas.org/supabase.conf` then `apachectl configtest && apachectl graceful` |
| DNS added | Remove the record at GoDaddy |

After any rollback, re-run steps 50–55.

---

## 11. Reminders

- **Every new table in `public` is granted full read/write to `anon` by
  default, with RLS off.** `SUPABASE_PUBLISHABLE_KEY` ships in the JavaScript
  bundle. Enable and force RLS on creation; run the step 49 audit after every
  migration.
- **Multi-line pastes are dropped by this terminal**, and output lines have
  been observed glued together on display. One command at a time; verify counts
  with `wc -l` rather than reading.
- **cPanel's nightly `upcp` runs around 00:46 UTC**, restarts firewalld, and
  overwrites configs outside its include directories. Avoid working across it.
- **Docker packages are version-locked**, so no automatic security updates.
  Watch the Docker and coturn release notes.
- **Monitor `/var/lib/containerd`**, not `/var/lib/docker`.
- **Prefer designs that fail loudly** (prep §7). Four services on this box died
  silently because nothing watched them. Every gate in this document prints an
  unambiguous pass or fail for that reason.
