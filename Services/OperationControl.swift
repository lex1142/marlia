import Foundation

/// A thread-safe pause/cancel flag for one operation. Not @MainActor: the copy loop
/// (FileOperationService) and the Process wrapper (ArchiveService) run synchronously
/// (not async) on a DiskOperationQueue background thread, so checks go through a plain
/// lock rather than an actor.
///
/// Two different pause mechanisms under the hood:
/// - for copy/move/duplicate (our own loop over items in this process) — a blocking
///   wait on an NSCondition between items (waitWhilePaused());
/// - for archives (an external zip/unzip/tar process) — the pause/resume handlers send
///   SIGSTOP/SIGCONT to the process itself, and cancel calls terminate(); they're
///   installed via setPauseHandlers/setCancelHandler right after the process starts.
final class OperationControl {
    private let condition = NSCondition()
    private var _isPaused = false
    private var _isCancelled = false
    private var pauseHandler: (() -> Void)?
    private var resumeHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?

    var isCancelled: Bool {
        condition.lock(); defer { condition.unlock() }
        return _isCancelled
    }

    private var isPaused: Bool {
        condition.lock(); defer { condition.unlock() }
        return _isPaused
    }

    func pause() {
        condition.lock()
        _isPaused = true
        let handler = pauseHandler
        condition.unlock()
        handler?()
    }

    func resume() {
        condition.lock()
        _isPaused = false
        let handler = resumeHandler
        condition.signal()
        condition.unlock()
        handler?()
    }

    func cancel() {
        condition.lock()
        _isCancelled = true
        _isPaused = false
        let handler = cancelHandler
        condition.signal()
        condition.unlock()
        handler?()
    }

    /// For copy/move/duplicate: called between items; blocks the background thread
    /// while paused and returns immediately on cancel.
    func waitWhilePaused() {
        condition.lock()
        while _isPaused && !_isCancelled {
            condition.wait()
        }
        condition.unlock()
    }

    /// For external processes (archives): wire SIGSTOP/SIGCONT to an already-running
    /// process. If a pause was requested before this call (a race), applies it right
    /// away.
    func setPauseHandlers(pause: @escaping () -> Void, resume: @escaping () -> Void) {
        condition.lock()
        pauseHandler = pause
        resumeHandler = resume
        let alreadyPaused = _isPaused
        condition.unlock()
        if alreadyPaused { pause() }
    }

    /// For external processes: wire terminate() to an already-running process.
    /// If a cancel was requested before this call (a race), applies it right
    /// away.
    func setCancelHandler(_ handler: @escaping () -> Void) {
        condition.lock()
        if _isCancelled {
            condition.unlock()
            handler()
            return
        }
        cancelHandler = handler
        condition.unlock()
    }
}
