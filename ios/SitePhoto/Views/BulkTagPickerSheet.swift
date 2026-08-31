import SwiftUI

/// Pick a tag from the controlled vocabulary and apply it to every photo
/// in `photoIDs`. Mirrors the visual pattern of `ClearAITagsSheet` (large
/// teal primary chips with indented purple secondary chips below) but
/// flips the action: instead of removing tags, every tap *adds* the tag
/// to the selected photos via `ProjectStore.addTag`. Manual application
/// always lands at confidence 1.0 so the result behaves like a typed tag.
struct BulkTagPickerSheet: View {
    let projectID: UUID
    let photoIDs: Set<UUID>
    let onApplied: () -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(ToastCenter.self) private var toastCenter
    @Environment(\.dismiss) private var dismiss

    @State private var lastAppliedLabel: String?
    @State private var lastAppliedAt: Date?

    private var project: Project? { store.project(withID: projectID) }
    private var entries: [(primary: String, secondaries: [String])] {
        var names: [String] = []
        var secondaries: [String: [String]] = [:]
        for context in store.tagLibrary.contexts {
            for primary in context.primaries {
                if secondaries[primary.name] == nil {
                    names.append(primary.name)
                    secondaries[primary.name] = []
                }
                for secondary in primary.secondaries where !(secondaries[primary.name] ?? []).contains(secondary.name) {
                    secondaries[primary.name, default: []].append(secondary.name)
                }
            }
        }
        return names.map { (primary: $0, secondaries: secondaries[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    infoBanner
                    Divider()
                    if let lastAppliedLabel,
                       let lastAppliedAt,
                       Date().timeIntervalSince(lastAppliedAt) < 4 {
                        appliedBanner(label: lastAppliedLabel)
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(entries, id: \.primary) { entry in
                            tagGroup(primary: entry.primary,
                                       secondaries: entry.secondaries)
                        }
                    }
                    .padding(12)
                }
            }
            .navigationTitle("Apply Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        onApplied()
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var infoBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tap a tag to apply it to all \(photoIDs.count) selected photo\(photoIDs.count == 1 ? "" : "s").")
                .font(.callout)
            Text("Tap multiple tags to layer them on. Manual tags land at 100% confidence — they survive any future \"Clear AI Tags\" operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    @ViewBuilder
    private func appliedBanner(label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Applied \"\(label)\" to \(photoIDs.count) photo\(photoIDs.count == 1 ? "" : "s")")
                .font(.caption)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.1))
    }

    @ViewBuilder
    private func tagGroup(primary: String, secondaries: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                primaryChip(primary)
                Spacer(minLength: 0)
            }
            if !secondaries.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(secondaries, id: \.self) { secondary in
                        secondaryChip(parent: primary, label: secondary)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private func primaryChip(_ primary: String) -> some View {
        Button {
            apply(parent: nil, label: primary)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .font(.subheadline)
                Text(primary)
                    .font(.callout.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func secondaryChip(parent: String, label: String) -> some View {
        Button {
            apply(parent: parent, label: label)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle")
                    .font(.caption2)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(Color.purple)
        }
        .buttonStyle(.plain)
    }

    /// Apply `label` (with optional `parent`) to every selected photo.
    /// `addTag` dedupes by (parent, label) per-photo so re-tapping the
    /// same chip is a no-op for already-tagged photos. "None" secondaries
    /// are skipped — adding a literal "None" tag would clutter without
    /// adding meaning.
    private func apply(parent: String?, label: String) {
        guard let project else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none" else { return }
        var current = project
        for id in photoIDs {
            current = store.addTag(current,
                                     photoID: id,
                                     tag: trimmed,
                                     confidence: 1.0,
                                     parentTag: parent)
        }
        lastAppliedLabel = parent.map { "\($0) / \(trimmed)" } ?? trimmed
        lastAppliedAt = Date()
        Haptics.tap()
        let count = photoIDs.count
        toastCenter.post("Tagged \(count) photo\(count == 1 ? "" : "s") with \(lastAppliedLabel ?? trimmed)",
                          kind: .success)
    }
}
