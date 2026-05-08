import SwiftUI

/// Edit the project's address. Saving forwards the new address through the
/// caller's `onSave` so the parent can run forward-geocoding and update the
/// project's coordinates to match.
struct AddressEditSheet: View {
    let projectID: UUID
    let currentAddress: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Street, city, state",
                        text: $draft,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                } header: {
                    Text("Address")
                } footer: {
                    Text("The project's coordinates will be updated to match the new address. Photos already located on the floor plan are unchanged.")
                }
            }
            .navigationTitle("Edit Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines)
                              == currentAddress.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            .onAppear {
                draft = currentAddress
            }
        }
    }
}
