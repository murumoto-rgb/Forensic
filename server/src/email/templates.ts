/**
 * Email templates for the collaboration-safety notifications
 * (Build #5.61.1). Plain-HTML output — no template engine, no
 * external CSS, no images. Keeps deliverability tight and the
 * dependency surface flat. Inline styles match the rest of the
 * app's neutral palette so the mail looks like it belongs.
 *
 * Each template returns `{subject, html, text}` ready to feed
 * straight into `sendEmail()`. The HTML and text bodies carry the
 * same information; render targets pick whichever they prefer.
 */

import type { SendEmailArgs } from "./resend.js";

interface BaseProjectArgs {
  projectId: string;
  projectName: string;
  /** Full URL of the web app — used to build a "reopen project" link. */
  webBaseUrl: string;
}

interface LockForceReleasedArgs extends BaseProjectArgs {
  /** Email of the person who clicked Force release. */
  actorEmail: string;
}

interface LockTakenOverArgs extends BaseProjectArgs {
  /** Email of the person who acquired your expired lock. */
  newHolderEmail: string;
}

function escape(s: string): string {
  // Light HTML escape for the values we splice into the templates.
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function projectUrl(args: BaseProjectArgs): string {
  // Trim a trailing slash so `${base}/projects/${id}` is well-formed
  // for both `https://app.example.com` and `https://app.example.com/`.
  const base = args.webBaseUrl.replace(/\/$/, "");
  return `${base}/projects/${encodeURIComponent(args.projectId)}`;
}

function shell(bodyHtml: string): string {
  // Single-column, inline-styled. Mirrors the in-app neutral palette
  // (neutral-900 background, neutral-100 body text) so the mail
  // feels like part of the app. No image refs — many corporate
  // filters strip remote images by default and the layout has to
  // hold up without them.
  return `<!doctype html>
<html><body style="margin:0;background:#0a0a0a;padding:24px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;color:#f5f5f5;">
  <div style="max-width:560px;margin:0 auto;background:#171717;border:1px solid #262626;border-radius:8px;padding:24px;">
    ${bodyHtml}
    <hr style="border:0;border-top:1px solid #262626;margin:24px 0;">
    <div style="font-size:11px;color:#737373;">
      You're receiving this because you were the active editor on a
      Forensic project. These notifications can't be turned off — they're
      sent only when another user takes the edit lock from you.
    </div>
  </div>
</body></html>`;
}

export function lockForceReleasedEmail(
  args: LockForceReleasedArgs
): SendEmailArgs & { to: string } {
  // Don't have the recipient email here — caller supplies `to` on the
  // send call. We just compose the body.
  const url = projectUrl(args);
  const subject = `Your edit lock on "${args.projectName}" was taken`;
  const html = shell(`
    <h2 style="margin:0 0 12px;font-size:18px;color:#fafafa;">
      Your edit lock was taken
    </h2>
    <p style="margin:0 0 12px;line-height:1.45;">
      <strong style="color:#fafafa;">${escape(args.actorEmail)}</strong>
      force-released your edit lock on
      <strong style="color:#fafafa;">${escape(args.projectName)}</strong>
      and is now editing the project.
    </p>
    <p style="margin:0 0 16px;line-height:1.45;color:#a3a3a3;">
      Any unsaved edits you had open in your browser tab will not have
      reached the server. Re-open the project to see the current state
      and re-acquire the lock if you need to continue editing.
    </p>
    <a href="${url}" style="display:inline-block;background:#2563eb;color:#fff;text-decoration:none;padding:10px 16px;border-radius:6px;font-weight:500;">
      Open project
    </a>
    <p style="margin:16px 0 0;font-size:11px;color:#737373;">
      ${escape(url)}
    </p>
  `);
  const text = [
    `Your edit lock was taken`,
    ``,
    `${args.actorEmail} force-released your edit lock on "${args.projectName}" and is now editing the project.`,
    ``,
    `Any unsaved edits you had open in your browser tab will not have reached the server. Re-open the project to see the current state and re-acquire the lock if you need to continue editing.`,
    ``,
    `Open project: ${url}`,
  ].join("\n");
  return { to: "", subject, html, text };
}

export function lockExpiredTakenOverEmail(
  args: LockTakenOverArgs
): SendEmailArgs & { to: string } {
  const url = projectUrl(args);
  const subject = `Your edit lock on "${args.projectName}" expired`;
  const html = shell(`
    <h2 style="margin:0 0 12px;font-size:18px;color:#fafafa;">
      Your edit lock expired
    </h2>
    <p style="margin:0 0 12px;line-height:1.45;">
      Your edit lock on
      <strong style="color:#fafafa;">${escape(args.projectName)}</strong>
      timed out (10 minutes without a heartbeat), and
      <strong style="color:#fafafa;">${escape(args.newHolderEmail)}</strong>
      has since taken over editing the project.
    </p>
    <p style="margin:0 0 16px;line-height:1.45;color:#a3a3a3;">
      The lock expires automatically if your tab is closed or backgrounded
      for too long. Re-open the project to view the current state.
    </p>
    <a href="${url}" style="display:inline-block;background:#2563eb;color:#fff;text-decoration:none;padding:10px 16px;border-radius:6px;font-weight:500;">
      Open project
    </a>
    <p style="margin:16px 0 0;font-size:11px;color:#737373;">
      ${escape(url)}
    </p>
  `);
  const text = [
    `Your edit lock expired`,
    ``,
    `Your edit lock on "${args.projectName}" timed out (10 minutes without a heartbeat), and ${args.newHolderEmail} has since taken over editing the project.`,
    ``,
    `The lock expires automatically if your tab is closed or backgrounded for too long. Re-open the project to view the current state.`,
    ``,
    `Open project: ${url}`,
  ].join("\n");
  return { to: "", subject, html, text };
}
