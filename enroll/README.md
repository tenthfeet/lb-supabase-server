# enroll.lilbrahmas.org — deploy kit

Everything for running this app on the VPS. Start with the document that matches
what you need.

| File | Read it when |
|---|---|
| `OPERATIONS.md` | **Day to day.** Deploying, secrets, migrations, rollback, troubleshooting. |
| `LAUNCH-CHECKLIST.md` | Before the site takes real traffic. What is deferred and why none of it fails visibly. |
| `MIGRATION-RECORD.md` | Understanding how this was built, or migrating another Lovable app. |
| `LOVABLE-CHANGES.md` | Changes made, and still pending, in Lovable. |
| `EXECUTE.md` | The original step-by-step migration run. Historical. |

## Scripts

| Script | Runs on | Purpose |
|---|---|---|
| `deploy.sh` | server, as `/usr/local/sbin/deploy-enroll` | The whole release |
| `apply-migrations.sh` | server, in `/opt/apps/kit/` | First-time schema build only |
| `export-content.sh` | Windows (Git Bash) | Pull content out of Lovable Cloud |
| `import-content.sh` | Windows (Git Bash) | Push it into the VPS |
| `sync-videos.sh` | server, in `/opt/apps/kit/` | Mirror Lovable-hosted video assets locally |
| `schema-fingerprint.sh` | Windows (Git Bash) | Reduce a `types.ts` to a comparable checksum |
| `phase0-check-db-access.sh` | Windows (Git Bash) | Probe what access a Lovable project allows |

`htaccess-frontend`, `htaccess-api` and `functions-env-snippet.yml` are config
staged at `/opt/apps/kit/` on the server. `content-export/` is the 397-row
snapshot taken 22 Aug 2026.

## The three things most likely to catch you out

**Root SSH is disabled.** Use WHM Terminal for commands and cPanel File Manager
for transfers. `scp root@…` will always fail, however correct your key is.

**The terminal drops multi-line pastes.** Run one line at a time and check the
output. Every command in these documents is a single line for that reason.

**Content edited in the Lovable preview does not reach the live site.** Lovable
is for code. Production content is edited at
https://enroll.lilbrahmas.org/admin-control.

## Deploy, in one line

```
deploy-enroll
```

Add `--with-migrations` when the pull brings schema changes. Applying them is
safe to repeat — the ledger of what has run lives in the database, and each file
lands inside a transaction with its own ledger row. `--list-migrations` shows
what is pending without changing anything.
