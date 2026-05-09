import SwiftUI
import UIKit

/// Per-batch failure report. Replaces the old "AI tagging done" alert when
/// any photos failed during a batch. Lists each failed photo with its
/// thumbnail, sequence number, and error message; bottom button retries
/// just the failed set in the same Add/Overwrite mode the original batch
/// used.
struct BatchTagSummarySheet: View {
    let projectID: UUID
    let result: ProjectStore.BatchTagResult
    let candidateCount: Int
    /// The mode the failed batch ran with — preserved so retry uses the
    /// same Add / Overwrite semantics.
    let mode: ProjectStore.BatchTagMode
    let onRetry: (Set<UUID>, ProjectStore.BatchTagMode) -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var project: Project? { store.project(withID: projectID) }

    /// Holder for the share-sheet-as-text export. Identifiable so SwiftUI
    /// can drive the sheet presentation.
    private struct ShareItem: Identifiable {
        let id = UUID()
        let text: String
    }
    @State private var sharing: ShareItem?
    @State private var navigatePhotoID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    if !result.countsByPrimary.isEmpty {
                        primariesCard
                    }
                    if !result.countsByRecommendedUse.isEmpty {
                        recommendedUseCard
                    }
                    if !result.lowConfidence.isEmpty {
                        needsReviewSection(
                            title: "Low Confidence",
                            icon: "questionmark.circle.fill",
                            color: .orange,
                            refs: result.lowConfidence
                        )
                    }
                    if !result.reviewerFlagged.isEmpty {
                        needsReviewSection(
                            title: "Reviewer Flag",
                            icon: "exclamationmark.triangle.fill",
                            color: .orange,
                            refs: result.reviewerFlagged
                        )
                    }
                    if !result.validationIssues.isEmpty {
                        needsReviewSection(
                            title: "Validation Issues",
                            icon: "xmark.octagon.fill",
                            color: .red,
                            refs: result.validationIssues
                        )
                    }
                    if !result.parseFailed.isEmpty {
                        needsReviewSection(
                            title: "Parse Failed",
                            icon: "doc.questionmark",
                            color: .red,
                            refs: result.parseFailed
                        )
                    }
                    if !result.failures.isEmpty {
                        failuresList
                        explainer
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Batch Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        sharing = ShareItem(text: shareText)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !result.failures.isEmpty {
                    retryBar
                }
            }
            .sheet(item: $sharing) { item in
                ShareSheet(items: [item.text])
            }
        }
    }

    @ViewBuilder
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            statRow(icon: "checkmark.circle.fill", color: .green,
                    label: "Tagged", count: result.tagged)
            if result.failed > 0 {
                statRow(icon: "exclamationmark.triangle.fill", color: .red,
                        label: "Failed", count: result.failed)
            }
            if result.skipped > 0 {
                statRow(icon: "forward.circle", color: .secondary,
                        label: "Skipped (already tagged)", count: result.skipped)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func statRow(icon: String, color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            Text("\(count)")
                .font(.body.monospaced().bold())
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var failuresList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Failed Photos")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(result.failures) { failure in
                    FailureRow(failure: failure,
                                project: project,
                                store: store)
                    if failure.id != result.failures.last?.id {
                        Divider().padding(.leading, 76)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var primariesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Primary Tags")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(result.countsByPrimary.enumerated()),
                        id: \.offset) { idx, row in
                    HStack {
                        Text(row.primary)
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(row.count)")
                            .font(.body.monospaced().bold())
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if idx < result.countsByPrimary.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var recommendedUseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended Use")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(result.countsByRecommendedUse.enumerated()),
                        id: \.offset) { idx, row in
                    HStack {
                        Text(row.bucket)
                            .font(.callout)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("\(row.count)")
                            .font(.body.monospaced().bold())
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    if idx < result.countsByRecommendedUse.count - 1 {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func needsReviewSection(title: String,
                                     icon: String,
                                     color: Color,
                                     refs: [ProjectStore.BatchPhotoRef]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(color)
                Spacer()
                Text("\(refs.count)")
                    .font(.subheadline.monospaced().bold())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(refs) { ref in
                    NeedsReviewRow(ref: ref, project: project, store: store)
                    if ref.id != refs.last?.id {
                        Divider().padding(.leading, 76)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Plain-text dump of the batch summary, suitable for emailing /
    /// pasting into a project log. Mirrors the on-screen sections in the
    /// same order so a reader can cross-reference.
    private var shareText: String {
        var lines: [String] = []
        lines.append("Batch tagging summary")
        lines.append(String(repeating: "=", count: 32))
        lines.append("Photos processed: \(candidateCount)")
        lines.append("  Tagged:  \(result.tagged)")
        lines.append("  Failed:  \(result.failed)")
        lines.append("  Skipped: \(result.skipped)")
        lines.append("")

        if !result.countsByPrimary.isEmpty {
            lines.append("Primary tag counts:")
            for row in result.countsByPrimary {
                lines.append("  \(row.primary): \(row.count)")
            }
            lines.append("")
        }
        if !result.countsByRecommendedUse.isEmpty {
            lines.append("Recommended use:")
            for row in result.countsByRecommendedUse {
                lines.append("  \(row.bucket): \(row.count)")
            }
            lines.append("")
        }
        if !result.lowConfidence.isEmpty {
            lines.append("Low confidence (\(result.lowConfidence.count)):")
            for ref in result.lowConfidence {
                lines.append("  #\(ref.sequenceNumber)\(ref.detail.map { " — \($0)" } ?? "")")
            }
            lines.append("")
        }
        if !result.reviewerFlagged.isEmpty {
            lines.append("Reviewer flag (\(result.reviewerFlagged.count)):")
            for ref in result.reviewerFlagged {
                lines.append("  #\(ref.sequenceNumber)\(ref.detail.map { " — \($0)" } ?? "")")
            }
            lines.append("")
        }
        if !result.validationIssues.isEmpty {
            lines.append("Validation issues (\(result.validationIssues.count)):")
            for ref in result.validationIssues {
                lines.append("  #\(ref.sequenceNumber)\(ref.detail.map { " — \($0)" } ?? "")")
            }
            lines.append("")
        }
        if !result.parseFailed.isEmpty {
            lines.append("Parse failed (\(result.parseFailed.count)):")
            for ref in result.parseFailed {
                lines.append("  #\(ref.sequenceNumber)\(ref.detail.map { " — \($0)" } ?? "")")
            }
            lines.append("")
        }
        if !result.failures.isEmpty {
            lines.append("Network/HTTP failures (\(result.failures.count)):")
            for f in result.failures {
                lines.append("  #\(f.sequenceNumber): \(f.message)")
            }
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("About these failures", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
            Text("Most batch failures are transient — network blips, rate-limit timeouts, or the occasional malformed Claude response. **Retrying usually fixes them.**")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("If a specific photo fails repeatedly, the cause is usually one of:")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                bullet("Corrupt or unreadable image file")
                bullet("Image blocked by Claude's safety filters")
                bullet("Persistent network or API outage")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            Text(text)
        }
    }

    @ViewBuilder
    private var retryBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(result.failed) photo\(result.failed == 1 ? "" : "s") to retry")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let ids = Set(result.failures.map { $0.photoID })
                    onRetry(ids, mode)
                    dismiss()
                } label: {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.ultraThinMaterial)
    }
}

/// One row in the "needs review" sub-sections of the batch summary.
/// Shows the photo's thumbnail, sequence number, and the optional
/// detail line (reviewer flag, validation message, etc.). Doesn't yet
/// link through to the editor — the user dismisses the sheet and taps
/// the photo in the project list.
private struct NeedsReviewRow: View {
    let ref: ProjectStore.BatchPhotoRef
    let project: Project?
    let store: ProjectStore

    private var photo: Photo? {
        project?.photos.first(where: { $0.id == ref.photoID })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
                .frame(width: 64, height: 48)
                .clipped()
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(ref.sequenceNumber)")
                    .font(.subheadline.monospaced().bold())
                if let detail = ref.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let photo, let project,
           let url = store.thumbnailURL(for: photo, in: project),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// UIActivityViewController wrapped as a SwiftUI sheet so the user can
/// share the batch-summary text via Mail, Messages, Files, etc.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

private struct FailureRow: View {
    let failure: ProjectStore.BatchTagFailure
    let project: Project?
    let store: ProjectStore

    private var photo: Photo? {
        project?.photos.first(where: { $0.id == failure.photoID })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
                .frame(width: 64, height: 48)
                .clipped()
                .background(Color.secondary.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(failure.sequenceNumber)")
                    .font(.subheadline.monospaced().bold())
                Text(friendlyMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Strip the worst noise out of common Claude error messages so the
    /// row reads as a one-liner cause rather than a stack-trace excerpt.
    private var friendlyMessage: String {
        let raw = failure.message
        if raw.lowercased().contains("network") {
            return raw
        }
        if raw.lowercased().contains("api error") {
            // "Anthropic API error (429): { ... }" → keep the status hint.
            if let openParen = raw.firstIndex(of: "("),
               let closeParen = raw.firstIndex(of: ")"),
               openParen < closeParen {
                let status = raw[raw.index(after: openParen)..<closeParen]
                return "Anthropic API error \(status) — likely rate-limit or content filter; retry usually works."
            }
            return raw
        }
        if raw.lowercased().contains("malformed") || raw.lowercased().contains("decode") {
            return "Claude returned an unparseable response. Retry usually fixes this."
        }
        if raw.lowercased().contains("couldn't read") {
            return "Couldn't read this photo file. The image may be corrupt."
        }
        return raw
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let photo, let project,
           let url = store.thumbnailURL(for: photo, in: project),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
