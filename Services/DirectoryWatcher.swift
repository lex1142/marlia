import Foundation
import CoreServices

/// Watches a directory for changes via FSEvents. Unlike the earlier kqueue-based
/// implementation (which watched only the directory itself, not its contents in
/// depth), an FSEvents stream is recursive by nature: an event arrives even when
/// something changes inside a nested folder. The practical benefit: a subfolder's
/// own modification date in the list updates by itself, without a manual Refresh,
/// when something inside it changes. FSEvents also works reliably on network
/// volumes (SMB), where kqueue often sends no events at all.
final class DirectoryWatcher {
    /// What the FSEvents callback sees is a separate object, NOT the watcher itself.
    ///
    /// The callback arrives on a background queue, and FSEventStreamStop in deinit isn't
    /// synchronized with a callback that's already running: context.info used to hold an
    /// unretained pointer to the watcher, so an event arriving exactly as the user left
    /// the folder (watcher already freed) touched freed memory. Retaining the watcher
    /// itself in the context isn't an option — then its deinit would never run and nobody
    /// would stop the stream. So the stream retains this box holding a closure instead: it
    /// outlives the callback no matter what, while the watcher is still freed normally and
    /// shuts the stream down.
    private final class CallbackBox {
        let onChange: () -> Void
        init(_ onChange: @escaping () -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?

    init?(url: URL, onChange: @escaping () -> Void) {
        let boxPointer = Unmanaged.passRetained(CallbackBox(onChange)).toOpaque()

        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = boxPointer
        context.release = { info in
            guard let info else { return }
            Unmanaged<CallbackBox>.fromOpaque(info).release()
        }

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let clientCallBackInfo else { return }
            Unmanaged<CallbackBox>.fromOpaque(clientCallBackInfo).takeUnretainedValue().onChange()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else {
            // The stream wasn't created — nobody will call context.release now, so
            // release it ourselves.
            Unmanaged<CallbackBox>.fromOpaque(boxPointer).release()
            return nil
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
