import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import type { ReportBranding } from "@forensic/shared";
import { signOutLocal, supabase } from "../lib/supabase";
import { api, ApiError } from "../lib/api";
import { brandingLogoData } from "../lib/brandingLogo";

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
 *   - Logo             — a small PNG in the app-wide branding store.
 *     Publishing its immutable key uses the same config revision check.
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
  const [logoPreview, setLogoPreview] = useState<string | null>(null);
  const savedLogoPreview = useRef<string | null>(null);
  const savedLogoKey = useRef<string | null>(null);
  const draftLogoKey = useRef<string | null>(null);

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
          savedLogoKey.current = resp.value.logoStoragePath;
          draftLogoKey.current = resp.value.logoStoragePath;
          revisionRef.current = resp.revision;
          if (resp.value.logoStoragePath) {
            api.getBrandingLogo().then((logo) => {
              if (cancelled || logo.objectKey !== resp.value.logoStoragePath || savedLogoKey.current !== logo.objectKey) return;
              savedLogoPreview.current = logo.url;
              if (draftLogoKey.current === logo.objectKey) setLogoPreview(logo.url);
            })
              .catch(() => { if (!cancelled && savedLogoKey.current === resp.value.logoStoragePath) setUploadError("The saved logo could not be downloaded. Retry by reloading this page."); });
          }
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

  function update(field: keyof ReportBranding, value: string | null) {
    if (field === "logoStoragePath") draftLogoKey.current = value;
    setDraft((cur) => ({ ...cur, [field]: value }));
    setDirty(true);
    setSavedAt(null);
    setSaveError(null);
  }

  function discard() {
    if (typeof load === "object" && "branding" in load) {
      setDraft(load.branding);
      draftLogoKey.current = load.branding.logoStoragePath;
      setLogoPreview(load.branding.logoStoragePath ? savedLogoPreview.current : null);
    } else {
      setDraft(EMPTY);
      draftLogoKey.current = null;
      setLogoPreview(null);
    }
    setDirty(false);
    setSaveError(null);
    setUploadError(null);
  }

  async function save() {
    if (saving || uploadingLogo) return;
    setSaving(true);
    setSaveError(null);
    try {
      const expectedRevision = revisionRef.current;
      const { data: sessionData } = await supabase.auth.getSession();
      if (sessionData.session?.user.id !== session.user.id) throw new Error("Your account changed. Reload before saving branding.");
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
      savedLogoKey.current = draft.logoStoragePath;
      savedLogoPreview.current = logoPreview;
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

  function openLogoPicker() { logoInputRef.current?.click(); }

  async function onLogoFileChosen(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.currentTarget.files?.[0];
    e.currentTarget.value = "";
    if (!file) return;
    setUploadingLogo(true);
    setUploadError(null);
    try {
      const pngDataUrl = await brandingLogoData(file);
      const { objectKey } = await api.uploadBrandingLogo(pngDataUrl.split(",")[1]!);
      update("logoStoragePath", objectKey);
      setLogoPreview(pngDataUrl);
    } catch (e: unknown) {
      setUploadError(e instanceof Error ? e.message : "Logo upload failed.");
    } finally { setUploadingLogo(false); }
  }

  function clearLogo() {
    setLogoPreview(null);
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
        Shared PDF export customisations. Both iOS and the
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
        <fieldset disabled={saving || uploadingLogo} className="flex flex-col gap-4">
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
              accept="image/png,image/jpeg"
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
            {draft.logoStoragePath && logoPreview && <img src={logoPreview} alt="Report logo preview" className="mt-3 max-h-20 max-w-full rounded bg-white p-2" />}
            {draft.logoStoragePath && (
              <p className="mt-2 break-all font-mono text-[11px] text-neutral-500">
                {draft.logoStoragePath}
              </p>
            )}
            {uploadError && (
              <p className="mt-2 text-xs text-red-400">{uploadError}</p>
            )}
            <p className="mt-2 text-[11px] text-neutral-600">
              PNG or JPEG, up to 2 MiB. Save this page to publish the logo to iPhone and web reports.
              Uploading alone does not change the shared report branding.
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
        </fieldset>
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
