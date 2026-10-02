#if os(iOS)
import SwiftUI

/// v12.2 project list. Projects are saved automatically; this sheet opens, renames and deletes them.
struct ProjectLibraryView: View {
    @ObservedObject var store: PlanOpsisMobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: ProjectLibrary.Entry?

    var body: some View {
        NavigationStack {
            List {
                if let project = store.project {
                    Section("Open project") {
                        TextField(project.displayName, text: Binding(
                            get: { store.project?.name ?? "" },
                            set: { store.renameProject($0) }
                        ))
                        LabeledContent("Rooms", value: "\(project.rooms.count)")
                    }
                }

                Section {
                    if store.libraryEntries.isEmpty {
                        Text("No saved projects yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.libraryEntries) { entry in
                        Button {
                            store.openProject(entry.id)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.name)
                                        .foregroundStyle(.primary)
                                    Text("\(entry.roomCount) room\(entry.roomCount == 1 ? "" : "s") · \(entry.modified.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if entry.id == store.project?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .accessibilityLabel("Open")
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { pendingDelete = entry }
                        }
                    }
                } header: {
                    Text("Projects")
                } footer: {
                    Text("Projects save automatically after every change and before a new scan or import replaces them.")
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete \u{201C}\(pendingDelete?.name ?? "")\u{201D}?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete project", role: .destructive) {
                    if let entry = pendingDelete { store.deleteProject(entry.id) }
                    pendingDelete = nil
                }
            } message: {
                Text("This removes the project from this device. Exported files are not affected.")
            }
            .onAppear { store.refreshLibrary() }
        }
    }
}
#endif
