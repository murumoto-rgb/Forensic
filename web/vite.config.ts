import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// Build info — embedded into the bundle at compile time via Vite's
// `define` substitution. Source of truth: Vercel's automatic env
// vars in production; local `git rev-parse` in dev. Falls back to
// "dev" if neither is reachable so the build doesn't break.
function shellOrFallback(cmd: string, fallback: string): string {
  try {
    return execSync(cmd, { encoding: "utf-8" }).trim();
  } catch {
    return fallback;
  }
}

/**
 * Read the sequential build number from `docs/builds.md`. Returns
 * the highest `## Build N` heading we find (entries should be in
 * descending order with the latest at the top). Returns empty
 * string if the file doesn't exist or has no entries — older
 * worktrees pre-Build-1.
 */
function readBuildNumber(): string {
  try {
    const buildsPath = resolve(__dirname, "..", "docs", "builds.md");
    const text = readFileSync(buildsPath, "utf-8");
    const match = /^## Build (\d+)/m.exec(text);
    return match?.[1] ?? "";
  } catch {
    return "";
  }
}

const buildSha =
  process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 8) ??
  shellOrFallback("git rev-parse --short=8 HEAD", "dev");
const buildBranch =
  process.env.VERCEL_GIT_COMMIT_REF ??
  shellOrFallback("git rev-parse --abbrev-ref HEAD", "dev");
const buildTime = new Date().toISOString();
const buildNumber = readBuildNumber();

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
  },
  define: {
    __BUILD_SHA__: JSON.stringify(buildSha),
    __BUILD_BRANCH__: JSON.stringify(buildBranch),
    __BUILD_TIME__: JSON.stringify(buildTime),
    __BUILD_NUMBER__: JSON.stringify(buildNumber),
  },
});
