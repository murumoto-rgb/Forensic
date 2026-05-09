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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !result.failures.isEmpty {
                    retryBar
                }
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
