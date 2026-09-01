import Foundation

/// App-wide report branding. Stored once at the storage root (alongside
/// projects) so a single firm-level identity feeds every project's PDF
/// export. Per-project overrides are intentionally not modeled here —
/// they're a future follow-up if Baykal's workflow needs them.
///
/// `logoFilename` references a PNG saved next to the JSON manifest. nil
/// means "fall back to the bundled `BaykalLogo` asset" so existing
/// installs keep the same look until the user customises.
struct ReportBranding: Codable, Hashable, Sendable {
    var coverTitle: String?
    var coverSubtitle: String?
    var footerText: String?
    var logoFilename: String?
    /// R2 object key of the team logo as known to the server
    /// (`app_config.reportBranding.logoStoragePath`). Build #6.2.1
    /// round-trips it opaquely: iOS neither uploads nor downloads the
    /// R2 logo yet (follow-on), but carrying the path means an iOS
    /// text edit can never clobber a logo the web admin set. Optional
    /// so pre-#6.2.1 `branding.json` files keep decoding.
    var logoStoragePath: String?
    /// Local-only upload/cache state. Older branding files decode nil.
    var logoNeedsUpload: Bool?
    var logoCachedStoragePath: String?

    static let empty = ReportBranding()

    var hasContent: Bool {
        !(coverTitle?.isEmpty ?? true)
            || !(coverSubtitle?.isEmpty ?? true)
            || !(footerText?.isEmpty ?? true)
            || logoFilename != nil
            || logoStoragePath != nil
    }
}

/// Wire shape for the `reportBranding` app_config key. Field names
/// match `ReportBranding` in `packages/shared/src/appConfig.ts`
/// exactly — they differ from the local struct above (`coverTitle` /
/// `coverSubtitle` / `footerText` predate the shared schema), so the
/// mapping lives right here where both shapes are visible.
struct ReportBrandingWire: Codable, Sendable {
    var titleOverride: String?
    var subtitleOverride: String?
    var footerOverride: String?
    var logoStoragePath: String?
}

extension ReportBranding {
    /// Build the wire value for a push. Empty strings normalise to
    /// null so "cleared on iPhone" reads as "no override" on web.
    var wireValue: ReportBrandingWire {
        func normalised(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return s
        }
        return ReportBrandingWire(
            titleOverride: normalised(coverTitle),
            subtitleOverride: normalised(coverSubtitle),
            footerOverride: normalised(footerText),
            logoStoragePath: logoStoragePath
        )
    }

    /// Apply a pulled wire value onto the local state. The local
    /// `logoFilename` (this device's logo PNG) is preserved — the
    /// wire has no concept of it.
    func applying(_ wire: ReportBrandingWire) -> ReportBranding {
        var out = self
        out.coverTitle = wire.titleOverride
        out.coverSubtitle = wire.subtitleOverride
        out.footerText = wire.footerOverride
        if out.logoStoragePath != wire.logoStoragePath {
            out.logoFilename = nil
            out.logoCachedStoragePath = nil
        }
        out.logoStoragePath = wire.logoStoragePath
        out.logoNeedsUpload = false
        return out
    }
}
