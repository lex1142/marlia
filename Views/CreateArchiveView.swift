import SwiftUI

/// Sheet for creating an archive from the selection: name, format, optional password (ZIP
/// only).
struct CreateArchiveView: View {
    let itemCount: Int
    let onCreate: (_ name: String, _ format: ArchiveFormat, _ password: String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var format: ArchiveFormat = .zip
    @State private var password = ""

    init(itemCount: Int, defaultName: String, onCreate: @escaping (String, ArchiveFormat, String) -> Void, onCancel: @escaping () -> Void) {
        self.itemCount = itemCount
        self.onCreate = onCreate
        self.onCancel = onCancel
        _name = State(initialValue: defaultName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(itemCount == 1 ? "Compress 1 Item" : "Compress \(itemCount) Items")
                .font(.headline)

            TextField("Archive Name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Format", selection: $format) {
                ForEach(ArchiveFormat.allCases) { format in
                    Text(format.label).tag(format)
                }
            }
            .pickerStyle(.menu)

            if format.supportsPassword {
                SecureField("Password (optional)", text: $password)
                    .textFieldStyle(.roundedBorder)
                // The system zip only supports classic ZipCrypto (see the comment on
                // ArchiveFormat.supportsPassword), which has long been broken by a
                // known-plaintext attack. The user should understand this protects against
                // casual browsing, not confidential data.
                Text("ZIP passwords use legacy encryption — suitable for casual protection, not for sensitive data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.escape)
                Button("Create") { onCreate(name, format, password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
