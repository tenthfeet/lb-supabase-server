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

**38.** The config is these five lines, with this instance's gateway port. Do
not write them straight into the include directory: steps 38a–38c build the file
in `/root`, test it, and only then install it.

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

**38a.** Build the file from instance 1's working copy, changing only the port.
`diff` must show exactly lines 3–4, the two port lines.

```
sed 's|127\.0\.0\.1:8000/|127.0.0.1:<GATEWAY>/|g' /etc/apache2/conf.d/userdata/ssl/2_4/enroll/api.enroll.lilbrahmas.org/supabase.conf > /root/<new>-api-supabase.conf && diff /etc/apache2/conf.d/userdata/ssl/2_4/enroll/api.enroll.lilbrahmas.org/supabase.conf /root/<new>-api-supabase.conf
```

**38b.** Syntax-test it on top of the live config. `-t` only parses, and `-c`
adds a directive after the config is read, so nothing is applied. The first
command names a file that does not exist and **must fail**. That proves `-c`
reads the file, so the second command's `Syntax OK` is about this file.

```
httpd -t -c 'Include /root/<new>-no-such-file.conf'
```
```
httpd -t -c 'Include /root/<new>-api-supabase.conf'
```

**38c.** Install the tested file. Nothing live changes yet: Apache reads it only
after step 39 wires it into `httpd.conf` and step 41 reloads.

```
cp /root/<new>-api-supabase.conf /etc/apache2/conf.d/userdata/ssl/2_4/<cpuser>/api.<new>.lilbrahmas.org/supabase.conf
```

**39.** Keep a copy of `httpd.conf`, then register the include **without
reloading**. `ensure_vhost_includes` restarts Apache by itself whenever it
updates a vhost, unless it is given `--no-restart`. Run bare, as this step once
was, it reloads every site before anything has tested the new config.
`--no-restart` goes last: if the space before it is lost, the user name becomes
invalid, no vhost is updated, and nothing reloads.

```
(set -C && cat /etc/apache2/conf/httpd.conf > /root/<new>-pre-include-httpd.conf) && /scripts/ensure_vhost_includes --user=<cpuser> --no-restart
```

**39a.** Prove Apache did not reload. **Must print `404`:** with the proxy not
loaded, Apache looks for a file. `401` would be Envoy answering, meaning Apache
reloaded.

```
sleep 10; curl -s -o /dev/null -m 10 -w '%{http_code}\n' https://api.<new>.lilbrahmas.org/auth/v1/health
```

**39b.** Review what the rebuild changed, site by site. `ensure_vhost_includes`
re-emits the account's vhost blocks and may put them in a new order, so a plain
`diff` of `httpd.conf` shows hundreds of lines for a one-line change. This
compares each site's block before and after, keyed by address and `ServerName`,
ignoring `ServerAlias` word order, and skips the new include only inside the
new hostname's `:443` block. **Expect `differing: 0` and `new include lines: 1`,
with no `DIFFERS` lines.**

```
awk 'FNR==1{f++;k="GLOBAL";h=""}/^[[:space:]]*<VirtualHost/{h=$2;k=h;next}/^[[:space:]]*<\/VirtualHost>/{k="GLOBAL";next}/^[[:space:]]*ServerName/{k=h"|"$2}$1=="ServerAlias"{n=split($0,w);asort(w);s="";for(j=1;j<=n;j++)s=s" "w[j];$0=s}f==2&&k~/:443.*\|api\.<new>\.lilbrahmas\.org$/&&/^[[:space:]]*Include.*userdata\/ssl\/2_4\/<cpuser>\/api\.<new>\.lilbrahmas\.org\//{inc++;next}{b[f,k]=b[f,k]"\n"$0;K[k]=1}END{for(k in K)if(b[1,k]!=b[2,k]){d++;print("DIFFERS "k)}print("site blocks compared: "length(K)" differing: "d+0" new include lines: "inc+0)}' /root/<new>-pre-include-httpd.conf /etc/apache2/conf/httpd.conf
```

Block order matters only for which vhost is an address's default. `httpd -S`
prints those for the old file and the new one: **the same names**. Line numbers
after the new hostname's blocks are one higher.

```
httpd -S -f /root/<new>-pre-include-httpd.conf 2>&1 | awk '/default server/{n++;print("old "$3" "$4)}END{print("old default servers: "n+0)}'; httpd -S 2>&1 | awk '/default server/{n++;print("new "$3" "$4)}END{print("new default servers: "n+0)}'
```

A `DIFFERS` line or a changed default site stops §8 here.

**40.** See what a reload would apply. A reload loads everything on disk, not only
this change, and Apache may not have reloaded for days, so anything cPanel wrote
in the meantime would go live now and look like this instance's doing. This
prints each site's code, where the new API must still be `404`, and the last
reload's log line. For more than one existing instance, add its hostnames and
raise the `of 4`.

```
curl -s -m 10 -w '\nCODE %{http_code} %{url_effective}\n' https://enroll.lilbrahmas.org/ https://api.enroll.lilbrahmas.org/auth/v1/health https://<new>.lilbrahmas.org/ https://api.<new>.lilbrahmas.org/auth/v1/health | awk '/^CODE/{n++;print}END{print("urls checked: "n+0" of 4")}'; awk '/resuming normal operations/{t=$0}END{print("last reload: "t)}' /etc/apache2/logs/error_log
```

**41.** Gate, test, apply and re-check, in one line. Each part runs only if the
one before it passed. Put the last reload's time into `-newermt` as
`YYYY-MM-DD HH:MM:SS`. The gate opens only if the files changed since then are
this step's own: the new `supabase.conf` and `httpd.conf`, plus cPanel's
`httpd.conf.datastore` cache if it was written. Anything else prints as
`NOT THIS STEP` and nothing reloads, and an empty `find` keeps the gate shut
too. Graceful, not restart.

```
find /etc/apache2 /var/cpanel/ssl/apache_tls -type f -newermt '<YYYY-MM-DD HH:MM:SS>' | awk '$0=="/etc/apache2/conf.d/userdata/ssl/2_4/<cpuser>/api.<new>.lilbrahmas.org/supabase.conf"||$0=="/etc/apache2/conf/httpd.conf"{r++;next}$0=="/etc/apache2/conf/httpd.conf.datastore"{next}{o++;print("NOT THIS STEP "$0)}END{print("changed since last reload: expected "r+0" of 2, other "o+0);exit(!(r==2&&o==0))}' && apachectl configtest && apachectl graceful && sleep 5 && curl -s -m 10 -w '\nCODE %{http_code} %{url_effective}\n' https://enroll.lilbrahmas.org/ https://api.enroll.lilbrahmas.org/auth/v1/health https://<new>.lilbrahmas.org/ https://api.<new>.lilbrahmas.org/auth/v1/health | awk '/^CODE/{n++;print}END{print("urls checked: "n+0" of 4")}'
```

**Expect** `expected 2 of 2, other 0`, `Syntax OK`, then the same codes as step
40 except the new API: `404` becomes `401`, Envoy refusing a request with no
key.

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

**47.** ACME probe. AutoSSL renews the certificate by writing a file under
`/.well-known/acme-challenge/` **as the cPanel account** and having Let's
Encrypt fetch it. First confirm that folder exists and belongs to `<cpuser>`.
**Do not create it as root:** AutoSSL cannot write into a root-owned
`acme-challenge/`, and the certificate then expires ~90 days later without
warning.

```
ls -la /home/<cpuser>/public_html/api.<new>.lilbrahmas.org/.well-known/
```

If `acme-challenge` is missing, create it and hand it to the account in the same
line:

```
mkdir -p /home/<cpuser>/public_html/api.<new>.lilbrahmas.org/.well-known/acme-challenge && chown -R <cpuser>:<cpuser> /home/<cpuser>/public_html/api.<new>.lilbrahmas.org/.well-known
```

Then write a probe file, fetch it over **HTTP and HTTPS**, and delete it. **Both
fetches must print `probe` with `[200 …]`.**

```
echo probe > /home/<cpuser>/public_html/api.<new>.lilbrahmas.org/.well-known/acme-challenge/probe && curl -s -m 10 -L -w ' [%{http_code} %{url_effective}]\n' http://api.<new>.lilbrahmas.org/.well-known/acme-challenge/probe; curl -s -m 10 -w ' [%{http_code} %{url_effective}]\n' https://api.<new>.lilbrahmas.org/.well-known/acme-challenge/probe; rm -f /home/<cpuser>/public_html/api.<new>.lilbrahmas.org/.well-known/acme-challenge/probe
```

The HTTPS fetch is the one that tests `ProxyPass /.well-known/ !`. Step 38's
include sits in the SSL vhost only, so when port 80 does not redirect (growth's
does not), the HTTP fetch never meets the proxy and passes even with that line
missing. Without the line, the HTTPS fetch gets Envoy's `Unauthorized`.

**48.** Frontend. **Check the content, not the status code:** a docroot with no
index file answers `200` with Apache's own `Index of /` listing. Expect the app's
`<title>`. `Index of /` means nothing is being served yet.

```
curl -s -m 10 -w '\nCODE %{http_code}\n' https://<new>.lilbrahmas.org/ | awk '/<title>|^CODE/{n++;print}END{print("lines: "n+0)}'
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

**58.** Record the instance **directly under the last instance line**. The upstream
branch note comes after those lines, so appending with `>>` would put the new
entry below the note, away from the others. List them first:

```
awk '/.=.instance.[0-9]+:./{n++;print(FNR": "$0)}END{print("instance lines: "n+0" of "NR)}' /opt/supabase/README.md
```

Then insert under the last one, writing that line's spaces as `.` in the
pattern. The pattern must match the whole line: if it does not, nothing is
inserted and the listing afterwards shows it. With growth as the last instance:

```
sed --in-place "/^growth.=.instance.2:.8010.\/.5442.\/.6553\$/a $INST = instance $N: $((8000+10*(N-1))) / $((5432+10*(N-1))) / $((6543+10*(N-1)))" /opt/supabase/README.md && awk '/.=.instance.[0-9]+:./{n++;print(FNR": "$0)}END{print("instance lines: "n+0" of "NR)}' /opt/supabase/README.md
```

---

## 10. Rollback

Instance 1 is unaffected throughout — separate project, network, volumes and
ports.

| Step reached | To undo |
|---|---|
| Copied only | `rm -rf /opt/supabase/stacks/$INST` |
| Started | `cd /opt/supabase/stacks/$INST && docker compose down -v` then `rm -rf` |
| Apache configured | the two steps below, **not** `rm` of the include first |
| DNS added | Remove the record at GoDaddy |

**Rolling back §8.** Deleting `supabase.conf` while `httpd.conf` still has the
active `Include ".../api.<new>.lilbrahmas.org/*.conf"` leaves a wildcard that
matches no file. Apache 2.4 documents that as an error for `Include` (unlike
`IncludeOptional`): `configtest` fails, `graceful` is refused, and a full
restart or reboot would leave Apache down for every site. Not tested on this
box. Do it in this order instead:

1. Empty the include to a comment, then reload. The proxy is off and the
   wildcard still matches.

   ```
   printf '%s\n' '# rolled back' > /etc/apache2/conf.d/userdata/ssl/2_4/<cpuser>/api.<new>.lilbrahmas.org/supabase.conf && apachectl configtest && apachectl graceful
   ```

2. Un-wire it in one chain, so the broken state lasts seconds with no reload
   inside it: remove the file and its directory, let `ensure_vhost_includes`
   comment the `Include` out, then test and reload. If `configtest` fails here,
   put step 1's comment-only file back before anything else.

   ```
   rm /etc/apache2/conf.d/userdata/ssl/2_4/<cpuser>/api.<new>.lilbrahmas.org/supabase.conf && rmdir /etc/apache2/conf.d/userdata/ssl/2_4/<cpuser>/api.<new>.lilbrahmas.org && /scripts/ensure_vhost_includes --user=<cpuser> --no-restart && apachectl configtest && apachectl graceful
   ```

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
