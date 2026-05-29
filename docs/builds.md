# Build registry

This file is the **source of truth for build numbers**. iOS Settings →
About and the web page footer display the topmost number below at
build time.

## Numbering scheme

Format: **`MAJOR.BRANCH.PUSH`**

- **MAJOR** — incremented on every merge to `main`. The build
  immediately after a merge is `N.0.0`.
- **BRANCH** — incremented when a new feature branch is opened from
  `main`. Resets to `0` on each new MAJOR. The build immediately
  after a branch is created is `N.M.0`.
- **PUSH** — incremented on every commit pushed to the active
  branch. Resets to `0` on each new BRANCH. The build after the
  first commit on a branch is `N.M.1`.

### Example timeline

```
1.0.0   ← initial main
1.1.0   ← open first feature branch
1.1.1   ← first push on that branch
1.1.2   ← second push
2.0.0   ← merge to main (MAJOR bumps, BRANCH/PUSH reset)
2.1.0   ← open next feature branch
2.1.1   ← first push
3.0.0   ← merge
```

Multiple branches under the same MAJOR are allowed in case parallel
work happens (e.g. server + iOS PRs both open before either merges).
The second concurrent branch would be `N.2.0`, third `N.3.0`, etc.

## How to add a build

Insert a new section **at the top** with the next number. The number
is embedded into iOS via `ios/scripts/gen-build-info.sh` and into
web via `web/vite.config.ts` at build time.

Section template:

```markdown
## Build N.M.P

* **Date:** YYYY-MM-DD
* **PR:** [#NN](https://github.com/murumoto-rgb/Forensic/pull/NN)
* **Merge SHA:** ... (filled in after merge; "TBD" while PR is open)
* **Summary:** one-line description.

---
```

## Conventions for chat

Sessions referencing this registry should state the active build in
each response, in one of two forms:

- **Build #N.M.P (new)** — about to push a commit that creates
  build N.M.P
- **Build #N.M.P (active)** — current/latest build is N.M.P;
  testing or follow-up work in progress

---

## Build 3.1.1

* **Date:** 2026-05-29
* **PR:** [#XX](https://github.com/murumoto-rgb/Forensic/pull/XX) (to be assigned)
* **Branch:** claude/local-signout-and-pending-placeholder
* **Merge SHA:** TBD
* **Summary:** Device-local sign-out (web + iOS) so signing out on one platform no longer kicks the other; web shows a "pending upload" placeholder instead of a 404 error for photos whose binaries haven't uploaded from the iPhone yet.

---

## Build 2.1.1

* **Date:** 2026-05-29
* **PR:** [#XX](https://github.com/murumoto-rgb/Forensic/pull/XX) (to be assigned)
* **Branch:** claude/phase-2-c-web-photo-viewer
* **Merge SHA:** TBD
* **Summary:** Phase 2 PR C — web project-detail page with photo viewer. New `/projects/:id` route, photo grid, lightbox modal with keyboard nav, project list rows now clickable.

---

## Build 1.1.5

* **Date:** 2026-05-29
* **PR:** [#23](https://github.com/murumoto-rgb/Forensic/pull/23)
* **Merge SHA:** TBD
* **Summary:** Fix zod validation rejection of distress points. CGPoint encodes as `[x, y]` arrays; relax server zod to `z.array(z.unknown())` and update TS type to `unknown[]`. Distress-on-web Phase 3 will land structured `{ x, y }` encoding.

---

## Build 1.1.4

* **Date:** 2026-05-29
* **PR:** [#23](https://github.com/murumoto-rgb/Forensic/pull/23)
* **Merge SHA:** TBD
* **Summary:** Restructure build-number scheme to `MAJOR.BRANCH.PUSH` per project preference.

---

## Build 1.1.3

* **Date:** 2026-05-29
* **PR:** [#23](https://github.com/murumoto-rgb/Forensic/pull/23)
* **Merge SHA:** TBD
* **Summary:** Add Build # tracking system (initial flat numbering).

---

## Build 1.1.2

* **Date:** 2026-05-29
* **PR:** [#23](https://github.com/murumoto-rgb/Forensic/pull/23)
* **Merge SHA:** TBD
* **Summary:** Push all local manifests before photo upload at launch (404 storm fix).

---

## Build 1.1.1

* **Date:** 2026-05-29
* **Branch:** claude/push-before-photosync (initial creation)
* **PR:** [#23](https://github.com/murumoto-rgb/Forensic/pull/23)
* **Merge SHA:** TBD
* **Summary:** Branch opened from main.

---

## Build 1.0.0

* **Date:** 2026-05-28
* **Summary:** Initial baseline — current state of `main` at the time the build registry was introduced. Predates the per-build numbering system.

---
