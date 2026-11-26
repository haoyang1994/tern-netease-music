import Darwin
import Foundation

@main
struct CurrentTrackTests {
    static func main() throws {
        let scratch = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let cache = scratch.appendingPathComponent("online_play_cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let track = CurrentTrack(cacheDirectory: cache)
        let pid = getpid()

        func open(_ name: String, in directory: URL) throws -> FileHandle {
            let file = directory.appendingPathComponent(name)
            try Data().write(to: file)
            return try FileHandle(forReadingFrom: file)
        }

        let outside = try open("99-foreign.uc!", in: scratch)
        let complete = try open("99-complete.uc", in: cache)
        let malformed = try open("98plus-sample.uc!", in: cache)
        let first = try open("101-a.uc!", in: cache)
        precondition(track.read(pid: pid) == nil)
        precondition(track.read(pid: pid) == "101")
        let sameID = try open("101-b.uc!", in: cache)
        precondition(track.read(pid: pid) == "101")
        let second = try open("102-a.uc!", in: cache)
        precondition(track.read(pid: pid) == nil)
        precondition(track.read(pid: pid) == nil)
        try first.close()
        try sameID.close()
        precondition(track.read(pid: pid) == nil)
        precondition(track.read(pid: pid) == "102")
        try second.close()
        precondition(track.read(pid: pid) == nil)
        precondition(track.read(pid: nil) == nil)
        try outside.close()
        try complete.close()
        try malformed.close()
        print("Current track stabilization, ambiguity, path filtering and closed files passed.")
    }
}
