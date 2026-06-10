// Split out of ProjectDetailView.swift (Build #6.24.1 — iOS
// decomposition part 2). Members moved verbatim into a same-module
// extension; `private` dropped on the struct's members because Swift
// scopes private to the file and these now cross file boundaries.
// No behavior change.

import SwiftUI
import UIKit

extension ProjectDetailView {

    @ViewBuilder
    func aiTaggingSection(_ project: Project) -> some View {
        let untaggedCount = project.photos.filter { $0.tags.isEmpty }.count
        let taggedCount   = project.photos.count - untaggedCount

        // Build #5.130.1: split today's monolithic AI Tagging section
        // into three visual subgroups (Vocabulary / Notes / Run) so the
        // user can find what they're looking for at a glance. The
        // misplaced "Filter photos by tag…" button is removed (filtering
        // already lives in the photos-section filter chip bar).
        Section {
            Button {
                showingTagSelection = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Tags")
                        Text(tagSelectionSubtitle(for: project))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: project.tagSelection?.isEmpty == false
                          ? "tag.fill" : "tag")
                }
            }

            Button {
                showingExtraVocabulary = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Job-Specific Vocabulary")
                        Text(extraVocabSubtitle(for: project))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: hasExtras(project)
                          ? "tag.circle.fill" : "tag.circle")
                }
            }
        } header: {
            Text("Vocabulary")
        } footer: {
            Text("AI Tags scopes which contexts and tags this project sends to Claude. Job-Specific Vocabulary appends project-only tags without changing the team library.")
        }

        Section {
            Button {
                showingAIInstructions = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Notes")
                        Text(aiNotesSubtitle(for: project))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: hasNotes(project)
                          ? "note.text" : "square.dashed")
                }
            }
        } header: {
            Text("Notes")
        } footer: {
            Text("One-off guidance appended to the AI prompt for this project (e.g. \"focus on the east elevation\"). Templates available from inside the editor.")
        }

        Section {
            // Build #6.9.1: tagging without a tag selection used to
            // fail at runtime ("Pick at least one investigation
            // context first" toast). Disable the run buttons up
            // front and say why — the only required configuration is
            // AI Tags; Vocabulary extras and Notes are optional.
            let tagsConfigured = !(project.tagSelection?.isEmpty ?? true)
            if !tagsConfigured {
                Text("Tagging is disabled until AI Tags is configured — pick at least one investigation context under Vocabulary above. (Job-Specific Vocabulary and AI Notes are optional.)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                batchTagConfirm = BatchTagPrompt(
                    candidateCount: untaggedCount,
                    skippedCount: taggedCount,
                    skipAlreadyTagged: true,
                    candidatesWithExistingTags: 0,
                    onlyPhotoIDs: nil
                )
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-tag untagged photos with AI")
                        if untaggedCount > 0 {
                            Text("\(untaggedCount) photo\(untaggedCount == 1 ? "" : "s") · ~\(estimatedCostString(for: untaggedCount))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Every photo already has tags.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "wand.and.sparkles")
                }
            }
            .disabled(untaggedCount == 0 || batchTagTask != nil || !tagsConfigured)

            if taggedCount > 0 && project.photos.count > 0 {
                Button {
                    batchTagConfirm = BatchTagPrompt(
                        candidateCount: project.photos.count,
                        skippedCount: 0,
                        skipAlreadyTagged: false,
                        candidatesWithExistingTags: taggedCount,
                        onlyPhotoIDs: nil
                    )
                } label: {
                    Label("Auto-tag every photo",
                          systemImage: "wand.and.sparkles.inverse")
                }
                .disabled(batchTagTask != nil || !tagsConfigured)
            }

            Button(role: .destructive) {
                showingClearAITags = true
            } label: {
                Label("Clear AI tagging from photos…",
                      systemImage: "eraser")
            }
            .disabled(project.photos.isEmpty || batchTagTask != nil)
        } header: {
            Text("Run")
        } footer: {
            Text("Each photo is sent to Claude (~1¢ each with prompt caching, billed to your Anthropic account) using the project's tagging guide. Returned tags are auto-accepted. Cancel any time. \"Clear AI tagging\" lets you pick which AI tags to remove from selected photos while preserving manual entries and the photo's saved AI analysis.")
        }
    }

    // MARK: - Buckets section


    /// Per-photo cost is ~$0.01 with the long forensic prompt + prompt
    /// caching enabled. The first photo in a 5-min window pays a write
    /// premium; subsequent photos in the same batch pay only ~10% of the
    /// cached portion. Across a full batch the average lands near 1¢.
    func estimatedCostString(for count: Int) -> String {
        let cents = Double(count) * 1.0
        if cents < 100 {
            return String(format: "%.0f¢", cents)
        }
        return String(format: "$%.2f", cents / 100)
    }

    /// Subtitle under the "AI Tags" row — surfaces how much vocabulary
    /// the project has scoped for AI tagging without having to open the
    /// picker.
    func tagSelectionSubtitle(for project: Project) -> String {
        guard let selection = project.tagSelection, !selection.isEmpty else {
            return "Not configured — AI tagging is disabled until you pick at least one investigation context."
        }
        let ctxCount = selection.contextIDs.count
        let primaryCount = selection.primariesByContext.values
            .reduce(0) { $0 + $1.count }
        return "\(ctxCount) context\(ctxCount == 1 ? "" : "s"), \(primaryCount) primary tag\(primaryCount == 1 ? "" : "s")"
    }

    /// Subtitle under the "AI Notes" row — shows whether any notes are
    /// in play, but doesn't expose the full text.
    func aiNotesSubtitle(for project: Project) -> String {
        hasNotes(project)
            ? "Custom notes appended to the AI prompt for this project"
            : "Optional one-off guidance appended to the AI prompt"
    }

    func hasNotes(_ project: Project) -> Bool {
        let trimmed = (project.aiInstructions ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    /// Subtitle under the "Job-Specific Vocabulary" row — shows the
    /// number of project-scoped primaries / secondaries Claude will
    /// see on top of the main library vocabulary.
    func extraVocabSubtitle(for project: Project) -> String {
        guard let extras = project.aiExtraVocabulary, !extras.isEmpty else {
            return "Optional project-only tags appended to the AI vocabulary"
        }
        let pCount = extras.primaries.count
        let sCount = extras.secondaryCount
        return "\(pCount) primar\(pCount == 1 ? "y" : "ies"), \(sCount) secondar\(sCount == 1 ? "y" : "ies")"
    }

    func hasExtras(_ project: Project) -> Bool {
        !(project.aiExtraVocabulary?.isEmpty ?? true)
    }


    func presentSelectedAITagPrompt() {
        guard !selectedPhotoIDs.isEmpty else { return }
        guard let project else { return }
        let selectedPhotos = project.photos.filter { selectedPhotoIDs.contains($0.id) }
        let existingTaggedCount = selectedPhotos.filter { !$0.tags.isEmpty }.count
        batchTagConfirm = BatchTagPrompt(
            candidateCount: selectedPhotos.count,
            skippedCount: 0,
            skipAlreadyTagged: false,
            candidatesWithExistingTags: existingTaggedCount,
            onlyPhotoIDs: selectedPhotoIDs
        )
    }

    func startBatchTagging(_ prompt: BatchTagPrompt,
                                    mode: ProjectStore.BatchTagMode) {
        batchTagError = nil
        batchTagSummary = nil
        batchTagProgressCurrent = 0
        batchTagProgressTotal = prompt.candidateCount
        batchTagProgressSeq = nil

        // (A) Keep the screen alive while the batch runs so iOS doesn't
        // suspend us when the auto-lock timer fires. Reset on completion.
        UIApplication.shared.isIdleTimerDisabled = true

        // (B) Ask iOS for ~30s of background grace if the user briefly
        // backgrounds the app — long enough for the in-flight requests to
        // finish and persist their manifests before suspension. The user
        // can resume the batch by re-tapping "Auto-tag untagged" since
        // already-tagged photos are skipped automatically.
        batchBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "AI Tagging"
        ) {
            // Expiration handler — iOS is about to suspend us. Cancel the
            // task cleanly so the in-flight Claude calls bail out.
            batchTagTask?.cancel()
            endBatchBackgroundTask()
        }

        let pid = projectID
        let skip = prompt.skipAlreadyTagged
        let candidateCount = prompt.candidateCount
        let onlyIDs = prompt.onlyPhotoIDs
        // The multi-select "Tag with AI" path passes a specific photo
        // set; exit selection mode immediately so the user sees the
        // progress overlay on top of the normal grid rather than the
        // selection toolbar.
        if onlyIDs != nil {
            exitSelectionMode()
        }
        batchTagTask = Task { @MainActor in
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                endBatchBackgroundTask()
            }
            do {
                let result = try await store.batchClaudeTagging(
                    projectID: pid,
                    skipAlreadyTagged: skip,
                    mode: mode,
                    onlyPhotoIDs: onlyIDs,
                    onProgress: { current, total, seq in
                        self.batchTagProgressCurrent = current
                        self.batchTagProgressTotal = total
                        self.batchTagProgressSeq = seq
                    }
                )
                self.presentResult(result, candidateCount: candidateCount, mode: mode)
            } catch is CancellationError {
                self.batchTagSummary = "Cancelled at \(self.batchTagProgressCurrent) of \(self.batchTagProgressTotal). Re-run \"Auto-tag untagged\" to resume — already-tagged photos will be skipped."
            } catch let err as ClaudeTaggingService.Error {
                self.batchTagError = err.errorDescription ?? "Failed."
            } catch {
                self.batchTagError = error.localizedDescription
            }
            self.batchTagTask = nil
        }
    }

    func endBatchBackgroundTask() {
        if batchBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(batchBackgroundTaskID)
            batchBackgroundTaskID = .invalid
        }
    }

    func cancelBatchTagging() {
        batchTagTask?.cancel()
    }

    /// Decide how to surface a finished batch: a completely-clean run
    /// (no failures, no parse errors, no validation issues, no reviewer
    /// flags, no low-confidence picks) gets a quiet text alert; anything
    /// else opens the rich summary sheet so the user can see counts per
    /// primary, counts per recommended use, the photos that need review,
    /// and any failed photos to retry.
    func presentResult(_ result: ProjectStore.BatchTagResult,
                                 candidateCount: Int,
                                 mode: ProjectStore.BatchTagMode) {
        if result.isCompletelyClean {
            self.batchTagSummary = "Tagged \(result.tagged) of \(candidateCount) photo\(candidateCount == 1 ? "" : "s")."
                + (result.skipped > 0 ? " \(result.skipped) already had tags." : "")
        } else {
            self.batchTagFailureReport = BatchTagFailureReport(
                result: result,
                candidateCount: candidateCount,
                mode: mode
            )
        }
    }

    /// Re-run the batch on a specific set of photo IDs (typically the
    /// failed ones from a prior run). Bypasses the confirmation alert
    /// since the user explicitly asked to retry, and uses the same
    /// Add/Overwrite mode the original batch ran with.
    func retryFailedTagging(photoIDs: Set<UUID>,
                                      mode: ProjectStore.BatchTagMode) {
        guard !photoIDs.isEmpty else { return }
        guard batchTagTask == nil else { return }   // a batch is already running

        batchTagError = nil
        batchTagSummary = nil
        batchTagFailureReport = nil
        batchTagProgressCurrent = 0
        batchTagProgressTotal = photoIDs.count
        batchTagProgressSeq = nil

        UIApplication.shared.isIdleTimerDisabled = true
        batchBackgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "AI Tagging Retry"
        ) {
            batchTagTask?.cancel()
            endBatchBackgroundTask()
        }

        let pid = projectID
        let candidateCount = photoIDs.count
        batchTagTask = Task { @MainActor in
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                endBatchBackgroundTask()
            }
            do {
                let result = try await store.batchClaudeTagging(
                    projectID: pid,
                    mode: mode,
                    onlyPhotoIDs: photoIDs,
                    onProgress: { current, total, seq in
                        self.batchTagProgressCurrent = current
                        self.batchTagProgressTotal = total
                        self.batchTagProgressSeq = seq
                    }
                )
                self.presentResult(result, candidateCount: candidateCount, mode: mode)
            } catch is CancellationError {
                self.batchTagSummary = "Retry cancelled at \(self.batchTagProgressCurrent) of \(self.batchTagProgressTotal)."
            } catch let err as ClaudeTaggingService.Error {
                self.batchTagError = err.errorDescription ?? "Failed."
            } catch {
                self.batchTagError = error.localizedDescription
            }
            self.batchTagTask = nil
        }
    }

}
