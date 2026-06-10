// Split out of PhotoPreviewPanel.tsx (Build #6.22.1) — the panel had
// grown to 1,614 lines holding four independent sub-features. Each
// file owns one feature plus its private helpers; the panel shell
// imports the exported components. No behavior change.
import type { Photo, Tag, TagSuggestion } from "@forensic/shared";
import { useTagConfidenceThreshold } from "../lib/useTagConfidenceThreshold";

/**
 * Apply a single suggestion to a photo's `tags` list, removing it
 * from `pendingSuggestions`. Mirrors iOS's
 * `ProjectStore.confirmSuggestion` — dedups against any tag the
 * user already has (so a re-accept doesn't double).
 */
function applySuggestionToPhoto(
  photo: Photo,
  suggestion: TagSuggestion
): Photo {
  const existing = photo.tags.find(
    (t) =>
      t.label.toLowerCase() === suggestion.label.toLowerCase() &&
      (t.parentTag ?? null) === (suggestion.parentTag ?? null)
  );
  const nextTags: Tag[] = existing
    ? photo.tags
    : [
        ...photo.tags,
        {
          label: suggestion.label,
          confidence: suggestion.confidence,
          parentTag: suggestion.parentTag,
        },
      ];
  const nextPending = photo.pendingSuggestions.filter(
    (s) =>
      !(
        s.label.toLowerCase() === suggestion.label.toLowerCase() &&
        (s.parentTag ?? null) === (suggestion.parentTag ?? null)
      )
  );
  return { ...photo, tags: nextTags, pendingSuggestions: nextPending };
}

function removeSuggestionFromPhoto(
  photo: Photo,
  suggestion: TagSuggestion
): Photo {
  return {
    ...photo,
    pendingSuggestions: photo.pendingSuggestions.filter(
      (s) =>
        !(
          s.label.toLowerCase() === suggestion.label.toLowerCase() &&
          (s.parentTag ?? null) === (suggestion.parentTag ?? null)
        )
    ),
  };
}

/**
 * Review UI for `photo.pendingSuggestions`. Each suggestion renders
 * as a chip with accept ✓ / reject ✕ buttons; the header carries
 * bulk "Accept all" / "Reject all" actions. Mirrors iOS's
 * pending-suggestions chip row in `PhotoTagEditorSheet`.
 *
 * Suggestions group by primary so accepting a primary's worth of
 * secondaries in one go is straightforward. Confidence percentages
 * read the same `useTagConfidenceThreshold` slider value as the
 * AI analysis viewer; below-threshold suggestions are visually
 * dimmed but still rendered so the user can choose to accept them.
 */
export function PendingSuggestionsReview({
  photo,
  onPhotoUpdated,
}: {
  photo: Photo;
  onPhotoUpdated: (next: Photo) => void;
}) {
  const [threshold] = useTagConfidenceThreshold();
  const suggestions = photo.pendingSuggestions;
  if (suggestions.length === 0) return null;

  function acceptOne(s: TagSuggestion) {
    onPhotoUpdated(applySuggestionToPhoto(photo, s));
  }
  function rejectOne(s: TagSuggestion) {
    onPhotoUpdated(removeSuggestionFromPhoto(photo, s));
  }
  function acceptAll() {
    let next = photo;
    for (const s of suggestions) next = applySuggestionToPhoto(next, s);
    onPhotoUpdated(next);
  }
  function rejectAll() {
    onPhotoUpdated({ ...photo, pendingSuggestions: [] });
  }

  // Group by parentTag (null = primary). Preserves the order the
  // backend pipeline emitted suggestions in.
  const byParent = new Map<string | null, TagSuggestion[]>();
  for (const s of suggestions) {
    const key = s.parentTag ?? null;
    const list = byParent.get(key) ?? [];
    list.push(s);
    byParent.set(key, list);
  }

  // Render order: each primary suggestion first, with its
  // secondaries indented; primaries that don't have an explicit
  // suggestion entry but DO have secondaries get a synthesised
  // header so the user can tell what they're nesting under.
  const primaries: TagSuggestion[] =
    byParent.get(null)?.slice() ?? [];
  const synthesisedHeaders = new Set<string>();
  for (const [parent] of byParent) {
    if (parent == null) continue;
    if (!primaries.some((p) => p.label === parent)) {
      synthesisedHeaders.add(parent);
    }
  }

  return (
    <details
      className="mt-2 border-t border-neutral-800 pt-2 text-xs"
      open
    >
      <summary className="flex cursor-pointer items-center justify-between gap-2 text-neutral-300 hover:text-neutral-100">
        <span>
          Pending suggestions
          <span className="ml-2 rounded bg-blue-900/50 px-1.5 py-0.5 text-[10px] text-blue-200">
            {suggestions.length}
          </span>
        </span>
        <span className="flex gap-1">
          <button
            type="button"
            onClick={(e) => {
              e.preventDefault();
              acceptAll();
            }}
            className="rounded border border-emerald-700 bg-emerald-950/40 px-2 py-0.5 text-[10px] text-emerald-200 hover:bg-emerald-900/40"
          >
            Accept all
          </button>
          <button
            type="button"
            onClick={(e) => {
              e.preventDefault();
              rejectAll();
            }}
            className="rounded border border-neutral-700 px-2 py-0.5 text-[10px] text-neutral-300 hover:bg-neutral-800"
          >
            Reject all
          </button>
        </span>
      </summary>
      <div className="mt-2 flex flex-col gap-1.5">
        {primaries.map((primary) => (
          <SuggestionGroup
            key={`p::${primary.label}`}
            header={primary}
            children={byParent.get(primary.label) ?? []}
            threshold={threshold}
            onAccept={acceptOne}
            onReject={rejectOne}
          />
        ))}
        {Array.from(synthesisedHeaders).map((parent) => (
          <SuggestionGroup
            key={`syn::${parent}`}
            header={null}
            synthesisedHeaderLabel={parent}
            children={byParent.get(parent) ?? []}
            threshold={threshold}
            onAccept={acceptOne}
            onReject={rejectOne}
          />
        ))}
      </div>
    </details>
  );
}

function SuggestionGroup({
  header,
  synthesisedHeaderLabel,
  children,
  threshold,
  onAccept,
  onReject,
}: {
  header: TagSuggestion | null;
  synthesisedHeaderLabel?: string;
  children: TagSuggestion[];
  threshold: number;
  onAccept: (s: TagSuggestion) => void;
  onReject: (s: TagSuggestion) => void;
}) {
  return (
    <div className="flex flex-col gap-1">
      {header ? (
        <SuggestionChip
          suggestion={header}
          isPrimary
          threshold={threshold}
          onAccept={onAccept}
          onReject={onReject}
        />
      ) : (
        <div className="text-[10px] uppercase tracking-wide text-neutral-500">
          {synthesisedHeaderLabel}
        </div>
      )}
      {children.length > 0 && (
        <div className="ml-3 flex flex-col gap-1">
          {children.map((s) => (
            <SuggestionChip
              key={s.label}
              suggestion={s}
              isPrimary={false}
              threshold={threshold}
              onAccept={onAccept}
              onReject={onReject}
            />
          ))}
        </div>
      )}
    </div>
  );
}

function SuggestionChip({
  suggestion,
  isPrimary,
  threshold,
  onAccept,
  onReject,
}: {
  suggestion: TagSuggestion;
  isPrimary: boolean;
  threshold: number;
  onAccept: (s: TagSuggestion) => void;
  onReject: (s: TagSuggestion) => void;
}) {
  const conf = Math.max(0, Math.min(1, suggestion.confidence));
  const belowThreshold = conf < threshold;
  return (
    <div
      className={
        belowThreshold
          ? "flex items-center justify-between gap-2 rounded border border-neutral-800 bg-neutral-900/40 px-2 py-1 opacity-60"
          : "flex items-center justify-between gap-2 rounded border border-neutral-800 bg-neutral-900/40 px-2 py-1"
      }
    >
      <span className={isPrimary ? "font-medium text-neutral-100" : "text-neutral-200"}>
        {suggestion.label}
        <span className="ml-2 font-mono text-[10px] text-neutral-500">
          {Math.round(conf * 100)}%
        </span>
      </span>
      <span className="flex gap-1">
        <button
          type="button"
          onClick={() => onAccept(suggestion)}
          className="rounded border border-emerald-700 bg-emerald-950/40 px-1.5 py-0.5 text-[10px] text-emerald-200 hover:bg-emerald-900/40"
          aria-label={`Accept ${suggestion.label}`}
        >
          ✓
        </button>
        <button
          type="button"
          onClick={() => onReject(suggestion)}
          className="rounded border border-neutral-700 px-1.5 py-0.5 text-[10px] text-neutral-300 hover:bg-neutral-800"
          aria-label={`Reject ${suggestion.label}`}
        >
          ✕
        </button>
      </span>
    </div>
  );
}

