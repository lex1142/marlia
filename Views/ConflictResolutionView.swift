import SwiftUI

/// Name-conflict dialog for copy/move: shown when the destination already has an
/// item with the same name. "Apply to all" extends the choice to the remaining
/// conflicts of the same operation without asking again.
struct ConflictResolutionView: View {
    let conflict: PendingConflict
    let onResolve: (ConflictAction, Bool) -> Void

    @State private var applyToAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Item Already Exists")
                .font(.headline)
            Text("“\(conflict.item.name)” already exists in “\(conflict.destination.lastPathComponent)”.")
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Apply to all remaining conflicts", isOn: $applyToAll)

            HStack {
                Spacer()
                Button("Skip") { onResolve(.skip, applyToAll) }
                Button("Replace", role: .destructive) { onResolve(.replace, applyToAll) }
                // The default button (Enter) is the safe "Keep Both", not replacing
                // the existing file: a destructive action must not fire from a stray
                // Enter.
                Button("Keep Both") { onResolve(.keepBoth, applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
