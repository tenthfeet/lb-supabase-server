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
  Whether growth's stack already has `pg_net` installed has **not been checked**.
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
