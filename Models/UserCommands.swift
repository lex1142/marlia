import Foundation

/// User commands — Total Commander's "user commands" / button-bar entries: a name, a shell
/// script, an optional shortcut. They appear in the Commands menu (and therefore in the
/// command palette), run against the active pane, and show up in the progress HUD with
/// pause and cancel.
///
/// What a script gets (also documented in Settings ▸ Commands and in Help):
/// - `"$@"` — the selected items' paths (none selected → no arguments);
/// - `$MARLIA_DIR` — the active pane's folder, also the working directory;
/// - `$MARLIA_OTHER_DIR` — the other pane's folder (empty when the second pane is hidden);
/// - `$MARLIA_SELECTION` — the selected paths, one per line; `$MARLIA_FILE` — the first one.
/// Scripts run in a zsh login shell (`zsh -l -c`), so a PATH set in ~/.zprofile (Homebrew)
/// is there, whatever the user's interactive shell is.
struct UserCommand: Codable, Identifiable, Equatable {
    enum OutputMode: String, Codable, CaseIterable, Identifiable {
        case onError, always
        var id: String { rawValue }
        var title: String { self == .onError ? "Only on error" : "Always" }
    }

    var id = UUID()
    var name: String
    var script: String
    var shortcut: Shortcut?
    /// Reload both panes when the script finishes (it probably changed files).
    var refreshAfter = true
    var output: OutputMode = .onError

    /// Ready-made starting points offered by the "+" menu in Settings.
    static let templates: [UserCommand] = [
        UserCommand(name: "Open in Visual Studio Code", script: #"open -a "Visual Studio Code" "${@:-$MARLIA_DIR}""#, refreshAfter: false),
        UserCommand(name: "Copy with rsync to Other Pane", script: #"rsync -a --progress "$@" "$MARLIA_OTHER_DIR/""#),
        UserCommand(name: "Make Images 1600 px", script: #"for f in "$@"; do sips -Z 1600 "$f" --out "${f%.*}-1600.${f##*.}"; done"#),
        UserCommand(name: "Git Status", script: "git status", refreshAfter: false, output: .always),
        UserCommand(name: "Disk Usage of Selection", script: #"du -sh "${@:-.}""#, refreshAfter: false, output: .always),
    ]
}

/// Persisted list of user commands (UserDefaults, JSON). App-wide, like shortcuts.
final class UserCommandStore: ObservableObject {
    static let shared = UserCommandStore()
    private static let defaultsKey = "Marlia.UserCommands"
    private let defaults: UserDefaults

    @Published var commands: [UserCommand] { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([UserCommand].self, from: data) {
            commands = decoded
        } else {
            commands = []
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(commands) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Runs a user command's script. Foundation + POSIX only, so a scratchpad script can
/// exercise it.
///
/// `posix_spawn` with `POSIX_SPAWN_SETPGROUP` rather than `Process`: the script becomes the
/// leader of its own process group, so pause/cancel (SIGSTOP/SIGCONT/SIGTERM to `-pid`)
/// reach everything it started — an `rsync` or `ffmpeg` it runs, not just the shell.
enum UserCommandRunner {
    struct Context {
        let directory: URL
        let otherDirectory: URL?
        let selection: [URL]
    }

    struct Result {
        let status: Int32
        /// stdout and stderr interleaved; the last `outputLimit` bytes if it was longer.
        let output: String
        let wasCancelled: Bool
    }

    static let outputLimit = 256 * 1024

    static func environment(for context: Context, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["MARLIA_DIR"] = context.directory.path
        env["MARLIA_OTHER_DIR"] = context.otherDirectory?.path ?? ""
        env["MARLIA_SELECTION"] = context.selection.map(\.path).joined(separator: "\n")
        env["MARLIA_FILE"] = context.selection.first?.path ?? ""
        return env
    }

    /// Starts the script and returns its pid via `onStart` (so the caller can wire pause and
    /// cancel to the process group), then blocks until it exits. Call off the main thread.
    static func run(_ script: String, context: Context, onStart: (pid_t) -> Void = { _ in }) -> Result {
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { return Result(status: -1, output: "Could not create a pipe.", wasCancelled: false) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, pipe[1], 2)
        posix_spawn_file_actions_addclose(&actions, pipe[0])
        posix_spawn_file_actions_addclose(&actions, pipe[1])
        posix_spawn_file_actions_addchdir_np(&actions, context.directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let arguments = ["/bin/zsh", "-l", "-c", script, "marlia"] + context.selection.map(\.path)
        let environment = environment(for: context).map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawned = withCStrings(arguments) { argv in
            withCStrings(environment) { envp in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
            }
        }
        close(pipe[1])
        guard spawned == 0 else {
            close(pipe[0])
            return Result(status: -1, output: "Could not start zsh: \(String(cString: strerror(spawned)))", wasCancelled: false)
        }
        onStart(pid)

        // Read until EOF (every writer in the group has closed the pipe), keeping the tail.
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(pipe[0], &buffer, buffer.count)
            if count > 0 {
                collected.append(buffer, count: count)
                if collected.count > outputLimit * 2 { collected = collected.suffix(outputLimit) }
            } else if count == 0 || errno != EINTR {
                break
            }
        }
        close(pipe[0])

        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signaled = (status & 0x7f) != 0 && (status & 0x7f) != 0x7f
        let exitCode = signaled ? 128 + (status & 0x7f) : (status >> 8) & 0xff
        let text = String(decoding: collected.suffix(outputLimit), as: UTF8.self)
        return Result(status: exitCode, output: text, wasCancelled: signaled && (status & 0x7f) == SIGTERM)
    }

    /// Signals the whole process group the script leads.
    static func signal(_ pid: pid_t, _ signal: Int32) {
        kill(-pid, signal)
    }

    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}
