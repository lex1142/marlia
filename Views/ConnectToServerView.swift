import SwiftUI

/// The "Connect to Server" sheet — connects to an SMB share without going through Finder (see
/// NetworkMountService).
struct ConnectToServerView: View {
    let onSuccess: (URL) -> Void
    let onCancel: () -> Void

    @State private var server = ""
    @State private var share = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isGuest = false
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Server")
                .font(.headline)

            TextField("Server (e.g. 192.168.1.10)", text: $server)
                .textFieldStyle(.roundedBorder)
                .disabled(isConnecting)
            TextField("Share Name", text: $share)
                .textFieldStyle(.roundedBorder)
                .disabled(isConnecting)

            Toggle("Connect as Guest", isOn: $isGuest)
                .disabled(isConnecting)

            if !isGuest {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isConnecting)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isConnecting)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.escape)
                    .disabled(isConnecting)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isConnecting || server.trimmingCharacters(in: .whitespaces).isEmpty || share.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func connect() {
        errorMessage = nil
        isConnecting = true
        NetworkMountService.connectSMB(
            server: server.trimmingCharacters(in: .whitespaces),
            share: share.trimmingCharacters(in: .whitespaces),
            username: isGuest ? "" : username,
            password: isGuest ? "" : password
        ) { result in
            isConnecting = false
            switch result {
            case .success(let url):
                onSuccess(url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
