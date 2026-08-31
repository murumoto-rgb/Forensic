import { ReportBrandingSchema } from "@forensic/shared";
import { supabaseAdmin } from "./supabase.js";
import { getObjectBytes } from "./r2.js";
import { probeImageDimensions } from "./exports/imageProbe.js";

export interface ReportBrandingForExport {
  titleOverride: string | null;
  subtitleOverride: string | null;
  footerOverride: string | null;
  logoDataUrl: string | null;
}

/** Snapshot once per export. A configured but unavailable logo is an error,
 * not permission to silently substitute another firm's report identity. */
export async function loadReportBrandingForExport(): Promise<ReportBrandingForExport> {
  const { data, error } = await supabaseAdmin.from("app_config").select("value")
    .eq("key", "reportBranding").abortSignal(AbortSignal.timeout(10000)).maybeSingle();
  if (error) throw new Error("Report branding could not be loaded");
  const branding = ReportBrandingSchema.parse(data?.value ?? {});
  let logoDataUrl: string | null = null;
  if (branding.logoStoragePath) {
    const bytes = await getObjectBytes(branding.logoStoragePath, { maxBytes: 1024 * 1024, timeoutMs: 10000 });
    const info = probeImageDimensions(bytes);
    if (info.width * info.height > 4_000_000) throw new Error("Report logo exceeds 4 megapixels; upload a smaller logo");
    logoDataUrl = `data:image/${info.type};base64,${bytes.toString("base64")}`;
  }
  return { titleOverride: branding.titleOverride, subtitleOverride: branding.subtitleOverride,
    footerOverride: branding.footerOverride, logoDataUrl };
}
