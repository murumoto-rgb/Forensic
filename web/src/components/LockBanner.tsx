import { useState } from "react";
import type { LockStatus } from "../lib/useProjectLock";

/**
 * Header banner that drives the project edit-lock UX (Build #5.60.1;
 * `holding_elsewhere` branch added #5.120.1).
 *
 * Renders different shapes for each `LockStatus.kind`:
 *  - **loading** — quiet "Checking lock…" placeholder so the rest of
 *    the page can render without flicker.
 *  - **free** — neutral row with an "Edit" button. Clicking acquires.
 *  - **holding** — green pill ("You're editing"), the holder's email
 *    + acquired-at, a "Release" button. While holding, edit controls
 *    elsewhere on the page are enabled.
 *  - **holding_elsewhere** — same user holds the lock from another
 *    tab/device. "Resume here" calls `acquire` to take it for this
 *    tab (succeeds — server lets the same user re-acquire).
 *  - **read_only** — amber banner naming the holder ("Currently
 *    editing: alice@…, since 11:42") plus a "Force release" button
 *    (visible to everyone for now — Phase 5 may admin-gate it).
 *  - **lock_lost** — red banner explaining the lock expired or was
 *    forced; "Re-acquire" + "Dismiss" buttons.
 *  - **error** — red banner with the message; "Retry" hits refresh.
 *
 * The banner is the ONLY component that calls `acquire`, `release`,
 * `force`, and `acknowledgeLost` — pages stay focused on their
 * normal render paths.
 */
interface Props {
  status: LockStatus;
  acquire: () => Promise<void>;
  release: () => Promise<void>;
  /** Resolves true when the force landed; false when the server
   *  rejected it (e.g. the #6.11.1 owner-or-admin 403). */
  force: () => Promise<boolean>;
  refresh: () => Promise<void>;
  acknowledgeLost: () => void;
}

function formatRelativeTime(iso: string): string {
  const d = new Date(iso);
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

export function LockBanner({
  status,
  acquire,
  release,
  force,
  refresh,
  acknowledgeLost,
}: Props) {
  const [confirmingForce, setConfirmingForce] = useState(false);

  if (status.kind === "loading") {
    return (
      <div className="mb-4 rounded border border-neutral-800 bg-neutral-900/60 px-3 py-2 text-xs text-neutral-500">
        Checking edit lock…
      </div>
    );
  }

  if (status.kind === "free") {
    return (
      <div className="mb-4 flex items-center justify-between gap-3 rounded border border-neutral-800 bg-neutral-900/60 px-3 py-2 text-sm">
        <span className="text-neutral-400">
          This project is read-only until you take the edit lock.
        </span>
        <button
          type="button"
          onClick={() => void acquire()}
          className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1 text-xs font-medium text-white hover:bg-blue-600"
        >
          Edit
        </button>
      </div>
    );
  }

  if (status.kind === "holding") {
    return (
      <div className="mb-4 flex items-center justify-between gap-3 rounded border border-green-800 bg-green-950/30 px-3 py-2 text-sm">
        <div className="flex items-center gap-2 text-green-200">
          <span className="inline-block h-2 w-2 rounded-full bg-green-400" />
          <span>
            You're editing this project — others see it as read-only.
          </span>
        </div>
        <button
          type="button"
          onClick={() => void release()}
          className="rounded border border-green-700 bg-green-900/40 px-3 py-1 text-xs text-green-100 hover:bg-green-900/60"
        >
          Release lock
        </button>
      </div>
    );
  }

  if (status.kind === "holding_elsewhere") {
    const since = formatRelativeTime(status.lock.acquiredAt);
    const clientLabel = status.lock.client === "ios" ? "iPad" : "another tab";
    return (
      <div className="mb-4 flex items-center justify-between gap-3 rounded border border-amber-800 bg-amber-950/30 px-3 py-2 text-sm">
        <div className="flex items-center gap-2 text-amber-200">
          <span className="inline-block h-2 w-2 rounded-full bg-amber-400" />
          <span>
            You're editing this in {clientLabel}{" "}
            <span className="text-amber-400/80">(since {since})</span>.
          </span>
        </div>
        <button
          type="button"
          onClick={() => void acquire()}
          className="rounded border border-blue-500 bg-blue-600/80 px-3 py-1 text-xs font-medium text-white hover:bg-blue-600"
        >
          Resume here
        </button>
      </div>
    );
  }

  if (status.kind === "read_only") {
    const since = formatRelativeTime(status.lock.acquiredAt);
    const clientLabel = status.lock.client === "ios" ? "iPad" : "web";
    return (
      <div className="mb-4 flex flex-col gap-2 rounded border border-amber-800 bg-amber-950/30 px-3 py-2 text-sm sm:flex-row sm:items-center sm:justify-between">
        <div className="flex items-center gap-2 text-amber-200">
          <span className="inline-block h-2 w-2 rounded-full bg-amber-400" />
          <span>
            Currently editing on {clientLabel}:{" "}
            <span className="font-medium">{status.lock.userEmail}</span>{" "}
            <span className="text-amber-400/80">since {since}</span>
          </span>
        </div>
        <div className="flex items-center gap-2">
          {confirmingForce ? (
            <>
              <span className="text-xs text-amber-300">
                Take it from them?
              </span>
              <button
                type="button"
                onClick={async () => {
                  setConfirmingForce(false);
                  // Only chain the acquire when the force landed —
                  // otherwise the acquire's re-fetch would replace
                  // the 403 error banner before it could be read.
                  if (await force()) {
                    await acquire();
                  }
                }}
                className="rounded border border-red-600 bg-red-950/60 px-3 py-1 text-xs text-red-100 hover:bg-red-900/60"
              >
                Force release
              </button>
              <button
                type="button"
                onClick={() => setConfirmingForce(false)}
                className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
              >
                Cancel
              </button>
            </>
          ) : (
            <button
              type="button"
              onClick={() => setConfirmingForce(true)}
              className="rounded border border-amber-700 px-3 py-1 text-xs text-amber-200 hover:bg-amber-900/40"
              title="Forcibly release someone else's lock and take it for yourself. Logged on the server."
            >
              Force release
            </button>
          )}
        </div>
      </div>
    );
  }

  if (status.kind === "lock_lost") {
    return (
      <div className="mb-4 flex items-center justify-between gap-3 rounded border border-red-800 bg-red-950/40 px-3 py-2 text-sm">
        <span className="text-red-200">
          Your edit lock was lost (expired or force-released). Unsaved
          changes may not have reached the server.
        </span>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => void acquire()}
            className="rounded border border-red-500 bg-red-600/80 px-3 py-1 text-xs font-medium text-white hover:bg-red-600"
          >
            Re-acquire
          </button>
          <button
            type="button"
            onClick={acknowledgeLost}
            className="rounded border border-neutral-700 px-3 py-1 text-xs text-neutral-300 hover:bg-neutral-800"
          >
            Dismiss
          </button>
        </div>
      </div>
    );
  }

  // error
  return (
    <div className="mb-4 flex items-center justify-between gap-3 rounded border border-red-800 bg-red-950/40 px-3 py-2 text-sm text-red-300">
      <span>Lock state: {status.message}</span>
      <button
        type="button"
        onClick={() => void refresh()}
        className="rounded border border-red-500 px-3 py-1 text-xs text-red-100 hover:bg-red-900/40"
      >
        Retry
      </button>
    </div>
  );
}
