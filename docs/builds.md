# Build registry

Build entries live as individual files in [`docs/builds/`](builds/).
One file per build, named `<MAJOR>.<BRANCH>.<PUSH>.md`. This file is
the conventions document only — see the directory for the actual
build history.

The latest build number (used by iOS Settings → About and the web
page footer at compile time) is computed as the version-sorted
maximum of the filenames in `docs/builds/`. Lookup logic lives in:

- `ios/scripts/gen-build-info.sh` — embeds into iOS at xcodegen time.
- `web/vite.config.ts` — embeds into the web bundle at compile time.

## Numbering scheme

Format: **`MAJOR.BRANCH.PUSH`**

(Rewritten in Build #6.18.1 to match ~150 builds of actual practice —
the original scheme described MAJOR bumping on every merge, which was
never how the registry was used.)

- **MAJOR** — a deliberate, rare milestone marker, bumped by hand
  when the team decides to (it also doubles as the app's marketing
  version — `CFBundleShortVersionString` was aligned to it at
  Build #6.0.0 / PR #169). It does **not** bump on merges.
- **BRANCH** — the de-facto **build counter**: +1 for each new
  feature branch / PR cut from `main`. It does not reset until the
  next MAJOR bump.
- **PUSH** — `1` on the first push of a branch; +1 for each
  subsequent push to the same branch (so a PR that needed a fix-up
  push goes `N.M.1 → N.M.2`). Most PRs are single-push, which is
  why the registry is dominated by `.1` entries.

### Example timeline (matches real history)

```
5.133.1  ← PR branch, first push
5.134.1  ← next PR branch, first push
6.0.0    ← deliberate MAJOR milestone (marketing-version alignment)
6.1.1    ← next PR branch, first push
6.1.2    ← second push to the same PR branch (fix-up)
6.2.1    ← next PR branch
```

Multiple PR branches may be open concurrently; each takes the next
BRANCH number when its first build doc is created.

## How to add a build

Create a new file at `docs/builds/<N>.<M>.<P>.md` with the section
template below. Don't touch any other entry — the registry is a
directory of independent files now, so multiple open PRs each add
their own file without colliding.

Section template:

```markdown
## Build N.M.P

* **Date:** YYYY-MM-DD
* **PR:** [#NN](https://github.com/murumoto-rgb/Forensic/pull/NN)
* **Branch:** claude/<branch-name>
* **Merge SHA:** ... (filled in after merge; "TBD" while PR is open)
* **Summary:** one-line description.

---
```

The PR number and merge SHA are recoverable from the squash-commit
subject on `main` (`Build #N.M.P: … (#PR)`), so placeholders can be
backfilled mechanically — Build #6.18.1 did exactly that for the
~157 entries that had accumulated `[#XX] (to be assigned)`.

## Conventions for chat

Sessions referencing this registry should state the active build in
each response, in one of two forms:

- **Build #N.M.P (new)** — about to push a commit that creates
  build N.M.P
- **Build #N.M.P (active)** — current/latest build is N.M.P;
  testing or follow-up work in progress
