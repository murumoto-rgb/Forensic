/**
 * Runtime Chromium installer (Build #5.74.1).
 *
 * The Path-C PDF export keeps tripping on "Could not find Chrome
 * (ver. 149.0.7827.22)" on Render even after the build-command + env
 * var fixes from #5.66.1. Root cause is brittle: pnpm + Render build
 * cache + `PUPPETEER_CACHE_DIR` env var must all line up across both
 * the build phase and the runtime phase, and any one of those
 * drifting drops Chromium where puppeteer can't see it.
 *
 * This module sidesteps the whole chain at runtime: on server boot,
 * check whether the binary exists at the path `puppeteer.executablePath()`
 * returns. If it does, log + return immediately (the cache survived,
 * we're done). If it doesn't, use puppeteer's own
 * `@puppeteer/browsers` sub-dep — already on disk because it's a
 * transitive dep of `puppeteer` itself — to download Chromium into
 * whichever cache dir puppeteer is configured to look at. The
 * download is ~150 MB and takes ~30 s on a cold cache, but it
 * always lands in the right place.
 *
 * The check is fire-once-on-boot, not per-render — we call this from
 * `index.ts` AFTER the HTTP listener binds (so the `/healthz`
 * endpoint stays up even during the install), and AFTER `initSentry`
 * (so any install failure gets captured). The PDF worker waits for
 * this promise via `startPdfExportWorker`'s own startup gate.
 */

import { existsSync } from "node:fs";
import puppeteer from "puppeteer";
import {
  install,
  resolveBuildId,
  Browser,
  detectBrowserPlatform,
} from "@puppeteer/browsers";
import type { FastifyBaseLogger } from "fastify";
import { captureMessage } from "../sentry.js";

/** True once `ensureChromium` has resolved successfully. */
let chromiumReady = false;

export function isChromiumReady(): boolean {
  return chromiumReady;
}

export async function ensureChromium(log: FastifyBaseLogger): Promise<void> {
  if (chromiumReady) return;

  // Where puppeteer.launch() is going to look for the binary. This
  // reflects whatever PUPPETEER_CACHE_DIR was at puppeteer's import
  // time (Puppeteer reads it once and caches the resolved path).
  // `executablePath()` became async in puppeteer v25 — must await.
  let expectedPath: string;
  try {
    expectedPath = await puppeteer.executablePath();
  } catch (err) {
    // puppeteer.executablePath() throws when it can't determine the
    // path at all (very old or very new puppeteer versions, mostly).
    // Treat as "not installed" — the install path below picks up.
    log.warn(
      { err },
      "chromium boot — executablePath() threw, will attempt fresh install"
    );
    expectedPath = "";
  }

  if (expectedPath && existsSync(expectedPath)) {
    log.info(
      { chromiumPath: expectedPath },
      "chromium boot — binary present, no install needed"
    );
    chromiumReady = true;
    return;
  }

  log.warn(
    { expectedPath },
    "chromium boot — binary missing, downloading now (~150 MB, ~30 s)"
  );

  const platform = detectBrowserPlatform();
  if (!platform) {
    const msg = "chromium boot — could not detect browser platform";
    log.error(msg);
    captureMessage(msg, "error");
    throw new Error(msg);
  }

  // Honour PUPPETEER_CACHE_DIR explicitly so the download lands where
  // puppeteer.launch() will look. When the env var is unset, default
  // to the same `~/.cache/puppeteer` puppeteer itself defaults to.
  const cacheDir =
    process.env.PUPPETEER_CACHE_DIR ||
    `${process.env.HOME ?? "/root"}/.cache/puppeteer`;

  // Resolve a concrete build id matching puppeteer's pinned version.
  // `"latest"` works but pins drift across deploys; "stable" gives us
  // the channel Chromium calls stable, which is what puppeteer's own
  // install scripts use.
  const buildId = await resolveBuildId(Browser.CHROME, platform, "stable");

  const start = Date.now();
  await install({
    browser: Browser.CHROME,
    buildId,
    cacheDir,
  });
  const elapsedSec = Math.round((Date.now() - start) / 1000);

  log.info(
    { cacheDir, buildId, elapsedSec },
    "chromium boot — install complete"
  );
  chromiumReady = true;
}
