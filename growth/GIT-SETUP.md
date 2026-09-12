# Git onto the server — growth

Completed 12 Sep 2026. This is both the record of what was run and the template
for instance 3, because nothing in it is specific to growth beyond the names.

**Server:** `184.168.122.104` · root SSH disabled, use **WHM → Terminal**
**Every command is a single line.** The terminal silently drops multi-line
pastes; this is not a formatting preference.

---

## 1. The constraint everything follows from

**A GitHub deploy key is globally unique and bound to one repository.** The same
public key cannot be added to a second repo — GitHub rejects it with *"Key is
already in use"*. So every app needs its own keypair.

That in turn forces the ssh config shape. Two `IdentityFile` lines under a single
`Host github.com` block make ssh offer whichever matches first; GitHub
authenticates the connection and then refuses the repository, reporting
**`Repository not found`**. That error reads like a typo in the URL and is not
one — it is the single most expensive way this can go wrong.

The fix is one alias per app. See `../enroll/OPERATIONS.md` §0 for the live
description of the convention.

---

## 2. Generate the key

```bash
ssh-keygen -t ed25519 -C "growth-vps-deploy" -f /root/.ssh/growth_deploy -N ""
```

`-N ""` means no passphrase, and is required — the deploy runs unattended and a
passphrase would make `git pull` hang forever waiting on input that never comes.

Confirm the modes. Expect `600` on the private key, `644` on the `.pub`; ssh
refuses a world-readable key:

```bash
stat -c '%a %n' /root/.ssh/growth_deploy /root/.ssh/growth_deploy.pub
```

Print the public half. This is the only part that leaves the server:

```bash
cat /root/.ssh/growth_deploy.pub
```

Record the fingerprint, so the key GitHub shows can be matched against the key
you generated rather than a stale one from an earlier ticket:

```bash
ssh-keygen -lf /root/.ssh/growth_deploy.pub
```

---

## 3. Getting it added

Adding a deploy key to `librahmas-hue` requires org admin, which is a separate
person here. That round trip is the slowest part of this procedure — generate the
key first and continue with the ssh config while waiting.

The request needs to be unambiguous, because *"add this SSH key"* is vague enough
that it commonly lands on someone's personal account instead. That looks like
success and silently gives the server everything that person can reach.

> Repo → **Settings** → **Deploy keys** → **Add deploy key**
> - **Title:** `growth VPS deploy (read-only)`
> - **Key:** the `ssh-ed25519 …` line, on one line
> - **Allow write access:** **unchecked**
>
> It must be a deploy key on that specific repo — not an account SSH key, not an
> org-level setting. Read-only means a compromised VPS cannot push or rewrite
> history.

If a key already exists on an old repo, ask for its deletion in the same message.
A key cannot attach to a second repo while it is registered on the first.

---

## 4. Verify the key reaches the right repo

```bash
ssh -F /dev/null -i /root/.ssh/growth_deploy -o IdentitiesOnly=yes -T git@github.com
```

`-F /dev/null` is load-bearing: it ignores `/root/.ssh/config` entirely so that
exactly one key is offered. Without it the result tells you nothing about which
key actually worked.

**Expect:** `Hi librahmas-hue/learniverse-hub-442-dfdb7c25! You've successfully
authenticated, but GitHub does not provide shell access.`

The greeting **names the repository the key is bound to** — the fastest available
check that it went to the right place.

| Reply | Meaning |
|---|---|
| `Hi <owner>/<repo>!` | Correct. Read the name to the end; repos here differ only by suffix. |
| `Hi <a person's username>!` | Added to an account, not as a deploy key. Undo it — the server has their full access. |
| `Permission denied (publickey).` | Not added, wrong repo, or a mangled paste. |
| A password prompt | Key auth failed and ssh fell through. Never type one. |

**Ignore the exit code.** This command exits `1` even on success, because GitHub
closes the session rather than giving a shell. Read the message.

---

## 5. The ssh config

Back it up first — enroll's deploy depends on this file:

```bash
cp -a /root/.ssh/config /root/.ssh/config.backup-$(date +%F)
```

Write the aliases. One long single line:

```bash
printf 'Host github-enroll\n  HostName github.com\n  User git\n  IdentityFile /root/.ssh/enroll_deploy\n  IdentitiesOnly yes\n\nHost github-growth\n  HostName github.com\n  User git\n  IdentityFile /root/.ssh/growth_deploy\n  IdentitiesOnly yes\n' > /root/.ssh/config
```

```bash
ls -la /root/.ssh/config
```

Mode must still be `600`.

**There is deliberately no plain `Host github.com` block.** Its absence is what
makes a checkout still using the bare hostname fail immediately, rather than
quietly borrowing another app's key.

That also means **enroll breaks the moment this lands** and stays broken until
§6. Run them back to back. Nothing on this box deploys on a schedule, so there is
no risk of a release firing in the gap.

---

## 6. Repoint enroll — one time only

Enroll was cloned before the convention existed, so its remote still named
`github.com`. This reads the existing address and swaps only the host part,
leaving the repo path untouched:

```bash
git -C /opt/apps/enroll remote set-url origin "$(git -C /opt/apps/enroll remote get-url origin | sed 's|git@github\.com:|git@github-enroll:|')"
```

```bash
git -C /opt/apps/enroll remote -v
```

Prove enroll can still reach GitHub. This asks for the latest commit and writes
nothing:

```bash
git -C /opt/apps/enroll ls-remote origin HEAD
```

A 40-character hash followed by `HEAD` closes the gap. **Undo**, if it does not:
restore `/root/.ssh/config.backup-<date>` and run the `set-url` in reverse.

`deploy.sh` needs no change in either direction — it runs
`git -C "$REPO" pull --ff-only`, which uses whatever address the clone carries.

---

## 7. Clone

```bash
git clone --filter=blob:none git@github-growth:librahmas-hue/learniverse-hub-442-dfdb7c25.git /opt/apps/growth
```

`--filter=blob:none` fetches file contents on demand rather than every version
ever committed. `MIGRATION-RECORD.md` §4.1 recommends it after enroll's clone came
to 538 MB, mostly deleted videos still reachable in history. Growth came to
**13 MB**, so it made little difference here — deploys only ever build from HEAD,
so it costs nothing either way.

```bash
git -C /opt/apps/growth log --oneline -3
```

```bash
du -sh /opt/apps/growth
```

---

## 8. What is deliberately not done

**`/opt/apps/growth/.env.production.local` does not exist yet.** It needs the
publishable key from the growth Supabase stack, and that stack has not been
created. `deploy.sh` refuses to build without this file precisely so a build
cannot silently ship pointing at Lovable Cloud.

It will be gitignored when it exists: growth's `.gitignore` carries `*.local`,
which matches `.env.production.local` — git's pattern matching has no
leading-dot rule. `.env` itself **is** tracked, holding Lovable Cloud's URL and
publishable key. Both values are public by design and ship in the browser bundle,
so nothing sensitive is in that history.

---

## 9. When Lovable moves the repo

This happened during setup and cost a full round trip. Lovable re-creates a
project against a fresh GitHub repo when its sync breaks — growth moved from
`learniverse-hub-442` to `learniverse-hub-442-dfdb7c25`.

Do not reason about what Lovable did. Ask GitHub what the key is attached to:

```bash
ssh -T git@github-growth
```

The greeting resolves the repo's *current* identity, so it answers regardless of
whether the repo was renamed, transferred or replaced.

**Names match** — same repository, renamed or moved, key rode along. Update the
remote to the new name and carry on.

**Names differ** — a different repository. The key cannot move, so this is a new
keypair and another manager round trip. Ask for the old key's deletion at the same
time.

If the checkout already existed and Lovable *recreated* rather than renamed, the
history has a different root commit and `deploy.sh` will refuse with
`fatal: Not possible to fast-forward`. That guard is correct — the fix is a fresh
clone, carrying `.env.production.local` across, not a forced merge.

---

## 10. Adding instance 3

Sections 2, 3, 4, 7 unchanged with the new name. Section 5 gains one more alias
block; section 6 does not apply — only enroll ever needed repointing.
