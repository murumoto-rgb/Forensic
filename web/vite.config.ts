import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { execSync } from "node:child_process";
import { readdirSync } from "node:fs";
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
 * Read the dotted build number from `docs/builds/`. One file per
 * build, named `N.M.P.md`; take the version-sorted maximum
 * filename and strip the `.md` extension. Returns empty string if
 * the directory doesn't exist or is empty (older worktrees pre-
 * Build-1). See `docs/builds.md` for the registry layout.
 */
function readBuildNumber(): string {
  try {
    const buildsDir = resolve(__dirname, "..", "docs", "builds");
    const versions = readdirSync(buildsDir)
      .filter((f) => f.endsWith(".md"))
      .map((f) => f.replace(/\.md$/, ""));
    if (versions.length === 0) return "";
    versions.sort((a, b) => {
      const aParts = a.split(".").map(Number);
      const bParts = b.split(".").map(Number);
      const len = Math.max(aParts.length, bParts.length);
      for (let i = 0; i < len; i++) {
        const diff = (aParts[i] ?? 0) - (bParts[i] ?? 0);
        if (diff !== 0) return diff;
      }
      return 0;
    });
    return versions[versions.length - 1] ?? "";
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
