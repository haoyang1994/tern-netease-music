import AppKit
import ApplicationServices

let neteaseBundle = "com.netease.163music"

struct ControlError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Intent: String, CaseIterable {
    case play, pause, previous, next
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"

    private var labels: [String] {
        switch self {
        case .play: return ["播放", "继续播放", "继续", "play", "resume", "play playback"]
        case .pause: return ["暂停", "暂停播放", "pause", "pause playback"]
        case .previous: return ["上一个", "上一首", "上一曲", "previous", "previous track", "previous song"]
        case .next: return ["下一个", "下一首", "下一曲", "next", "next track", "next song"]
        case .volumeUp: return ["升高音量", "increase volume", "volume up"]
        case .volumeDown: return ["降低音量", "decrease volume", "volume down"]
        }
    }

    static func match(title: String?, description: String?) -> Self? {
        let names = [title, description].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let matches = allCases.filter { $0.labels.contains(where: names.contains) }
        return matches.count == 1 ? matches.first : nil
    }
}

private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

private struct Node {
    let element: AXUIElement
    let role: String
    let title: String?
    let intent: Intent?
    let children: [AXUIElement]

    init(_ element: AXUIElement, includeChildren: Bool = false) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, 0.2)
        var attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        if includeChildren { attributes.append(kAXChildrenAttribute) }
        var values: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values)
        let fields = values as? [Any] ?? []
        role = fields.first as? String ?? ""
        title = fields.count >= 3 ? fields[1] as? String : nil
        intent = Intent.match(title: title, description: fields.count >= 3 ? fields[2] as? String : nil)
        children = fields.count == 4 ? fields[3] as? [AXUIElement] ?? [] : []
    }

    var offersPress: Bool {
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success
            && (actions as? [String])?.contains(kAXPressAction) == true
    }

    var isEnabled: Bool {
        (axValue(element, kAXEnabledAttribute) as? Bool) != false
    }
}

private func unique(_ controls: [Node], for intent: Intent) -> AXUIElement? {
    let matches = controls.filter { $0.intent == intent && $0.isEnabled && $0.offersPress }
    return matches.count == 1 ? matches.first?.element : nil
}

struct PlaybackState {
    var running = false
    var trusted = false
    var pid: pid_t?
    var controls: [Intent: AXUIElement] = [:]
    var problem = ""

    var toggle: Intent? {
        switch (controls[.play] != nil, controls[.pause] != nil) {
        case (true, false): return .play
        case (false, true): return .pause
        default: return nil
        }
    }

    var status: String {
        switch toggle {
        case .play: return "paused"
        case .pause: return "playing"
        default: return "unknown"
        }
    }
}

final class Playback {
    private var pid: pid_t?
    private var web: [AXUIElement] = []
    private var menu: [AXUIElement] = []
    private var searchAfter = 0.0

    private func findMenu(_ app: AXUIElement) -> [AXUIElement] {
        guard let bar = axValue(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return [] }
        let groups = Node(bar as! AXUIElement, includeChildren: true).children
            .map { Node($0, includeChildren: true) }
            .filter { $0.role == kAXMenuBarItemRole && ["controls", "control", "控制"].contains($0.title?.lowercased() ?? "") }
        guard groups.count == 1 else { return [] }
        return groups[0].children.flatMap { element -> [AXUIElement] in
            let submenu = Node(element, includeChildren: true)
            guard submenu.role == kAXMenuRole else { return [] }
            return submenu.children.filter { child in
                let item = Node(child)
                return item.role == kAXMenuItemRole && item.intent != nil && item.offersPress
            }
        }
    }

    private func findWeb(_ app: AXUIElement) -> [AXUIElement] {
        guard let windows = axValue(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        // A lone Play button could belong to a song, playlist or search result.
        // Require a compact group with previous, play/pause and next in the web tree.
        typealias Visit = (element: AXUIElement, ancestors: [Int?], inWeb: Bool)
        var queue: [Visit] = windows.map { ($0, [], false) }
        var cursor = 0
        var groups: [Int: [Node]] = [:]
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while cursor < queue.count {
            guard cursor < 4000, ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            let visit = queue[cursor]
            let scope = cursor
            cursor += 1
            let node = Node(visit.element, includeChildren: true)
            let inWeb = visit.inWeb || node.role == "AXWebArea"
            if inWeb && [kAXButtonRole, "AXToggle", kAXCheckBoxRole].contains(node.role) {
                if let intent = node.intent, intent != .volumeUp, intent != .volumeDown, node.offersPress {
                    for ancestor in visit.ancestors.suffix(4).compactMap({ $0 }) {
                        groups[ancestor, default: []].append(node)
                    }
                }
                continue
            }
            if visit.ancestors.count < 36 {
                let isGroup = inWeb && [kAXGroupRole, kAXToolbarRole].contains(node.role)
                let ancestors = visit.ancestors + [isGroup ? scope : nil]
                queue.append(contentsOf: node.children.map { ($0, ancestors, inWeb) })
            }
        }
        let matches = groups.values.filter { nodes in
            let intents = nodes.compactMap(\.intent)
            return nodes.count == 3 && intents.contains(.previous) && intents.contains(.next)
                && (intents.contains(.play) || intents.contains(.pause))
        }
        guard let first = matches.first else { return [] }
        let elements = first.map(\.element)
        // Nested ancestors can describe the same group. Distinct groups are ambiguous.
        guard matches.allSatisfy({ group in
            zip(group.map(\.element), elements).allSatisfy { CFEqual($0.0, $0.1) }
        }) else { return [] }
        return elements
    }

    func read(rescan: Bool = false) -> PlaybackState {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: neteaseBundle)
            .filter { !$0.isTerminated }
        var state = PlaybackState(running: !apps.isEmpty, trusted: AXIsProcessTrusted())
        guard apps.count <= 1 else {
            state.problem = "More than one NetEase Cloud Music process is running."
            return state
        }
        guard let app = apps.first else {
            pid = nil
            return state
        }
        state.pid = app.processIdentifier
        guard state.trusted else {
            pid = nil
            state.problem = "macOS Accessibility access is required for the NetEase helper."
            return state
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        let now = ProcessInfo.processInfo.systemUptime
        if pid != state.pid {
            pid = state.pid
            searchAfter = 0
            // CEF may expose its web tree only after an accessibility client asks for it.
            for attribute in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                AXUIElementSetAttributeValue(root, attribute as CFString, kCFBooleanTrue)
            }
        }
        if rescan || now >= searchAfter {
            menu = findMenu(root)
            web = findWeb(root)
            searchAfter = ProcessInfo.processInfo.systemUptime + (web.isEmpty ? 2 : 10)
        }
        let webNodes = web.map { Node($0) }
        let menuNodes = menu.map { Node($0) }
        for nodes in [webNodes, menuNodes] {
            // Keep Play and Pause from one surface so a stale menu cannot contradict the player bar.
            if state.toggle == nil {
                let play = unique(nodes, for: .play)
                let pause = unique(nodes, for: .pause)
                if (play != nil) != (pause != nil) {
                    state.controls[.play] = play
                    state.controls[.pause] = pause
                }
            }
            for intent in [Intent.previous, .next] where state.controls[intent] == nil {
                state.controls[intent] = unique(nodes, for: intent)
            }
        }
        for intent in [Intent.volumeDown, .volumeUp] {
            state.controls[intent] = unique(menuNodes, for: intent)
        }
        if state.controls.isEmpty {
            state.problem = "NetEase playback controls are unavailable in the Accessibility tree."
        }
        return state
    }
}
