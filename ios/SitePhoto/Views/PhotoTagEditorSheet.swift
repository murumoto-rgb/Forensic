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
    /// Local editing buffers for the caption / observation overrides. They
    /// mirror the photo's `userCaption` / `userObservation` while the sheet
    /// is open and get flushed back to the store on focus loss + on submit.
    @State private var captionDraft: String = ""
    @State private var observationDraft: String = ""
    @FocusState private var captionFocused: Bool
    @FocusState private var observationFocused: Bool
    /// One dictation controller per overridable field so two recordings
    /// don't trample each other. SwiftUI rebuilds the view a lot, so these
    /// live as `@State` to survive re-renders.
    @State private var captionDictation = VoiceDictationController()
    @State private var observationDictation = VoiceDictationController()
    @State private var showingMarkup: Bool = false

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
                    userOverridesSection
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
                    Button("Done") {
                        flushOverrides()
                        dismiss()
                    }
                }
            }
            .task(id: photoID) { await loadImage() }
            .onAppear { loadOverrideDrafts() }
            .onChange(of: photoID) { _, _ in loadOverrideDrafts() }
            .onChange(of: captionFocused) { _, focused in
                if !focused { flushCaptionOverride() }
            }
            .onChange(of: observationFocused) { _, focused in
                if !focused { flushObservationOverride() }
            }
            // Mirror live dictation back into the buffer + the store. The
            // controller keeps appending to `seed`, so writing the full
            // transcript into the draft is safe — no double-text bug.
            .onChange(of: captionDictation.transcript) { _, new in
                guard captionDictation.isRecording else { return }
                captionDraft = new
            }
            .onChange(of: observationDictation.transcript) { _, new in
                guard observationDictation.isRecording else { return }
                observationDraft = new
            }
            .onChange(of: captionDictation.isRecording) { _, recording in
                if !recording { flushCaptionOverride() }
            }
            .onChange(of: observationDictation.isRecording) { _, recording in
                if !recording { flushObservationOverride() }
            }
            .sheet(isPresented: $showingMarkup) {
                PhotoMarkupView(projectID: projectID, photoID: photoID)
                    .environment(store)
            }
        }
    }

    // MARK: - Engineer overrides

    /// Editable caption + observation that live alongside the AI's draft.
    /// Saving on focus loss keeps disk writes off the keystroke path; the
    /// Done button does a final flush before dismissal so the sheet always
    /// closes with the latest text persisted.
    @ViewBuilder
    private var userOverridesSection: some View {
        let aiCaption = photo?.aiAnalysis?.captionDraft
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let aiObservation = photo?.aiAnalysis?.summaryObservation
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        VStack(alignment: .leading, spacing: 10) {
            Label("Engineer's Overrides", systemImage: "pencil")
                .font(.headline)
            Text("Edits below replace the AI's draft in PDF and folder exports. Leave a field blank to keep the AI version.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Caption")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    micButton(controller: captionDictation, seedProvider: { captionDraft })
                }
                TextField(
                    aiCaption.isEmpty
                        ? "Short caption for the report figure"
                        : aiCaption,
                    text: $captionDraft,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($captionFocused)
                .submitLabel(.done)
                .onSubmit { flushCaptionOverride() }
                if !aiCaption.isEmpty && captionDraft.isEmpty {
                    Text("AI: \u{201C}\(aiCaption)\u{201D}")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let err = captionDictation.error {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Summary Observation")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    micButton(controller: observationDictation, seedProvider: { observationDraft })
                }
                TextField(
                    aiObservation.isEmpty
                        ? "One sentence using cautious language"
                        : aiObservation,
                    text: $observationDraft,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($observationFocused)
                .submitLabel(.done)
                .onSubmit { flushObservationOverride() }
                if !aiObservation.isEmpty && observationDraft.isEmpty {
                    Text("AI: \(aiObservation)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let err = observationDictation.error {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(12)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func loadOverrideDrafts() {
        captionDraft = photo?.userCaption ?? ""
        observationDraft = photo?.userObservation ?? ""
    }

    /// Mic button rendered next to each override field's label. Tapping
    /// starts dictation with the current text as the seed (so we append,
    /// not replace); tapping again stops. Recording state colors the
    /// icon red so the user can spot an active session at a glance.
    @ViewBuilder
    private func micButton(controller: VoiceDictationController,
                            seedProvider: @escaping () -> String) -> some View {
        Button {
            if controller.isRecording {
                controller.stop()
            } else {
                Task { await controller.start(seed: seedProvider()) }
            }
        } label: {
            Image(systemName: controller.isRecording ? "stop.circle.fill" : "mic.circle")
                .font(.title3)
                .foregroundStyle(controller.isRecording ? Color.red : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(controller.isRecording ? "Stop dictation" : "Start dictation")
    }

    private func flushCaptionOverride() {
        guard let project else { return }
        _ = store.setUserCaption(project, photoID: photoID, captionDraft)
    }

    private func flushObservationOverride() {
        guard let project else { return }
        _ = store.setUserObservation(project, photoID: photoID, observationDraft)
    }

    private func flushOverrides() {
        flushCaptionOverride()
        flushObservationOverride()
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
                        Button {
                            showingMarkup = true
                        } label: {
                            Label(photo.markupOverlayFilename == nil ? "Markup" : "Edit Markup",
                                  systemImage: "pencil.tip.crop.circle")
                                .font(.caption.bold())
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.black.opacity(0.6),
                                            in: RoundedRectangle(cornerRadius: 6))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .frame(height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - AI metadata (schema-2 analysis + legacy fallback)

    /// Renders the schema-2 `AIPhotoAnalysis` when available — recommended
    /// use, confidence (with note), summary observation, caption draft,
    /// visible measurement, reviewer flag, validation errors. Falls back
    /// to the legacy single-string aiObservation/aiSeverity/aiFollowUp
    /// display for photos that haven't been re-tagged with the new prompt
    /// yet, so historical records keep showing something.
    @ViewBuilder
    private var aiMetadataSection: some View {
        if let analysis = photo?.aiAnalysis {
            analysisSection(analysis)
        } else {
            legacyMetadataSection
        }
    }

    @ViewBuilder
    private func analysisSection(_ a: AIPhotoAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI Findings", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                recommendedUseChip(a.recommendedUse)
                confidenceChip(a.confidence)
            }
            if shouldShowConfidenceNote(a) {
                Text(a.confidenceNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !a.summaryObservation.isEmpty {
                metadataRow(label: "Summary Observation",
                            value: a.summaryObservation)
            }
            if !a.captionDraft.isEmpty {
                metadataRow(label: "Caption Draft",
                            value: "\u{201C}\(a.captionDraft)\u{201D}",
                            italic: true)
            }
            if let m = a.measurementVisible, !m.isEmpty {
                HStack(spacing: 6) {
                    Text("Measurement")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(m)
                        .font(.callout.monospaced().bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.blue)
                }
            }
            if !a.reviewerFlag.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reviewer Flag")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(a.reviewerFlag)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if !a.validationErrors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Validation Issues", systemImage: "xmark.octagon.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    ForEach(a.validationErrors, id: \.self) { msg in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\u{2022}").foregroundStyle(.red)
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(8)
                .background(Color.red.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8))
            }
            if a.parseFailed, let raw = a.rawResponse, !raw.isEmpty {
                DisclosureGroup("Raw Response (parse failed)") {
                    ScrollView(.vertical) {
                        Text(raw)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 180)
                }
                .font(.caption.weight(.semibold))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    /// Legacy display path for photos tagged before schema-2. Shows
    /// whatever the old prompt produced (severity / observation /
    /// follow-up) so historical records stay readable.
    @ViewBuilder
    private var legacyMetadataSection: some View {
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
                            .background(Color.secondary.opacity(0.18),
                                        in: Capsule())
                            .foregroundStyle(.secondary)
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
    private func metadataRow(label: String, value: String, italic: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(italic ? .callout.italic() : .callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Colour-coded chip for the recommended-use bucket. Body figure =
    /// green (use it), Re-shoot = red (don't use it as-is), Appendix =
    /// neutral, Context/locator = blue.
    @ViewBuilder
    private func recommendedUseChip(_ use: RecommendedUse) -> some View {
        let (bg, fg): (Color, Color) = {
            switch use {
            case .bodyFigure:         return (.green, .green)
            case .appendixOnly:       return (.gray, .secondary)
            case .contextLocator:     return (.blue, .blue)
            case .reshootRecommended: return (.red, .red)
            case .unknown:            return (.gray, .secondary)
            }
        }()
        Text(use.displayName.isEmpty ? "—" : use.displayName)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(bg.opacity(0.18), in: Capsule())
            .foregroundStyle(fg)
    }

    /// True when the confidence-note row should render: there is a note,
    /// AND the confidence isn't High (the prompt says High should leave
    /// the note empty, but we belt-and-suspenders here).
    private func shouldShowConfidenceNote(_ a: AIPhotoAnalysis) -> Bool {
        guard !a.confidenceNote.isEmpty else { return false }
        if case .high = a.confidence { return false }
        return true
    }

    /// Colour-coded chip for the model's self-reported confidence. High =
    /// green, Medium = orange, Low = red. Hidden when no confidence was
    /// reported (e.g. parse failure with empty enum).
    @ViewBuilder
    private func confidenceChip(_ c: Confidence) -> some View {
        let (label, fg): (String, Color) = {
            switch c {
            case .high:           return ("High",   .green)
            case .medium:         return ("Medium", .orange)
            case .low:            return ("Low",    .red)
            case .unknown(let s): return (s.isEmpty ? "" : s, .secondary)
            }
        }()
        if !label.isEmpty {
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(fg.opacity(0.18), in: Capsule())
                .foregroundStyle(fg)
        }
    }

    // MARK: - Confirmed tags

    /// One primary→secondary group in the confirmed-tags display. Built per
    /// render from the photo's flat tag list. The `primaryTag` is non-nil
    /// when the photo actually carries the primary tag itself; if a photo
    /// has only secondaries under a primary, `primaryTag` is nil and the
    /// header chip is drawn in a "category-only" style.
    private struct ConfirmedGroup {
        let primary: String
        var primaryTag: Tag?
        var secondaries: [Tag]
    }

    private var confirmedGroups: [ConfirmedGroup] {
        guard let tags = photo?.tags, !tags.isEmpty else { return [] }
        var byLC: [String: ConfirmedGroup] = [:]
        var orderLC: [String] = []
        for tag in tags {
            let parentName: String
            let isPrimaryEntry: Bool
            if let p = tag.parentTag?.trimmingCharacters(in: .whitespacesAndNewlines),
               !p.isEmpty {
                parentName = p
                isPrimaryEntry = false
            } else {
                parentName = tag.label
                isPrimaryEntry = true
            }
            let lc = parentName.lowercased()
            if byLC[lc] == nil {
                byLC[lc] = ConfirmedGroup(primary: parentName, primaryTag: nil, secondaries: [])
                orderLC.append(lc)
            }
            if isPrimaryEntry {
                byLC[lc]?.primaryTag = tag
            } else {
                byLC[lc]?.secondaries.append(tag)
            }
        }
        return orderLC
            .compactMap { byLC[$0] }
            .sorted { lhs, rhs in
                let lr = AIInstructions.primaryRank(lhs.primary)
                let rr = AIInstructions.primaryRank(rhs.primary)
                if lr != rr { return lr < rr }
                return lhs.primary.lowercased() < rhs.primary.lowercased()
            }
    }

    @ViewBuilder
    private var confirmedTagsSection: some View {
        let tags = photo?.tags ?? []
        let groups = confirmedGroups
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
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.primary) { group in
                        confirmedGroupView(group)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func confirmedGroupView(_ group: ConfirmedGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Primary header chip. If the photo actually carries the
            // primary tag itself, the chip is removable (and removing it
            // cascade-clears the secondaries underneath — they'd be
            // orphaned otherwise). If only secondaries are present, the
            // header chip is purely a category label.
            if let primary = group.primaryTag {
                TagChip(text: group.primary,
                        confidence: primary.confidence,
                        removable: true) {
                    removePrimary(group.primary)
                }
            } else {
                Text(group.primary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if !group.secondaries.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(group.secondaries, id: \.label) { tag in
                        TagChip(text: tag.label,
                                confidence: tag.confidence,
                                removable: true) {
                            removeSecondary(label: tag.label, parent: group.primary)
                        }
                    }
                }
                .padding(.leading, 12)
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

    /// Build the same primary→secondaries grouping the confirmed-tags
    /// section uses, but for `[TagSuggestion]`. Drives the hierarchical
    /// suggestion chip layout.
    private struct SuggestionGroup {
        let primary: String
        var primaryItem: TagSuggestion?
        var secondaries: [TagSuggestion]
    }

    private func suggestionGroups(from items: [TagSuggestion]) -> [SuggestionGroup] {
        var byLC: [String: SuggestionGroup] = [:]
        var orderLC: [String] = []
        for s in items {
            let parentName: String
            let isPrimaryEntry: Bool
            if let p = s.parentTag?.trimmingCharacters(in: .whitespacesAndNewlines),
               !p.isEmpty {
                parentName = p
                isPrimaryEntry = false
            } else {
                parentName = s.label
                isPrimaryEntry = true
            }
            let lc = parentName.lowercased()
            if byLC[lc] == nil {
                byLC[lc] = SuggestionGroup(primary: parentName, primaryItem: nil, secondaries: [])
                orderLC.append(lc)
            }
            if isPrimaryEntry {
                byLC[lc]?.primaryItem = s
            } else {
                byLC[lc]?.secondaries.append(s)
            }
        }
        return orderLC
            .compactMap { byLC[$0] }
            .sorted { lhs, rhs in
                let lr = AIInstructions.primaryRank(lhs.primary)
                let rr = AIInstructions.primaryRank(rhs.primary)
                if lr != rr { return lr < rr }
                return lhs.primary.lowercased() < rhs.primary.lowercased()
            }
    }

    @ViewBuilder
    private func suggestionGroup(_ title: String,
                                  items: [TagSuggestion],
                                  accent: Color) -> some View {
        let grouped = suggestionGroups(from: items)
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(grouped, id: \.primary) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        if let primaryItem = g.primaryItem {
                            SuggestionChip(suggestion: primaryItem, accent: accent,
                                           onAccept: { confirm(primaryItem) },
                                           onDismiss: { reject(primaryItem) })
                        } else {
                            Text(g.primary)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                        if !g.secondaries.isEmpty {
                            FlowLayout(spacing: 6) {
                                ForEach(g.secondaries) { sug in
                                    SuggestionChip(suggestion: sug, accent: accent,
                                                   onAccept: { confirm(sug) },
                                                   onDismiss: { reject(sug) })
                                }
                            }
                            .padding(.leading, 12)
                        }
                    }
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

    /// Remove a primary tag and every secondary that lives under it. The
    /// editor uses this on the primary chip's "x" so the user can clear a
    /// whole category in one tap; otherwise removing only the primary
    /// would leave dangling secondaries with a parent name that's no
    /// longer represented.
    private func removePrimary(_ name: String) {
        guard let project else { return }
        _ = store.removePrimaryTag(project, photoID: photoID, primary: name)
    }

    /// Remove a single secondary tag under a specific primary. Scoped so we
    /// don't accidentally drop a same-named secondary that belongs to a
    /// different category.
    private func removeSecondary(label: String, parent: String) {
        guard let project else { return }
        _ = store.removeTag(project, photoID: photoID, tag: label, parentTag: parent)
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
                photoID: photo.imageFilename,
                instructions: project.effectiveAIInstructions
            )
            // Merge with existing pending suggestions rather than
            // overwriting. Also persist the full structured analysis so
            // the new metadata surface (recommended use, confidence,
            // reviewer flag, validation errors) reflects this run.
            let existing = photo.pendingSuggestions
            var p = project
            p = store.setPendingSuggestions(
                p,
                photoID: photoID,
                suggestions: existing + r.suggestions
            )
            _ = store.setPhotoAIAnalysis(
                p, photoID: photoID,
                analysis: r.analysis
            )
            // Surface a parse failure inline — it didn't throw, but the
            // user shouldn't think the call succeeded silently.
            if r.analysis.parseFailed {
                aiError = "Claude returned an unparseable response — saved for review on the photo."
            }
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
