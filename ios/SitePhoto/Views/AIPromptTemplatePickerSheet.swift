import SwiftUI

/// Pick a saved AI prompt template and load it into the current
/// project's AI Instructions editor. Rendered as a list with a name +
/// a short prompt preview per row; tap to load and dismiss.
struct AIPromptTemplatePickerSheet: View {
    let onPick: (AIPromptTemplate) -> Void

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.aiPromptTemplates.isEmpty {
                    EmptyStateView(
                        icon: "doc.on.doc",
                        title: "No templates yet",
                        message: "Save your current prompt from the AI Instructions sheet (toolbar → \"Save as Template…\") to start building your library."
                    )
                } else {
                    List {
                        ForEach(store.aiPromptTemplates) { template in
                            Button {
                                onPick(template)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(template.name)
                                        .font(.body.bold())
                                        .foregroundStyle(.primary)
                                    Text(template.prompt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Load Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
