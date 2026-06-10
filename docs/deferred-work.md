# Deferred work

Items intentionally postponed. Each entry records the idea, why it's
deferred, and what it would take so a future session can pick it up
without re-deriving the context.

---

## Cloud-first storage (offload projects to R2, download on demand)

**Status:** Deferred. Hybrid local-first model is the current
shipped behaviour and is the intended steady state for now.

**Idea (user request, 2026-06-06):** Let a project's photo / plan
binaries live permanently on Cloudflare R2 and NOT require a full
local copy on the phone. Local disk becomes a size-capped cache;
"offload project" frees local space while keeping the manifest;
tapping a project (or a specific photo / plan) re-fetches binaries
on demand.

**Why deferred:** The hybrid model — local disk is source of truth,
iCloud Drive is an optional backup, R2 is the upload sink + backfill
source for new devices — gives most of the safety net without the
UX disruption of an on-demand fetch model. Cloud-first is a
Phase 5/6 effort once the team is comfortable with the backend
being authoritative.

**What it would take (rough scope, ~1–2 weeks):**
1. **Lazy fetch** — replace eager `BinaryBackfillService` with an
   on-demand `BinaryCache` exposing `async bytesForPhoto(...)` /
   `bytesForPlan(...)` that downloads-or-returns-cached. Every UI
   surface that reads a file (grid thumb, lightbox, plan viewer,
   PDF export) routes through it.
2. **Cache management** — LRU eviction with a configurable cap
   (e.g. 5 GB), surfaced in Settings → Storage with a
   "Used: X / cap" bar + "Free cache" button.
3. **Offload action** — per-project "Offload binaries" (delete
   local files, keep manifest) + per-project "Download all"
   (pre-warm before going off-grid).
4. **UI fallbacks** — placeholder + spinner for not-yet-downloaded
   items; error + retry for failed fetches.
5. **Offline capture** — capture stores locally, manifest sync +
   upload deferred and retried on connectivity.
6. **PDF export** — currently assumes all binaries on disk. Either
   download-then-export, or lean on the server-side PDF path
   (Sprint E2 groundwork in the AI-tagging plan partly anticipates
   this).
7. **Backup-story messaging** — today the iCloud Drive folder is a
   usable archive; cloud-first moves that archive to R2, so the
   user-facing "where is my work safe" copy needs updating.

**Trade-off summary:**

| | Hybrid (current) | Cloud-first |
|---|---|---|
| Offline use | Full | Partial (cached only) |
| Phone storage | Grows with usage | Capped by cache limit |
| New device | Backfill loops everything in | Empty cache, fills on use |
| Network needed | Only for upload | For most viewing too |
| Mental model | "My phone has my work" | "My team server has my work" |
| Cost | shipped | ~1–2 weeks |

Infrastructure already in place that makes this tractable when
wanted: R2 storage, `BinaryBackfillService` download path,
presigned GET URL endpoints (`/v1/projects/:id/photos/:id/image`,
`/plans/:id/image`).

---

## Pre-launch checklist (revisit before wide rollout)

A small list of "good now, must-have before more users" items. Triggered
when the team is about to onboard a meaningful number of users (rough
threshold: ~10 daily active web users, OR opening up to non-engineer
office staff who can't debug their own browsers).

### 1. Sentry (server + web error reporting)

**Status:** Skipped during the #5.55.1–#5.64.1 ops setup
(2026-06-06). The plumbing is in: `server/src/sentry.ts` +
`web/src/lib/observability.ts` both already conditionally
init on `SENTRY_DSN` / `VITE_SENTRY_DSN`. When either env var is
blank (current state), every helper no-ops cleanly.

**Why deferred:** With 1–3 users and the engineer watching Render's
Logs tab directly, Sentry's value-add (cross-user grouping,
breadcrumbs, release tagging) doesn't pay for the account-management
friction yet. Render's built-in logs + Resend lock-takeover emails
cover everything user-visible.

**What it takes when ready (~5 min total):**
1. sentry.io → sign up → create TWO projects: one **Node.js**
   ("forensic-server"), one **React** ("forensic-web"). Their
   pricing flow pushes a 14-day Business trial; ignore it — the
   permanent free **Developer** plan (5K errors/mo, 1 user) is
   reached by either letting the trial lapse or finding
   "Switch to Developer" in account settings.
2. Render → `forensic-server` → Environment → add `SENTRY_DSN`
   with the Node.js project's DSN. Save → redeploy.
3. Vercel → `forensic-web` → Settings → Environment Variables →
   add `VITE_SENTRY_DSN` with the React project's DSN. Save →
   redeploy.
4. Optional: also add `VITE_POSTHOG_KEY` + `VITE_POSTHOG_HOST` at
   the same time for product analytics (`web/src/lib/observability.ts`
   already inits PostHog conditionally too).

No code change required.

### 2. Resend domain verification (graduate from `onboarding@resend.dev`)

**Status:** Currently sending lock-takeover emails from
`onboarding@resend.dev` (Resend's sandbox sender). Works, but the
recipient sees `@resend.dev` not a Baykal Consulting domain.

**Why deferred:** No code change required to switch; emails arrive
either way.

**What it takes (~10 min + DNS propagation wait):**
1. resend.com → Domains → Add Domain → enter the chosen domain
   (recommended: a subdomain like `mail.baykalconsulting.com` so
   your existing MX records on the apex stay untouched).
2. Resend shows 3-4 DNS records (SPF, DKIM, optional DMARC). Paste
   them into Squarespace / Cloudflare / wherever DNS lives.
3. Wait ~10 min, click Verify in Resend until all rows show green.
4. Render → `forensic-server` → Environment → change
   `RESEND_FROM_EMAIL` from `onboarding@resend.dev` to a real
   address on the verified domain (e.g.
   `noreply@mail.baykalconsulting.com`). Save → redeploy.

### 3. ~~Tighten lock force-release authorization~~ — CLOSED #6.11.1

**Status:** Done. `POST /lock/force` now requires project Owner or
Org Admin (`isOrgAdmin || isProjectOwner` in
`server/src/routes/locks.ts`) — the same elevated-role rule as
flipping `isFrozen`. Web's LockBanner surfaces the 403 message
instead of silently re-fetching over it. The gate became possible
when roles landed in #5.121–#5.125; #6.11.1 closed the gap.

### 4. Stage / production split

**Status:** One Render service + one Vercel project + one
Supabase project = production-only. Risky once external users are
sending real data.

**What it takes:** Duplicate the three services, point them at a
`staging` branch of the repo, and let `main` deploy to prod only
on tag. ~half day of ops work.

