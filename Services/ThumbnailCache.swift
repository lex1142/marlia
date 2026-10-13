import SwiftUI
import QuickLookThumbnailing

/// Thumbnail cache for images/videos. Generating them through QuickLook isn't
/// fast (disk + decoding), so results are cached by URL and requested
/// asynchronously — a cell first shows the regular file-type icon, then swaps
/// in the real thumbnail if one is available.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [URL: NSImage] = [:]

    /// Synchronous access to an already-generated thumbnail — so a cell (NSCollectionView)
    /// can set it immediately, without a "generic icon → thumbnail" flash on every
    /// reconfigure/reload.
    func cached(for url: URL) -> NSImage? { cache[url] }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        if let cached = cache[url] { return cached }
        // Same symlink gotcha as in FileItem.init/IconCache: QLThumbnailGenerator doesn't
        // resolve the final symlink itself — for a link (Workspace) the request fails with
        // "the file doesn't exist" instead of producing the target's thumbnail.
        let request = QLThumbnailGenerator.Request(
            fileAt: url.resolvingSymlinksInPath(), size: size, scale: scale, representationTypes: .thumbnail
        )
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
        if let image { cache[url] = image }
        return image
    }
}

/// A small "alias arrow" over the icon/thumbnail of a symbolic link — as in
/// Finder, so it's clear this is a link to a file elsewhere (mostly relevant
/// for Workspaces, where every item is a symlink), even once the icon/thumbnail
/// already shows the target's content rather than a placeholder.
struct SymlinkBadge: View {
    let diameter: CGFloat

    var body: some View {
        Image(systemName: "arrow.turn.up.right")
            .font(.system(size: diameter * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(.black.opacity(0.55)))
    }
}

/// The cell icon: a thumbnail for media files (images/videos), otherwise the
/// regular file-type icon from IconCache.
struct ThumbnailImage: View {
    let item: FileItem
    let displaySize: CGFloat

    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? item.icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: displaySize, height: displaySize)
            .overlay(alignment: .bottomLeading) {
                if item.isSymbolicLink {
                    SymlinkBadge(diameter: max(12, displaySize * 0.3))
                }
            }
            .task(id: item.url) {
                guard item.isPreviewableMedia else { return }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                thumbnail = await ThumbnailCache.shared.thumbnail(
                    for: item.url,
                    size: CGSize(width: displaySize, height: displaySize),
                    scale: scale
                )
            }
    }
}
