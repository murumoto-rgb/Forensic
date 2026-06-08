import { useState } from "react";
import { Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { signOutLocal, supabase } from "../lib/supabase";
import { useUserPrefs } from "../lib/useUserPrefs";
import { buildInfo } from "../lib/buildInfo";

/**
 * Settings page (Build #5.85.1).
 *
 * Web-side counterpart to iOS Settings. Sections:
 *   - Account — email, password change, sign out.
 *   - AI tagging preferences — model picker, confidence threshold,
 *     parallel-request concurrency. Backed by `useUserPrefs`
 *     (localStorage today; server-sync in a later PR).
 *   - Team-wide config — entry points to tag library + AI rules
 *     editors. Report-branding lands in a later PR.
 *   - Diagnostics — build SHA / branch / timestamp.
 *
 * iOS-only items (device Anthropic API key, team-server toggle,
 * accent color, app icon, storage status, sync/backfill buttons)
 * stay iOS-only by definition — see `docs/parity-matrix.md` →
 * "Platform exclusions".
 */
interface Props {
  session: Session;
}

export function SettingsPage({ session }: Props) {
  const prefs = useUserPrefs();

  return (
    <div className="mx-auto max-w-3xl px-6 py-10">
      <header className="mb-8 flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">Settings</h1>
          <p className="text-xs text-neutral-500">{session.user.email}</p>
        </div>
        <Link
          to="/projects"
          className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
        >
          ← Projects
        </Link>
      </header>

      <div className="flex flex-col gap-6">
        <AccountSection session={session} />
        <AIPreferencesSection prefs={prefs} />
        <TeamConfigSection />
        <DiagnosticsSection />
      </div>
    </div>
  );
}

function Card({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded border border-neutral-800 bg-neutral-950/40 p-5">
      <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-neutral-400">
        {title}
      </h2>
      {children}
    </section>
  );
}

function AccountSection({ session }: { session: Session }) {
  const [newPassword, setNewPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function changePassword() {
    if (newPassword.length < 8) {
      setError("Password must be at least 8 characters.");
      return;
    }
    setBusy(true);
    setError(null);
    setMessage(null);
    try {
      const { error: e } = await supabase.auth.updateUser({
        password: newPassword,
      });
      if (e) throw e;
      setNewPassword("");
      setMessage("Password updated.");
    } catch (e: unknown) {
      setError(
        e instanceof Error ? e.message : "Failed to update password"
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card title="Account">
      <dl className="mb-4 grid grid-cols-[max-content_1fr] gap-x-6 gap-y-1 text-sm">
        <dt className="text-neutral-500">Email</dt>
        <dd className="text-neutral-100">{session.user.email ?? "—"}</dd>
        <dt className="text-neutral-500">User ID</dt>
        <dd className="font-mono text-xs text-neutral-400">
          {session.user.id}
        </dd>
      </dl>
      <div className="mb-3 flex items-end gap-2">
        <label className="flex flex-1 flex-col gap-1 text-xs text-neutral-500">
          New password
          <input
            type="password"
            value={newPassword}
            onChange={(e) => setNewPassword(e.target.value)}
            disabled={busy}
            placeholder="At least 8 characters"
            className="rounded border border-neutral-700 bg-neutral-900 px-2 py-1 text-sm text-neutral-100 placeholder:text-neutral-600 focus:border-blue-600 focus:outline-none disabled:opacity-50"
          />
        </label>
        <button
          type="button"
          onClick={changePassword}
          disabled={busy || newPassword.length < 8}
          className="rounded border border-blue-700 bg-blue-900/40 px-3 py-1.5 text-sm text-blue-100 hover:bg-blue-900/70 disabled:opacity-50"
        >
          {busy ? "Saving…" : "Update password"}
        </button>
      </div>
      {message && <div className="text-xs text-green-400">{message}</div>}
      {error && <div className="text-xs text-red-400">{error}</div>}
      <div className="mt-5">
        <button
          type="button"
          onClick={() => signOutLocal()}
          className="rounded border border-red-800 px-3 py-1.5 text-sm text-red-300 hover:bg-red-900/30"
        >
          Sign out (this browser only)
        </button>
        <p className="mt-2 text-xs text-neutral-600">
          Sign-out is device-local — your iOS session stays active.
        </p>
      </div>
    </Card>
  );
}

function AIPreferencesSection({
  prefs,
}: {
  prefs: ReturnType<typeof useUserPrefs>;
}) {
  return (
    <Card title="AI tagging">
      <label className="mb-4 flex flex-col gap-1 text-xs">
        <span className="text-neutral-500">Model</span>
        <select
          value={prefs.model}
          onChange={(e) =>
            prefs.setModel(
              e.currentTarget.value as ReturnType<
                typeof useUserPrefs
              >["model"]
            )
          }
          className="max-w-xs rounded border border-neutral-700 bg-neutral-900 px-2 py-1 text-sm text-neutral-100"
        >
          <option value="claude-sonnet-4-6">
            Claude Sonnet 4.6 (careful, slower)
          </option>
          <option value="claude-haiku-4-5">
            Claude Haiku 4.5 (fast, cheaper)
          </option>
        </select>
        <span className="text-[11px] text-neutral-600">
          Used when re-tagging photos from the AI tab. Per-batch
          override is still available from the Re-tag modal.
        </span>
      </label>

      <label className="mb-4 flex flex-col gap-1 text-xs">
        <span className="text-neutral-500">
          Confidence threshold:{" "}
          <span className="font-mono text-neutral-300">
            {prefs.threshold.toFixed(2)}
          </span>
        </span>
        <input
          type="range"
          min={0}
          max={1}
          step={0.05}
          value={prefs.threshold}
          onChange={(e) =>
            prefs.setThreshold(Number.parseFloat(e.currentTarget.value))
          }
          className="max-w-xs accent-blue-500"
        />
        <span className="text-[11px] text-neutral-600">
          Tags below this confidence are hidden from tag chips, filter
          bars, and PDF export. Matches iOS Settings → Tag confidence.
        </span>
      </label>

      <label className="flex flex-col gap-1 text-xs">
        <span className="text-neutral-500">
          Parallel AI requests:{" "}
          <span className="font-mono text-neutral-300">
            {prefs.concurrency}
          </span>
        </span>
        <input
          type="range"
          min={1}
          max={20}
          step={1}
          value={prefs.concurrency}
          onChange={(e) =>
            prefs.setConcurrency(Number.parseInt(e.currentTarget.value, 10))
          }
          className="max-w-xs accent-blue-500"
        />
        <span className="text-[11px] text-neutral-600">
          Higher = faster batch runs but more likely to hit
          Anthropic's rate limit. 3 is safe on Tier 1.
        </span>
      </label>
    </Card>
  );
}

function TeamConfigSection() {
  return (
    <Card title="Team-wide configuration">
      <p className="mb-3 text-xs text-neutral-500">
        These settings affect everyone on your team — edit with care.
      </p>
      <div className="flex flex-wrap gap-2">
        <Link
          to="/admin/tag-library"
          className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-200 hover:bg-neutral-800"
        >
          Tag library →
        </Link>
        <Link
          to="/admin/ai-rules"
          className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-200 hover:bg-neutral-800"
        >
          AI rules template →
        </Link>
      </div>
      <p className="mt-3 text-xs text-neutral-600">
        Report branding (logos, colors, header text) lands in a later
        PR.
      </p>
    </Card>
  );
}

function DiagnosticsSection() {
  return (
    <Card title="Diagnostics">
      <dl className="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-1 font-mono text-xs text-neutral-300">
        <dt className="text-neutral-500">Build #</dt>
        <dd>{buildInfo.number || "(dev)"}</dd>
        <dt className="text-neutral-500">Branch</dt>
        <dd>{buildInfo.branch}</dd>
        <dt className="text-neutral-500">SHA</dt>
        <dd>{buildInfo.sha}</dd>
        <dt className="text-neutral-500">Built</dt>
        <dd>{buildInfo.time}</dd>
      </dl>
    </Card>
  );
}
