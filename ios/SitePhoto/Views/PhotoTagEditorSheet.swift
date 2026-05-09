import SwiftUI
import UIKit

/// Full-screen editor for a single photo's tags. Shows the photo, the
/// confirmed tags as removable chips, a typeahead input that suggests from
/// project + global history, and pending AI suggestions (Vision + Claude)
/// that can be accepted or dismissed individually. The "Suggest with AI"
/// button kicks off a Claude analysis on demand.
struct PhotoTagEditorSheet: View {
    let projectID: UUID
    let photoID: UUID

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var input: String = ""
    @State private var aiRunning: Bool = false
    @State private var aiError: String?

    private var project: Project? { store.project(withID: projectID) }
    private var photo: Photo? {
        project?.photos.first(where: { $0.id == photoID })
    }

    /// Tags the user has already typed in any project, used as typeahead
    /// after the current project's tags are exhausted.
    private var typeaheadCandidates: [String] {
        guard let project else { return [] }
        let existing = Set((photo?.tags ?? []).map { $0.label.lowercased() })
        let projectTags  = store.tagsUsed(in: project).filter {
            !existing.contains($0.lowercased())
        }
        let globalTags = store.tagsUsedGlobally().filter { gt in
            !existing.contains(gt.lowercased()) &&
            !projectTags.contains(where: { $0.lowercased() == gt.lowercased() })
        }
        return projectTags + globalTags
    }

    private var typeaheadMatches: [String] {
        let q = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return typeaheadCandidates
            .filter { $0.lowercased().contains(q) }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    photoPreview
                    aiMetadataSection
                    confirmedTagsSection
                    inputSection
                    suggestionsSection
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: photoID) { await loadImage() }
        }
    }

    // MARK: - Photo preview

    @ViewBuilder
    private var photoPreview: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
            if let photo {
                VStack {
                    HStack {
                        Text("#\(photo.sequenceNumber)")
                            .font(.headline.monospaced())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.6),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                        Spacer()
                    }
                    Spacer()
                }
            }
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - AI metadata (severity / observation / follow-up)

    @ViewBuilder
    private var aiMetadataSection: some View {
        let severity    = photo?.aiSeverity.nilIfBlank
        let observation = photo?.aiObservation.nilIfBlank
        let followUp    = photo?.aiFollowUp.nilIfBlank
        if severity != nil || observation != nil || followUp != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("AI Findings", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    if let severity {
                        Text(severity)
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(severityColor(severity).opacity(0.18),
                                        in: Capsule())
                            .foregroundStyle(severityColor(severity))
                    }
                }
                if let observation {
                    metadataRow(label: "Summary Observation", value: observation)
                }
                if let followUp {
                    metadataRow(label: "Follow-up", value: followUp)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func metadataRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Map Claude's severity buckets to a colour. "None"/"Cannot Determine"
    /// stay neutral; the others escalate green→red.
    private func severityColor(_ s: String) -> Color {
        switch s.lowercased() {
        case "minor":              return .yellow
        case "moderate":           return .orange
        case "significant":        return .red
        case "severe":             return .red
        case "none":               return .green
        case "cannot determine":   return .secondary
        default:                   return .secondary
        }
    }

    // MARK: - Confirmed tags

    @ViewBuilder
    private var confirmedTagsSection: some View {
        let tags = photo?.tags ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tags").font(.headline)
                Spacer()
                Text("\(tags.count)").font(.subheadline).foregroundStyle(.secondary)
            }
            if tags.isEmpty {
                Text("No tags yet. Type below to add one, or tap \"Suggest with AI\" to let Claude propose some.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.label) { tag in
                        TagChip(text: tag.label,
                                confidence: tag.confidence,
                                removable: true) {
                            removeTag(tag.label)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Input + typeahead

    @ViewBuilder
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "tag")
                    .foregroundStyle(.secondary)
                TextField("Add a tag", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { commitInput() }
                if !input.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add") { commitInput() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 10))

            if !typeaheadMatches.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(typeaheadMatches, id: \.self) { candidate in
                        Button {
                            addTag(candidate)
                            input = ""
                        } label: {
                            Text(candidate)
                                .font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.15),
                                            in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - AI Suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        // Only Claude suggestions are surfaced. Old manifests may still
        // carry .vision-source pending entries from when on-device tagging
        // existed; treat them as if they're not there. "Clear AI Tagging"
        // wipes them when the user runs it.
        let suggestions = (photo?.pendingSuggestions ?? [])
            .filter { $0.source == .claude }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI Suggestions").font(.headline)
                Spacer()
                Button {
                    Task { await runClaude() }
                } label: {
                    if aiRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Analysing…")
                        }
                    } else {
                        Label("Suggest with AI", systemImage: "wand.and.sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(aiRunning || photo == nil)
            }

            if let aiError {
                Text(aiError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if suggestions.isEmpty {
                if !aiRunning {
                    Text("No pending suggestions. Tap \"Suggest with AI\" to ask Claude to categorise this photo.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                suggestionGroup("Claude",
                                items: suggestions,
                                accent: .purple)
                HStack {
                    Button("Accept all") { acceptAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(role: .destructive) {
                        dismissAll()
                    } label: {
                        Text("Dismiss all")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private func suggestionGroup(_ title: String,
                                  items: [TagSuggestion],
                                  accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(items) { sug in
                    SuggestionChip(suggestion: sug, accent: accent,
                                    onAccept: { confirm(sug) },
                                    onDismiss: { reject(sug) })
                }
            }
        }
    }

    // MARK: - Actions

    private func commitInput() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        addTag(trimmed)
        input = ""
    }

    private func addTag(_ tag: String) {
        guard let project else { return }
        _ = store.addTag(project, photoID: photoID, tag: tag)
    }

    private func removeTag(_ tag: String) {
        guard let project else { return }
        _ = store.removeTag(project, photoID: photoID, tag: tag)
    }

    private func confirm(_ suggestion: TagSuggestion) {
        guard let project else { return }
        _ = store.confirmSuggestion(project, photoID: photoID, suggestion: suggestion)
    }

    private func reject(_ suggestion: TagSuggestion) {
        guard let project else { return }
        _ = store.dismissSuggestion(project, photoID: photoID, suggestion: suggestion)
    }

    private func acceptAll() {
        guard let project, let photo else { return }
        var p = project
        for s in photo.pendingSuggestions {
            p = store.confirmSuggestion(p, photoID: photoID, suggestion: s)
        }
    }

    private func dismissAll() {
        guard let project, let photo else { return }
        var p = project
        for s in photo.pendingSuggestions {
            p = store.dismissSuggestion(p, photoID: photoID, suggestion: s)
        }
    }

    private func loadImage() async {
        guard let project, let photo else { return }
        let url = store.imageURL(for: photo, in: project)
        if let data = await store.loadFileBytes(at: url),
           let img = UIImage(data: data) {
            self.image = img
        }
    }

    private func runClaude() async {
        guard let project, let photo else { return }
        aiError = nil
        aiRunning = true
        defer { aiRunning = false }

        let url = store.imageURL(for: photo, in: project)
        // Make sure iCloud has the file before we try to read it.
        await store.ensureDownloaded(url)

        do {
            let r = try await ClaudeTaggingService.tag(
                imageURL: url,
                instructions: project.effectiveAIInstructions
            )
            // Merge with existing pending suggestions (e.g. Vision tags)
            // rather than overwriting. Also persist the metadata Claude
            // returned alongside the tags.
            let existing = photo.pendingSuggestions
            var p = project
            p = store.setPendingSuggestions(
                p,
                photoID: photoID,
                suggestions: existing + r.suggestions
            )
            _ = store.setPhotoAIMetadata(
                p, photoID: photoID,
                severity:    r.metadata.severity,
                observation: r.metadata.observation,
                followUp:    r.metadata.followUp
            )
        } catch let err as ClaudeTaggingService.Error {
            aiError = err.errorDescription ?? "Failed."
        } catch {
            aiError = error.localizedDescription
        }
    }
}

// MARK: - Chip views

private struct TagChip: View {
    let text: String
    var confidence: Double? = nil
    var removable: Bool = false
    var onRemove: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.callout)
            if let confidence, confidence < 1.0 {
                Text("\(Int(round(confidence * 100)))%")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.accentColor.opacity(0.65))
            }
            if removable {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .foregroundStyle(Color.accentColor)
    }
}

private struct SuggestionChip: View {
    let suggestion: TagSuggestion
    let accent: Color
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onAccept) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption2.bold())
                    Text(suggestion.label)
                        .font(.callout)
                    Text("\(Int(round(suggestion.confidence * 100)))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(accent.opacity(0.15), in: Capsule())
                .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - FlowLayout

/// Wrapping horizontal stack — children flow to the next line when they
/// don't fit. Used for tag/suggestion chips.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                totalHeight = y
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        totalHeight = y + rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : totalWidth,
                       height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect,
                        proposal: ProposedViewSize,
                        subviews: Subviews,
                        cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y),
                       anchor: .topLeading,
                       proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

private extension Optional where Wrapped == String {
    /// Treat blank/whitespace strings as `nil` — keeps the `aiMetadataSection`
    /// from rendering empty rows when Claude returns "" for a field.
    var nilIfBlank: String? {
        switch self {
        case .none: return nil
        case .some(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
