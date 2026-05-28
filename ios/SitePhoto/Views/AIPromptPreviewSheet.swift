import SwiftUI

/// Read-only preview of the system prompt Claude will receive when AI
/// tagging runs against this project right now. Composed from the same
/// `PromptCompiler.compile` call the tagging entry points use, so what
/// you see here is what gets sent — no drift, no caching, no surprises.
///
/// Useful when the engineer has just edited the rules template, the AI
/// Tags selection, or the project's AI Notes, and wants to confirm the
/// changes actually landed in the prompt before burning rate-limit
/// budget on a batch.
struct AIPromptPreviewSheet: View {
    let projectID: UUID
    /// When the user opens the preview from a sheet that has unsaved
    /// edits to the tag selection (e.g. AI Tags), passing the draft
    /// here means the preview reflects what they're about to save —
    /// not the older saved state.
    var draftSelection: ProjectTagSelection? = nil
    /// Same idea for the per-project AI Notes editor.
    var draftAINotes: String? = nil

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Outcome of compiling the current store + draft overrides into a
    /// prompt. Plain enum instead of `Result<_, Error>` so the failure
    /// branch can carry a user-facing message string directly without a
    /// throw-away Error wrapper.
    private enum CompileOutcome {
        case success(PromptCompiler.Result)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("AI Prompt Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if case .success(let result) = compileResult {
                            ShareLink(item: result.joinedSystemPrompt,
                                       subject: Text("AI prompt preview"),
                                       message: Text("System prompt that SitePhoto sends to Claude for this project.")) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch compileResult {
        case .success(let result):
            blockList(result)
        case .failure(let message):
            errorState(message)
        }
    }

    /// Re-compile on every render. Cheap (string concatenation only,
    /// no I/O) and guarantees the preview reflects unsaved edits to
    /// the underlying state as soon as they're written back to the
    /// store.
    private var compileResult: CompileOutcome {
        guard var project = store.project(withID: projectID) else {
            return .failure("Project not found.")
        }
        // Apply draft overrides so the preview can show what's in the
        // *editor*, not what was last saved. Each override is applied
        // independently — passing draftSelection alone leaves notes at
        // their saved value, and vice versa.
        if let draftSelection {
            project.tagSelection = draftSelection
        }
        if let draftAINotes {
            project.aiInstructions = draftAINotes
        }
        do {
            let result = try PromptCompiler.compile(
                rulesTemplate: store.aiRulesTemplate,
                tagLibrary: store.tagLibrary,
                project: project
            )
            return .success(result)
        } catch let e as PromptCompiler.CompileError {
            return .failure(e.errorDescription ?? "Could not build the prompt.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func blockList(_ result: PromptCompiler.Result) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This is the exact system message that will be sent to Claude on the next AI tagging request for this project. Tap a section to expand its full text.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    let chars = result.joinedSystemPrompt.count
                    Text("\(result.blocks.count) blocks · \(chars) characters")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(Array(result.blocks.enumerated()), id: \.offset) { index, block in
                let title = blockTitle(index: index, total: result.blocks.count)
                Section(title) {
                    DisclosureGroup {
                        Text(block.text)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(blockSummary(for: block.text))
                                .font(.callout)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                            Text("\(block.text.count) characters")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text("Can't build prompt")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Block ordering matches `PromptCompiler.compile`:
    ///   0     — preamble + rules
    ///   1     — controlled vocabulary
    ///   2     — project AI Notes (optional; missing when the project's
    ///           notes are empty, so total may be 3 instead of 4)
    ///   last  — output contract reinforcement
    private func blockTitle(index: Int, total: Int) -> String {
        if index == 0 { return "Rules & schema" }
        if index == total - 1 { return "Output contract" }
        if index == 1 { return "Controlled vocabulary" }
        return "Project AI Notes"
    }

    /// First non-empty line, trimmed and bounded — gives the disclosure
    /// row a useful one-line summary so the user can scan all four blocks
    /// at a glance.
    private func blockSummary(for text: String) -> String {
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return String(firstLine.prefix(140))
    }
}
