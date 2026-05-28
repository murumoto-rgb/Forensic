import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { execSync } from "node:child_process";

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

const buildSha =
  process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 8) ??
  shellOrFallback("git rev-parse --short=8 HEAD", "dev");
const buildBranch =
  process.env.VERCEL_GIT_COMMIT_REF ??
  shellOrFallback("git rev-parse --abbrev-ref HEAD", "dev");
const buildTime = new Date().toISOString();

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
  },
  define: {
    __BUILD_SHA__: JSON.stringify(buildSha),
    __BUILD_BRANCH__: JSON.stringify(buildBranch),
    __BUILD_TIME__: JSON.stringify(buildTime),
  },
});
