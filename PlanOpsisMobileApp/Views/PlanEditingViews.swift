#if os(iOS)
import SwiftUI

/// v12.3 editing a plan dimension by value: type the length; for walls choose which end stays.
struct PlanDimensionEditor: View {
    let edit: PlanDimensionEdit
    /// Returns true when the change was applied.
    let onApply: (Double, PlanLengthAnchor) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double
    @State private var anchor: PlanLengthAnchor = .start
    @FocusState private var focused: Bool

    init(edit: PlanDimensionEdit, onApply: @escaping (Double, PlanLengthAnchor) -> Bool) {
        self.edit = edit
        self.onApply = onApply
        _value = State(initialValue: (edit.measured * 10).rounded() / 10)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(edit.title)
                    .font(.headline)
                Spacer()
                Text("now \(Int(edit.measured.rounded())) mm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField("Length", value: $value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit(apply)
                Text("mm")
                    .foregroundStyle(.secondary)
            }
            if edit.target.isWall {
                Picker("Keep", selection: $anchor) {
                    ForEach(PlanLengthAnchor.allCases) { anchor in
                        Text(anchor.title).tag(anchor)
                    }
                }
                .pickerStyle(.segmented)
                Text("Walls joined at the moving end follow it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .planOpsisGlassProminentButton(active: true)
                    .disabled(!(value.isFinite && value > 0))
            }
        }
        .padding(20)
        .onAppear { focused = true }
    }

    private func apply() {
        if onApply(value, anchor) { dismiss() }
    }
}

/// Hardware-keyboard shortcuts for the plan editor on iPad: undo/redo, delete, select all and escape.
/// Every editing shortcut carries ⌘ so typing in a field never triggers one.
struct PlanKeyboardShortcuts: View {
    @ObservedObject var store: PlanOpsisMobileStore

    var body: some View {
        ZStack {
            Button("Undo") { store.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)
            Button("Redo") { store.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!store.canRedo)
            Button("Delete") { store.deleteSelectedObject() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selectedIDs.isEmpty || store.creationTool != nil)
            Button("Select all") { store.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
            Button("Cancel") {
                if store.creationTool != nil || store.componentCreationTool != nil || store.underlayAlignment != nil || store.isTracingWalls { store.cancelCreation() }
                else if store.isMovingUnderlay { store.isMovingUnderlay = false }
                else { store.clearSelection() }
            }
            .keyboardShortcut(.escape, modifiers: [])
            Button("Draw walls") { store.beginCreation(.wall) }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .accessibilityHidden(true)
    }
}
#endif
