/**
 * Background worker for "Folder by Bucket" exports (Build #5.97.1).
 *
 * Mirrors the iOS `FolderExportRunner` shape: one subfolder per
 * bucket (with `01_`, `02_`, … `99_` numeric prefix matching iOS's
 * sort), full-resolution JPEGs copied bit-for-bit from R2 with
 * EXIF intact, and a `captions.txt` per folder summarizing each
 * photo's metadata.
 *
 * The zip is built **streaming** via `archiver` — we don't
 * materialize the whole zip in memory before uploading. Photo
 * bytes are pulled from R2 via `getObjectBytes`, fed into the
 * archive entry, and the archive's stream is piped into R2 via
 * the s3 client's multipart upload.
 *
 * Polling cadence mirrors the PDF worker: every 5 seconds, with
 * atomic claim via `update where status='queued'`.
 *
 * Per-job options:
 *   - `burnTimestampAndGPS` — when true, re-encodes each JPEG
 *     with a timestamp + GPS string burnt into the bottom corner.
 *     Deferred to a follow-on PR; this PR ships pure-copy export
 *     (EXIF preserved).
 *   - `scope` + `selectedPhotoIds` — which photos to include.
 */

import type { FastifyBaseLogger } from "fastify";
import archiver from "archiver";
import { PassThrough } from "node:stream";
import { Upload } from "@aws-sdk/lib-storage";
import {
  type ExportStatus,
  type FolderExportOptions,
  type Photo,
  type Project,
} from "@forensic/shared";
import { supabaseAdmin } from "../supabase.js";
import { getObjectSize, getObjectStream, r2, r2Bucket } from "../r2.js";
import { captureException } from "../sentry.js";

const POLL_MS = 5_000;
const FOLDER_PREFIX = "exports/folder";

let workerStarted = false;

interface ExportRow {
  id: string;
  project_id: string;
  created_by: string;
  kind: "pdf" | "folder" | "csv";
  status: ExportStatus;
  object_key: string | null;
  size_bytes: number | null;
  options: Partial<FolderExportOptions>;
  error_message: string | null;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  progress_done: number | null;
  progress_total: number | null;
}

async function claimNextJob(log: FastifyBaseLogger): Promise<ExportRow | null> {
  const { data: candidate, error } = await supabaseAdmin
    .from("project_exports")
    .select("*")
    .eq("status", "queued")
    .eq("kind", "folder")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (error) {
    log.error({ err: error }, "folder export worker — candidate scan failed");
    return null;
  }
  if (!candidate) return null;

  const { data: claimed, error: claimErr } = await supabaseAdmin
    .from("project_exports")
    .update({ status: "running", started_at: new Date().toISOString() })
    .eq("id", (candidate as ExportRow).id)
    .eq("status", "queued")
    .select("*")
    .maybeSingle();
  if (claimErr) {
    log.error({ err: claimErr, jobId: (candidate as ExportRow).id }, "folder export worker — claim failed");
    return null;
  }
  return (claimed as ExportRow | null) ?? null;
}

async function markFailed(jobId: string, message: string): Promise<void> {
  await supabaseAdmin
    .from("project_exports")
    .update({
      status: "failed",
      error_message: message.slice(0, 1000),
      completed_at: new Date().toISOString(),
    })
    .eq("id", jobId);
}

async function markDone(jobId: string, objectKey: string, sizeBytes: number): Promise<void> {
  await supabaseAdmin
    .from("project_exports")
    .update({
      status: "done",
      object_key: objectKey,
      size_bytes: sizeBytes,
      completed_at: new Date().toISOString(),
    })
    .eq("id", jobId);
}

/** Progress writer — batched. Folder + CSV workers write
 *  `progress_done` + `progress_total` so the Exports page can show
 *  a live counter. Throttled to one write per ~5 items to avoid
 *  hammering Postgres on big projects. */
class ProgressWriter {
  private done = 0;
  private lastFlushed = 0;
  private readonly flushEvery: number;
  constructor(
    private jobId: string,
    private total: number,
    flushEvery = 5
  ) {
    this.flushEvery = flushEvery;
  }
  async setTotal(): Promise<void> {
    await supabaseAdmin
      .from("project_exports")
      .update({ progress_total: this.total, progress_done: 0 })
      .eq("id", this.jobId);
  }
  async tick(): Promise<void> {
    this.done += 1;
    if (this.done - this.lastFlushed >= this.flushEvery || this.done === this.total) {
      this.lastFlushed = this.done;
      await supabaseAdmin
        .from("project_exports")
        .update({ progress_done: this.done })
        .eq("id", this.jobId);
    }
  }
}

/**
 * Bounded-concurrency fetcher. Returns an array of promises in the
 * same order as the input. At most `concurrency` fetches in flight
 * at once. Each promise resolves with the fetched value or null on
 * error so the caller can skip-and-continue without rejecting the
 * whole batch.
 *
 * Critical pattern: parallel FETCH (network-bound), serial CONSUME
 * (archive.append on the result stream). With Build #5.108.1 the
 * fetcher returns a Node Readable rather than a Buffer, so memory
 * cost is per-socket overhead instead of the full body in RAM.
 */
function parallelFetch<T, U>(
  items: readonly T[],
  fetcher: (item: T) => Promise<U>,
  concurrency: number
): Promise<U | null>[] {
  const out: Promise<U | null>[] = new Array(items.length);
  let nextToStart = 0;
  let inFlight = 0;
  const resolvers: Array<(b: U | null) => void> = new Array(items.length);

  for (let i = 0; i < items.length; i++) {
    out[i] = new Promise<U | null>((resolve) => {
      resolvers[i] = resolve;
    });
  }

  function kick(): void {
    while (inFlight < concurrency && nextToStart < items.length) {
      const i = nextToStart++;
      inFlight++;
      const item = items[i];
      if (item === undefined) {
        resolvers[i]!(null);
        inFlight--;
        continue;
      }
      fetcher(item)
        .then((val) => {
          resolvers[i]!(val);
        })
        .catch(() => {
          resolvers[i]!(null);
        })
        .finally(() => {
          inFlight--;
          kick();
        });
    }
  }
  kick();
  return out;
}

/**
 * Wait for the archive entry to finish streaming. archiver emits
 * 'entry' once the previous entry's stream has been drained into
 * the zip. We wrap that in a Promise so the serial-append loop can
 * actually wait for backpressure rather than racing ahead and
 * piling up streams in memory.
 */
function waitForEntry(archive: archiver.Archiver): Promise<void> {
  return new Promise((resolve) => {
    archive.once("entry", () => resolve());
  });
}

/**
 * R2 GET concurrency. With streaming bodies (Build #5.108.1) each
 * in-flight request only holds a small socket buffer (~64KB) in
 * memory — not the full photo body. Even at 8 in-flight that's
 * ~512KB of socket bookkeeping vs the previous ~96MB of buffered
 * Buffers at concurrency 12 which OOM'd Render free tier (#5.107.1).
 *
 * Bumped DOWN to 3 in #5.109.1 after seeing SIGTERMs (not OOM)
 * mid-export on free tier. With concurrency 3 + streaming, at most
 * 3 R2 connections open at once and one body streams through the
 * archive. Memory footprint should sit well under Render's
 * eviction threshold.
 *
 * For projects > 200 photos on Render free tier, even this may not
 * finish reliably — the export runtime exceeds free tier's CPU
 * budget. Render Starter ($7/mo) gives dedicated CPU + no
 * auto-spin-down, which is the right fit for production export
 * workloads.
 */
const PHOTO_FETCH_CONCURRENCY = 3;

/** Log heap + RSS every N photos so we can correlate memory growth
 *  with progress in Render logs. */
const MEMORY_LOG_EVERY = 10;

/** Filter a name down to filesystem-safe characters; mirrors the
 *  iOS `safeFilename` helper. */
function safeName(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return "untitled";
  return trimmed
    .replace(/[/\\?%*:|"<>]/g, "-")
    .replace(/\s+/g, " ")
    .slice(0, 80);
}

/** Build the folder name iOS uses — "01 Foundation", "02 Framing",
 *  etc. Unbucketed photos land in "99 Unbucketed". */
function bucketFolderName(idx: number | null, name: string | null): string {
  if (idx == null || name == null) return "99 Unbucketed";
  return `${String(idx + 1).padStart(2, "0")} ${safeName(name)}`;
}

/** Compose a per-photo filename matching iOS:
 *  `<projectName> - <seq> - <yyMMdd>.jpg`. */
function photoFilename(
  project: Pick<Project, "name">,
  photo: Photo
): string {
  const ts = new Date(photo.timestamp);
  const yy = String(ts.getUTCFullYear()).slice(2);
  const mm = String(ts.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(ts.getUTCDate()).padStart(2, "0");
  const dateStr = `${yy}${mm}${dd}`;
  const ext = photo.imageFilename.split(".").pop() ?? "jpg";
  return `${safeName(project.name)} - ${photo.sequenceNumber} - ${dateStr}.${ext}`;
}

/** Build the captions.txt body for a bucket folder. */
function captionsTextForBucket(
  project: Pick<Project, "name">,
  photos: Photo[]
): string {
  const lines: string[] = [];
  lines.push(`# ${project.name} — captions.txt`);
  lines.push(`# Generated ${new Date().toISOString()}`);
  lines.push("");
  for (const p of photos) {
    lines.push(`## #${p.sequenceNumber} — ${photoFilename(project, p)}`);
    lines.push(`Captured: ${p.timestamp}`);
    if (p.userCaption) lines.push(`Caption: ${p.userCaption}`);
    if (p.userObservation) lines.push(`Observation: ${p.userObservation}`);
    if (p.aiAnalysis?.summaryObservation) {
      lines.push(`AI summary: ${p.aiAnalysis.summaryObservation}`);
    }
    const visibleTags = p.tags.filter((t) => t.confidence >= 0.5);
    if (visibleTags.length > 0) {
      lines.push(`Tags: ${visibleTags.map((t) => t.label).join(", ")}`);
    }
    lines.push("");
  }
  return lines.join("\n");
}

/**
 * Run a single folder export. Streams entries into an archiver
 * which pipes into an R2 multipart upload.
 */
async function runJob(job: ExportRow, log: FastifyBaseLogger): Promise<void> {
  // Step 1: read the manifest.
  const { data: projectRow, error: projErr } = await supabaseAdmin
    .from("projects")
    .select("manifest")
    .eq("id", job.project_id)
    .maybeSingle();
  if (projErr || !projectRow) {
    throw new Error(`Manifest read failed: ${projErr?.message ?? "not_found"}`);
  }
  const project = projectRow.manifest as unknown as Project;

  // Step 2: figure out which photos to include.
  const opts: FolderExportOptions = {
    burnTimestampAndGPS: job.options.burnTimestampAndGPS ?? false,
    scope: job.options.scope ?? "all",
    selectedPhotoIds: job.options.selectedPhotoIds ?? null,
  };
  let photos = project.photos;
  if (opts.scope === "selected" && opts.selectedPhotoIds) {
    const set = new Set(opts.selectedPhotoIds);
    photos = photos.filter((p) => set.has(p.id));
  }

  // Step 3: group by bucket. Buckets in their saved sortOrder; null
  // (unbucketed) lands in "99 Unbucketed".
  const buckets = [...project.buckets].sort(
    (a, b) => a.sortOrder - b.sortOrder
  );
  const byBucket = new Map<string | null, Photo[]>();
  for (const p of photos) {
    const key = p.bucketID ?? null;
    if (!byBucket.has(key)) byBucket.set(key, []);
    byBucket.get(key)!.push(p);
  }

  // Step 4: set up the archive + the R2 multipart upload sink.
  //
  // `store: true` skips deflate compression. JPEGs + HEICs barely
  // compress (they're already entropy-encoded); deflate on top is
  // pure CPU overhead. With store-mode the worker becomes purely
  // network-bound, which is what we want.
  const objectKey = `${FOLDER_PREFIX}/${job.id}.zip`;
  const archive = archiver("zip", { store: true });
  const passthrough = new PassThrough();
  archive.pipe(passthrough);

  const uploadPromise = new Upload({
    client: r2,
    params: {
      Bucket: r2Bucket,
      Key: objectKey,
      Body: passthrough,
      ContentType: "application/zip",
    },
  }).done();

  // Initialize progress tracking — the user sees X / Y in the
  // Exports page as photos are pulled.
  const totalItems = photos.length + project.floorPlans.length;
  const progress = new ProgressWriter(job.id, totalItems);
  await progress.setTotal();

  // Step 4a: floor plans — `00 Floor Plans/` folder at the top.
  // iOS export today skips plans; the user asked for them on web.
  if (project.floorPlans.length > 0) {
    await addFloorPlansToArchive(archive, project, log, progress);
  }

  // Step 5: walk each bucket folder.
  let bucketIdx = 0;
  for (const bucket of buckets) {
    const photosInBucket = byBucket.get(bucket.id);
    if (!photosInBucket || photosInBucket.length === 0) continue;
    const folderName = bucketFolderName(bucketIdx++, bucket.name);
    await addBucketToArchive(
      archive,
      folderName,
      project,
      photosInBucket.sort((a, b) => a.sequenceNumber - b.sequenceNumber),
      log,
      progress
    );
  }
  // Unbucketed.
  const unbucketed = byBucket.get(null);
  if (unbucketed && unbucketed.length > 0) {
    const folderName = bucketFolderName(null, null);
    await addBucketToArchive(
      archive,
      folderName,
      project,
      unbucketed.sort((a, b) => a.sequenceNumber - b.sequenceNumber),
      log,
      progress
    );
  }

  // Properly chain finalize → upload close. archive.finalize()
  // returns a Promise that resolves once every entry has been
  // flushed into the stream; PassThrough then emits 'end' which
  // lib-storage's Upload sees as the trigger to close the multipart.
  await archive.finalize();
  await uploadPromise;

  // HEAD the uploaded zip to get the final size for the row. We
  // stream bodies through the archive (#5.108.1) instead of
  // buffering, so we don't accumulate byte counts during the run.
  const finalSize = (await getObjectSize(objectKey)) ?? 0;
  await markDone(job.id, objectKey, finalSize);
  log.info(
    { jobId: job.id, projectId: job.project_id, bytes: finalSize },
    "folder export — done"
  );
}

async function addFloorPlansToArchive(
  archive: archiver.Archiver,
  project: Project,
  log: FastifyBaseLogger,
  progress: ProgressWriter
): Promise<void> {
  const folder = "00 Floor Plans";
  // Look up plan binaries (case-safe; mirrors photo lookup).
  const planIds = project.floorPlans.map((p) => p.id);
  const { data: fileRows, error: filesErr } = await supabaseAdmin
    .from("files")
    .select("photo_id, object_key, kind")
    .eq("project_id", project.id)
    .in("photo_id", planIds)
    .eq("kind", "plan");
  if (filesErr) {
    log.warn(
      { err: filesErr, projectId: project.id },
      "folder export — floor-plan files lookup failed; skipping plan binaries"
    );
  }
  const keyByPlanIdLower = new Map<string, string>();
  for (const row of fileRows ?? []) {
    const r = row as { photo_id: string; object_key: string };
    keyByPlanIdLower.set(r.photo_id.toLowerCase(), r.object_key);
  }

  // Sidecar with calibration values.
  const lines: string[] = [];
  lines.push(`# ${project.name} — floor plans`);
  lines.push(`# Generated ${new Date().toISOString()}`);
  lines.push("");
  for (const [idx, plan] of project.floorPlans.entries()) {
    lines.push(`## Plan ${idx + 1} — ${plan.label}`);
    lines.push(`pixelsPerFoot: ${plan.pixelsPerFoot}`);
    lines.push(`calibrationDistanceFeet: ${plan.calibrationDistanceFeet}`);
    lines.push(`anchorPixel: (${plan.anchorPixelX}, ${plan.anchorPixelY})`);
    lines.push(
      `anchorLocalFeet: (${plan.anchorLocalXFeet}, ${plan.anchorLocalYFeet})`
    );
    lines.push(`northDeg: ${plan.northDeg}`);
    lines.push(`distress markers: ${plan.distress.length}`);
    lines.push("");
  }

  // Parallel-fetch streams; consume serially in array order.
  const fetches = parallelFetch(
    project.floorPlans,
    async (plan) => {
      const objectKey = keyByPlanIdLower.get(plan.id.toLowerCase());
      if (!objectKey) {
        log.warn(
          { planId: plan.id },
          "folder export — no files row for plan; skipping binary"
        );
        throw new Error("no_files_row");
      }
      return getObjectStream(objectKey);
    },
    PHOTO_FETCH_CONCURRENCY
  );

  for (let i = 0; i < project.floorPlans.length; i++) {
    const plan = project.floorPlans[i]!;
    const stream = await fetches[i]!;
    if (stream) {
      const ext = plan.imageFilename.split(".").pop() ?? "png";
      const safeLabel = safeName(plan.label);
      const entryDone = waitForEntry(archive);
      archive.append(stream, {
        name: `${folder}/${String(i + 1).padStart(2, "0")} ${safeLabel}.${ext}`,
      });
      await entryDone;
    }
    await progress.tick();
  }

  const metadata = lines.join("\n");
  archive.append(metadata, { name: `${folder}/plans.txt` });
}

async function addBucketToArchive(
  archive: archiver.Archiver,
  folderName: string,
  project: Project,
  photos: Photo[],
  log: FastifyBaseLogger,
  progress: ProgressWriter
): Promise<void> {
  // Look up the actual R2 object_key for each photo (case-safe;
  // see comment in addFloorPlansToArchive).
  const photoIds = photos.map((p) => p.id);
  const { data: fileRows, error: filesErr } = await supabaseAdmin
    .from("files")
    .select("photo_id, object_key, kind")
    .eq("project_id", project.id)
    .in("photo_id", photoIds)
    .eq("kind", "photo");
  if (filesErr) {
    log.error(
      { err: filesErr, projectId: project.id },
      "folder export — files-table lookup failed; skipping photos but keeping captions.txt"
    );
  }
  const keyByPhotoIdLower = new Map<string, string>();
  for (const row of fileRows ?? []) {
    const r = row as { photo_id: string; object_key: string };
    keyByPhotoIdLower.set(r.photo_id.toLowerCase(), r.object_key);
  }

  // Parallel fetch the bucket's photos AS STREAMS. The fetch
  // promise resolves once R2 has sent response headers, not after
  // the body downloads — body bytes flow lazily as archiver
  // consumes the stream. So memory is bounded by socket buffers
  // not photo size, and concurrency can be higher without OOMing.
  const fetchStart = Date.now();
  let fetchedCount = 0;
  let totalFetchMs = 0;
  const fetches = parallelFetch(
    photos,
    async (photo) => {
      const objectKey = keyByPhotoIdLower.get(photo.id.toLowerCase());
      if (!objectKey) throw new Error("no_files_row");
      const t0 = Date.now();
      const stream = await getObjectStream(objectKey);
      const elapsed = Date.now() - t0;
      totalFetchMs += elapsed;
      fetchedCount++;
      if (elapsed > 2000) {
        log.warn(
          { photoId: photo.id, objectKey, ms: elapsed },
          "folder export — slow R2 response (headers)"
        );
      }
      return stream;
    },
    PHOTO_FETCH_CONCURRENCY
  );

  for (let i = 0; i < photos.length; i++) {
    const photo = photos[i]!;
    const stream = await fetches[i]!;
    if (stream) {
      const filename = photoFilename(project, photo);
      const entryDone = waitForEntry(archive);
      archive.append(stream, { name: `${folderName}/${filename}` });
      // Wait until archiver has drained THIS entry's stream before
      // moving on; otherwise the loop races ahead and the next R2
      // stream piles up in memory while this one is still consuming.
      await entryDone;
    } else {
      log.warn(
        { photoId: photo.id, projectId: project.id },
        "folder export — photo skipped (no files row OR R2 read failed)"
      );
    }
    await progress.tick();
    // Periodic memory snapshot so we can correlate growth with
    // progress when investigating SIGTERMs on resource-constrained
    // tiers.
    if ((i + 1) % MEMORY_LOG_EVERY === 0) {
      const m = process.memoryUsage();
      log.info(
        {
          folder: folderName,
          processed: i + 1,
          total: photos.length,
          rssMb: Math.round(m.rss / 1024 / 1024),
          heapUsedMb: Math.round(m.heapUsed / 1024 / 1024),
          heapTotalMb: Math.round(m.heapTotal / 1024 / 1024),
          externalMb: Math.round(m.external / 1024 / 1024),
        },
        "folder export — memory snapshot"
      );
    }
  }
  const wallMs = Date.now() - fetchStart;
  log.info(
    {
      folder: folderName,
      photoCount: photos.length,
      wallMs,
      avgHeaderMs: fetchedCount > 0 ? Math.round(totalFetchMs / fetchedCount) : 0,
      concurrency: PHOTO_FETCH_CONCURRENCY,
    },
    "folder export — bucket batch done"
  );
  const captions = captionsTextForBucket(project, photos);
  archive.append(captions, { name: `${folderName}/captions.txt` });
}

async function tick(log: FastifyBaseLogger): Promise<void> {
  const job = await claimNextJob(log);
  if (!job) return;
  try {
    await runJob(job, log);
  } catch (e: unknown) {
    const message = e instanceof Error ? e.message : String(e);
    log.error({ err: e, jobId: job.id }, "folder export — render failed");
    captureException(e, { jobId: job.id, projectId: job.project_id });
    try {
      await markFailed(job.id, message);
    } catch (markErr) {
      log.error({ err: markErr, jobId: job.id }, "folder export — markFailed also failed");
    }
  }
}

export function startFolderExportWorker(log: FastifyBaseLogger): void {
  if (workerStarted) return;
  workerStarted = true;
  log.info("folder export worker started");
  setInterval(() => {
    void tick(log).catch((err) => {
      log.error({ err }, "folder export worker — unhandled tick error");
    });
  }, POLL_MS);
}
