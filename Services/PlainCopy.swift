import Foundation

/// Copying onto volumes that can't store extended attributes (FAT32/exFAT flash drives and
/// cameras, SMB shares without stream support) without littering them with `._name` files.
///
/// On such a volume macOS keeps a file's extended attributes in an AppleDouble twin `._name`
/// next to it. Since macOS 13 the kernel attaches `com.apple.provenance` to every file a
/// process **creates or modifies** — even `echo > file` from a shell — so every file and
/// folder written there gets a twin, and not copying attributes doesn't help. The attribute
/// can't be removed either (`removexattr` reports success, the attribute stays). What does
/// work: deleting the twin once writing is done. Reading, listing, Spotlight and Quick Look
/// don't bring it back; only a later write does. All of this was measured on FAT32 and exFAT
/// disk images before the code was written.
///
/// So: copy as usual (data, dates, permissions), then delete the twins the copy produced —
/// **except** for things that can be run and carry the quarantine flag (apps, executables,
/// installers, archives, scripts): on FAT the twin is the only place quarantine can live, and
/// losing it would let an app downloaded from the internet bypass Gatekeeper after a trip
/// through a flash drive.
///
/// Foundation only, so a scratchpad script can exercise it against a real FAT image.
enum PlainCopy {

    /// Whether the volume holding `url` stores extended attributes itself. Unknown counts
    /// as yes, so the usual copy is kept whenever in doubt.
    /// `pathconf(_PC_XATTR_SIZE_BITS)` can't tell: FAT and exFAT report support there,
    /// meaning the AppleDouble emulation; the volume capability bit is the honest answer.
    static func volumeStoresExtendedAttributes(_ url: URL) -> Bool {
        guard let root = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume else { return true }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES))
        struct Reply { var length: UInt32 = 0; var capabilities = vol_capabilities_attr_t() }
        var reply = Reply()
        guard getattrlist(root.path, &request, &reply, MemoryLayout<Reply>.size, 0) == 0 else { return true }
        let mask = UInt32(VOL_CAP_INT_EXTENDED_ATTR)
        // Index 1 is VOL_CAPABILITIES_INTERFACES.
        guard reply.capabilities.valid.1 & mask != 0 else { return true }
        return reply.capabilities.capabilities.1 & mask != 0
    }

    /// Whether two URLs are on the same volume (a move between them is a rename).
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let ida = (try? a.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject,
              let idb = (try? b.resourceValues(forKeys: key))?.volumeIdentifier as? NSObject
        else { return false }
        return ida.isEqual(idb)
    }

    /// Copies `source` (file, folder or package) to `destination`, which must not exist yet —
    /// if it does, nothing is touched and EEXIST is thrown. On failure whatever was partly
    /// written at `destination` is removed (it didn't exist before, so it's ours).
    static func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        // fileExists follows symlinks, so a dangling link at the destination is checked
        // separately: it's still something we must not delete.
        if fm.fileExists(atPath: destination.path)
            || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST), userInfo: [NSFilePathErrorKey: destination.path])
        }
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        removeTwins(copied: destination, source: source)
    }

    /// Deletes the `._` twins of a copied tree, children before their folder: removing an
    /// entry modifies its folder, and only twins removed after the last write stay gone.
    private static func removeTwins(copied destination: URL, source: URL) {
        // A quarantined runnable keeps its twin — and an app bundle everything inside it.
        if carriesQuarantine(source) { return }
        let values = try? destination.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isDirectory == true, values?.isSymbolicLink != true,
           let names = try? FileManager.default.contentsOfDirectory(atPath: destination.path) {
            for name in names where !name.hasPrefix("._") {
                removeTwins(copied: destination.appendingPathComponent(name), source: source.appendingPathComponent(name))
            }
        }
        let twin = destination.deletingLastPathComponent().appendingPathComponent("._" + destination.lastPathComponent)
        unlink(twin.path)   // ENOENT is fine: nothing to remove
    }

    /// Things that can be run and were downloaded: quarantine must travel with them.
    static func carriesQuarantine(_ url: URL) -> Bool {
        guard getxattr(url.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { return false }
        if runnableExtensions.contains(url.pathExtension.lowercased()) { return true }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static let runnableExtensions: Set<String> = [
        "app", "pkg", "mpkg", "dmg", "zip", "command", "tool", "sh", "workflow", "action",
        "jar", "terminal", "scpt", "applescript", "prefpane", "saver", "webloc",
    ]
}
