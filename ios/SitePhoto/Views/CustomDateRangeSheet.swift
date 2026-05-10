import SwiftUI

/// Half-height sheet for picking an explicit start / end date pair to
/// drive the photo list's date-range filter. Two DatePickers (graphical)
/// stacked vertically; "Apply" validates that end ≥ start and dismisses.
/// Used from `ProjectDetailView.dateFilterChip` when the engineer picks
/// the "Custom range…" menu option.
struct CustomDateRangeSheet: View {
    let current: ProjectDetailView.DateFilter
    let onApply: (ProjectDetailView.DateFilter) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var start: Date
    @State private var end: Date

    init(current: ProjectDetailView.DateFilter,
         onApply: @escaping (ProjectDetailView.DateFilter) -> Void) {
        self.current = current
        self.onApply = onApply
        // Pre-fill with the current custom range if there is one;
        // otherwise default to "yesterday and today" so the engineer
        // sees a useful starting state instead of two identical pickers.
        if case .custom(let s, let e) = current {
            _start = State(initialValue: s)
            _end = State(initialValue: e)
        } else {
            let today = Calendar.current.startOfDay(for: Date())
            let yesterday = Calendar.current.date(byAdding: .day, value: -1,
                                                    to: today) ?? today
            _start = State(initialValue: yesterday)
            _end = State(initialValue: today)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("From") {
                    DatePicker("Start",
                                selection: $start,
                                displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
                Section("To") {
                    DatePicker("End",
                                selection: $end,
                                in: start...,
                                displayedComponents: .date)
                        .datePickerStyle(.graphical)
                }
            }
            .navigationTitle("Custom date range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Apply") {
                        onApply(.custom(start: start, end: end))
                        dismiss()
                    }
                    .bold()
                    .disabled(end < start)
                }
            }
        }
    }
}
