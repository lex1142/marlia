import Foundation
import NetFS

/// Connects to an SMB share without going through Finder — via the system NetFS API
/// (`NetFSMountURLSync`, the same mechanism Finder itself mounts with). Once mounted,
/// the share is an ordinary folder in the file system: the rest of the code
/// (Sidebar/Drives, copying, browsing) works with it unchanged, since VolumesStore
/// already listens to NSWorkspace.didMountNotification and picks up new volumes
/// automatically.
///
/// This used to launch /sbin/mount_smbfs with a URL like
/// "//user:password@server/share" in its arguments. That leaks the secret: process
/// arguments are visible in `ps` output to any process of the same user and to root
/// (verified), and Apple's Secure Coding Guide explicitly forbids passing passwords
/// via argv. NetFS takes the password as a separate parameter, so it ends up neither
/// in argv nor in the environment.
enum NetworkMountService {
    enum MountError: LocalizedError {
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .processFailed(let message): return message
            }
        }
    }

    /// Mount in the user's home folder rather than /Volumes: mount_smbfs can't create
    /// a mount point under /Volumes by itself without privileges a regular process
    /// doesn't have (for Finder a privileged helper does it behind the scenes).
    /// FileManager.mountedVolumeURLs sees mounted volumes wherever the mount point is
    /// — not only under /Volumes.
    static let mountsRoot: URL = {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Marlia/Mounts")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    /// hasPrefix on bare strings would also match "…/Marlia/MountsExtra" — compare
    /// either for an exact match or for nesting across a "/" boundary.
    static func isManagedMount(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let root = mountsRoot.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    static func connectSMB(
        server: String, share: String, username: String, password: String,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        DiskOperationQueue.shared.addOperation {
            let mountPoint: URL
            do {
                mountPoint = try createUniqueMountPoint(name: share)
            } catch {
                Task { @MainActor in completion(.failure(error)) }
                return
            }

            // The share URL WITHOUT credentials in it — the user name and password go as
            // separate NetFSMountURLSync parameters. URLComponents percent-encodes the
            // host and path itself, so special characters in the share name don't break
            // parsing.
            var components = URLComponents()
            components.scheme = "smb"
            components.host = server
            components.path = "/" + share
            guard let shareURL = components.url else {
                try? FileManager.default.removeItem(at: mountPoint)
                Task { @MainActor in
                    completion(.failure(MountError.processFailed("Invalid server or share name")))
                }
                return
            }

            let openOptions = NSMutableDictionary()
            // No system UI: we have our own login/error dialog, and a system
            // password prompt popping up from a background thread would simply hang
            // the operation (the same reason mount_smbfs used to run with -N).
            openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
            if username.isEmpty {
                openOptions[kNetFSUseGuestKey] = true
            }
            // Mount exactly at the point we prepared, not in /Volumes: an
            // unprivileged process can't create a directory there (see mountsRoot).
            let mountOptions = NSMutableDictionary()
            mountOptions[kNetFSMountAtMountDirKey] = true

            var mountedPaths: Unmanaged<CFArray>?
            let status = NetFSMountURLSync(
                shareURL as CFURL,
                mountPoint as CFURL,
                username.isEmpty ? nil : username as CFString,
                password.isEmpty ? nil : password as CFString,
                openOptions as CFMutableDictionary,
                mountOptions as CFMutableDictionary,
                &mountedPaths
            )
            mountedPaths?.release()

            guard status == 0 else {
                try? FileManager.default.removeItem(at: mountPoint)
                Task { @MainActor in
                    completion(.failure(MountError.processFailed(Self.message(forStatus: status))))
                }
                return
            }
            Task { @MainActor in completion(.success(mountPoint)) }
        }
    }

    /// NetFS returns ordinary POSIX codes (and its own negative ones for specific cases
    /// like "password must be changed"). For errno use the system description, for the
    /// rest a neutral text with the code: raw output of an external tool, which could
    /// contain the URL with the password passed to it, no longer ends up here.
    private static func message(forStatus status: Int32) -> String {
        switch status {
        case EAUTH, EACCES, EPERM:
            return "Incorrect user name or password."
        case 1..<256:
            return String(cString: strerror(status))
        default:
            return "Connection failed (error \(status))."
        }
    }

    /// This used to check fileExists first and create in a separate call — leaving a
    /// race window between the check and the creation (e.g. a symbolic link planted at
    /// the same path in advance by another process of the same user). Now creation is
    /// the single source of truth: try to create a specific name
    /// (withIntermediateDirectories: false — the parent is guaranteed to exist, so the
    /// call fails atomically if anything at all is already there), and only on failure
    /// move on to the next name, never reusing a path that could have been swapped.
    private static func createUniqueMountPoint(name: String) throws -> URL {
        for suffix in 1...1000 {
            let candidateName = suffix == 1 ? name : "\(name) \(suffix)"
            let candidate = mountsRoot.appendingPathComponent(candidateName)
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch {
                continue
            }
        }
        throw MountError.processFailed("Could not create a mount point for “\(name)”")
    }
}
