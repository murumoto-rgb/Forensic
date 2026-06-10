import { useEffect } from "react";

/**
 * Bind an Escape-key handler that fires only when the gate is true
 * (Build #6.17.1). Lets modal callers add a single hook line —
 * `useEscapeKey(showModal, onClose)` — to honor the standard Escape
 * dismissal that browser dialogs ship with by default but custom
 * `role="dialog"` divs do not.
 *
 * The listener is attached at `window` rather than the modal element
 * itself because the modal opens in a portal-style fixed overlay and
 * may not own focus. Stopping propagation is left to the caller (the
 * handler is keyboard-only so it can't double-dismiss via mouse).
 */
export function useEscapeKey(active: boolean, onEscape: () => void): void {
  useEffect(() => {
    if (!active) return;
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") {
        e.preventDefault();
        onEscape();
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [active, onEscape]);
}
