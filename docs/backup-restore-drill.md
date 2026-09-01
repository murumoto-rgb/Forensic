# Backup & restore drill

Recovery procedures for the Forensic stack. Pair with
[the ops runbook](ops-runbook.md) and [the coordinated release gate](../server/RECOVERY.md).

**No completed independent restore drill is recorded below.** Candidate tests
exercise application recovery behavior; they do not certify the deployed
service, a complete device/iCloud copy, or a recoverable off-site backup.
Preserve every available copy before recovery. Never force device sync or
replace a production manifest merely because one copy appears older or newer.

## Copies and their limits

| Data | Possible copies | What must be verified |
|---|---|---|
| Project manifest | Device JSON, Supabase current manifest, candidate version snapshots, optional iCloud files | Schema, revision, completeness, and whether the desired state was preserved |
| Originals, thumbnails, plans and markup | Device files, R2 objects, optional iCloud files | Actual bytes for every referenced filename/object key; a registry row is insufficient |
| Tag library, AI rules, report branding | Supabase `app_config`; some bundled defaults; branding logo object | Defaults do not recover customized settings; copy the logo bytes as well as its reference |
| Accounts, membership, locks and receipts | Supabase database/Auth | Backup scope, roles/grants and supported restoration of authentication data |

Candidate version history is protected application state in the **same live
database and object store**. It is not an independent backup against account
loss, privileged deletion or loss of both services. Incomplete snapshots remain
visible; legacy non-immutable registrations are not certified restorable
history. `audit_log` helps investigate events but is not a full manifest backup
or a replay mechanism.

Device and iCloud copies are potential recovery sources, not proven archives.
The presence of a manifest, thumbnail or iCloud folder does not establish that
all original images, plans and markup are downloadable. Physical-device and
iCloud restore behavior remains unverified until a recorded drill proves it.

## Independent backup requirements

- Free Supabase projects need regular manual exports and off-site backups.
  Paid plans offer daily backups; PITR is a separately enabled paid add-on,
  not automatically included with Pro. Confirm the actual project's plan,
  retention and available recovery points. Supabase project deletion also
  deletes its hosted backups. [Supabase backup documentation](https://supabase.com/docs/guides/platform/backups).
- Preserve a restorable database dump with its required schema, data, grants
  and migration state, using the supported export procedure for the project.
  Inventory any excluded Auth/role/configuration material explicitly. Keep an
  encrypted copy outside the production account and test restoration before
  calling it a backup. Do not print credentials in logs or put dumps in Git.
- Database backups do not contain R2 bytes. Maintain a separate, access-controlled
  object copy outside the production failure boundary, including current and
  retained historical keys plus branding assets. Record key, byte length and a
  checksum computed from copied bytes; the application's declared `sha256` is
  unverified. Do not use a destructive mirror that propagates source deletions.
- R2 does not implement `GetBucketVersioning` or `PutBucketVersioning`; there is
  no S3 bucket-versioning switch to turn on for this recovery plan.
  [R2 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/).
- Coordinate the database and object inventory at a quiescent recovery point.
  Record timestamps, serving build, schema version, copied counts and restore
  results. Storage durability and application immutability do not replace this
  independent copy. Backup automation and retention are not established by this
  document; an operator must verify them before claiming a recovery guarantee.

## Recovery procedures

### A. A field or photo record was overwritten

1. Pause edits to the affected project. Preserve the current manifest/revision,
   relevant version details, audit events and any device copy without syncing it.
2. On the matching candidate release, preview the desired version and its diff.
   A full version restore requires write access, the current expected revision,
   an unfrozen project and every required historical object to pass live checks.
   A missing/unverifiable asset must block restore; do not bypass that refusal.
3. For a single-field repair, compare the preserved copies and review the exact
   change against the latest manifest before saving through the normal API.
   Do not replace the whole manifest to recover one caption.
4. If application history is insufficient, restore an independent database
   backup into an isolated environment and extract the needed evidence there.
   Use PITR only if it was enabled and contains the desired recovery point.

### B. A server manifest is corrupt or unparseable

1. Stop affected writes and preserve the corrupt row and all candidate source
   copies. Do not press "Sync now" to overwrite it, and do not assume the capture
   device is authoritative after later web/device edits.
2. Inspect an independently restored database or preserved device copy offline.
   Validate schema, entity IDs and every binary reference in an isolated copy.
3. Prepare a reviewed repair with the exact target project and revision. A
   production repair requires a separate controlled change and recoverable
   pre-repair copy; this drill does not authorize direct SQL replacement or
   disabling revision/frozen/history safeguards.

### C. An R2 binary is missing

1. Preserve the manifest and registry. On the matching candidate server, run
   project health with `?verify=true`. Distinguish a missing object from an
   unregistered asset, filename mismatch or unavailable storage service.
2. Locate the exact original in an independent backup or a preserved device/
   iCloud copy. Download and inspect that copy without changing the source.
   Do not infer availability from a thumbnail or registry row.
3. Review the selected source and filename before re-uploading through the
   upgraded client's normal immutable upload/commit flow. Recheck byte length,
   health and the resulting complete checkpoint. A new current registration
   does not repair an old snapshot's missing exact object key.
4. If no verified copy exists, record the asset as unrecovered. Do not substitute
   another image, claim a successful restore, or promise automatic repopulation.

### D. Device loss, accidental trash or project deletion

1. Keep surviving devices/copies untouched. In an isolated test installation,
   verify which server or iCloud manifests and binaries can actually be fetched.
   Do not wipe a real device or connect a stale recovery copy to automatic sync.
2. Recover an accidentally trashed project through the supported restore action
   after reviewing the target and current state; do not hand-edit `isDeleted`.
3. Permanent deletion may remove live metadata, history and object bytes.
   Recovery then depends on a verified independent copy. Rehearse any import in
   isolation before planning a production restoration; no automatic import or
   complete fresh-device/iCloud recovery is certified here.

### E. Database or object-store loss

1. Disable mutations and background jobs; preserve surviving data. If legacy
   server uploads were active, stop URL issuance and account for their remaining
   15-minute validity plus transfers in flight before taking a final baseline.
2. Restore the independent database and object copies into isolated replacement
   resources. A surviving `files` registry does not recover missing bytes, and
   database PITR does not restore R2 objects.
3. Compare the restored schema with the migration ledger; apply only reviewed
   missing migrations. Do not replay all migrations blindly over a restored DB.
4. Verify access controls, representative complete assets, historical references
   and the compatible server/client build. Keep original devices disconnected
   from automatic sync until differences are reviewed. Resume production only
   through a separately reviewed cutover; do not let stale devices overwrite
   restored state.

## Isolated drill (proposed quarterly)

Use synthetic projects in a **separate staging database and test-only bucket**,
with isolated credentials and no production device/account connected. A scratch
prefix alone is not protection when a client still points at production.
No destructive drills on real data, production backups or sole surviving copies.

1. Create synthetic originals, plans, thumbnails and both markup kinds; record
   expected filenames, object keys, checksums, revisions and visible content.
   Copy the database and objects to the independent backup destination.
2. Restore those backups into isolated replacement resources. Verify the
   application can read the restored data without access to the original source.
3. On a disposable simulator/test device, check clean-install backfill of every
   asset kind. Test iCloud separately on a dedicated test device/account; do not
   claim that simulator success establishes physical-device or iCloud recovery.
4. Remove only a disposable fixture object. Verify health detects it and restore/
   export fails visibly. Recover from the preserved test copy through the reviewed
   path, then verify actual bytes and the expected checkpoint. Confirm automatic
   sync does not overwrite a conflicting fixture manifest.
5. Test a metadata conflict and version preview/restore with a current revision;
   verify stale revisions, frozen projects and old v4-dropping codecs are refused.
   The candidate returns 426 for legacy uploads and current-v4 writes missing the
   raw checklist/session arrays, even if an old codec echoes schema version 4.
6. If PITR is enabled for the test project, separately test its supported recovery
   workflow on disposable resources. Pro membership alone is not proof of PITR.
7. Record the build, environments, backup timestamp, asset counts, checksum
   results, recovery time and all unresolved failures below. A plan is not a pass.

### Drill log

| Date | Who | Result | Notes |
|---|---|---|---|
| _(none yet — first independent restore drill pending)_ | | | |
