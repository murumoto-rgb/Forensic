# Build registry

This file is the **source of truth for build numbers**. Each section
below is one build. The build number embedded in:

- iOS Settings → About row
- Web page footer (bottom-right)

…matches the heading of the **topmost section** in this file (highest
number).

## How to add a build

When shipping a change that produces a new build, insert a new
section **at the top** with the next build number. The build number
gets embedded into iOS via `ios/scripts/gen-build-info.sh` (run by
`regen-project.sh`) and into web via `web/vite.config.ts` at build
time.

Format:

```markdown
## Build N

* **Date:** YYYY-MM-DD
* **PR:** [#NN](https://github.com/murumoto-rgb/Forensic/pull/NN)
* **Merge SHA:** ... (filled in after merge; "TBD" while PR is open)
* **Summary:** one-line description.

---
```

## Conventions for chat

Sessions referencing this registry should state the active build in
each response, in one of two forms:

- **Build #N (new)** — about to ship a change that creates build N
- **Build #N (active)** — current/latest build is N; testing or
  follow-up work in progress

---

## Build 1

* **Date:** 2026-05-28
* **PR:** [#23](https://github.com/murumoto-rgb/Forensic/pull/23)
* **Merge SHA:** TBD
* **Summary:** Push all local manifests to the server before PhotoSyncer at launch (fixes 404 storm on `/files/upload-url` for projects predating Phase 1B-2). Also introduces this build-number tracking system.

---
