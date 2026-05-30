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

## Conventions for chat

Sessions referencing this registry should state the active build in
each response, in one of two forms:

- **Build #N.M.P (new)** — about to push a commit that creates
  build N.M.P
- **Build #N.M.P (active)** — current/latest build is N.M.P;
  testing or follow-up work in progress
