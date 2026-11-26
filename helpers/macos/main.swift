import AppKit
import ApplicationServices
import Darwin

private final class Foreground {
    private let workspace = NSWorkspace.shared
    private var observer: NSObjectProtocol?
    private(set) var activations: [String] = []
    private let start: NSRunningApplication?

    init() {
        start = workspace.frontmostApplication
    }

    func watch() {
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] event in
            let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.activations.append(Self.identity(app))
        }
    }

    deinit {
        if let observer { workspace.notificationCenter.removeObserver(observer) }
    }

    static func identity(_ app: NSRunningApplication?) -> String {
        guard let app else { return "unavailable" }
        return "\(app.bundleIdentifier ?? "unknown") (\(app.processIdentifier))"
    }

    var before: String { Self.identity(start) }
    var after: String { Self.identity(workspace.frontmostApplication) }

    func requireBackground(target: pid_t) throws {
        guard let start else { throw ControlError("The macOS foreground application could not be determined.") }
        guard start.processIdentifier != target else {
            throw ControlError("NetEase is in the foreground. Switch to another app before sending a background command.")
        }
        guard activations.isEmpty, workspace.frontmostApplication?.processIdentifier == start.processIdentifier else {
            throw ControlError("The foreground application changed during the NetEase command.")
        }
    }
}

private func execute(_ command: String, using playback: Playback, foreground: Foreground) throws {
    switch command {
    case "open": throw ControlError("Opening NetEase is disabled on macOS. The helper only controls an already running app in the background.")
    case "mute", "volume": throw ControlError("Setting absolute volume or mute is unavailable on macOS.")
    case "toggle", "previous", "next", "volume-up", "volume-down": break
    default: throw ControlError("Unknown NetEase command.")
    }

    var state = playback.read()
    guard state.running else { throw ControlError("NetEase Cloud Music is not running.") }
    guard state.trusted else { throw ControlError(state.problem) }
    guard let pid = state.pid else { throw ControlError(state.problem) }
    try foreground.requireBackground(target: pid)
    foreground.watch()

    func control(in state: PlaybackState) -> AXUIElement? {
        let intent = command == "toggle" ? state.toggle : Intent(rawValue: command)
        return intent.flatMap { state.controls[$0] }
    }

    if control(in: state) == nil {
        // CEF can populate its accessibility tree after our first query returns.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        state = playback.read(rescan: true)
    }
    guard state.pid == pid, let element = control(in: state) else {
        throw ControlError("The NetEase \(command) control is unavailable or ambiguous in Accessibility.")
    }
    var target: pid_t = 0
    guard AXUIElementGetPid(element, &target) == .success, target == pid else {
        throw ControlError("The NetEase Accessibility control no longer belongs to the active target process.")
    }
    try foreground.requireBackground(target: pid)
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
    try foreground.requireBackground(target: pid)
    guard result == .success else { throw ControlError("NetEase AXPress failed (\(result.rawValue)).") }

    guard command == "toggle" else { return }
    let expected = state.status == "playing" ? "paused" : "playing"
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var rescan = false
    while ProcessInfo.processInfo.systemUptime < deadline {
        let observed = playback.read(rescan: rescan)
        try foreground.requireBackground(target: pid)
        if observed.pid != pid { break }
        if observed.status == expected { return }
        rescan = !rescan && observed.status == "unknown"
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }
    throw ControlError("NetEase accepted AXPress, but the expected \(expected) state could not be verified.")
}

private func unixTime() -> Int { Int(Date().timeIntervalSince1970) }

private final class Server {
    private let data: URL
    private let queue: URL
    private let fs = FileManager.default
    private let playback = Playback()
    private let currentTrack = CurrentTrack()
    private var ack = ""
    private var error = ""
    private var seq = 0
    private var lastBody = ""
    private var lastWrite = -Double.infinity
    private var lastLease: Int?

    init(path: String) throws {
        data = URL(fileURLWithPath: path, isDirectory: true)
        queue = data.appendingPathComponent("cmd", isDirectory: true)
        try fs.createDirectory(at: queue, withIntermediateDirectories: true)
    }

    private func leaseIsLive() -> Bool {
        let lease = data.appendingPathComponent("lease")
        if let text = try? String(contentsOf: lease, encoding: .utf8),
           let timestamp = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            lastLease = timestamp
        }
        // The window can truncate the lease briefly while renewing it.
        return lastLease.map { $0 >= unixTime() - 45 } ?? false
    }

    private func runNextCommand() throws {
        for file in try fs.contentsOfDirectory(atPath: queue.path).sorted() where file.hasSuffix(".cmd") {
            let path = queue.appendingPathComponent(file)
            let id = String(file.dropLast(4))
            guard let written = Int(id.prefix(while: { $0 != "-" })), written >= unixTime() - 15 else {
                try fs.removeItem(at: path)
                continue
            }
            // The v1 writer sends two newline-terminated lines. A newly created file may still be empty.
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            guard lines.count >= 3, !lines[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            try fs.removeItem(at: path)
            ack = id
            do {
                try execute(lines[0].trimmingCharacters(in: .whitespacesAndNewlines), using: playback, foreground: Foreground())
                error = ""
            } catch let failure {
                error = failure.localizedDescription
            }
            return
        }
    }

    private func writeState() throws {
        let state = playback.read()
        let trackID = currentTrack.read(pid: state.pid) ?? ""
        let fields: [(String, String)] = [
            ("v", "1"), ("backend", "macos"), ("pid", String(getpid())),
            ("running", state.running ? "1" : "0"), ("status", state.status),
            ("title", ""), ("artist", ""), ("track_id", trackID), ("pos_seq", "0"),
            ("volume", ""), ("muted", ""), ("can_volume", "0"), ("can_mute", "0"),
            ("can_volume_up", state.controls[.volumeUp] == nil ? "0" : "1"),
            ("can_volume_down", state.controls[.volumeDown] == nil ? "0" : "1"),
            ("can_play", state.toggle == nil ? "0" : "1"), ("can_next", state.controls[.next] == nil ? "0" : "1"),
            ("can_prev", state.controls[.previous] == nil ? "0" : "1"),
            ("ack", ack), ("error", error), ("problem", state.problem),
        ]
        let body = fields.map { key, value in
            "\(key)=\(value.components(separatedBy: .newlines).joined(separator: " "))\n"
        }.joined()
        let now = ProcessInfo.processInfo.systemUptime
        let changed = body != lastBody
        guard changed || now - lastWrite >= 2 else { return }
        let nextSeq = changed ? seq + 1 : seq
        let text = body + "seq=\(nextSeq)\nbeat=\(unixTime())\n"
        try text.write(to: data.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
        seq = nextSeq
        lastBody = body
        lastWrite = now
    }

    func run() throws {
        let lock = data.appendingPathComponent("helper.lock").path
        let fd = open(lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ControlError("Could not open the NetEase helper lock (errno \(errno)).") }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EWOULDBLOCK { return }
            throw ControlError("Could not lock the NetEase helper (errno \(errno)).")
        }
        while leaseIsLive() {
            try runNextCommand()
            try writeState()
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
    }
}

private func describe(_ state: PlaybackState) {
    print("trusted=\(state.trusted)")
    print("running=\(state.running)")
    print("target_pid=\(state.pid.map(String.init) ?? "unavailable")")
    print("status=\(state.status)")
    print("controls=\(state.controls.keys.map(\.rawValue).sorted().joined(separator: ","))")
    print("problem=\(state.problem)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "serve" where arguments.count == 2:
        try Server(path: arguments[1]).run()
    case "status" where arguments.count == 1:
        let playback = Playback()
        var state = playback.read()
        if state.pid != nil && state.trusted && state.controls.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
            state = playback.read(rescan: true)
        }
        describe(state)
        print("frontmost=\(Foreground.identity(NSWorkspace.shared.frontmostApplication))")
        exit(state.running && state.trusted && !state.controls.isEmpty ? 0 : 1)
    case "verify" where arguments.count == 2:
        let playback = Playback()
        let foreground = Foreground()
        var failed = false
        print("status_before=\(playback.read().status)")
        do {
            try execute(arguments[1], using: playback, foreground: foreground)
        } catch {
            print("error=\(error.localizedDescription)")
            failed = true
        }
        print("frontmost_before=\(foreground.before)")
        print("frontmost_after=\(foreground.after)")
        print("activation_events=\(foreground.activations.joined(separator: ", "))")
        describe(playback.read())
        exit(failed ? 1 : 0)
    default:
        throw ControlError("Usage: netease-helper serve DATA | status | verify toggle|previous|next|volume-up|volume-down")
    }
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
