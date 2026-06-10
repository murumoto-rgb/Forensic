// Split out of PhotoPreviewPanel.tsx (Build #6.22.1) — the panel had
// grown to 1,614 lines holding four independent sub-features. Each
// file owns one feature plus its private helpers; the panel shell
// imports the exported components. No behavior change.
import { useTagConfidenceThreshold } from "../lib/useTagConfidenceThreshold";

/**
 * Read-only viewer for a photo's `AIPhotoAnalysis`. Mirrors the
 * fields iOS's `PhotoTagEditorSheet` surfaces — recommended use,
 * scale presence, transcribed measurement, reviewer flag, the
 * tag-tree with per-secondary confidence percentages, and the
 * validator errors iOS may have written on the previous tag run.
 *
 * The caption + observation rows in the panel already surface
 * `captionDraft` + `summaryObservation`, so this viewer
 * intentionally skips those — duplicating them would just make the
 * footer twice as tall.
 *
 * Renders nothing extra when a field is empty / null / the iOS
 * "unknown" sentinel so a sparsely-populated analysis doesn't show
 * a wall of dashes.
 */
export function AIAnalysisViewer({
  analysis,
}: {
  analysis: import("@forensic/shared").AIPhotoAnalysis;
}) {
  const hasTags =
    analysis.primaryTags.length > 0 ||
    Object.keys(analysis.secondaryTagsByPrimary).length > 0;
  const hasAnyVisible =
    hasTags ||
    nonTrivialString(analysis.recommendedUse) ||
    nonTrivialString(analysis.scalePresent) ||
    nonTrivialString(analysis.measurementVisible) ||
    nonTrivialString(analysis.locationInferred) ||
    nonTrivialString(analysis.reviewerFlag) ||
    analysis.validationErrors.length > 0 ||
    analysis.parseFailed;

  // An aiAnalysis that's structurally present but every field is
  // empty (e.g. an early parse failure on a model with no usable
  // output) renders as a one-line header rather than nothing — so
  // the user knows the call ran but produced nothing useful.
  if (!hasAnyVisible) {
    return (
      <details className="mt-2 border-t border-neutral-800 pt-2 text-xs">
        <summary className="cursor-pointer text-neutral-400 hover:text-neutral-200">
          AI analysis (empty)
        </summary>
      </details>
    );
  }

  return (
    <details
      className="mt-2 border-t border-neutral-800 pt-2 text-xs"
      open
    >
      <summary className="cursor-pointer text-neutral-300 hover:text-neutral-100">
        AI analysis
        {analysis.parseFailed && (
          <span className="ml-2 rounded bg-amber-900/40 px-1.5 py-0.5 text-[10px] text-amber-300">
            parse failed
          </span>
        )}
      </summary>
      <div className="mt-2 flex flex-col gap-2">
        {nonTrivialString(analysis.recommendedUse) && (
          <AnalysisRow label="Recommended use" value={analysis.recommendedUse} />
        )}
        {nonTrivialString(analysis.scalePresent) && (
          <AnalysisRow label="Scale" value={analysis.scalePresent} />
        )}
        {nonTrivialString(analysis.measurementVisible) && (
          <AnalysisRow
            label="Measurement"
            value={analysis.measurementVisible!}
          />
        )}
        {nonTrivialString(analysis.locationInferred) && (
          <AnalysisRow label="Location" value={analysis.locationInferred} />
        )}
        {nonTrivialString(analysis.reviewerFlag) && (
          <AnalysisRow
            label="Reviewer flag"
            value={analysis.reviewerFlag}
            tone="warning"
          />
        )}
        {hasTags && <AITagTree analysis={analysis} />}
        {analysis.validationErrors.length > 0 && (
          <div className="rounded border border-amber-800 bg-amber-950/40 px-2 py-1 text-amber-200">
            <div className="mb-1 font-semibold text-amber-100">
              Validator issues
            </div>
            <ul className="ml-4 list-disc space-y-0.5">
              {analysis.validationErrors.map((e, i) => (
                <li key={i}>{e}</li>
              ))}
            </ul>
          </div>
        )}
        {analysis.parseFailed && analysis.rawResponse && (
          <details className="mt-1">
            <summary className="cursor-pointer text-neutral-500 hover:text-neutral-300">
              Show raw response
            </summary>
            <pre className="mt-1 max-h-48 overflow-auto rounded border border-neutral-800 bg-neutral-950 p-2 text-[10px] text-neutral-400">
              {analysis.rawResponse}
            </pre>
          </details>
        )}
      </div>
    </details>
  );
}

function AnalysisRow({
  label,
  value,
  tone = "neutral",
}: {
  label: string;
  value: string;
  tone?: "neutral" | "warning";
}) {
  return (
    <div className="flex flex-col">
      <span
        className={
          tone === "warning"
            ? "text-[10px] uppercase tracking-wide text-amber-400"
            : "text-[10px] uppercase tracking-wide text-neutral-500"
        }
      >
        {label}
      </span>
      <span
        className={
          tone === "warning" ? "text-amber-200" : "text-neutral-200"
        }
      >
        {value}
      </span>
    </div>
  );
}

/**
 * Render the analysis's tag tree as a list of primaries, each with
 * its bullet of secondary chips. Per-secondary confidence is read
 * from `tagConfidences` (case-insensitive lookup on the chip's
 * label) and rendered as a small percentage when present.
 *
 * Secondaries below the app-wide confidence threshold (Build
 * #5.40.1; same `sitephoto.tagConfidenceThreshold` key iOS uses)
 * are hidden by default; a small inline slider in the tree header
 * lets the user surface them again. Hidden-count chip shown beside
 * the slider when any secondary was filtered out, mirroring iOS's
 * "8 hidden" affordance.
 */
function AITagTree({
  analysis,
}: {
  analysis: import("@forensic/shared").AIPhotoAnalysis;
}) {
  const [threshold, setThreshold] = useTagConfidenceThreshold();
  // Build a lowercase-keyed confidence lookup once so we don't
  // walk the map per chip.
  const confByLower = new Map<string, number>();
  for (const [k, v] of Object.entries(analysis.tagConfidences)) {
    confByLower.set(k.trim().toLowerCase(), v);
  }

  let hiddenCount = 0;
  // Pre-compute the rendered tree so we can count hidden secondaries
  // before laying out the header.
  const renderedPrimaries = analysis.primaryTags.map((primary) => {
    const trimmedPrimary = primary.trim();
    const matchKey = Object.keys(analysis.secondaryTagsByPrimary).find(
      (k) => k.trim().toLowerCase() === trimmedPrimary.toLowerCase()
    );
    const secondaries =
      (matchKey && analysis.secondaryTagsByPrimary[matchKey]) || [];
    const chips: { label: string; conf: number | undefined }[] = [];
    for (const sec of secondaries) {
      const trimmedSec = sec.trim();
      if (trimmedSec.length === 0 || trimmedSec.toLowerCase() === "none") {
        continue;
      }
      const conf = confByLower.get(trimmedSec.toLowerCase());
      // Filter rule: hide a secondary when its confidence is BELOW
      // the threshold. A secondary with no confidence entry is
      // treated as "kept" — iOS's pipeline assigns the fallback
      // confidence (0.7) when a secondary's tag_confidences entry
      // is missing, which keeps it above the default 50% threshold
      // and matches the visible-by-default behaviour.
      if (conf != null && conf < threshold) {
        hiddenCount += 1;
        continue;
      }
      chips.push({ label: trimmedSec, conf });
    }
    return { trimmedPrimary, chips, key: primary };
  });

  return (
    <div className="flex flex-col gap-1.5">
      <div className="flex items-center justify-between gap-2">
        <span className="text-[10px] uppercase tracking-wide text-neutral-500">
          Tags
        </span>
        <div className="flex items-center gap-2">
          {hiddenCount > 0 && (
            <span
              className="text-[10px] text-neutral-500"
              title={`${hiddenCount} secondary tag${
                hiddenCount === 1 ? "" : "s"
              } hidden below ${Math.round(threshold * 100)}% confidence`}
            >
              {hiddenCount} hidden
            </span>
          )}
          <label
            className="flex items-center gap-1.5 text-[10px] text-neutral-500"
            title="Hide AI tags below this confidence. Stored in localStorage; mirrors iOS Settings → Tag Confidence Filter."
          >
            Min&nbsp;
            <input
              type="range"
              min={0}
              max={1}
              step={0.05}
              value={threshold}
              onChange={(e) =>
                setThreshold(Number.parseFloat(e.currentTarget.value))
              }
              className="h-1 w-20 cursor-pointer accent-blue-500"
              aria-label="Minimum tag confidence"
            />
            <span className="font-mono text-neutral-400">
              {Math.round(threshold * 100)}%
            </span>
          </label>
        </div>
      </div>
      {analysis.primaryTags.length === 0 && (
        <div className="text-neutral-500 italic">
          No primaries — secondaries below carry no parent in the analysis.
        </div>
      )}
      {renderedPrimaries.map(({ trimmedPrimary, chips, key }) => (
        <div key={key} className="flex flex-col gap-1">
          <div className="font-medium text-neutral-200">{trimmedPrimary}</div>
          {chips.length > 0 && (
            <div className="ml-2 flex flex-wrap gap-1">
              {chips.map(({ label, conf }) => (
                <span
                  key={label}
                  className="rounded bg-neutral-800 px-1.5 py-0.5 text-[11px] text-neutral-200"
                >
                  {label}
                  {conf != null && (
                    <span className="ml-1 text-neutral-500">
                      {Math.round(Math.max(0, Math.min(1, conf)) * 100)}%
                    </span>
                  )}
                </span>
              ))}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

/**
 * True when `s` carries useful content. Treats the empty string AND
 * the iOS-side "unknown" sentinel (`scalePresent` / `recommendedUse`
 * are stored as raw strings but iOS represents the "unknown" enum
 * case as a bare `""` on the wire) as falsy so the viewer doesn't
 * show empty rows.
 */
function nonTrivialString(s: string | null | undefined): boolean {
  if (s == null) return false;
  return s.trim().length > 0;
}

