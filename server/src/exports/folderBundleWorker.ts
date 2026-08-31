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
 * bytes are pulled serially from R2 via `getObjectStream`, fed into the
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
import { PassThrough, Transform } from "node:stream";
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
 * Wait for the archive entry to finish streaming. archiver emits
 * 'entry' once the previous entry's stream has been drained into
 * the zip. We wrap that in a Promise so the serial-append loop can
 * actually wait for backpressure rather than racing ahead and
 * piling up streams in memory.
 */
function waitForEntry(archive: archiver.Archiver, name: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const cleanup = () => { archive.off("entry", onEntry); archive.off("error", onError); };
    const onEntry = (entry: { name: string }) => {
      if (entry.name !== name) return;
      cleanup(); resolve();
    };
    const onError = (error: Error) => { cleanup(); reject(error); };
    archive.on("entry", onEntry);
    archive.once("error", onError);
  });
}

function appendStream(archive: archiver.Archiver, stream: import("node:stream").Readable, name: string): void {
  stream.once("error", (err) => archive.emit("error", err));
  archive.append(stream, { name });
}

/**
 * Validate an R2 body while it is consumed by archiver. The registry size is
 * part of the export contract: a short body must not silently become a valid
 * (but truncated) archive entry, and an overlong body must not be accepted
 * either. This stays streaming and never buffers the asset.
 */
function validateAssetStream(
  source: import("node:stream").Readable,
  expectedBytes: number,
  objectKey: string,
): import("node:stream").Readable {
  let consumed = 0;
  const checked = new Transform({
    transform(chunk, _encoding, callback) {
      const bytes = Buffer.isBuffer(chunk) ? chunk.length : Buffer.byteLength(chunk);
      consumed += bytes;
      if (consumed > expectedBytes) {
        callback(new Error(`Asset ${objectKey} exceeds registered size ${expectedBytes} bytes`));
        return;
      }
      callback(null, chunk);
    },
    flush(callback) {
      if (consumed !== expectedBytes) {
        callback(new Error(`Asset ${objectKey} consumed ${consumed} bytes; registered size is ${expectedBytes}`));
        return;
      }
      callback();
    },
  });
  source.once("error", (error) => checked.destroy(error));
  // Also close the upstream socket when validation/archiving stops early.
  checked.once("close", () => source.destroy());
  source.pipe(checked);
  return checked;
}

function registeredSize(value: unknown, objectKey: string): number {
  const size = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(size) || size <= 0) {
    throw new Error(`Asset ${objectKey} has invalid registered size`);
  }
  return size;
}

/** The current view matches the live manifest, which may have changed since
 * this job read its snapshot. Supported legacy rows were backfilled by 0017;
 * null/unmatched filenames are not usable evidence and must not be guessed. */
function assertSnapshotFilename(actual: string | null, expected: string | undefined, objectKey: string): void {
  if (expected === undefined || actual !== expected) {
    throw new Error(`Asset ${objectKey} filename changed or is unverified for the export snapshot. Retry the export.`);
  }
}

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

function planArchivePath(plan: Project["floorPlans"][number], index: number): string {
  const ext = plan.imageFilename.split(".").pop() ?? "png";
  return `00 Floor Plans/${String(index + 1).padStart(2, "0")} ${safeName(plan.label)}.${ext}`;
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
export async function runFolderExportJob(job: ExportRow, log: FastifyBaseLogger): Promise<void> {
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
    const set = new Set(opts.selectedPhotoIds.map(id => id.toLowerCase()));
    photos = photos.filter((p) => set.has(p.id.toLowerCase()));
  }

  // Step 3: group by bucket. Buckets in their saved sortOrder; null
  // (unbucketed) lands in "99 Unbucketed".
  const buckets = [...project.buckets].sort(
    (a, b) => a.sortOrder - b.sortOrder
  );
  const byBucket = new Map<string | null, Photo[]>();
  const knownBucketIds = new Set(buckets.map((b) => b.id.toLowerCase()));
  for (const p of photos) {
    const key = p.bucketID && knownBucketIds.has(p.bucketID.toLowerCase()) ? p.bucketID.toLowerCase() : null;
    if (!byBucket.has(key)) byBucket.set(key, []);
    byBucket.get(key)!.push(p);
  }

  const groups: Array<{ folderName: string; photos: Photo[] }> = [];
  for (const bucket of buckets) {
    const members = byBucket.get(bucket.id.toLowerCase());
    if (members?.length) groups.push({ folderName: bucketFolderName(groups.length, bucket.name), photos: members });
  }
  const unbucketed = byBucket.get(null);
  if (unbucketed?.length) groups.push({ folderName: bucketFolderName(null, null), photos: unbucketed });

  // Check final paths before starting multipart upload. Different source names
  // can collapse after sanitizing/truncating; duplicate sequence numbers also
  // collide. Case folding protects common case-insensitive extraction volumes.
  const paths = new Set<string>();
  const reservePath = (path: string) => {
    const normalized = path.normalize("NFC").toLowerCase();
    if (paths.has(normalized)) throw new Error(`Duplicate export path: ${path}. Choose a smaller selection or resolve conflicting filenames.`);
    paths.add(normalized);
  };
  for (const group of groups) {
    for (const photo of group.photos) {
      reservePath(`${group.folderName}/${photoFilename(project, photo)}`);
      for (const source of [photo.markupOverlayFilename, photo.markupDrawingFilename]) {
        if (source) reservePath(`01 Markups/${safeName(source)}`);
      }
    }
    reservePath(`${group.folderName}/captions.txt`);
  }
  project.floorPlans.forEach((plan, index) => reservePath(planArchivePath(plan, index)));
  if (project.floorPlans.length) reservePath("00 Floor Plans/plans.txt");

  // Step 4: set up the archive + the R2 multipart upload sink.
  //
  // `store: true` skips deflate compression. JPEGs + HEICs barely
  // compress (they're already entropy-encoded); deflate on top is
  // pure CPU overhead. With store-mode the worker becomes purely
  // network-bound, which is what we want.
  const objectKey = `${FOLDER_PREFIX}/${job.id}.zip`;
  const archive = archiver("zip", { store: true });
  const passthrough = new PassThrough();
  // Any entry or upload failure must tear down the pipeline. Attach the
  // rejection handler immediately so a failed multipart upload cannot
  // become an unhandled rejection while the worker is marking the job.
  archive.on("error", (err) => passthrough.destroy(err));
  archive.pipe(passthrough);

  const upload = new Upload({
    client: r2,
    params: {
      Bucket: r2Bucket,
      Key: objectKey,
      Body: passthrough,
      ContentType: "application/zip",
    },
  });
  const uploadPromise = upload.done();
  void uploadPromise.catch((err) => {
    passthrough.destroy(err instanceof Error ? err : new Error(String(err)));
  });

  try {
  // Initialize progress tracking — the user sees X / Y in the
  // Exports page as photos are pulled.
  const markupCount = photos.reduce(
    (count, photo) => count + (photo.markupOverlayFilename ? 1 : 0) + (photo.markupDrawingFilename ? 1 : 0),
    0,
  );
  const totalItems = photos.length + project.floorPlans.length + markupCount;
  const progress = new ProgressWriter(job.id, totalItems);
  await progress.setTotal();

  // Step 5: walk each bucket folder.
  for (const group of groups) {
    await addBucketToArchive(
      archive,
      group.folderName,
      project,
      group.photos.sort((a, b) => a.sequenceNumber - b.sequenceNumber),
      log,
      progress
    );
  }

  // Floor-plan binaries follow photo/markup bodies in the stream; their
  // "00 Floor Plans" path still sorts first in the extracted folder.
  if (project.floorPlans.length > 0) {
    await addFloorPlansToArchive(archive, project, progress);
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
  const finalSize = await getObjectSize(objectKey);
  if (typeof finalSize !== "number" || !Number.isSafeInteger(finalSize) || finalSize <= 0) {
    throw new Error("Uploaded ZIP is unavailable or has an invalid byte length. Export not completed.");
  }
  await markDone(job.id, objectKey, finalSize);
  log.info(
    { jobId: job.id, projectId: job.project_id, bytes: finalSize },
    "folder export — done"
  );
  } catch (error) {
    try {
      archive.abort();
    } catch (abortErr) {
      log.warn({ err: abortErr, jobId: job.id }, "folder export — archive abort failed");
    }
    passthrough.destroy(error instanceof Error ? error : new Error(String(error)));
    await upload.abort().catch(() => undefined);
    await uploadPromise.catch(() => undefined);
    throw error;
  }
}

async function addFloorPlansToArchive(
  archive: archiver.Archiver,
  project: Project,
  progress: ProgressWriter
): Promise<void> {
  const folder = "00 Floor Plans";
  // Look up plan binaries (case-safe; mirrors photo lookup).
  const planIds = project.floorPlans.map((p) => p.id);
  const { data: fileRows, error: filesErr } = await supabaseAdmin
    .from("current_project_files")
    .select("photo_id, object_key, kind, size_bytes, source_filename")
    .eq("project_id", project.id)
    .in("photo_id", planIds)
    .eq("kind", "plan");
  if (filesErr) {
    throw new Error(`Floor-plan files lookup failed: ${filesErr.message}`);
  }
  const filenames = new Map(project.floorPlans.map(plan => [plan.id.toLowerCase(), plan.imageFilename]));
  const fileByPlanIdLower = new Map<string, { objectKey: string; sizeBytes: number }>();
  for (const row of fileRows ?? []) {
    const r = row as { photo_id: string; object_key: string; size_bytes: unknown; source_filename: string | null };
    assertSnapshotFilename(r.source_filename, filenames.get(r.photo_id.toLowerCase()), r.object_key);
    fileByPlanIdLower.set(r.photo_id.toLowerCase(), {
      objectKey: r.object_key,
      sizeBytes: registeredSize(r.size_bytes, r.object_key),
    });
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

  for (let i = 0; i < project.floorPlans.length; i++) {
    const plan = project.floorPlans[i]!;
    const file = fileByPlanIdLower.get(plan.id.toLowerCase());
    if (!file) throw new Error(`Missing required plan file: ${plan.imageFilename}`);
    const stream = validateAssetStream(await getObjectStream(file.objectKey), file.sizeBytes, file.objectKey);
    const entryName = planArchivePath(plan, i);
    const entryDone = waitForEntry(archive, entryName);
    appendStream(archive, stream, entryName);
    await entryDone;
    await progress.tick();
  }

  const metadata = lines.join("\n");
  const metadataName = `${folder}/plans.txt`;
  const metadataDone = waitForEntry(archive, metadataName);
  archive.append(metadata, { name: metadataName });
  await metadataDone;
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
    .from("current_project_files")
    .select("photo_id, object_key, kind, size_bytes, source_filename")
    .eq("project_id", project.id)
    .in("photo_id", photoIds)
    .in("kind", ["photo", "markup_png", "markup_drawing"]);
  if (filesErr) {
    throw new Error(`Photo files lookup failed: ${filesErr.message}`);
  }
  const filenames = new Map<string, string>();
  for (const photo of photos) {
    filenames.set(`${photo.id.toLowerCase()}:photo`, photo.imageFilename);
    if (photo.markupOverlayFilename) filenames.set(`${photo.id.toLowerCase()}:markup_png`, photo.markupOverlayFilename);
    if (photo.markupDrawingFilename) filenames.set(`${photo.id.toLowerCase()}:markup_drawing`, photo.markupDrawingFilename);
  }
  const fileByPhotoAndKind = new Map<string, { objectKey: string; sizeBytes: number }>();
  for (const row of fileRows ?? []) {
    const r = row as { photo_id: string; object_key: string; kind: string; size_bytes: unknown; source_filename: string | null };
    const tuple = `${r.photo_id.toLowerCase()}:${r.kind}`;
    const filename = filenames.get(tuple);
    // An overlay added after this manifest snapshot is not part of this export.
    if (filename === undefined) continue;
    assertSnapshotFilename(r.source_filename, filename, r.object_key);
    fileByPhotoAndKind.set(tuple, {
      objectKey: r.object_key,
      sizeBytes: registeredSize(r.size_bytes, r.object_key),
    });
  }

  // Open one source only after the previous named archive entry drained.
  // No waiting stream pool retains sockets or source bodies between entries.
  const fetchStart = Date.now();

  for (let i = 0; i < photos.length; i++) {
    const photo = photos[i]!;
    const file = fileByPhotoAndKind.get(`${photo.id.toLowerCase()}:photo`);
    if (!file) throw new Error(`Missing required photo file: ${photo.id}`);
    const stream = validateAssetStream(await getObjectStream(file.objectKey), file.sizeBytes, file.objectKey);
    const filename = photoFilename(project, photo);
    const entryName = `${folderName}/${filename}`;
    const entryDone = waitForEntry(archive, entryName);
    appendStream(archive, stream, entryName);
    await entryDone;
    await progress.tick();
    for (const [kind, source] of [["markup_png", photo.markupOverlayFilename], ["markup_drawing", photo.markupDrawingFilename]] as const) {
      if (!source) continue;
      const file = fileByPhotoAndKind.get(`${photo.id.toLowerCase()}:${kind}`);
      if (!file) throw new Error(`Missing required ${kind} file: ${source}`);
      const markupStream = validateAssetStream(await getObjectStream(file.objectKey), file.sizeBytes, file.objectKey);
      const entryName = `01 Markups/${safeName(source)}`;
      const entryDone = waitForEntry(archive, entryName);
      appendStream(archive, markupStream, entryName);
      await entryDone;
      await progress.tick();
    }
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
      concurrency: 1,
    },
    "folder export — bucket batch done"
  );
  const captions = captionsTextForBucket(project, photos);
  const captionsName = `${folderName}/captions.txt`;
  const captionsDone = waitForEntry(archive, captionsName);
  archive.append(captions, { name: captionsName });
  await captionsDone;
}

async function tick(log: FastifyBaseLogger): Promise<void> {
  const job = await claimNextJob(log);
  if (!job) return;
  try {
    await runFolderExportJob(job, log);
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
