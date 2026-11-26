import Darwin
import Foundation

final class CurrentTrack {
    private let cachePrefix: String
    private var candidate: (pid: pid_t, id: String)?

    init(cacheDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/com.netease.163music/Caches/online_play_cache", isDirectory: true
    )) {
        let path = cacheDirectory.path
        if let resolved = realpath(path, nil) {
            cachePrefix = String(cString: resolved) + "/"
            free(resolved)
        } else {
            cachePrefix = path + "/"
        }
    }

    func read(pid: pid_t?) -> String? {
        guard let pid, let id = uniqueID(pid: pid) else {
            candidate = nil
            return nil
        }
        let stable = candidate?.pid == pid && candidate?.id == id
        candidate = (pid, id)
        return stable ? id : nil
    }

    private func uniqueID(pid: pid_t) -> String? {
        var owner = proc_bsdinfo()
        let ownerSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &owner, ownerSize) == ownerSize,
              owner.pbi_uid == geteuid() else { return nil }

        // Query kernel vnode path metadata for the verified NetEase PID. The files stay unopened.
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
        guard needed > 0, needed / stride <= 4096 else { return nil }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: needed / stride + 32)
        let capacity = descriptors.count * stride
        let copied = Int(descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        })
        guard copied > 0, copied < capacity, copied % stride == 0 else { return nil }

        var found: String?
        let detailsSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in descriptors.prefix(copied / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var details = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &details, detailsSize) == detailsSize
                else { continue }
            let path = withUnsafeBytes(of: details.pvip.vip_path) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard let id = Self.cacheID(path: path, prefix: cachePrefix) else { continue }
            if let found, found != id { return nil }
            found = id
        }
        return found
    }

    static func cacheID(path: String, prefix: String) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(".uc!") else { return nil }
        let name = path.dropFirst(prefix.count)
        guard !name.contains("/"), let separator = name.firstIndex(of: "-") else { return nil }
        let id = name[..<separator]
        guard let number = UInt64(id), number > 0, number <= 9_007_199_254_740_991,
              String(number) == id else { return nil }
        return String(id)
    }
}
