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
