import SwiftUI
import AppKit

/// Opens a .dmg "the Finder way". Mounting is still done by the system DiskImageMounter
/// (`NSWorkspace.open`): it shows the image verification, the license and the password
/// prompt for encrypted images itself — redoing that via `hdiutil attach` would mean losing
/// all of that UI. But DiskImageMounter doesn't report where it mounted the volume, and the
/// window with the image's contents is opened by Finder, not by it. So we wait for
/// `didMountNotification`, find our image in `hdiutil info` and show the install window
/// (`DiskImageInstallView`).
@MainActor
final class DiskImageOpener {
    static let shared = DiskImageOpener()

    /// Images we opened and are waiting to be mounted: path (resolved) → when opened.
    /// If the user cancels the license/password, the mount never happens — the entry
    /// simply expires.
    private var pending: [String: Date] = [:]
    private let pendingLifetime: TimeInterval = 600

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in DiskImageOpener.shared.volumeDidMount() }
        }
    }

    static func isDiskImage(_ url: URL) -> Bool {
        ["dmg", "sparseimage"].contains(url.pathExtension.lowercased())
    }

    func open(_ imageURL: URL) {
        let path = imageURL.resolvingSymlinksInPath().path
        Self.mountPoints { mounts in
            // Already mounted: DiskImageMounter does nothing in that case and
            // there will be no notification — show the window right away.
            if let mount = mounts[path] {
                AppWindowManager.shared.openDiskImage(volume: mount, image: imageURL)
                return
            }
            self.pending[path] = Date()
            NSWorkspace.shared.open(imageURL)
        }
    }

    private func volumeDidMount() {
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value) < pendingLifetime }
        guard !pending.isEmpty else { return }
        Self.mountPoints { mounts in
            for path in self.pending.keys {
                guard let mount = mounts[path] else { continue }
                self.pending[path] = nil
                AppWindowManager.shared.openDiskImage(volume: mount, image: URL(fileURLWithPath: path))
            }
        }
    }

    /// Image path → mount point of its volume, from `hdiutil info -plist`. The
    /// process runs off the main thread; the result is delivered on the main one.
    private static func mountPoints(_ completion: @escaping @MainActor ([String: URL]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["info", "-plist"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var result: [String: URL] = [:]
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                for image in plist?["images"] as? [[String: Any]] ?? [] {
                    guard let imagePath = image["image-path"] as? String else { continue }
                    let entities = image["system-entities"] as? [[String: Any]] ?? []
                    if let mount = entities.lazy.compactMap({ $0["mount-point"] as? String }).first {
                        result[URL(fileURLWithPath: imagePath).resolvingSymlinksInPath().path] =
                            URL(fileURLWithPath: mount, isDirectory: true)
                    }
                }
            }
            let mounts = result
            Task { @MainActor in completion(mounts) }
        }
    }
}

/// The window of a mounted image: the apps at the volume root shown large with an arrow
/// to Applications — the same picture as a typical installer window in Finder — and
/// installing with one button. If there are no apps but there is a .pkg, offer to run it.
/// `@MainActor` on the whole view, not just `body`: Swift 5.10 (CI) isolates only `body` of a
/// `View`, so helper methods that touch `AppStateRegistry`/`PaneViewModel` wouldn't compile there.
@MainActor
struct DiskImageInstallView: View {
    let volume: URL
    let image: URL

    private enum Status: Equatable {
        case idle, copying, installed, failed(String)
    }

    @State private var apps: [URL] = []
    @State private var packages: [URL] = []
    @State private var status: [URL: Status] = [:]
    @State private var ejecting = false

    private static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    ForEach(apps, id: \.self) { appRow($0) }
                    ForEach(packages, id: \.self) { packageRow($0) }
                    if apps.isEmpty && packages.isEmpty {
                        Text("This disk image contains no applications or installers.")
                            .foregroundColor(.secondary)
                            .padding(.top, 40)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("Show Contents") { showContents() }
                Spacer()
                if ejecting { ProgressView().controlSize(.small) }
                Button("Eject") { eject() }
                    .disabled(ejecting || status.values.contains(.copying))
            }
            .padding(12)
        }
        .themedTint(ThemeStore.shared.palette)
        .onAppear(perform: loadContents)
    }

    private func appRow(_ app: URL) -> some View {
        let state = status[app] ?? .idle
        return VStack(spacing: 10) {
            HStack(spacing: 24) {
                iconTile(app)
                Image(systemName: "arrow.right")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.secondary)
                iconTile(Self.applications)
            }
            switch state {
            case .idle:
                Button("Install") { install(app) }
                    .keyboardShortcut(.defaultAction)
            case .copying:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Copying to Applications…").foregroundColor(.secondary)
                }
            case .installed:
                HStack(spacing: 12) {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                    Button("Open") { openInstalled(app) }
                    Button("Eject & Close") { eject() }
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                VStack(spacing: 6) {
                    Text(message).foregroundColor(.red).multilineTextAlignment(.center)
                    Button("Try Again") { install(app) }
                }
            }
        }
    }

    private func packageRow(_ pkg: URL) -> some View {
        VStack(spacing: 10) {
            iconTile(pkg)
            Button("Open Installer") { NSWorkspace.shared.open(pkg) }
        }
    }

    private func iconTile(_ url: URL) -> some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 96, height: 96)
            Text(FileManager.default.displayName(atPath: url.path))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
        }
    }

    private func loadContents() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: volume, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let sorted = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        apps = sorted.filter { $0.pathExtension.lowercased() == "app" }
        packages = sorted.filter { ["pkg", "mpkg"].contains($0.pathExtension.lowercased()) }
    }

    private func install(_ app: URL) {
        let destination = Self.applications.appendingPathComponent(app.lastPathComponent)
        var replace = false
        if FileManager.default.fileExists(atPath: destination.path) {
            let alert = NSAlert()
            alert.messageText = "An item named “\(app.lastPathComponent)” already exists in Applications."
            alert.informativeText = "Do you want to replace it? The existing copy will be moved to the Trash."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            replace = true
        }
        status[app] = .copying
        let shouldReplace = replace
        DiskOperationQueue.shared.addOperation {
            var failure: String?
            do {
                if shouldReplace {
                    try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
                }
                try FileManager.default.copyItem(at: app, to: destination)
            } catch {
                failure = error.localizedDescription
            }
            let outcome: Status = failure.map { .failed($0) } ?? .installed
            Task { @MainActor in status[app] = outcome }
        }
    }

    private func openInstalled(_ app: URL) {
        NSWorkspace.shared.open(Self.applications.appendingPathComponent(app.lastPathComponent))
    }

    private func showContents() {
        guard let pane = AppStateRegistry.activeState?.activePane else { return }
        pane.navigate(to: volume)
        pane.selection.removeAll()
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }

    /// The window closes by itself on `didUnmountNotification` (see
    /// `AppWindowManager.openDiskImage`), so on success there's nothing to close here.
    /// `NSWorkspace` first; if it refuses, `diskutil eject` (as in the sidebar), which reports
    /// what is keeping the volume busy.
    private func eject() {
        ejecting = true
        let volume = volume
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            } catch {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                process.arguments = ["eject", volume.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                if (try? process.run()) != nil {
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        failure = output.isEmpty ? error.localizedDescription : output
                    }
                } else {
                    failure = error.localizedDescription
                }
            }
            let message = failure
            Task { @MainActor in
                ejecting = false
                guard let message else { return }
                let alert = NSAlert()
                alert.messageText = "Couldn’t eject “\(FileManager.default.displayName(atPath: volume.path))”"
                alert.informativeText = message
                alert.runModal()
            }
        }
    }
}
