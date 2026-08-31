# Operating the Forensic API on Render Free

Build 6.38.5 keeps `render.yaml` on `plan: free`. No paid compute,
workspace upgrade, new service or autoscaling is required by this patch.
The owner selected the existing plan after reviewing the release candidate.

## What Free can and cannot promise

The core API stores manifests in Supabase and sends normal photo uploads
directly to R2. Intermittent single-person use is a reasonable Free-plan
target. This is not a measured guarantee that every project or report fits
the 512 MB instance. Large Chromium PDF exports remain the main risk;
use smaller selections or the existing native iOS PDF exporter when needed.
No report content, image quality, export option or feature is disabled here.

Render provides 750 running hours **per workspace**, shared by Free web
services, each calendar month. One service running continuously for 31 days
uses 744 hours; multiple services can exhaust the allowance sooner. A code
optimization cannot refund already-consumed hours. Quota suspension lasts
until the next monthly reset unless the service is upgraded. Bandwidth and
build minutes have separate allowances and must be checked independently.
See [Render Free limits](https://render.com/docs/free).

The service sleeps after 15 minutes without inbound traffic and can take
about a minute to wake. Accept that delay; do not reinstate scheduled HTTP
pings just to keep the Free service awake. `keepalive.yml` is manual-only;
Render's deployment healthcheck is unchanged. The separate daily Supabase
workflow does not wake Render. Check its actual GitHub enabled state rather
than assuming that a YAML schedule is running.

## Idle work and export behavior

- Each of the three export workers waits for its previous tick to settle.
  It polls after 5 seconds initially, then backs off through 10, 20, 40 and
  60 seconds while idle or failing. Claimed work resets the delay to 5 seconds.
- At the settled idle cadence, this is roughly 180 queue scans/hour across
  three continuously awake workers, versus 2,160 before (about 92% fewer).
  This arithmetic is not a measured provider bill or app-latency benchmark.
  New export jobs can wait up to 60 seconds for discovery after idle.
- Chromium closes after every successful or failed PDF job. Page/browser
  cleanup has a five-second deadline; a stuck browser is terminated only
  through the Puppeteer-owned child handle. It is never the user's browser.
- Existing image, HTML, PDF and admission limits remain unchanged. The
  workers are independent; there is no new global export semaphore or
  execution lease. Arbitrary process restarts can still interrupt a running
  export. Check its status before deliberately retrying; this patch does not
  claim transparent restart recovery or bounded total process RSS.

## Controlled release without paid maintenance mode

Render's managed maintenance feature is paid-only. The repository includes
`server/maintenance.mjs`, a standalone Node entrypoint with no application,
database, object-storage, authentication, or worker imports. From the repo
root, its temporary Render start command is:

```sh
node server/maintenance.mjs
```

Only GET/HEAD on `/healthz` return 200, with `status: "maintenance"` and
the Render commit SHA. Every application path and mutation method returns
503 with no-store and Retry-After headers. This 200 proves only that the
barrier listener is ready, not that the normal API/database is ready.

1. Wait until the provider permits deployment again. Do not apply feature
   migrations while relying on temporary quota suspension to block old code.
2. Pause automatic release coordination and temporarily deploy the exact
   reviewed candidate with the maintenance start command, against the old
   schema. If this uses the still-unmerged candidate branch, explicitly record
   that non-main source choice. Confirm the serving maintenance SHA, 503s on
   application paths, and termination of all old application instances/workers.
3. Allow old in-flight work to finish or be accounted for; wait at least
   15 minutes after the last possible legacy upload URL issuance, plus any
   transfer still in flight. Refresh backup fingerprints if old writes resumed.
4. Apply only the missing migrations 0016–0019 in order while the barrier
   is held. Follow `server/RECOVERY.md` for the existing release checks.
5. Restore the normal start command (`pnpm --filter @forensic/server start`)
   only for the matching reviewed API, and coordinate the matching web/iOS
   clients before reopening uploads. Verify normal `/healthz` SHA/schema,
   authorization, immutable upload and export failure behavior. Record merge,
   production and Apple/TestFlight readbacks separately.

The maintenance entrypoint is tested on loopback with no application
credentials. Its actual Render deployment and old-instance termination
must still be verified at cutover. A successful test, changed start command
or green healthcheck alone is not evidence that the old instance stopped.

Do not roll back to writable `aa1a24e` after migration 0017. If release fails,
retain maintenance, backups and object bytes and use a compatible forward fix.
This procedure does not change billing or reset a provider quota.
