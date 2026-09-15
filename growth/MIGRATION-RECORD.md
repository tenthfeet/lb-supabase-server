# Migration record: growth, Lovable Cloud → VPS

Started by README step 2 on 14 Sep 2026. It records what moves and by which
route. **Step 2 writes nothing anywhere.** Steps 4, 5 and 10 add their records
here as they happen.

**Source:** Lovable Cloud project `hwchtywjbmcvpucidfmy`, the database behind
https://learniverse-hub-442.lovable.app. **Target:** growth's stack,
`/opt/supabase/stacks/growth` (instance 2).

---

## 1. The repo at the time of scoping

Checked on the workstation after `git fetch`. Lovable pushes many times a day,
so re-count rather than trust these numbers.

| | 14 Sep 2026 | 15 Sep 2026 |
|---|---|---|
| HEAD | `b1744482` (07:20 UTC) | `63b7ca15` (05:14 UTC), equal to `origin/main`, clean |
| Migrations | 249 | **263**, latest `20260914200900_*` |
| `types.ts` (`enroll/schema-fingerprint.sh`) | 167 tables, 2131 columns, 76 functions | **180 tables, 2294 columns, 77 functions** |

Later on 15 Sep, `df414acf` (08:11 UTC) added one migration, the escalation fix
in *`pg_cron` and `pg_net`* below. That makes **264**, and `types.ts` did not
change.

**No table drift between the repo and Lovable Cloud** (15 Sep, §3). Lovable's
own migration ledger holds **263** entries and its latest is `20260914200900`,
the same file the repo ends with. The database's 180 `public` tables are exactly
the 180 in `types.ts`, compared name by name with `comm` in both directions.
Drift does exist outside tables: one `pg_cron` job and the 7 storage buckets
were created without a migration (below).

### Storage buckets are not created by any migration

Storage policies in the migrations name **7 buckets**: `lms-media`,
`admission-payments`, `chat-attachments`, `org-photos`, `employee-documents`,
`hr-letters`, `call-audits`. No migration and nothing in `src/` creates a bucket.
There is no `storage.buckets` reference, `INSERT INTO storage` or `createBucket`.
Lovable created them outside the migration files. The source has exactly those 7,
all **private** (§3).

**For step 4:** replaying the migrations gives the policies but no buckets.
Create the 7 buckets separately, all private. Source settings, 15 Sep:
`call-audits` has a 50 MiB file size limit (52,428,800). The other six have
none, and no bucket restricts MIME types.

### `pg_cron` and `pg_net`: five jobs, two calling the Lovable-hosted app

Found 15 Sep 2026. It supersedes "zero `pg_net`" in `README.md` and
`STACK-PROVISIONING.md` §3.4, and "orphans" in §3.5.

The source's jobs, from query 2 (§3). Times are the database's, UTC.

| jobid | Job | Schedule | Runs | Created by | Last run |
|---|---|---|---|---|---|
| 1 | `dwr-shift-cutoff-nudge` | `*/15 * * * *` | HTTP to `lovable.app` | **no migration.** A grep of `supabase/` and `src/` for the name finds nothing | succeeded 07:30 15 Sep |
| 2 | `escalate-stale-approvals` | `15 * * * *` | SQL `public.escalate_stale_approvals()` | `20260722071430_*`, guarded; function fixed by `20260915081117_*` | failed through 07:15 15 Sep, **succeeded** 08:15 after the fix |
| 3 | `auto-generate-leave-delegations` | `30 0 * * *` | SQL `public.auto_generate_leave_delegations()` | `20260722071430_*`, guarded | succeeded 00:30 15 Sep |
| 5 | `renew-monthly-incentive-plans` | `35 0 * * *` | SQL | `20260914051218_*` / `20260914051303_*`, unguarded | succeeded 00:35 15 Sep |
| 6 | `attendance-roll-day` | `15 19 * * *` (00:45 IST) | HTTP to `lovable.app` | `20260914120009_*`, unguarded | succeeded 19:15 14 Sep |

For an HTTP job, "succeeded" only means `net.http_post` queued the request.
`pg_net` sends asynchronously, so it says nothing about whether the app answered.

**Runs in the 7 days to 15 Sep:**
- `dwr-shift-cutoff-nudge`: 672 succeeded, one every 15 minutes
- `auto-generate-leave-delegations`: 7 succeeded
- `attendance-roll-day` and `renew-monthly-incentive-plans`: 1 each, both created 14 Sep
- `escalate-stale-approvals`: **168 failed, 0 succeeded**

Only `escalate-stale-approvals` failed.

**`attendance-roll-day`.** Migration `20260914120009_*` (line 123) runs a
top-level `SELECT cron.schedule(…)`. Its command is a `net.http_post` to
`https://project--f44cdfc8-….lovable.app/api/public/hooks/attendance-roll-day`,
with Lovable Cloud's legacy anon JWT written into the migration as the `apikey`
header. It is the only migration that calls out of the database. No other file
mentions `lovable.app`, `hwchtywjbmcvpucidfmy` or `net.http_*`.

**`dwr-shift-cutoff-nudge`** is the oldest job (jobid 1) and exists only in
Lovable Cloud. It calls `project--f44cdfc8-….lovable.app/api/public/hooks/dwr-nudge`
(confirmed 15 Sep), so both of the app's hook routes are called in production.

- **Applying the migrations needs only `pg_cron`.** `cron.schedule` stores the
  command as text. `net.http_post` is looked up only when the job runs.
- **`attendance-roll-day` on the VPS, as written, is wrong either way.** It calls
  **Lovable's** app if growth's stack has `pg_net`, and fails every night if not.
  ✅ **Growth's stack has `pg_net` 0.20.3** (step 4, 15 Sep 11:09 UTC), so as
  written it calls Lovable's app (§6).
- **`dwr-shift-cutoff-nudge` will not exist on the VPS.** Replaying the
  migrations does not create it, so at cutover DWR nudges stop and nothing
  reports it.
- **`escalate-stale-approvals` has not succeeded once in 7 days.** Every run
  fails with `column "user_id" does not exist`. `public.escalate_stale_approvals()`
  is defined once (`20260722071430_*` line 124) and never replaced. Its second
  loop reads `user_id` from `change_requests`, whose columns are `requested_by`
  and `target_user_id`. PL/pgSQL checks a query only when it runs, so the
  migration applied without error. The error aborts the whole call, so the leave
  escalations from its first loop roll back too.
  **Fixed by Lovable on 15 Sep 2026** in `20260915081117_*` (`df414acf`,
  08:11 UTC), at our request:
  - a single `CREATE OR REPLACE FUNCTION`, with no cron job, table or grant
    touched; `CREATE OR REPLACE` keeps the `REVOKE` from `20260722085106_*`
  - `change_requests` now gives `COALESCE(target_user_id, requested_by)`
  - a `NOT EXISTS` check on `approval_history` flags each item once. Before the
    fix, once it worked, it would have added a row per stale item every hour
  - every other column it reads exists in `types.ts`

  ✅ **Confirmed working, 15 Sep 2026**, by a read-only query
  (`query-results-export-2026-09-15_13-47-34.csv`):
  - the live definition contains the `COALESCE`
  - runs: 07:15 `failed`, then 08:15 `succeeded`, the first after the fix
  - since 08:11 UTC: **108** `sla_breach_flagged` rows and no `sla_escalated`
    rows, so no leave request changed approver
  - **0** items flagged more than once

  That first success flagged every item already pending over 48 hours, so
  `approval_history` is now about 587 rows, past §3's 479. The 108 is itself a
  finding for the app's owner: that many approvals have waited over two days.
- **Step 4:** check `pg_net` on growth's stack, then unschedule or repoint
  `attendance-roll-day`. Drive both hooks from a host cron over loopback
  (`STACK-PROVISIONING.md` §3.5), so `dwr-nudge` keeps running.
- **Step 5:** pause every job in `cron.job` while importing.
- **Step 10:** stop Lovable Cloud's own jobs at the freeze. The two HTTP jobs keep
  calling the Lovable-hosted app, which writes to Lovable Cloud. On the VPS, no
  `cron.job` command may contain `lovable.app`.

---

## 2. Data route

enroll's order (`enroll/00-PLAN.md` §0.2) is direct Postgres, then the
service-role key, then the publishable key. For growth, Lovable's own Cloud
tools come first. Lovable's docs, read 14 Sep 2026:

- **SQL editor** in the Cloud panel: "Run SQL queries and commands against your
  database" (`docs.lovable.dev/features/cloud`).
- **Export data**, under More → Cloud → Overview → Advanced settings: "your full
  database, both structure and data", emailed as a download link. It excludes
  storage files, Edge Function code, project secrets and "User passwords in usable
  form". One export every 24 hours, 5 GB cap (`docs.lovable.dev/features/advanced-settings`).
- A connection string or the service-role key is not documented as visible.
  `LOVABLE_API_KEY` is write-only (`STACK-PROVISIONING.md` §5 item 8), and Lovable
  manages the service-role key in the same way.

**The publishable key alone (enroll's Route C) is weak here.** Under RLS, a table
it may not read answers `200` with count `0`, which looks the same as an empty
table. For a scope count it cannot tell empty from hidden, so it was not used.

| Route | Status |
|---|---|
| Cloud SQL editor, for counts | ✅ **works**, 15 Sep 2026. It reads `public`, `auth`, `storage`, `cron` and `supabase_migrations`, and exports results as CSV (`query-results-export-*.csv`). Three queries, printing only names, numbers and URLs with any query string stripped, never values |
| Cloud SQL editor, for the copy | ✅ **chosen** 15 Sep 2026, as JSON, below |
| Cloud Export data | not used. It would write an export file holding all HR data into Cloud storage, allows one export every 24 h, and leaves passwords out |
| Direct Postgres / service-role key | not documented as available |

### Choosing how to copy: ✅ decided 15 Sep 2026, the SQL editor as JSON

**The SQL editor, one JSON document per table**, for the rehearsal (step 5) and
again at cutover (step 10). *Export data* is not used. The deciding reasons, from
the table below:

- all 40 users keep their passwords, so there is no reset wave and step 9 is not
  forced ahead of the rest
- it repeats on demand
- nothing is written in Lovable Cloud
- JSON imports exactly

The comparison it was chosen from:

| | Export data | SQL editor, one JSON document per table |
|---|---|---|
| Passwords | excluded, per the docs: 40 password resets at cutover, so step 9 (SMTP) must come before step 10 | the editor reads `auth.users`: **40 of 40** users have a bcrypt hash. Hashes copy across unchanged, so logins survive |
| Repeating at cutover | once per 24 hours | any time |
| Writes in Lovable Cloud | an export file in Cloud storage | nothing |
| Faithfulness | format not documented | JSON keeps `null`, arrays and `jsonb` exact. The editor's CSV is not fit for data: it uses `;` and writes `NULL` as an empty field |
| Handling | download link by email | HR data and password hashes pass through a browser download on the workstation |
| Unknown | the format; whether `auth` rows are included | whether the editor exports a 2.3 MB cell (`hr_audit_log`, §4). A table can be split by row ranges |

Storage files are a separate path either way. The export excludes them, and there
are only 4 (§3), downloadable from Cloud → Storage.

---

## 3. Scope: snapshot of 15 Sep 2026

From the SQL editor, three queries. The export files are stamped
`2026-09-15_13-03-02`, `13-13-50` and `13-23-30` in local time. **The live app is in use**,
so these counts grow daily. Step 5 compares against a fresh count taken at import
time, not against this table.

| | |
|---|---|
| `public` tables | **180**, the same as `types.ts` and the repo |
| tables with rows | **120**; 60 empty |
| rows in `public` | **11,980** |
| foreign keys | **140** from `public` to `auth.users`, **186** within `public`. Users go in before data |
| rows containing `hwchtywjbmcvpucidfmy` or `lovable.app` | **0**, in all 180 tables scanned. No data carries a Lovable URL across |
| Lovable's migration ledger | **263**, latest `20260914200900`, equal to the repo |
| extensions | `pg_cron` 1.6.4, `pg_net` 0.20.3, `pg_stat_statements` 1.11, `pgcrypto` 1.3, `plpgsql` 1.0, `supabase_vault` 0.3.1, `uuid-ossp` 1.1. No migration creates any; step 4 compares with growth's stack |
| `pg_cron` jobs | **5**, see §1 |

### Auth

| | |
|---|---|
| `auth.users` | **40** (`profiles`: 40) |
| with a bcrypt hash | **40**; with no password: 0 |
| email confirmed | 40 |
| `auth.identities` | **39**, all provider `email`. **1 user has no identity row** |
| MFA factors | 0 |
| banned now | 3; soft-deleted: 0 |
| triggers on `auth.users` | `on_auth_user_created` runs `handle_new_user()`, moved to schema `private` by `20260704144036_*`. `on_auth_user_created_dev_roles` is described in `STACK-PROVISIONING.md` §3.7. Both are enabled, and both fire for every user inserted |
| signed in within 30 days | 5. `last_sign_in_at` changes on sign-in, not on token refresh, so this undercounts active users |

### Storage

| Bucket | Objects | Bytes | Rows that point at it |
|---|---|---|---|
| `admission-payments` (private) | 1 | 224,642 | payment screenshots from `TargetsView` and `PtmUpgradesView`. The one object is named in a row. `success_posts.screenshot_path`: 0 rows |
| `call-audits` (private) | 3 | 3,135,744 | `call_audits.audio_path`: 3 paths, **3 files exist** |
| `chat-attachments` (private) | 0 | | `chat_messages.attachment_path`: 0 of 12 messages set |
| `employee-documents` (private) | 0 | | `employee_documents.storage_path`: **30 paths, 0 files exist** |
| `hr-letters` (private) | 0 | | `issued_letters.pdf_path`: 0 of 6 rows set |
| `lms-media` (private) | 0 | | |
| `org-photos` (private) | 0 | | `org_units.photo_url`, a URL; none contains a Lovable reference |

**4 objects, about 3.4 MB, all named in some row.** Nothing is orphaned.

**All 30 `employee_documents` rows point at files that do not exist, in
production today.** The upload in `EmployeeDocumentsPanel.tsx` writes the file
before the row, so the files were removed afterwards or the rows came from
elsewhere. There is nothing to copy. The rows copy as they are, and the app shows
30 documents that cannot be opened, both before and after the move. That is for
the app's owner, through Lovable, not for this migration.

Largest tables: `dwr_reports` 1128, `inbox_messages` 898, `attendance_days` 877,
`sales_admissions` 870, `efficiency_entries` 723, `activity_sessions` 569,
`hr_audit_log` 552, `follow_up_calls` 520, `employee_holidays` 481,
`approval_history` 479.

`profiles` holds bank account numbers, Aadhaar numbers and salaries, and
`auth.users` holds password hashes. That data arrives on the box in step 5, which
is why step 3 (restricting Studio) comes first. Any file carrying it must be
handled as sensitive and deleted after use.

### Tables with rows (120)

| Table | Rows |
|---|---|
| `activity_sessions` | 569 |
| `appointment_break_windows` | 25 |
| `appointment_share_links` | 25 |
| `appointments` | 364 |
| `approval_delegations` | 2 |
| `approval_history` | 479 |
| `asset_assignments` | 6 |
| `assets` | 6 |
| `attendance_days` | 877 |
| `attendance_regularizations` | 24 |
| `call_audit_clients` | 2 |
| `call_audit_findings` | 24 |
| `call_audits` | 3 |
| `change_requests` | 204 |
| `chat_messages` | 12 |
| `chat_participants` | 24 |
| `chat_receipts` | 12 |
| `chat_threads` | 12 |
| `clearance_template_items` | 88 |
| `clearance_templates` | 11 |
| `content_nodes` | 125 |
| `content_views` | 190 |
| `coupon_bundles` | 1 |
| `coupon_conditions` | 7 |
| `coupon_template_conditions` | 12 |
| `coupon_templates` | 3 |
| `coupon_type_design_defaults` | 6 |
| `courses` | 1 |
| `custom_roles` | 9 |
| `departments` | 10 |
| `discrepancies` | 104 |
| `dwr_deduction_waivers` | 3 |
| `dwr_excuse_requests` | 48 |
| `dwr_field_comments` | 8 |
| `dwr_grace` | 242 |
| `dwr_miss_acks` | 5 |
| `dwr_report_history` | 8 |
| `dwr_reports` | 1128 |
| `dwr_settings` | 10 |
| `dwr_template_fields` | 77 |
| `dwr_template_roles` | 6 |
| `dwr_templates` | 11 |
| `efficiency_entries` | 723 |
| `employee_documents` | 30 |
| `employee_holidays` | 481 |
| `employee_notes` | 28 |
| `employee_perf_snapshots` | 56 |
| `employee_promotions` | 3 |
| `employee_work_days` | 259 |
| `enrollments` | 22 |
| `entry_amendments` | 141 |
| `exit_checklists` | 1 |
| `faqs` | 3 |
| `follow_up_calls` | 520 |
| `glossary_terms` | 5 |
| `help_articles` | 30 |
| `holiday_calendar_days` | 26 |
| `holiday_calendars` | 2 |
| `hr_audit_log` | 552 |
| `inbox_drafts` | 1 |
| `inbox_message_reads` | 2 |
| `inbox_messages` | 898 |
| `inbox_reads` | 2 |
| `inbox_threads` | 66 |
| `issued_letters` | 6 |
| `kb_entries` | 2 |
| `kb_languages` | 2 |
| `leave_encashment_requests` | 3 |
| `leave_requests` | 226 |
| `letter_templates` | 12 |
| `manager_tasks` | 392 |
| `message_group_members` | 10 |
| `message_groups` | 3 |
| `module_acknowledgements` | 1 |
| `node_completions` | 49 |
| `ojt_kpis` | 8 |
| `ojt_pip_milestones` | 12 |
| `ojt_pip_plans` | 3 |
| `ojt_pip_templates` | 2 |
| `ojt_progress` | 63 |
| `ojt_trainings` | 3 |
| `onboarding_checklists` | 40 |
| `org_strength_entries` | 130 |
| `org_units` | 72 |
| `page_blocks` | 140 |
| `price_courses` | 5 |
| `price_list_periods` | 2 |
| `price_seasonal_offers` | 21 |
| `price_slab_history` | 45 |
| `price_slabs` | 90 |
| `profiles` | 40 |
| `prorate_requests` | 4 |
| `ptm_activities` | 260 |
| `public_holidays` | 4 |
| `resignations` | 1 |
| `role_permissions` | 82 |
| `salary_adjustments` | 12 |
| `salary_line_items` | 24 |
| `salary_pl_balance` | 28 |
| `salary_revisions` | 3 |
| `salary_runs` | 2 |
| `salary_settings` | 1 |
| `salary_settlements` | 1 |
| `sales_admissions` | 870 |
| `sales_target_history` | 108 |
| `sales_targets` | 60 |
| `sales_upgrades` | 58 |
| `shift_days` | 35 |
| `shifts` | 5 |
| `slide_templates` | 46 |
| `success_point_reads` | 1 |
| `supervisor_idle_logs` | 98 |
| `titles` | 25 |
| `upgrade_target_history` | 5 |
| `upgrade_targets` | 10 |
| `user_access_flags` | 28 |
| `user_activity_targets` | 31 |
| `user_reporting_lines` | 81 |
| `user_roles` | 79 |
| `week_off_patterns` | 2 |

### Empty tables (60)

`ai_conversations` `ai_messages` `assignments` `attempt_answers` `attendance`
`attendance_time_adjustments` `certificates` `content_audiences`
`content_translations` `coupon_bundle_items` `coupon_conditions_applied`
`coupon_requests` `coupon_type_design_hidden` `coupons`
`course_completion_consents` `dashboard_layouts` `dashboard_user_prefs`
`department_incentive_settings` `dynamic_values` `employee_clearance_items`
`employee_clearances` `employee_document_exceptions` `entry_audit_log`
`hr_staging_users` `inbox_important` `incentive_month_stops`
`leave_accumulation_ledger` `lesson_assets` `lesson_progress` `lessons`
`message_group_departments` `message_group_posters` `message_threads` `messages`
`modules` `ojt_activities` `ojt_checklist_items` `ojt_incentive_rules`
`ojt_plan_checklist_items` `ojt_plans` `ojt_signoffs` `ojt_targets`
`pending_payouts` `price_announcements` `programs` `question_options`
`review_edit_requests` `review_meeting_participants` `review_meetings`
`salary_audit_log` `sales_knowledge` `schedules` `success_posts`
`success_reactions` `target_min_requests` `tech_meetings` `test_attempts`
`test_questions` `tests` `thread_participants`

---

## 4. Size of a JSON copy: 15 Sep 2026

`length(to_jsonb(row)::text)` summed per table. That counts characters.
Non-Latin text takes more bytes than that, and the app is bilingual.

| Table | Rows | JSON characters |
|---|---|---|
| `hr_audit_log` | 552 | 2,302,996 |
| `sales_admissions` | 870 | 1,257,727 |
| `dwr_reports` | 1128 | 862,468 |
| `attendance_days` | 877 | 485,826 |
| `inbox_messages` | 898 | 390,903 |
| `manager_tasks` | 392 | 365,441 |
| `activity_sessions` | 569 | 311,200 |
| `efficiency_entries` | 723 | 292,088 |
| `follow_up_calls` | 520 | 277,521 |
| `appointments` | 364 | 276,435 |
| **all 180 tables** | 11,980 | **9,679,226** (~9.7 MB) |
| `auth.users` | 40 | 51,163 |

Either route can carry this. With one JSON document per table, `hr_audit_log`
becomes a single 2.3 MB cell, and whether the editor exports a cell that large is
unknown. A table that does not fit can be split by row ranges.

---

## 5. Step 2: ✅ done 15 Sep 2026

The route (§2) and the scope (§3) are recorded. Nothing was written anywhere:
three read-only queries in Lovable Cloud's SQL editor, and `git fetch` plus reads
on the workstation.

### What step 5 inherits

**The export queries print data, by design.** Step 2's rule of names and
numbers only ends there. Results go to a downloaded file, and are **never pasted
into chat**.

**The download holds secrets.** It carries HR data (`profiles`: bank accounts,
Aadhaar, salaries) and 40 bcrypt hashes, and would show them in the editor's
result grid. That conflicts with "never let a secret reach the screen". A shape
to test in step 5, **not verified**:

- the source has `pgcrypto` 1.3, so each JSON document can be encrypted inside
  the query with `pgp_pub_encrypt`, using a public key generated on the server
- the grid and the download then hold only ciphertext
- the private key never leaves the server and stays root-only

**Getting the file to the server.** It goes through cPanel File Manager, so it
lands under `/home` first. Move it root-only at once, and delete every copy after
the import: the workstation's, the one under `/home`, and the server's.

**Order and IDs.**
- Users go first, with original IDs: selected columns of `auth.users`, then
  `auth.identities`. 140 foreign keys from `public` point at them.
- Both `auth.users` triggers fire on insert (§3), and 1 user has no identity row.
- Then `public` parents first, by the foreign-key graph.

**Around the import.**
- Pause every job in `cron.job` while importing.
- `hr_audit_log` is a 2.3 MB document, and may need splitting by row ranges.
- Take fresh row counts in the source at export time, and compare them after the
  import. §3 is a snapshot, not the target.
- Storage is 4 files (§3), downloaded from Cloud → Storage.

### Found on the way, for the app's owner (through Lovable)

- `escalate-stale-approvals` failed every hour, because `change_requests` has no
  `user_id`. ✅ **Fixed by Lovable on 15 Sep** in `20260915081117_*`, and
  confirmed by the 08:15 UTC run: 108 stale approvals flagged once each (§1).
- All 30 `employee_documents` rows point at files that do not exist (§3).
- `dwr-shift-cutoff-nudge` exists only in the database, not in any migration
  (§1).

---

## 6. Step 4: apply the migrations: ✅ done 15 Sep 2026

### Read on the workstation first: 15 Sep 2026

`git fetch` at ~11:15 UTC: HEAD `df414acf`, equal to `origin/main`, **264**
migrations, newest `20260915081117_*`.

- **Two migrations cannot replay.** `20260726090058_*` and `20260726090647_*`
  seed 8 test accounts (`…@lilbrahmas.local`) with one password written into
  the repo. They attach them by fixed ID to a department (`386ee13b…`), org
  unit, shift, week-off pattern and holiday calendar. No migration creates those
  5 rows: Lovable Cloud got them through the app. `profiles.department_id`
  references `departments` (`20260704130552_*` line 35), so the first insert
  fails. No later migration drops that constraint, and no migration inserts
  any department. ✅ **Decided 15 Sep 2026: skip both**, each recorded in the
  ledger with a note saying it was not run. The reasons:
  - they fail on an empty database
  - they are test data, not schema, and would leave 8 logins with a published
    password
  - step 5 copies the source's real users, these included if they still exist
  - the two later files that name the seed, `20260726093044_*` and
    `20260726111046_*`, only update or copy rows they find, so on an empty
    database they match nothing
- **The other 31 UUID literals** are updates, deletes and lookups of content
  rows. On an empty database they match nothing and do not fail.
- **6 files run `ALTER TYPE … ADD VALUE`**, and none uses the new value in the
  same file. They are applied outside a transaction, as enroll's `deploy.sh`
  (`tx_hostile`) does.
- **61 files insert rows** (`page_blocks`, `content_nodes`, `user_roles`, …).
  Step 5's import meets rows the migrations already put there.
- `crypt` and `gen_salt` appear only in the two seed files. `gen_random_bytes`
  is a column default in `20260704135430_*`, so pgcrypto must resolve at apply
  time.
- Still zero `CREATE EXTENSION` and zero `storage.buckets`. `net.http_post` is
  only in `20260914120009_*`. `cron.` is in 4 files.

### Progress

| Step | What | Result |
|---|---|---|
| 1 | read-only: server checkout, growth health, database state and extensions | ✅ 11:09 UTC. Checkout `c496de2e`, 224 migrations, `dirty: 0`. Growth `11 healthy: 11`. `public tables: 0`, `ledger schema tables: 0`, `buckets: 0`, `auth users: 0`, `cron schema: 0`. `cron.database_name: postgres`. search_path `"$user", public, extensions`, so pgcrypto resolves. `supabase_realtime` publication: 1 |
| 2 | server checkout: `git fetch origin && git merge --ff-only df414acf`, then HEAD, `origin/main`, dirty count, file count and the migrations tree ID | ✅ `head: df414acf origin: df414acf dirty: 0 migrations: 264 tree: f28ddded7cb1`. The same tree ID as the workstation, so the server has the same 264 files byte for byte, and Lovable had pushed nothing newer |
| 3 | host snapshot before the first write: the three reusable checks of `STACK-PROVISIONING.md` §4 in one line | ✅ 12:25 UTC, identical to 08:54. coturn `MainPID=1911360` since `2026-08-26 00:46:34 UTC`; missing `0`; relay `32768 49151`; `REDIRECT 1`; `removed: 0 added: 25 added-not-on-growth-bridge: 3` with the three loopback `DROP` lines; networks `bridge,enroll_default,growth_default,host,none`; enroll `11 healthy: 11`, API `401`. Growth `11 healthy: 11`; `iptables changes since the preproxy copy: 0`; `growth listeners: 3 of 3` on `127.0.0.1` |
| 4 | `CREATE EXTENSION pg_cron` (no `IF NOT EXISTS`, `ON_ERROR_STOP`), then facts only | ✅ ~12:30 UTC. `CREATE EXTENSION`; `pg_cron: 1.6.4@pg_catalog`, the source's version; `cron tables: 2`; `cron jobs: 0`; `postgres usage on cron: true`; `scheduler processes: 1`; `public tables: 0`. `postgres superuser: false`, as on hosted Supabase, where Lovable's migrations also run as `postgres`. No config change, no restart. Rollback while no job exists: `DROP EXTENSION pg_cron` |
| 5 | script uploaded through cPanel File Manager to `/home/growthlilbrahmas/`, then `test ! -e` target `&&` `mv` to `/root/growth-apply-migrations.sh` `&&` `chown root:root` `&&` `chmod 700` `&&` size, CR count and an `awk` sha256 comparison | ✅ 12:30 UTC. `-rwx------ root root 11748`; `lines: 236 bytes: 11748 CR bytes: 0`; `sha256 matches workstation: yes` |
| 6 | `bash /root/growth-apply-migrations.sh --plan` | ✅ 12:32:45 UTC, exactly as expected: `checkout: tree f28ddded7cb1, 264 files, clean`; `database: pg_cron installed, public tables 0, ledger rows 0`; `pending: 264 = atomic 256 + not atomic 6 + skipped 2`; the six not-atomic versions and the two to skip, as on the workstation; `plan only: nothing written` |
| 7 | `bash /root/growth-apply-migrations.sh --apply` | ⚠️ 12:34:40 UTC. Files 1–25 applied and ledgered (one of them, `20260705104630`, not atomic). **File 26, `20260705175005_*`, failed and was rolled back:** `insert or update on table "kb_entries" violates foreign key constraint "kb_entries_department_id_fkey"`, `Key (department_id)=(54c8a7ba-54bd-4c92-8db7-30e3e378c618) is not present in table "departments"`. The script stopped as designed. Nothing from file 26 applied |
| 8 | v2 uploaded through File Manager, then: installed sha256 must equal v1 (`awk` exit gate) `&&` `\mv` over it (root's `mv` is `mv -i`) `&&` `chown`/`chmod 700` `&&` size, CR count, sha256 against v2 | ✅ 13:11 UTC. `installed file is v1: yes`; `-rwx------ root root 14524`; `lines: 273 bytes: 14524 CR bytes: 0`; `sha256 matches v2: yes` |
| 9 | `--plan` with v2, against the 25 applied | ✅ 13:23:31 UTC, exactly as expected: `public tables 41` (equal to the `CREATE TABLE` count of files 1–25), `ledger rows 25`, `pending: 239 = atomic 227 + not atomic 5 + schema lines only 2 + skipped 5`, and the same three lists as the mock |
| 10 | `--apply` with v2, resuming at file 26 | ✅ 13:24:22 UTC. `h` first, marks where the mock put them, no failure. `NOTIFY pgrst sent`; `pgrst event triggers: 2 of 2`; `this run: atomic 227, not atomic 5, schema lines only 2, skipped 5`; **`ledger rows: 264 of 264, with a note: 7`**; **`public tables: 180`**, the number in `types.ts`; `done: every migration is in the ledger`. Cron jobs: 1 `escalate-stale-approvals` `15 * * * *`, 2 `auto-generate-leave-delegations` `30 0 * * *`, 4 `renew-monthly-incentive-plans` `35 0 * * *` (jobid 3 went when the second of its two migrations re-created it), all `calls lovable.app: false`; **5 `attendance-roll-day` `15 19 * * *`, `calls lovable.app: true`** |
| 11 | `cron.unschedule('attendance-roll-day')`, then counts and names only | ✅ ~13:35 UTC, well before its 19:15 run. `unscheduled: true`; `jobs: 3, calling lovable.app: 0, using net.http: 0`; jobs 1, 2 and 4 as above; `runs so far: 0`; `pg_net queued: 0, responses: 0`, so nothing was ever sent to Lovable's app. Unscheduled rather than repointed: step 7's host cron over loopback replaces it (and `dwr-shift-cutoff-nudge`), there is no app on the VPS to call before step 6, and the database container cannot reach the host's loopback |
| 12 | one `INSERT` of the 7 buckets into `storage.buckets`, the source's settings (§1); then each bucket's settings and the `storage.objects` policies naming it; then `GET /storage/v1/bucket` on `127.0.0.1:8010` with the service key and with the publishable key, keys read from `.env` into the header | ✅ `INSERT 0 7`. All 7 `public false`, `mime any`, `limit none`, except `call-audits` `limit 52428800`. Object policies naming each: `admission-payments` 5, `call-audits` 3, `chat-attachments` 3, `employee-documents` 4, `hr-letters` 4, `lms-media` 4, `org-photos` 4. Storage API with the service key lists all 7; **with the publishable key `[]`**, so the buckets cannot be listed with the key that ships in the browser |
| 13 | schema against `types.ts` at `df414acf`: the same name list built from growth's database (`table:`, `col:`, `func:` for `public`; tables and partitioned tables; live columns; functions excluding trigger and event-trigger functions), `LC_ALL=C sort -u`, saved to `/root/growth-schema-fingerprint.txt`, and sha256 prefixes compared with the workstation's, tables+columns (`fd53a079ac32dee1`) and functions (`9cc3ef066d7de79e`) separately | ✅ `server: table 180 col 2294 func 77`; **`tables+columns match types.ts: yes`**; **`functions match types.ts: yes`**. Every table, column and function name that Lovable's generator sees in production exists on growth, and nothing extra, despite the 5 files skipped and 2 cut |
| 14 | enroll's RLS audit (tables with RLS off or no policy, with `anon` / `authenticated` `SELECT`) and GRANT audit (tables `service_role` cannot `SELECT`), with totals | ✅ **`public tables: 180, rls on: 180`**, `rls forced: 0`. **`rls audit rows: 0`**: every table has RLS on and at least one policy. **`grant audit rows: 0`**: `service_role` reaches every table. No exceptions to write down |
| 15 | nothing disturbed: the reusable host check, growth health, the checks through the proxy, and the firewall against the preproxy copy, as in step 3 | ✅ 13:38 UTC, identical to 12:25. coturn `MainPID=1911360` since `2026-08-26 00:46:34 UTC`; missing `0`; relay `32768 49151`; `REDIRECT 1`; `removed: 0 added: 25 added-not-on-growth-bridge: 3` with the three loopback `DROP` lines; networks unchanged; enroll `11 healthy: 11`, API `401`. Growth `11 healthy: 11`; GoTrue `[200]`; `websocket: 101 after 5.000896s`; Studio `HTTP/2 403`, `studio header lines: 1`; `iptables changes since the preproxy copy: 0`; the three listeners on `127.0.0.1` (the pasted last line lost its final `3`, a copy drop) |

**What the audits do not prove.** They show every table is guarded and
reachable by the server. They do not show each policy is *right*: a policy
granting too much still passes. Step 10 checks from outside, with the
publishable key taken from the deployed app, that protected tables return `[]`.
`rls forced: 0` means the table owner (`postgres`) bypasses RLS. That does not
affect `anon`, `authenticated` or `service_role` through the API, and it is
Lovable's shape in production too.

### Step 4 is complete

**Done when** every migration is in the ledger, the schema matches `types.ts`,
and both audits pass or their exceptions are written down. All three hold:
- `ledger rows: 264 of 264`, 7 of them with a note
- tables, columns and functions match `types.ts` by name
- RLS audit 0 rows, GRANT audit 0 rows

Also done in this step:
- **Extensions:** `pg_cron` 1.6.4 created, so growth now has the source's
  seven extensions at identical versions. `pg_net` 0.20.3 was already there.
- **`attendance-roll-day`:** unscheduled before its first run, and `pg_net`
  never queued a request.
- **Buckets:** the 7 private buckets exist, with the source's settings.
- **Host:** enroll and coturn undisturbed.

**Not done here, by design:** `dwr-shift-cutoff-nudge` and
`attendance-roll-day` are replaced by step 7's host cron over loopback. Until
then neither hook runs on the VPS, which matters only once users move (step 10).

**Left on the server:**
- `/root/growth-apply-migrations.sh` (v2, sha256 `8e628675…6c31f51`), the record
  of what ran
- `/root/growth-schema-fingerprint.txt`, names only
- `/opt/supabase/stacks/growth/.migrations.lock`, empty, the script's lock

Growth's script writes no `.applied-migrations` mirror. The ledger is only in
the database.

### What later steps inherit from step 4

- **Step 5, rows already present.** 61 migrations insert rows (`page_blocks`,
  `content_nodes`, `user_roles`, `dwr_templates`, `price_*`, …), so the import
  meets rows it did not bring. Count rows per table before importing. Parents
  first with IDs kept will collide with these seeds unless they are cleared or
  replaced.
- **Step 5, the source's content arrives by import.** That covers everything
  the 5 skipped and 2 cut statements would have written: the `kb_entries` row,
  training pages and blocks, and DWR template fields.
- **Step 5 (and 10), the test accounts.** The 8 test accounts
  (`…@lilbrahmas.local`) are not on growth. If the source still has them,
  importing users brings them with whatever password they have, possibly the
  one written in the repo. Decide before importing. Checking by count only,
  without printing anything, is possible in the SQL editor with
  `crypt(<password>, encrypted_password) = encrypted_password`.
- **Step 5, cron jobs.** Three jobs are active against empty tables:
  `escalate-stale-approvals` (hourly at :15), `auto-generate-leave-delegations`
  (00:30) and `renew-monthly-incentive-plans` (00:35). Pause them for the
  import, as planned.
- **Step 6, the ledger.** `deploy-growth` takes over
  `supabase_migrations.schema_migrations`: enroll's columns plus `note`, keyed
  on the timestamp prefix. The first migration after `df414acf` is its first
  real apply.
  - Each new migration can carry the same two problems found here: content
    against production rows, and a `cron.schedule` that calls `lovable.app` or
    `net.http`.
  - After every apply, `deploy-growth` should print `cron.job` rows calling
    `lovable.app` or `net.http`, and stop unless the count is 0.
- **Step 7, the hooks.** Host cron for `attendance-roll-day` (daily 19:15 UTC,
  00:45 IST; the route defaults to yesterday in IST) and `dwr-nudge` (every 15
  minutes), over loopback.

### Migrations that depend on production rows (found after step 7)

**Root cause.** Some of Lovable's migrations also edit content: knowledge-base
entries, training pages, DWR template fields. Those edits point at rows that
were created in production through the app, not by any migration. On an empty
database the foreign key refuses them.

**The workstation scan missed this one.** It classified each UUID by its
*first* use, and `54c8a7ba…` is first used inside a function body. Every use of
every UUID literal was then reviewed, along with name-based lookups
(`SELECT id INTO … WHERE code/name/title …`):

| File | Schema in it | Fails on an empty database because |
|---|---|---|
| `20260705175005_*` | yes: creates `kb_languages`, `kb_entries` (lines 1–62) | `kb_entries` insert → department `54c8a7ba…` |
| `20260707153842_*` | none | 9 pages inserted under content node `50fb8694…` (`content_nodes.parent_id` has a foreign key) |
| `20260707163251_*` | none | `page_blocks` inserted for 11 fixed page IDs listed in the query (`page_blocks.node_id` is `NOT NULL` with a foreign key) |
| `20260707175304_*` | none | pages inserted under content node `f0ee2a18…` |
| `20260726090058_*`, `20260726090647_*` | none | test users → department `386ee13b…` and others. Already skipped |
| `20260726155545_*` | yes: one `ALTER TABLE` adding two columns (lines 1–6) | 14 `dwr_template_fields` rows → template `144d3aa2…` |

Checked and **harmless** on an empty database: `20260705122903_*` (no
`content_nodes` row exists yet to update), `20260706002555_*` (it creates the
`price_courses` it looks up, earlier in the same file), `20260721154237_*` (a
missing calendar gives `NULL`, and the column allows it), `20260726093044_*`,
`20260726111046_*` and `20260730190948_*` (they update or copy rows they find),
and `20260721093141_*` (settings, a template and its fields for each existing
department: none exists yet).
All other UUID uses are updates, deletes or `WHERE` clauses.

What these statements would have written is already in the source database, and
step 5 copies all 180 tables. A static review can still miss a case. The apply
stays safe if it does: each file rolls back on its own, and a re-run resumes.
✅ **Decided 15 Sep 2026: skip the data, keep the schema.**
- **The three content-only files** (`153842`, `163251`, `175304`) are not run,
  like the two seeds.
- **The two mixed files run their leading schema lines only:** `175005` lines
  1–62 (the two tables, their grants, policies and triggers, and the two
  `kb_languages` rows) and `155545` lines 1–6 (the `computed` columns).
- **In the ledger,** each of the five gets a row with the whole file's checksum
  and a note saying what did not run.

Nothing is invented, and step 5 brings the real content. The alternative,
copying the missing rows from Lovable Cloud ahead of each file, was rejected: a
department, 2 content nodes, 11 pages and a template, plus whatever those need in
turn, all to be overwritten at step 5.

**Boundaries checked in the committed files** (`git show df414acf:…`, LF):
- `175005`: line 61 ends the `kb_languages` insert, line 62 is blank, line 63
  starts the `kb_entries` insert. All 15 schema statements are in lines 1–62,
  none after.
- `155545`: line 5 ends the `ALTER TABLE`, line 6 is blank, line 7 starts the
  content comment. Its one schema statement is in lines 1–6, none after.
- The three skipped files contain no schema statement.

**Script v2.** `SKIP` becomes a list with a note per file (5), and a new
`HEAD_LINES` list with `HEAD_NOTE` runs the leading lines of the 2 mixed files.
For those two, the plan refuses a missing note, a file not longer than its cut,
or a statement that cannot run in a transaction. The progress marker for the
two is `h`. 273 lines, 14,524 bytes, LF, ASCII only, sha256
`8e6286756022f1d539c91ce15299363feea56a2d03b2bf529e97bdd8d6c31f51`.

**Mock-tested, 15 Sep 2026.** The fake started from the server's state (a ledger
of the first 25 files). It refused any statement containing text unique to one
of the five cut content statements, each string checked to occur only in its
own file:

| Case | Result |
|---|---|
| plan from 25 applied | `pending: 239 = atomic 227 + not atomic 5 + schema lines only 2 + skipped 5` |
| plan from empty | `pending: 264 = atomic 251 + not atomic 6 + schema lines only 2 + skipped 5` |
| a cut longer than its file · a mixed file without a note | `STOP` for each |
| `155545`'s schema lines fail | `FAILED, schema lines only`, `STOP … rolled back`, ledger 199 |
| resume to the end | `ledger rows: 264 of 264, with a note: 7`, `done`. The `kb_entries` table and the `computed` columns were each sent once. None of the five cut content statements was sent |
| plan after that | `pending: 0` |

A first mock run with a broader pattern stopped at `20260721093141_*`, which
also inserts into `dwr_template_fields`. That was the fake's pattern, not a
fault, and the file is harmless (above).

**Growth now has all seven of the source's extensions, every version identical.**

**Extensions against the source's seven (§3).** Installed on growth:
`pg_net` 0.20.3, `pg_stat_statements` 1.11, `pgcrypto` 1.3, `uuid-ossp` 1.1 (all
in `extensions`), `supabase_vault` 0.3.1 (`vault`), `plpgsql` 1.0. That is six
of seven, **every version identical**. `pg_cron` is available at 1.6.4, the
source's version, and not installed.

**`pg_net` is installed**, so `attendance-roll-day` as written would POST to the
Lovable-hosted app every night at 19:15 UTC. It must be unscheduled before 19:15
UTC on the day the migrations apply.

The pasted command read `orderby` and `'search_path:'`, yet the query ran and
printed `search_path: ` with its space: copy-only.

### The apply script: `growth/apply-migrations.sh`

Enroll's `deploy.sh` apply logic, trimmed to a build from empty, and pinned to
tree `f28ddded7cb1` and 264 files. `--plan` runs every guard and prints counts,
writing nothing. `--apply` is the real run, and it resumes after a failure. It
refuses to run:
- as anyone but root, or outside project `growth`
- unless growth's `db` is `(healthy)`
- on another checkout, a dirty one, or with a shared timestamp prefix
- without `pg_cron`
- with an empty ledger but tables in `public`
- with a ledger that is not exactly the first N files

The skipped files get a ledger row with a `note`. Error output is shown with
JWTs masked. At the end the script prints each cron job's name, schedule and
whether it calls `lovable.app`, never its command. It stops unless the ledger
holds 264 rows.

Every guard compares against an exact value, so a query that errors cannot pass.
Enroll's `apply-migrations.sh` counted an unreachable database as 0 tables.

**Mock-tested on the workstation, 15 Sep 2026.** A fake `docker` answered the
queries and kept a pretend ledger, against the workstation checkout at
`df414acf`. Every case behaved as designed:

| Case | Result |
|---|---|
| no argument · two arguments | usage, exit 2 · `STOP`, exit 2 |
| plan on an empty database | `pending: 264 = atomic 256 + not atomic 6 + skipped 2`, nothing written |
| `pg_cron` missing · database down · empty ledger with tables in `public` · wrong tree | `STOP` for each, nothing written |
| a not-atomic file runs but its ledger row fails | `STOP … record it by hand` |
| a not-atomic file fails (file 69) | `STOP … may be half applied`, ledger 68, the JWT in the error masked |
| resume, then atomic file 150 fails | resumed at 69; `STOP … rolled back … still pending`, ledger 149 |
| resume to the end | `ledger rows: 264 of 264, with a note: 2`, `done` |
| plan and apply again after that | `pending: 0`, `nothing pending`, exit 0 |
| a ledger row deleted from the middle | `STOP: ledger row 10 is …` |
| one ledger row lost during a run | `STOP: the ledger has '263' rows`, exit 1 |

The first mock run exposed a fault in the fake, not the script: it read three
migrations' own SQL as queries and dropped their ledger rows. The script's
prefix guard caught the gap. The end-of-run count check was added after that
run.

File: 236 lines, 11,748 bytes, LF only, sha256
`42293a6eeb1c82f98227dff8c332c05e78723e5bd1277fe911eecdb2b4024bd1`.
