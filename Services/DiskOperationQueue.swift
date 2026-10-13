import Foundation

/// App-wide limit on concurrent file operations (copy/move/duplicate/delete/rename,
/// archive create/extract) — there's one disk for the whole app, so the limit has to
/// be global rather than per window: otherwise N open tabs would mean up to N
/// simultaneous copies onto the same disk. 3 is a compromise between "fully
/// sequential" (small operations wait behind a big copy) and unbounded parallelism
/// (the disk slows every operation down at once).
enum DiskOperationQueue {
    static let shared: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        return queue
    }()
}
