// Split out of ProjectDetailView.swift (Build #6.23.1 — iOS
// decomposition part 1). File-scope support types moved verbatim;
// the only change is dropping the file-scope `fileprivate`/`private`
// (these are now internal, same module). No behavior change.

import SwiftUI

/// State envelope for the failure-summary sheet. Carries the batch result
/// + the parameters needed to retry just the failed photos with the same
/// settings the original run used.
struct BatchTagFailureReport: Identifiable {
    let id = UUID()
    let result: ProjectStore.BatchTagResult
    let candidateCount: Int
    let mode: ProjectStore.BatchTagMode
}

struct BatchTagPrompt: Identifiable {
    let id = UUID()
    let candidateCount: Int
    let skippedCount: Int
    let skipAlreadyTagged: Bool
    /// Number of candidate photos that already carry at least one tag —
    /// the population that "Overwrite" will actually clobber. Equal to 0
    /// when `skipAlreadyTagged` is true (those photos are filtered out
    /// before the prompt shows).
    let candidatesWithExistingTags: Int
    /// When set, the batch runs only against these specific photo IDs
    /// (the multi-select "Tag with AI" path). When nil, the batch
    /// targets every untagged photo in the project (the project-wide
    /// "Auto-tag untagged photos with AI" path).
    let onlyPhotoIDs: Set<UUID>?
}


struct BatchTagModifiers: ViewModifier {
    @Binding var confirm: BatchTagPrompt?
    @Binding var summary: String?
    @Binding var error: String?
    let isRunning: Bool
    let progressCurrent: Int
    let progressTotal: Int
    let progressSeq: Int?
    /// Thumbnail of the most recently started photo (Build #6.9.1) —
    /// lets the user see *which* photo a stuck batch is sitting on.
    let progressThumbURL: URL?
    let costFor: (Int) -> String
    let onConfirm: (BatchTagPrompt, ProjectStore.BatchTagMode) -> Void
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(confirmTitle, isPresented: confirmIsPresented, presenting: confirm) { prompt in
                Button("Add to existing · ~\(costFor(prompt.candidateCount))") {
                    onConfirm(prompt, .add)
                }
                if prompt.candidatesWithExistingTags > 0 {
                    Button("Overwrite existing · ~\(costFor(prompt.candidateCount))",
                           role: .destructive) {
                        onConfirm(prompt, .overwrite)
                    }
                }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: { prompt in
                Text(confirmMessage(for: prompt))
            }
            .alert("AI tagging done",
                   isPresented: summaryIsPresented,
                   presenting: summary) { _ in
                Button("OK") { summary = nil }
            } message: { s in
                Text(s)
            }
            .alert("AI tagging failed",
                   isPresented: errorIsPresented,
                   presenting: error) { _ in
                Button("OK") { error = nil }
            } message: { msg in
                Text(msg)
            }
            .overlay {
                if isRunning {
                    BatchTagProgressOverlay(
                        current: progressCurrent,
                        total: progressTotal,
                        photoSeq: progressSeq,
                        thumbURL: progressThumbURL,
                        onCancel: onCancel
                    )
                }
            }
    }

    private var confirmIsPresented: Binding<Bool> {
        Binding(get: { confirm != nil },
                set: { if !$0 { confirm = nil } })
    }
    private var summaryIsPresented: Binding<Bool> {
        Binding(get: { summary != nil },
                set: { if !$0 { summary = nil } })
    }
    private var errorIsPresented: Binding<Bool> {
        Binding(get: { error != nil },
                set: { if !$0 { error = nil } })
    }

    private var confirmTitle: String {
        let n = confirm?.candidateCount ?? 0
        let scopeWord = (confirm?.onlyPhotoIDs != nil) ? "selected " : ""
        return "Run AI tagging on \(n) \(scopeWord)photo\(n == 1 ? "" : "s")?"
    }

    private func confirmMessage(for prompt: BatchTagPrompt) -> String {
        let cost = costFor(prompt.candidateCount)
        var lines: [String] = []
        if prompt.onlyPhotoIDs != nil {
            lines.append("Each selected photo is sent to Claude vision and every returned tag is auto-accepted. Estimated cost: ~\(cost).")
        } else {
            lines.append("Each photo is sent to Claude vision and every returned tag is auto-accepted. Estimated cost: ~\(cost).")
        }

        if prompt.skipAlreadyTagged && prompt.skippedCount > 0 {
            lines.append("\(prompt.skippedCount) photo\(prompt.skippedCount == 1 ? "" : "s") with existing tags will be skipped.")
        }
        if prompt.candidatesWithExistingTags > 0 {
            lines.append("\(prompt.candidatesWithExistingTags) of these photo\(prompt.candidatesWithExistingTags == 1 ? "" : "s") already have tags. \"Add\" preserves them; \"Overwrite\" replaces them with what Claude returns.")
        }
        return lines.joined(separator: "\n\n")
    }
}

struct BatchTagProgressOverlay: View {
    let current: Int
    let total: Int
    let photoSeq: Int?
    let thumbURL: URL?
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if total > 0 {
                    ProgressView(value: Double(current), total: Double(max(total, 1)))
                        .tint(.white)
                        .frame(width: 220)
                }
                // Build #6.9.1: show the in-flight photo, not just
                // its number — a stuck batch becomes diagnosable at
                // a glance.
                if thumbURL != nil || photoSeq != nil {
                    HStack(spacing: 8) {
                        if let thumbURL {
                            CachedThumbnail(url: thumbURL)
                                .frame(width: 64, height: 48)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        if let photoSeq {
                            Text("Photo #\(photoSeq)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                Button("Cancel", role: .destructive, action: onCancel)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(28)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var headline: String {
        if total == 0 { return "Starting…" }
        return "Tagging \(current) of \(total)"
    }
}

