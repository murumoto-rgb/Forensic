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

    static let empty = ReportBranding()

    var hasContent: Bool {
        !(coverTitle?.isEmpty ?? true)
            || !(coverSubtitle?.isEmpty ?? true)
            || !(footerText?.isEmpty ?? true)
            || logoFilename != nil
    }
}
