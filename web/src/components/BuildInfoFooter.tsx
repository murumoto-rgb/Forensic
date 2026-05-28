import { buildInfo } from "../lib/buildInfo";

/**
 * Small low-contrast badge fixed to the bottom-right of the
 * viewport on every page. Shows the build's branch + short SHA +
 * UTC timestamp so the engineer can verify the deployed bundle
 * matches the most recently pushed code.
 *
 * Text is selectable for easy copy-into-Slack-or-issue. `pointer-
 * events-none` on the container leaves clicks falling through
 * to the page; the inner span re-enables them so text selection
 * works.
 */
export function BuildInfoFooter() {
  return (
    <div className="pointer-events-none fixed bottom-2 right-2 z-50 select-text font-mono text-[10px] text-neutral-600">
      <span className="pointer-events-auto">{buildInfo.display}</span>
    </div>
  );
}
