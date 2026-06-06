/**
 * Puppeteer configuration (Build #5.62.1).
 *
 * Honors `PUPPETEER_CACHE_DIR` when set (Render uses
 * `/opt/render/.cache/puppeteer` so the Chromium binary survives
 * across deploys). Falls back to Puppeteer's default
 * (`~/.cache/puppeteer`) for local dev.
 *
 * Without this file, Puppeteer creates its cache at install-time
 * relative to the project root by default on some setups, which
 * breaks the deploy-cache survival on Render.
 */

const { join } = require("path");

const fromEnv = process.env.PUPPETEER_CACHE_DIR;

/** @type {import("puppeteer").Configuration} */
module.exports = {
  cacheDirectory: fromEnv && fromEnv.length > 0
    ? fromEnv
    : join(require("os").homedir(), ".cache", "puppeteer"),
};
