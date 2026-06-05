# AI tagging end-to-end verification checklist — 2026-06-04

> Walks Sprints A → E of the AI-tagging completion plan
> (Builds #5.38.1 / #5.39.1 / #5.40.1 / #5.41.1 / #5.42.1 / #5.43.1 /
> #5.44.1 / #5.45.1 / #5.46.1) plus the foundational work this arc
> sits on (#5.32.1 / #5.33.1 / #5.35.1 / #5.36.1 / #5.37.1).
>
> Tick each box you've verified. Write what you saw in the
> `Comments:` line under any item that misbehaved (or any item you
> want to call out for follow-up). Items that don't apply to your
> test data can be marked n/a.
>
> Send the marked-up file back to Claude when done and we'll work
> through anything that didn't pass.

---

## Setup

- [ ] Migration `0005_audit_log.sql` ran cleanly in Supabase;
      `audit_log` table exists with the expected columns.
      Comments: 

- [ ] Render redeploy shows the latest build live on `/healthz`.
      Comments: 

- [ ] Vercel `forensic-web` shows the latest production deploy.
      Comments: 

---

## A. Web admin pages (Sprints D1 + D2)

### Tag library editor (`/admin/tag-library`)

- [ ] Open from project list → "Tag library" button. Page loads
      with your existing library expanded.
      Comments: 

- [ ] Inline-rename a context → "Unsaved edits" pill appears in the
      sticky header.
      Comments: 

- [ ] Add a context → fresh "New context" row appears,
      auto-expanded.
      Comments: 

- [ ] Add a primary tag under it, then a secondary under that.
      Inline-rename both.
      Comments: 

- [ ] Click "Save" → "Saved" pill flashes, revision pill updates.
      Comments: 

- [ ] Click "Discard" with unsaved edits → reverts to last-saved
      state.
      Comments: 

- [ ] Delete the test context you added.
      Comments: 

- [ ] On iOS Settings → AI Tagging → Tag Library, see the changes
      (after launch / sign-in / "Sync now").
      Comments: 

### AI rules editor (`/admin/ai-rules`)

- [ ] Open from project list → "AI rules" button. Textarea shows
      the current template (or empty + amber hint if never pushed).
      Comments: 

- [ ] Edit a line → "Unsaved edits" pill. Save → pill flashes
      "Saved".
      Comments: 

- [ ] Refresh the page → text persists from server.
      Comments: 

- [ ] iOS picks up the change at next sync.
      Comments: 

---

## B. Validator + repair retry (Sprint B)

- [ ] On the floor plan, click any AI-tagged pin. The AI analysis
      viewer's "Validator issues" section renders amber bullets
      when the photo has any `validationErrors`.
      Comments: 

- [ ] Click "Re-tag with AI" on a project with a normal tag
      selection → most often you'll see the green "Tagged" banner
      (no validation issues).
      Comments: 

- [ ] If you see "Tagged after one-shot repair retry" → the model
      emitted a vocabulary slip on the first pass and the repair
      fixed it.
      Comments: 

- [ ] If you see "Tagged with N remaining validation issues" →
      model still emitted problems after the repair; review them
      in the AI analysis viewer's amber bullets.
      Comments: 

---

## C. Suggest / accept / reject + batch (Sprint C)

### Per-photo suggest/accept/reject

- [ ] Re-tag a single photo. The new "Pending suggestions (N)"
      disclosure appears between metadata and AI analysis viewer.
      Comments: 

- [ ] ✓ on a chip → moves to `Photo.tags` (visible in the AI
      analysis viewer's tag tree after refresh).
      Comments: 

- [ ] ✕ on a chip → removed without landing in tags.
      Comments: 

- [ ] "Accept all" / "Reject all" headers work in bulk.
      Comments: 

- [ ] Below-threshold chips dim (opacity 60%) but remain
      actionable.
      Comments: 

### Batch "Re-tag all with AI"

- [ ] On the project detail page, click "Re-tag all with AI".
      Modal opens with model / concurrency / skip-tagged options.
      Comments: 

- [ ] Start → bottom-left sticky progress panel shows
      Preparing → Tagging with the counter incrementing.
      Comments: 

- [ ] Checkpoint saves at ~25 photos show "Saving checkpoint…"
      briefly.
      Comments: 

- [ ] Cancel mid-run → in-flight finish, final save lands,
      "Cancelled" with amber bar.
      Comments: 

- [ ] On done → green "Batch complete. Open each photo's preview
      panel to review pending suggestions."
      Comments: 

- [ ] Open the floor plan → tagged pins all have pending
      suggestions ready to review.
      Comments: 

---

## D. Cost tracking (Sprint E1)

- [ ] After any AI tagging call, open Supabase Table Editor →
      `audit_log`. There's a row per call with
      `event_type = ai_tag_photo`, your user_id, project_id,
      photo_id, model, token counts, duration_ms, and a non-zero
      `cost_estimate_hundred_thousandths_of_cents`.
      Comments: 

- [ ] Sample math: divide
      `cost_estimate_hundred_thousandths_of_cents` by 10,000,000
      to get USD. A typical Sonnet call should land around
      $0.02–$0.05.
      Comments: 

- [ ] After a batch run of N photos, you should see ~N new rows.
      Comments: 

- [ ] iOS-driven AI tagging (when the "Use team server for AI"
      toggle is on) also writes audit rows.
      Comments: 

---

## E. Server-side prompt compilation (Sprint E2)

Verify the new mode is reachable without breaking the existing one.

- [ ] Existing flow (web Re-tag with iOS-style client-driven
      prompt) still works — that's the regression check.
      Comments: 

- [ ] Force server-driven mode by hand:
      ```
      curl -X POST https://forensic-server.onrender.com/v1/ai/tag-photo \
        -H "Authorization: Bearer <jwt>" \
        -H "content-type: application/json" \
        -d '{"projectId":"…","photoId":"…","model":"claude-sonnet-4-6"}'
      ```
      (omit `systemPrompt` + `userText`). Returns the same
      response shape as before.
      Comments: 

- [ ] In Supabase Table Editor → `audit_log`, the rows from these
      curl calls have `detail.serverDrivenMode = true`. The
      web-driven rows have `detail.serverDrivenMode = false`.
      Comments: 

- [ ] Same curl call against a project with **no tagSelection**
      returns `422 no_tag_selection` with the hint message.
      Comments: 

- [ ] Same curl call against an empty server tag library (delete
      the row to test, then re-push from iOS afterwards) returns
      `422 config_missing`.
      Comments: 

- [ ] Half-and-half body (`systemPrompt` present but `userText`
      missing) returns `400 bad_request`.
      Comments: 

---

## F. Confidence threshold (Sprint A3)

- [ ] Slider in the AI analysis viewer's "Tags" header still hides
      below-threshold chips.
      Comments: 

- [ ] Slider value persists across page refresh and syncs
      cross-tab.
      Comments: 

---

## G. Cross-platform parity sanity

- [ ] On iOS: edit Tag Library → see the change land on the web
      admin page (after server sync).
      Comments: 

- [ ] Reverse: edit the web admin page → tag library → save → iOS
      picks it up at next launch / "Sync now".
      Comments: 

- [ ] iOS-tagged photo's `aiAnalysis` (rendered by the web AI
      analysis viewer) shows the same primaries / secondaries /
      confidences iOS would show.
      Comments: 

---

## H. Regressions to spot-check

- [ ] Pin drag → confirm → save on the floor plan still works.
      Comments: 

- [ ] Distress add → confirm → save still works.
      Comments: 

- [ ] Recentre on selected pin (orange pin lands at visible-region
      centre, not in the off-screen-tall portion of the Stage).
      Comments: 

- [ ] Group / All scope toggle in the panel header still works.
      Comments: 

- [ ] Pinch / wheel zoom on the floor plan canvas still works.
      Comments: 

- [ ] iOS device-key AI tagging (Settings toggle OFF) still works.
      Comments: 

- [ ] iOS backend AI tagging (Settings toggle ON) still works.
      Comments: 

---

## Notes

Use this block for anything that didn't fit a row above —
follow-up bugs you'd like filed, UX nits, ideas for Phase 5+.
