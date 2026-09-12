# iOS app workflow and release handoff

Read for app development, device testing or release work, as routed by AGENTS.md.

## Session conventions

Durable rules for how Claude operates in this repo, captured so
they survive across sessions instead of being re-explained each
time. Authorized by the user in chat on 2026-05-30.

### Local repo path on the user's Mac

The user keeps the working clone at `~/Developer/Forensic`. Every
pull/build one-liner included in a chat reply must start with
`cd ~/Developer/Forensic && …` — do not guess `~/Code/Forensic`,
`~/Projects/Forensic`, or any other path. If the user moves the
clone, the new path lands here in a follow-up PR.

### Auto-subscribe to PR activity

For app PRs, use `subscribe_pr_activity` when that provider capability is
available. Documentation-only PRs do not require a subscription. If unavailable,
verify checks during the current task and report any remaining monitoring limit. Subscribing means Claude
auto-reacts to CI failures and review comments without the user
having to flag them. This is a standing rule; the user does not
need to repeat the request per PR.

### Every chat response

For app build/test handoffs, provide the following when applicable.
Documentation-only changes need the PR link and validation summary instead:

1. **Lead with the build annotation** — `Build #N.M.P (new)`
   when the response is about to push a commit creating that
   build, or `Build #N.M.P (active)` when no push is happening
   but the response references the latest build.
2. **Include the pull + build terminal one-liner** when a PR is
   pushed in the turn, so the user can paste it straight into
   Terminal:
   ```
   cd ~/Developer/Forensic && scripts/sync-ios.sh <branch>
   ```
   (Earlier sessions used the longer
   `git fetch && git checkout && git pull && ./ios/scripts/regen-project.sh && open …`
   form; that still works, but `scripts/sync-ios.sh` shipped in
   #27 and is the canonical one-liner now.)
3. **Direct GitHub comment URL** for every checklist or self-test
   report posted in the turn — link to the specific comment
   (`#issuecomment-<id>`), not just the PR.

### Flag non-main branch choices explicitly

Whenever a reply asks the user to pick a branch — Xcode Cloud
manual Start Build, `scripts/sync-ios.sh <branch>`, "which
branch should I push to," etc. — call out the choice explicitly
if the answer is anything other than `main`. Example:

> Pick `claude/<branch>` here, **not** `main` — this PR is still
> open and main doesn't have the fix yet.

Default expectation: builds and deploys target `main`. Anything
else needs the explicit nudge so the user notices.

### Selective merging to main

PRs do not auto-merge on green CI. For app changes, the default is **branches
stay open** while the user iterates with
`scripts/sync-ios.sh <branch>` for tight-loop testing. Merge to
`main` happens when one of these is true:

1. A big task or phase is complete (multiple PRs' worth of work
   that belong together).
2. The user explicitly asks to ship the change.

Documentation-only PRs follow AGENTS.md's completion rule and may merge after
applicable checks; no device or TestFlight gate applies.

**Merging is just promote-to-main, NOT a TestFlight delivery.**
As of Build #5.24.1 the Xcode Cloud workflow's start condition is
"Tag Changes matching `ios-release*`" — there is no automatic
trigger on push to main any more. A merge gets the change onto
Vercel (web) and into Render's next deploy (server), but the
iPhone keeps running whatever TestFlight build it was already on
until the user explicitly fires a new one.

TestFlight is triggered by the user in one of two ways:

- App Store Connect → Apps → Forensic → Xcode Cloud → that
  workflow → **Start Build** → pick a branch.
- `git tag ios-release-<n> && git push origin ios-release-<n>`
  (the canonical way to make the shipped build identifiable in
  the repo history; preferred for actual release milestones).

So a typical iOS change cycle is now: open PR → iterate on
branch via `scripts/sync-ios.sh <branch>` for laptop builds →
merge when correct → **separately decide** whether/when to push
a new TestFlight build. Web/server-only changes need no
TestFlight step at all.

Practical implications:

- **Multiple concurrent open PRs are normal.** Don't pressure
  the user to merge "to clean up the queue."
- When `main` does move (because another PR merged), preemptively
  rebase the other open branches and resolve
  `docs/builds.md` conflicts — same dance documented during
  Builds #4.1.1 through #4.5.1. The user shouldn't have to
  notice the conflict before you fix it.
- Iterative testing of an unmerged PR uses
  `scripts/sync-ios.sh <branch>` or `--pr <N>`, not Xcode Cloud
  (Xcode Cloud is the laptop-free TestFlight path; burning its
  25 free hrs/mo on unmerged branches is the wrong trade).
- When the user merges a web-only or server-only PR, do NOT
  prompt them to start a TestFlight build — there's nothing iOS
  to ship. Only suggest a TestFlight build when an iOS-touching
  change has just merged AND the user hasn't already indicated
  they'll ship later.
