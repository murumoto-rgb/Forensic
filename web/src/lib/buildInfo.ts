/**
 * Build info baked into the bundle at compile time. Values come
 * from `vite.config.ts`'s `define` substitution — see there for
 * how they're resolved (Vercel env vars in production, local
 * `git rev-parse` in dev).
 *
 * Render this via `<BuildInfoFooter />` (in `web/src/lib/`); it
 * shows on every page so it's easy to confirm what's currently
 * deployed matches the last push.
 */

declare const __BUILD_SHA__: string;
declare const __BUILD_BRANCH__: string;
declare const __BUILD_TIME__: string;

export const buildInfo = {
  sha: __BUILD_SHA__,
  branch: __BUILD_BRANCH__,
  time: __BUILD_TIME__,
  display: `${__BUILD_BRANCH__}@${__BUILD_SHA__} · ${__BUILD_TIME__}`,
} as const;
