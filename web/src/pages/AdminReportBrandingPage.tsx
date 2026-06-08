import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type { ReportBranding } from "@forensic/shared";
import { signOutLocal, supabase } from "../lib/supabase";
import { api, ApiError } from "../lib/api";
import { uploadFile } from "../lib/uploadFile";

/**
 * Admin editor for the team's report branding (Build #5.92.1).
 *
 * Backed by `app_config.reportBranding` — both iOS and the
 * server-side PDF exporter read this key at render time. Four
 * editable fields:
 *
 *   - Title override   — replaces the project name on the PDF
 *     top-of-page H1 when set.
 *   - Subtitle         — typically the firm or report kind.
 *   - Footer           — appears at the bottom of every page.
 *   - Logo             — PNG uploaded as `kind=markup_png` to a
 *     branding-namespaced photoId. Storage path is written to
 *     `logoStoragePath`; the PDF exporter resolves a presigned-GET
 *     URL at render time.
 *
 * Same revision-token optimistic-concurrency model as the other
 * `app_config` admin pages; 409 surfaces as a banner with reload
 * instructions.
 */
interface Props {
  session: Session;
}

interface LoadedState {
  branding: ReportBranding;
  revision: string | null;
}

const EMPTY: ReportBranding = {
  titleOverride: null,
  subtitleOverride: null,
  footerOverride: null,
  logoStoragePath: null,
};

/** Synthetic photoId used as the second URL segment for branding
 *  blobs. The upload endpoint's `kind=markup_png` slot accepts any
 *  UUID-shaped second segment; we use a project's "branding-bucket"
 *  conceptually here — the project param is the calling user's
 *  first project, which any signed-in user has at least one of
 *  (the team-wide concept is enforced by app_config, not by
 *  project ownership). Phase 5's per-team scoping will revisit. */
function brandingPhotoId(): string {
  return crypto.randomUUID();
}

export function AdminReportBrandingPage({ session }: Props) {
  const [load, setLoad] = useState<
    LoadedState | "loading" | { error: string }
  >("loading");
  const [draft, setDraft] = useState<ReportBranding>(EMPTY);
  const [dirty, setDirty] = useState(false);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [savedAt, setSavedAt] = useState<number | null>(null);
  const revisionRef = useRef<string | null>(null);
  const logoInputRef = useRef<HTMLInputElement | null>(null);
  const [uploadingLogo, setUploadingLogo] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [firstProjectId, setFirstProjectId] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoad("loading");
    api
      .getReportBrandingConfig()
      .then((resp) => {
        if (cancelled) return;
        if (!resp) {
          setLoad({ branding: EMPTY, revision: null });
          setDraft(EMPTY);
          revisionRef.current = null;
        } else {
          setLoad({ branding: resp.value, revision: resp.revision });
          setDraft(resp.value);
          revisionRef.current = resp.revision;
        }
      })
      .catch((e: unknown) => {
        if (cancelled) return;
        setLoad({
          error:
            e instanceof ApiError
              ? `${e.status} ${e.errorCode}: ${e.message}`
              : "Failed to load report branding.",
        });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Fetch any one of the calling user's projects so the logo upload
  // can scope its R2 object key. (The /files/upload-url endpoint
  // currently requires a project id in the path; branding-asset
  // uploads piggy-back on any project the user owns.)
  useEffect(() => {
    let cancelled = false;
    api
      .listProjects()
      .then((resp) => {
        if (cancelled) return;
        const first = resp.projects[0];
        if (first) setFirstProjectId(first.id);
      })
      .catch(() => {
        if (!cancelled) setFirstProjectId(null);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  function update(field: keyof ReportBranding, value: string | null) {
    setDraft((cur) => ({ ...cur, [field]: value }));
    setDirty(true);
    setSavedAt(null);
    setSaveError(null);
  }

  function discard() {
    if (typeof load === "object" && "branding" in load) {
      setDraft(load.branding);
    } else {
      setDraft(EMPTY);
    }
    setDirty(false);
    setSaveError(null);
  }

  async function save() {
    setSaving(true);
    setSaveError(null);
    try {
      const expectedRevision = revisionRef.current;
      const { data: sessionData } = await supabase.auth.getSession();
      const jwt = sessionData.session?.access_token;
      const resp = await fetch(
        `${import.meta.env.VITE_API_URL ?? ""}/v1/config/reportBranding`,
        {
          method: "PUT",
          headers: {
            "content-type": "application/json",
            ...(jwt ? { Authorization: `Bearer ${jwt}` } : {}),
          },
          body: JSON.stringify({
            value: draft,
            expectedRevision,
          }),
        }
      );
      if (!resp.ok) {
        const body = (await resp.json().catch(() => ({}))) as {
          error?: string;
          message?: string;
        };
        if (resp.status === 409) {
          throw new ApiError(
            409,
            body.error ?? "revision_mismatch",
            body.message ??
              "Report branding was modified elsewhere. Reload to merge."
          );
        }
        throw new ApiError(
          resp.status,
          body.error ?? "unknown",
          body.message ?? `Save failed (${resp.status})`
        );
      }
      const okBody = (await resp.json()) as { revision: string };
      revisionRef.current = okBody.revision;
      setLoad({ branding: draft, revision: okBody.revision });
      setDirty(false);
      setSavedAt(Date.now());
    } catch (e: unknown) {
      setSaveError(
        e instanceof ApiError
          ? e.message
          : e instanceof Error
            ? e.message
            : "Save failed."
      );
    } finally {
      setSaving(false);
    }
  }

  function openLogoPicker() {
    if (!firstProjectId) {
      setUploadError(
        "Create at least one project before uploading a logo (the upload endpoint scopes by project)."
      );
      return;
    }
    logoInputRef.current?.click();
  }

  async function onLogoFileChosen(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.currentTarget.files?.[0];
    e.currentTarget.value = "";
    if (!file || !firstProjectId) return;
    if (!file.type.startsWith("image/")) {
      setUploadError("Logo must be an image.");
      return;
    }
    setUploadingLogo(true);
    setUploadError(null);
    try {
      const photoId = brandingPhotoId();
      await uploadFile({
        projectId: firstProjectId,
        photoId,
        kind: "markup_png",
        file,
        contentType: file.type || "image/png",
      });
      // Storage path mirrors `server/src/r2.ts:buildObjectKey` shape:
      // <projectId>/<photoId>/<kind>. We stash the full key so PDF
      // export can presign-GET it directly.
      const objectKey = `${firstProjectId}/${photoId}/markup_png`;
      update("logoStoragePath", objectKey);
    } catch (e: unknown) {
      setUploadError(e instanceof Error ? e.message : "Logo upload failed.");
    } finally {
      setUploadingLogo(false);
    }
  }

  function clearLogo() {
    update("logoStoragePath", null);
  }

  const loaded = typeof load === "object" && "branding" in load ? load : null;
  const loadError = typeof load === "object" && "error" in load ? load.error : null;

  return (
    <div className="mx-auto max-w-3xl px-6 py-10">
      <header className="mb-6 flex items-center justify-between">
        <div>
          <Link
            to="/settings"
            className="text-xs text-neutral-500 hover:text-neutral-300"
          >
            ← Settings
          </Link>
          <h1 className="text-2xl font-semibold">Report branding</h1>
          <p className="text-xs text-neutral-500">{session.user.email}</p>
        </div>
        <button
          type="button"
          onClick={() => signOutLocal()}
          className="rounded border border-neutral-700 px-3 py-1 text-sm text-neutral-300 hover:bg-neutral-800"
        >
          Sign out
        </button>
      </header>

      <p className="mb-4 text-sm text-neutral-400">
        Team-wide PDF export customisations. Both iOS and the
        server-side PDF exporter read these at render time. Empty
        fields fall back to the compile-time defaults (project name
        as title, etc).
      </p>

      {load === "loading" && (
        <div className="text-sm text-neutral-500">Loading…</div>
      )}
      {loadError && (
        <div className="rounded border border-red-800 bg-red-950/40 p-3 text-sm text-red-300">
          {loadError}
        </div>
      )}

      {loaded && (
        <div className="flex flex-col gap-4">
          <Field
            label="Title override"
            value={draft.titleOverride ?? ""}
            onChange={(v) =>
              update("titleOverride", v.trim() === "" ? null : v)
            }
            placeholder="(uses the project name when blank)"
          />
          <Field
            label="Subtitle"
            value={draft.subtitleOverride ?? ""}
            onChange={(v) =>
              update("subtitleOverride", v.trim() === "" ? null : v)
            }
            placeholder="e.g. Baykal Forensics — preliminary report"
          />
          <Field
            label="Footer"
            value={draft.footerOverride ?? ""}
            onChange={(v) =>
              update("footerOverride", v.trim() === "" ? null : v)
            }
            placeholder="e.g. © Baykal Forensics 2026"
          />

          {/* Logo */}
          <div className="rounded border border-neutral-800 bg-neutral-900/40 p-3">
            <div className="mb-2 text-xs uppercase tracking-wide text-neutral-500">
              Logo
            </div>
            <input
              ref={logoInputRef}
              type="file"
              accept="image/*"
              onChange={onLogoFileChosen}
              className="hidden"
            />
            <div className="flex flex-wrap items-center gap-2">
              <button
                type="button"
                onClick={openLogoPicker}
                disabled={uploadingLogo}
                className="rounded border border-blue-700 bg-blue-900/40 px-3 py-1.5 text-sm text-blue-100 hover:bg-blue-900/60 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {uploadingLogo ? "Uploading…" : "Upload logo"}
              </button>
              {draft.logoStoragePath && (
                <button
                  type="button"
                  onClick={clearLogo}
                  className="rounded border border-red-800 px-3 py-1.5 text-sm text-red-300 hover:bg-red-950/40"
                >
                  Clear
                </button>
              )}
            </div>
            {draft.logoStoragePath && (
              <p className="mt-2 break-all font-mono text-[11px] text-neutral-500">
                {draft.logoStoragePath}
              </p>
            )}
            {uploadError && (
              <p className="mt-2 text-xs text-red-400">{uploadError}</p>
            )}
            <p className="mt-2 text-[11px] text-neutral-600">
              Uploads use the same R2 pipeline as photo uploads.
              Logo storage path is what the PDF exporter resolves to
              a presigned-GET URL at render time.
            </p>
          </div>

          {/* Footer controls */}
          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={save}
              disabled={!dirty || saving}
              className="rounded border border-blue-700 bg-blue-900/40 px-3 py-1.5 text-sm text-blue-100 hover:bg-blue-900/60 disabled:cursor-not-allowed disabled:opacity-50"
            >
              {saving ? "Saving…" : "Save"}
            </button>
            <button
              type="button"
              onClick={discard}
              disabled={!dirty || saving}
              className="rounded border border-neutral-700 px-3 py-1.5 text-sm text-neutral-300 hover:bg-neutral-800 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Discard changes
            </button>
            {savedAt && !dirty && (
              <span className="text-xs text-green-400">
                Saved · {new Date(savedAt).toLocaleTimeString()}
              </span>
            )}
            {saveError && (
              <span className="text-xs text-red-400">{saveError}</span>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function Field({
  label,
  value,
  onChange,
  placeholder,
}: {
  label: string;
  value: string;
  onChange: (next: string) => void;
  placeholder?: string;
}) {
  return (
    <label className="flex flex-col gap-1 text-xs text-neutral-500">
      {label}
      <input
        type="text"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={placeholder}
        className="rounded border border-neutral-700 bg-neutral-900 px-3 py-2 text-sm text-neutral-100 placeholder:text-neutral-600 focus:border-blue-600 focus:outline-none"
      />
    </label>
  );
}
