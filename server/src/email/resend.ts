/**
 * Resend transactional-email client (Build #5.61.1).
 *
 * Drives the collaboration-safety notifications: "your edit lock was
 * force-released," "your lock expired and someone else picked it up."
 * The pattern mirrors `sentry.ts` — conditional initialization on the
 * `RESEND_API_KEY` + `RESEND_FROM_EMAIL` env vars so dev runs (and
 * any deploy where the keys aren't set yet) stay 100% offline. Every
 * helper here no-ops cleanly when email is off.
 *
 * Send sites (currently `routes/locks.ts`) should fire-and-forget:
 *
 *   void sendEmail({ to, subject, html, text });
 *
 * Failures are swallowed into a server-side log + Sentry breadcrumb;
 * they NEVER bubble into the API response. A lock route returning
 * 500 because a hosted SMTP relay had a hiccup would be far worse
 * than the user not getting a courtesy notification.
 */

import { Resend } from "resend";
import { env } from "../env.js";
import { captureMessage } from "../sentry.js";

let resend: Resend | null = null;
let fromAddress: string | null = null;

export function initEmail(): void {
  // All three vars are required — without WEB_BASE_URL the "Open
  // project" link in every template would have no host and arrive in
  // the user's mailbox as a broken relative URL. Better to no-op than
  // to send a dead link.
  if (
    !env.RESEND_API_KEY ||
    !env.RESEND_FROM_EMAIL ||
    !env.WEB_BASE_URL
  ) {
    return;
  }
  resend = new Resend(env.RESEND_API_KEY);
  fromAddress = env.RESEND_FROM_EMAIL;
}

/** True when API key + from address + web base URL were all
 *  present at boot. */
export function isEmailReady(): boolean {
  return resend !== null && fromAddress !== null;
}

export interface SendEmailArgs {
  to: string;
  subject: string;
  /** HTML body (rendered preferentially by every modern client). */
  html: string;
  /** Plain-text fallback (mandatory for deliverability — many
   *  filters score HTML-only mails harder). */
  text: string;
}

/**
 * Fire-and-forget send. Returns a promise so callers can `await` if
 * they want, but the standard call site is `void sendEmail(...)`.
 * Logs + Sentry-warns on failure; never throws.
 */
export async function sendEmail(args: SendEmailArgs): Promise<void> {
  if (!resend || !fromAddress) {
    // Email disabled — silent no-op so route handlers don't have to
    // guard every send.
    return;
  }
  try {
    const result = await resend.emails.send({
      from: fromAddress,
      to: args.to,
      subject: args.subject,
      html: args.html,
      text: args.text,
    });
    if (result.error) {
      captureMessage(
        `Resend send failed: ${result.error.message}`,
        "warning",
        { to: args.to, subject: args.subject, errorName: result.error.name }
      );
    }
  } catch (e: unknown) {
    captureMessage(
      `Resend threw: ${e instanceof Error ? e.message : String(e)}`,
      "warning",
      { to: args.to, subject: args.subject }
    );
  }
}
