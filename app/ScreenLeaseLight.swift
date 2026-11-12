// ScreenLeaseLight: menu bar status light for screen-lease.
//   🔴 an agent is driving the screen: hands off
//   🔴⏸ you asked for a pause; the agent is finishing its current UI step
//   🟡 the agent needs you, or it has paused and the screen is yours
//   🟢 the screen is yours
//   ⚪ stale: the agent holds the lease but stopped heart-beating (crashed or forgot)
// Never takes focus (accessory app, no Dock icon). Plays a sound on every change.
// Also shows the "ready to use the screen" dialog that `screen-lease acquire` asks for:
// a non-activating panel that can never become key, so no keystroke can reach or dismiss it,
// and typing in another app is not interrupted. Go ahead / Wait; auto-go when the countdown ends.
// Build: swiftc -O -o ScreenLeaseLight ScreenLeaseLight.swift

import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let env = ProcessInfo.processInfo.environment
let stateDir = env["SCREEN_LEASE_DIR"] ?? home + "/Library/Application Support/screen-lease"
let configPath = env["SCREEN_LEASE_CONFIG"] ?? home + "/.config/screen-lease/config.json"

struct Config {
    var staleSeconds = 120.0
    var sounds: [String: String] = [
        "driving": "Tink", "pausing": "Pop", "paused": "Glass", "need-you": "Glass",
        "free": "Hero", "stale": "Basso", "ask": "Ping", "waiting": "",
    ]
    var needYouRepeatSeconds = 0.0
    var onNeedYou: String? = nil
    var onFree: String? = nil
    var ownerURLTemplate: String? = nil

    static func load() -> Config {
        var c = Config()
        guard let data = FileManager.default.contents(atPath: configPath),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return c }
        if let v = obj["stale_seconds"] as? Double { c.staleSeconds = v }
        if let s = obj["sounds"] as? [String: String] { c.sounds.merge(s) { $1 } }
        if let v = obj["need_you_repeat_seconds"] as? Double { c.needYouRepeatSeconds = v }
        c.onNeedYou = obj["on_need_you"] as? String
        c.onFree = obj["on_free"] as? String
        c.ownerURLTemplate = obj["owner_url_template"] as? String
        return c
    }
}

enum Light: String {
    case driving, pausing, paused, needYou = "need-you", waiting, free, stale
    var glyph: String {
        switch self {
        case .driving: return "🔴"
        case .pausing: return "🔴⏸"
        case .paused, .needYou, .waiting: return "🟡"
        case .free: return "🟢"
        case .stale: return "⚪"
        }
    }
}

func readLease() -> [String: String] { readKV(stateDir + "/lease") }

func writeLease(_ l: [String: String]) {
    let order = ["state", "owner", "label", "purpose", "message", "acquired", "heartbeat"]
    let text = order.map { "\($0)=\(l[$0] ?? "")" }.joined(separator: "\n") + "\n"
    try? text.write(toFile: stateDir + "/lease", atomically: true, encoding: .utf8)
}

final class AskPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

func readKV(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var d: [String: String] = [:]
    for line in text.split(separator: "\n") {
        if let eq = line.firstIndex(of: "=") {
            d[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
    }
    return d
}

func busyAlive() -> Bool {
    guard let s = try? String(contentsOfFile: stateDir + "/busy", encoding: .utf8),
        let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return kill(pid, 0) == 0
}

func ago(_ secs: Double) -> String {
    let s = Int(max(0, secs))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s" }
    return "\(s / 3600)h \((s % 3600) / 60)m"
}

func shell(_ cmd: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    try? p.run()
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var config = Config.load()
    var light: Light? = nil
    var lightSince = Date()
    var lastChime = Date()
    var lease: [String: String] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        tick()
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
    }

    func compute() -> Light {
        lease = readLease()
        let paused = FileManager.default.fileExists(atPath: stateDir + "/paused")
        let state = lease["state"] ?? "free"
        let hb = Double(lease["heartbeat"] ?? "") ?? 0
        switch state {
        case "driving":
            let busy = busyAlive()
            if paused { return busy ? .pausing : .paused }
            if !busy && Date().timeIntervalSince1970 - hb > config.staleSeconds { return .stale }
            return .driving
        case "need-you": return .needYou
        case "waiting": return .waiting
        case "approved": return .driving
        default: return paused ? .paused : .free
        }
    }

    // MARK: ready-to-use-the-screen dialog

    var askPanel: AskPanel?
    var askID: String?
    var askDeadline = Date()
    var askCountdown: NSTextField?

    func checkAsk() {
        let ask = readKV(stateDir + "/ask")
        if let id = ask["id"], id != askID {
            showAsk(id: id, ask: ask)
        } else if ask["id"] == nil, askPanel != nil {
            closeAsk()  // the CLI gave up waiting
        }
        guard askPanel != nil else { return }
        let left = Int(ceil(askDeadline.timeIntervalSinceNow))
        if left <= 0 { answer("go") } else { askCountdown?.stringValue = "Going ahead in \(left) s unless you click Wait." }
    }

    func label(_ s: String, bold: Bool = false) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = bold ? .boldSystemFont(ofSize: 14) : .systemFont(ofSize: 12)
        t.preferredMaxLayoutWidth = 380
        return t
    }

    func button(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.keyEquivalent = ""
        b.refusesFirstResponder = true
        b.bezelStyle = .rounded
        return b
    }

    func showAsk(id: String, ask: [String: String]) {
        closeAsk()
        askID = id
        let timeout = Double(ask["timeout"] ?? "") ?? 10
        askDeadline = Date().addingTimeInterval(timeout)
        let who = ask["label"] ?? "An agent"
        let countdown = label("Going ahead in \(Int(timeout)) s unless you click Wait.")
        askCountdown = countdown
        let buttons = NSStackView(views: [button("Wait", #selector(askWait)), button("Go ahead", #selector(askGo))])
        buttons.spacing = 12
        let stack = NSStackView(views: [
            label("\(who) is ready to use the screen", bold: true),
            label(ask["purpose"] ?? ""), countdown, buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        let p = AskPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.title = "Screen Lease"
        p.contentView = stack
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.setContentSize(stack.fittingSize)
        if let screen = NSScreen.screens.first {
            let f = p.frame
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - f.width / 2, y: screen.visibleFrame.maxY - f.height - 40))
        }
        p.orderFrontRegardless()
        askPanel = p
        if let s = config.sounds["ask"], !s.isEmpty { NSSound(named: s)?.play() }
    }

    func answer(_ a: String) {
        if let id = askID {
            try? "id=\(id)\nanswer=\(a)\n".write(toFile: stateDir + "/ask-response", atomically: true, encoding: .utf8)
        }
        closeAsk()
    }

    func closeAsk() {
        askPanel?.orderOut(nil)
        askPanel = nil
        askCountdown = nil
    }

    @objc func askGo() { answer("go") }
    @objc func askWait() { answer("wait") }

    @objc func letGo() {
        var l = readLease()
        guard l["state"] == "waiting" else { return }
        l["state"] = "approved"
        l["message"] = "you said go"
        l["heartbeat"] = String(Int(Date().timeIntervalSince1970))
        writeLease(l)
        tick()
    }

    func tick() {
        checkAsk()
        let new = compute()
        if new != light {
            let first = (light == nil)
            light = new
            lightSince = Date()
            lastChime = Date()
            item.button?.title = new.glyph
            item.button?.toolTip = summary()
            if !first {
                if let s = config.sounds[new.rawValue], !s.isEmpty { NSSound(named: s)?.play() }
                if new == .needYou, let c = config.onNeedYou { shell(c) }
                if new == .free, let c = config.onFree { shell(c) }
            }
        } else if new == .needYou, config.needYouRepeatSeconds > 0,
            Date().timeIntervalSince(lastChime) >= config.needYouRepeatSeconds
        {
            lastChime = Date()
            if let s = config.sounds["need-you"] { NSSound(named: s)?.play() }
        }
        item.button?.toolTip = summary()
    }

    func summary() -> String {
        let who = lease["label"] ?? "agent"
        switch light ?? .free {
        case .driving: return "\(who) is driving the screen: hands off"
        case .pausing: return "Pause requested: \(who) is finishing its current step"
        case .paused: return "Paused: the screen is yours"
        case .needYou: return "\(who) needs you: \(lease["message"] ?? "")"
        case .waiting: return "\(who) is waiting for your OK to use the screen"
        case .free: return "The screen is yours"
        case .stale: return "\(who) holds the screen but stopped responding"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        config = Config.load()
        let now = Date().timeIntervalSince1970
        func info(_ s: String) {
            let m = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
        }
        info("\((light ?? .free).glyph)  \(summary())")
        let state = lease["state"] ?? "free"
        if let p = lease["purpose"], !p.isEmpty, state != "free" { info("Task: \(p)") }
        if state != "free", let a = Double(lease["acquired"] ?? "") {
            let hb = Double(lease["heartbeat"] ?? "") ?? now
            info("Held \(ago(now - a)) · last heard from \(ago(now - hb)) ago")
        }
        if state == "free", let m = lease["message"], !m.isEmpty {
            info("Last: \(lease["label"] ?? "agent"): \(m) (\(ago(now - lightSince.timeIntervalSince1970)) ago)")
        }
        menu.addItem(.separator())
        let paused = FileManager.default.fileExists(atPath: stateDir + "/paused")
        if state == "waiting" {
            add(menu, "Let \(lease["label"] ?? "agent") go ahead", #selector(letGo))
        }
        if paused {
            add(menu, "Resume agent", #selector(resume))
        } else if state == "driving" {
            add(menu, "Pause: I need the screen", #selector(pause))
        }
        if let owner = lease["owner"], let t = config.ownerURLTemplate, state != "free" || !owner.isEmpty,
            owner != "anonymous"
        {
            let m = add(menu, "Open \(lease["label"] ?? "agent") session", #selector(openOwner))
            m.representedObject = t.replacingOccurrences(of: "{owner}", with: owner)
        }
        if state != "free" { add(menu, "Clear lease (force free)", #selector(clearLease)) }
        menu.addItem(.separator())
        add(menu, "Quit ScreenLeaseLight", #selector(quit))
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ sel: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        m.target = self
        menu.addItem(m)
        return m
    }

    @objc func pause() {
        FileManager.default.createFile(
            atPath: stateDir + "/paused", contents: "\(Int(Date().timeIntervalSince1970))\n".data(using: .utf8))
        tick()
    }
    @objc func resume() {
        try? FileManager.default.removeItem(atPath: stateDir + "/paused")
        tick()
    }
    @objc func clearLease() {
        var l = readLease()
        l["state"] = "free"
        l["message"] = "cleared by you"
        l["heartbeat"] = String(Int(Date().timeIntervalSince1970))
        writeLease(l)
        try? FileManager.default.removeItem(atPath: stateDir + "/paused")
        try? FileManager.default.removeItem(atPath: stateDir + "/busy")
        tick()
    }
    @objc func openOwner(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
