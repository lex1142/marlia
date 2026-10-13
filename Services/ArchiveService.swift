import Foundation

/// Archive formats macOS handles out of the box — via the system /usr/bin/zip,
/// /usr/bin/unzip and /usr/bin/tar (bsdtar, which supports -a/auto-detecting
/// compression by extension when creating, and extracting without an explicit filter).
enum ArchiveFormat: String, CaseIterable, Identifiable {
    case zip, tarGz, tarBz2, tarXz, tar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zip: return "ZIP"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .tar: return "tar"
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tarGz: return "tar.gz"
        case .tarBz2: return "tar.bz2"
        case .tarXz: return "tar.xz"
        case .tar: return "tar"
        }
    }

    /// Only ZIP supports a password through the system tools without third-party ones
    /// (classic ZipCrypto via zip -P / unzip -P; AES archives from other programs can't
    /// be extracted this way — a limitation of the bundled Info-Zip).
    var supportsPassword: Bool { self == .zip }

    /// Determines the format from the file extension — for "Extract" / "View
    /// Contents".
    init?(url: URL) {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { self = .zip }
        else if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { self = .tarGz }
        else if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") { self = .tarBz2 }
        else if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { self = .tarXz }
        else if name.hasSuffix(".tar") { self = .tar }
        else { return nil }
    }

    /// Name for the extraction folder — without the archive extension (including a
    /// compound "tar.gz").
    func baseName(for url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz", ".zip", ".tar"] {
            if name.lowercased().hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }
}

/// Creating/extracting/listing archives via the system CLI tools (the same approach
/// already used for "Open in Terminal" — Process, no shell, so file names with
/// spaces need no escaping). Work runs on the app-wide DiskOperationQueue (see its
/// comment) — the same concurrency limit as copy/move/duplicate, since the disk is a
/// shared resource.
final class ArchiveService {
    enum ArchiveError: LocalizedError {
        case passwordRequired
        case processFailed(String)
        case unsafePath(String)

        var errorDescription: String? {
            switch self {
            case .passwordRequired: return "This archive is password-protected."
            case .processFailed(let message): return message
            case .unsafePath(let path): return "This archive contains an unsafe path (“\(path)”) and was not extracted."
            }
        }
    }

    /// Zip-slip protection: an entry like "../../etc/whatever" or an absolute path
    /// inside the archive could write a file outside destination. Modern unzip/bsdtar
    /// usually block this themselves, but we don't rely on them alone — the archive
    /// listing is checked before extraction starts.
    /// Surrounding whitespace is trimmed BEFORE the check rather than relying on the
    /// listing parser to be careful: until it was trimmed, an entry " ../x" didn't start
    /// with "/" and had no component that was exactly ".." — i.e. a path leading outside
    /// passed the check as safe (which is exactly what happened with `unzip -l`'s column
    /// alignment).
    private static func isSafeEntryPath(_ path: String) -> Bool {
        let path = path.trimmingCharacters(in: .whitespaces)
        guard !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// The second way out of destination isn't an entry path but a SYMLINK inside the
    /// archive: "link -> ../.." followed by an entry "link/whatever" already writes
    /// outside. The entry's own path is perfectly legitimate, so isSafeEntryPath lets it
    /// through. So check the link target: absolute — not allowed; relative — count
    /// components from the link's directory and forbid going above the archive root.
    ///
    /// In practice this applies to tar: bsdtar shows the target in its listing ("link ->
    /// target"), while `unzip -l` doesn't (it's only visible in `unzip -Z`, a different
    /// format and one more process launch). For zip we rely on unzip's own behavior:
    /// verified that it defers creating symlinks to the end and refuses to write through
    /// them ("unable to process link/inner.txt", exit code 2), so writing outside
    /// doesn't get through there either.
    private static func symlinkEscapes(entryPath: String, target: String) -> Bool {
        guard !target.hasPrefix("/") else { return true }
        var components = entryPath.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            switch part {
            case ".":
                continue
            case "..":
                if components.isEmpty { return true }
                components.removeLast()
            default:
                components.append(String(part))
            }
        }
        return false
    }

    /// An archive entry is safe if both its own path and (for a symlink) its
    /// target stay inside the extraction folder.
    private static func isSafeEntry(_ entry: Entry) -> Bool {
        guard isSafeEntryPath(entry.path) else { return false }
        guard let target = entry.linkTarget else { return true }
        return !symlinkEscapes(entryPath: entry.path, target: target)
    }

    struct Entry: Identifiable {
        let id = UUID()
        let path: String
        let size: Int64
        let isDirectory: Bool
        /// The symbolic link target, if the entry is a symlink and the listing
        /// format shows it (tar). nil for regular files and for all zip entries.
        var linkTarget: String? = nil
    }

    func createArchive(
        items: [FileItem], destination: URL, format: ArchiveFormat, password: String?,
        control: OperationControl = OperationControl(),
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        DiskOperationQueue.shared.addOperation {
            guard let parent = items.first?.url.deletingLastPathComponent() else {
                Task { @MainActor in completion(.success(())) }
                return
            }
            let process = Process()
            var arguments: [String]
            // "--" before the list of names is mandatory, not cosmetic: the file names come
            // from disk, i.e. this is FOREIGN input (someone else's extracted folder, a
            // flash drive, a network share). Info-ZIP parses options anywhere in the
            // argument list, so a file named "-T"/"-x"/"-P" turned into a FLAG: confirmed
            // with /usr/bin/zip — the files "-T", "-TT", "rm" made zip run an external
            // program (-TT = what to test the archive with) and lose the result, while "-x"
            // silently dropped files from the archive. bsdtar doesn't parse options after
            // operands (also verified), but "--" goes there too — consistent and
            // independent of the implementation.
            if format == .zip {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                arguments = ["-r"]
                if let password, !password.isEmpty {
                    arguments += ["-P", password]
                }
                arguments += [destination.path, "--"] + items.map(\.name)
            } else {
                // -a: bsdtar picks the compression filter from the destination's
                // extension itself.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                arguments = ["-acf", destination.path, "--"] + items.map(\.name)
            }
            process.arguments = arguments
            process.currentDirectoryURL = parent
            process.standardInput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
                // Pausing/cancelling an external process: SIGSTOP/SIGCONT suspend it
                // without any pause support from zip/tar themselves, and terminate()
                // aborts extraction/packing immediately.
                control.setPauseHandlers(
                    pause: { kill(process.processIdentifier, SIGSTOP) },
                    resume: { kill(process.processIdentifier, SIGCONT) }
                )
                control.setCancelHandler {
                    // If the process is currently paused (SIGSTOP), SIGTERM just gets
                    // queued and has no effect until the process resumes — wake it first,
                    // then stop it, otherwise cancelling while paused would hang.
                    kill(process.processIdentifier, SIGCONT)
                    process.terminate()
                }
                process.waitUntilExit()
                if control.isCancelled {
                    try? FileManager.default.removeItem(at: destination)
                    Task { @MainActor in completion(.failure(CancellationError())) }
                    return
                }
                if process.terminationStatus != 0 {
                    let message = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown error"
                    Task { @MainActor in completion(.failure(ArchiveError.processFailed(message))) }
                    return
                }
                Task { @MainActor in completion(.success(())) }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    /// onProgress receives (processed, total) — "total" is first read from the archive
    /// listing, then lines in the extracting process's own stdout are counted (unzip and
    /// `tar -v` print one line per file) — approximate, but enough for a progress bar.
    func extractArchive(
        url: URL, format: ArchiveFormat, destination: URL, password: String?,
        control: OperationControl = OperationControl(),
        onProgress: @escaping @MainActor (Int, Int) -> Void = { _, _ in },
        completion: @escaping @MainActor (Result<Void, Error>) -> Void
    ) {
        DiskOperationQueue.shared.addOperation {
            // The listing is mandatory, not "if it works out": there used to be a try?
            // here, and on any error reading the archive entries became nil — the check
            // below silently didn't run, and extraction went ahead with no path control
            // at all. If the contents can't be read, we don't extract. (Verified this
            // doesn't affect password-protected archives: names in a zip aren't
            // encrypted, `unzip -l` returns them and exits with 0, so the normal "ask for
            // the password" flow still works.)
            let entries: [Entry]
            do {
                entries = try Self.runListProcess(url: url, format: format)
            } catch {
                Task { @MainActor in completion(.failure(error)) }
                return
            }
            if let unsafe = entries.first(where: { !Self.isSafeEntry($0) }) {
                Task { @MainActor in completion(.failure(ArchiveError.unsafePath(unsafe.path))) }
                return
            }
            let total = entries.count
            Task { @MainActor in onProgress(0, total) }

            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let process = Process()
            var arguments: [String]
            if format == .zip {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                arguments = ["-o"]
                if let password, !password.isEmpty {
                    arguments += ["-P", password]
                }
                arguments += [url.path, "-d", destination.path]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                arguments = ["-xvf", url.path, "-C", destination.path]
            }
            process.arguments = arguments
            // stdin = null: without a controlling terminal unzip might otherwise try
            // to read a password from /dev/tty and hang — this way it fails with an
            // error right away.
            process.standardInput = FileHandle.nullDevice
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // unzip prints "extracting:"/"creating:" line by line to stdout, while bsdtar
            // -v prints line by line to stderr; either way both streams have to be
            // drained as data arrives (not after waitUntilExit), otherwise with many
            // files the pipe fills up and the child process blocks forever waiting for a
            // reader.
            var linesSoFar = 0
            var stderrText = ""
            let progressStream = format == .zip ? stdoutPipe : stderrPipe
            let silentStream = format == .zip ? stderrPipe : stdoutPipe

            let stdoutDone = DispatchSemaphore(value: 0)
            let stderrDone = DispatchSemaphore(value: 0)

            progressStream.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    (progressStream === stdoutPipe ? stdoutDone : stderrDone).signal()
                    return
                }
                if let text = String(data: data, encoding: .utf8) {
                    if progressStream === stderrPipe { stderrText += text }
                    if total > 0 {
                        let newLines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
                        if newLines > 0 {
                            linesSoFar += newLines
                            let done = min(linesSoFar, total)
                            Task { @MainActor in onProgress(done, total) }
                        }
                    }
                }
            }
            silentStream.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    (silentStream === stdoutPipe ? stdoutDone : stderrDone).signal()
                    return
                }
                if silentStream === stderrPipe, let text = String(data: data, encoding: .utf8) {
                    stderrText += text
                }
            }

            do {
                try process.run()
                control.setPauseHandlers(
                    pause: { kill(process.processIdentifier, SIGSTOP) },
                    resume: { kill(process.processIdentifier, SIGCONT) }
                )
                control.setCancelHandler {
                    // If the process is currently paused (SIGSTOP), SIGTERM just gets
                    // queued and has no effect until the process resumes — wake it first,
                    // then stop it, otherwise cancelling while paused would hang.
                    kill(process.processIdentifier, SIGCONT)
                    process.terminate()
                }
                stdoutDone.wait()
                stderrDone.wait()
                process.waitUntilExit()
                if control.isCancelled {
                    try? FileManager.default.removeItem(at: destination)
                    Task { @MainActor in completion(.failure(CancellationError())) }
                    return
                }
                if process.terminationStatus != 0 {
                    try? FileManager.default.removeItem(at: destination)
                    // Snapshot into a let: stderrText accumulates in the read loop above,
                    // and Swift 5.10 (which CI builds with) forbids capturing a mutable
                    // var in a concurrent closure. The process has finished by now and
                    // the string no longer grows.
                    let failureText = stderrText
                    if format == .zip && failureText.lowercased().contains("password") {
                        Task { @MainActor in completion(.failure(ArchiveError.passwordRequired)) }
                    } else {
                        Task { @MainActor in completion(.failure(ArchiveError.processFailed(failureText.isEmpty ? "Extraction failed" : failureText))) }
                    }
                    return
                }
                Task { @MainActor in
                    if total > 0 { onProgress(total, total) }
                    completion(.success(()))
                }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    func listContents(
        url: URL, format: ArchiveFormat, completion: @escaping @MainActor (Result<[Entry], Error>) -> Void
    ) {
        DiskOperationQueue.shared.addOperation {
            do {
                let entries = try Self.runListProcess(url: url, format: format)
                Task { @MainActor in completion(.success(entries)) }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    private static func runListProcess(url: URL, format: ArchiveFormat) throws -> [Entry] {
        let process = Process()
        if format == .zip {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-l", url.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-tvf", url.path]
        }
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unable to read archive"
            throw ArchiveError.processFailed(message)
        }
        let output = String(data: outputData, encoding: .utf8) ?? ""
        return format == .zip ? Self.parseUnzipListing(output) : Self.parseTarListing(output)
    }

    /// unzip -l prints a table like:
    ///   Length      Date    Time    Name
    /// ---------  ---------- -----   ----
    ///      1234  01-01-2024 00:00   folder/file.txt
    /// ---------                     -------
    /// Data rows sit between the first and second dashed lines.
    private static func parseUnzipListing(_ output: String) -> [Entry] {
        let lines = output.components(separatedBy: "\n")
        guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("---") }) else { return [] }
        var entries: [Entry] = []
        for line in lines[(headerIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("---") { break }
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let size = Int64(parts[0]) else { continue }
            // maxSplits is exhausted, so the remainder keeps the column alignment (unzip
            // pads the name with three spaces) — without trimming the name arrived as "
            // file.txt": it looked shifted in the contents list, and the path check saw a
            // different path from the one that would actually be extracted.
            let name = String(parts[3]).trimmingCharacters(in: .whitespaces)
            entries.append(Entry(path: name, size: size, isDirectory: name.hasSuffix("/")))
        }
        return entries
    }

    /// tar -tvf prints lines like:
    /// -rw-r--r--  0 user  staff   1234 Jul 14 20:00 path/to/file
    /// and for a symbolic link — with the target after " -> ":
    /// lrwxr-xr-x  0 user  staff      0 Jul 14 20:00 link -> ../target
    private static func parseTarListing(_ output: String) -> [Entry] {
        var entries: [Entry] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9, let size = Int64(parts[4]) else { continue }
            var name = parts[8...].joined(separator: " ")
            // The first character of the permissions string is the entry type, as in ls: 'l'
            // for a symlink, 'd' for a folder.
            var linkTarget: String?
            if parts[0].hasPrefix("l"), let range = name.range(of: " -> ") {
                linkTarget = String(name[range.upperBound...])
                name = String(name[..<range.lowerBound])
            }
            entries.append(Entry(path: name, size: size, isDirectory: parts[0].hasPrefix("d"), linkTarget: linkTarget))
        }
        return entries
    }
}
