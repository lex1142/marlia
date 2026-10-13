import SwiftUI

/// Batch rename with a live preview.
///
/// The preview isn't decoration: the operation changes dozens of names in one click,
/// and seeing the result BEFORE applying it is the only way to keep a typo in the
/// pattern from turning into fifty ruined names. For the same reason the apply button
/// stays disabled while the list has even one conflict: a partial "as many as
/// possible" rename would leave the folder in a state nobody could reconstruct in
/// their head.
struct BatchRenameView: View {
    let items: [FileItem]
    /// Names in the same folder that aren't part of the rename — target names are
    /// checked against them.
    let existingNames: Set<String>
    let onApply: ([(url: URL, newName: String)]) -> Void
    let onCancel: () -> Void

    @State private var settings = BatchRenameSettings()

    private var entries: [BatchRenameEntry] {
        BatchRenamePlan.build(
            names: items.map(\.name),
            existingNames: existingNames,
            settings: settings
        )
    }

    private var problemCount: Int { entries.filter { $0.problem != nil }.count }
    private var changedCount: Int { entries.filter(\.isChanged).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(items.count == 1 ? "Rename 1 Item" : "Rename \(items.count) Items")
                .font(.headline)

            Picker("", selection: $settings.mode) {
                ForEach(BatchRenameMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch settings.mode {
            case .pattern: patternFields
            case .findReplace: findReplaceFields
            }

            Divider()
            preview
            Divider()

            HStack(spacing: 8) {
                if problemCount > 0 {
                    Label(
                        problemCount == 1 ? "1 name can’t be used" : "\(problemCount) names can’t be used",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else {
                    Text(changedCount == 0 ? "Nothing would change" : "\(changedCount) of \(items.count) will be renamed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problemCount > 0 || changedCount == 0)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var patternFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Pattern", text: $settings.pattern)
                    .textFieldStyle(.roundedBorder)
                Text("Start at")
                    .foregroundStyle(.secondary)
                TextField("", value: $settings.startIndex, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
            }
            Text("“#” becomes the number (### gives 001), “*” keeps the original name. The extension is always kept; a number is added automatically when the pattern has none.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var findReplaceFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Find", text: $settings.find)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("Replace with", text: $settings.replace)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Matches the whole file name, including the extension. Case-sensitive.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Text(entry.originalName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)

                        Text(entry.newName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(entry.problem != nil ? Color.orange
                                             : (entry.isChanged ? Color.primary : Color.secondary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .help(entry.problem?.message ?? "")
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: 180)
    }

    private func apply() {
        // Only names that actually change go into the plan: renaming a file to itself is
        // pointless, and such pairs would only add noise to undo.
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.url) })
        let plan = entries.compactMap { entry -> (url: URL, newName: String)? in
            guard entry.isChanged, entry.problem == nil, let url = byName[entry.originalName] else { return nil }
            return (url: url, newName: entry.newName)
        }
        onApply(plan)
    }
}
