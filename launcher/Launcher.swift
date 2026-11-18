// Themed game launcher (v2, Dusklight-style) for nxnative Mac apps.
// One source for every game; each launcher bundle carries theme.json + its own art and sounds
// (taken from the player's own copy of the game). Play starts the game app with DM_LAUNCHER=0,
// so its plain settings window is skipped; Settings edits the same saved choices the game app
// uses (its preferences domain, keys "launcher.<ENV>").
//
// Self-tests (no screen capture): LAUNCHER_SNAPSHOT=/x.png draws the real window into a file
// and quits; LAUNCHER_PANEL=Settings|Tools opens a panel first; LAUNCHER_MUTE=1 silences audio;
// LAUNCHER_NO_AUTOART=1 skips the automatic art step; LAUNCHER_FORCE_MOVE=1 shows the move panel;
// LAUNCHER_AUTOMOVE=1 (+ LAUNCHER_MOVE_TO=<folder>) moves the launcher at start.

import SwiftUI
import AppKit
import AVFoundation
import GameController

let ENV = ProcessInfo.processInfo.environment

// MARK: - Theme

struct Theme: Decodable {
    var name = "Game"
    var gameApp = ""
    var presents: String?
    var platform = "Nintendo Switch"
    var logo: String?
    var backgrounds: [String] = []
    var music: String?
    var playlist: [Track] = []    // menu music choices; the first is the default
    var thinFont = "Avenir Next"  // now-playing text (drawn ultra-light)
    var sounds: [String: String] = [:]
    var menuFont = "Avenir Next Condensed"
    var labelFont = "Avenir Next Condensed"
    var bodyFont = "Avenir Next"
    var accent = "#E8D9A8"        // highlight bar (left)
    var accent2: String?          // highlight bar (right); defaults to accent
    var glow: String?             // glow around the highlight; none if unset
    var content: [[String: String]] = []   // installed content rows: {"label": "...", "value": "..."}
    var accentText = "#1A1630"
    var text = "#FFFFFF"
    var dim = "#C9C3DA"
    var panel = "#17142C"
    var border = "#D8C08A"
    var shade = "#0B0A18"         // backdrop darkening
    var slideSeconds = 9.0
    var logoWidth = 540.0
    var titleID: String?          // for the installer: seeds a hand-made profile before the first build
    var profile: String?          // folder in Resources holding that profile (game.tsv)
    var shadeStrength = 1.0       // how much the backdrop is darkened behind the menu (0...1)
    var skyTop: String?           // layered scene backdrop (instead of a slideshow)
    var skyBottom: String?
    var layers: [Layer] = []

    enum K: String, CodingKey { case name, gameApp, presents, platform, logo, backgrounds, music, playlist, thinFont, sounds,
        menuFont, labelFont, bodyFont, accent, accent2, glow, content, accentText, text, dim, panel, border, shade, slideSeconds, skyTop, skyBottom, layers, logoWidth, shadeStrength, titleID, profile }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        func s(_ k: K) throws -> String? { try c.decodeIfPresent(String.self, forKey: k) }
        name = try s(.name) ?? name; gameApp = try s(.gameApp) ?? ""
        presents = try s(.presents); platform = try s(.platform) ?? platform; logo = try s(.logo)
        backgrounds = try c.decodeIfPresent([String].self, forKey: .backgrounds) ?? []
        playlist = try c.decodeIfPresent([Track].self, forKey: .playlist) ?? []
        thinFont = try s(.thinFont) ?? thinFont
        music = try s(.music); sounds = try c.decodeIfPresent([String: String].self, forKey: .sounds) ?? [:]
        menuFont = try s(.menuFont) ?? menuFont; labelFont = try s(.labelFont) ?? labelFont; bodyFont = try s(.bodyFont) ?? bodyFont
        accent = try s(.accent) ?? accent; accentText = try s(.accentText) ?? accentText; text = try s(.text) ?? text
        dim = try s(.dim) ?? dim; panel = try s(.panel) ?? panel; border = try s(.border) ?? border; shade = try s(.shade) ?? shade
        slideSeconds = try c.decodeIfPresent(Double.self, forKey: .slideSeconds) ?? slideSeconds
        skyTop = try s(.skyTop); skyBottom = try s(.skyBottom)
        logoWidth = try c.decodeIfPresent(Double.self, forKey: .logoWidth) ?? logoWidth
        titleID = try s(.titleID); profile = try s(.profile)
        shadeStrength = try c.decodeIfPresent(Double.self, forKey: .shadeStrength) ?? shadeStrength
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        accent2 = try s(.accent2); glow = try s(.glow)
        content = try c.decodeIfPresent([[String: String]].self, forKey: .content) ?? []
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        self.init(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Audio (music loops gaplessly from a PCM buffer; sounds are preloaded)

final class Audio {
    private let engine = AVAudioEngine()
    private let musicNode = AVAudioPlayerNode()
    private var sfx: [String: AVAudioPlayer] = [:]
    private let muted = ENV["LAUNCHER_MUTE"] == "1"
    // Full scale is 30% of the system level: 100% in the menu = 30% actual (user found louder too loud).
    static let scale: Float = 0.3
    var musicVolume: Float { Float(UserDefaults.standard.object(forKey: "musicVolume") as? Double ?? 0.5) * Audio.scale }
    var musicOn: Bool { UserDefaults.standard.object(forKey: "musicOn") as? Bool ?? true }
    var soundsOn: Bool { UserDefaults.standard.object(forKey: "soundsOn") as? Bool ?? true }
    var soundVolume: Float { Float(UserDefaults.standard.object(forKey: "soundVolume") as? Double ?? 0.5) * Audio.scale }

    let tracks: [Track]
    private let res: URL
    private var connectedFormat: AVAudioFormat?
    private(set) var current = 0

    init(theme: Theme, res: URL) {
        self.res = res
        tracks = !theme.playlist.isEmpty ? theme.playlist : theme.music.map { [Track(file: $0, title: "")] } ?? []
        for (k, f) in theme.sounds {
            if let p = try? AVAudioPlayer(contentsOf: res.appendingPathComponent(f)) { p.prepareToPlay(); sfx[k] = p }
        }
        guard !muted, !tracks.isEmpty else { return }
        engine.attach(musicNode)
        start(0, fadeIn: 1.5)
    }

    private func buffer(_ i: Int) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: res.appendingPathComponent(tracks[i].file)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { return nil }
        return buf
    }

    /// Start track i from the top, looping gaplessly.
    private func start(_ i: Int, fadeIn: Double) {
        guard let buf = buffer(i) else { return }
        current = i
        musicNode.stop()
        if connectedFormat != buf.format {
            if connectedFormat != nil { engine.disconnectNodeOutput(musicNode) }
            engine.connect(musicNode, to: engine.mainMixerNode, format: buf.format)
            connectedFormat = buf.format
        }
        if !engine.isRunning { try? engine.start() }
        if let ls = tracks[i].loopStart, ls > 0, let loop = Audio.tail(of: buf, from: ls) {
            musicNode.scheduleBuffer(buf, at: nil, options: [])          // intro + first pass, once
            musicNode.scheduleBuffer(loop, at: nil, options: .loops)     // then only the loop section
        } else {
            musicNode.scheduleBuffer(buf, at: nil, options: .loops)
        }
        musicNode.volume = 0
        if musicOn { musicNode.play(); fade(to: musicVolume, over: fadeIn) }
    }

    /// The part of a buffer from `seconds` to its end (for intro + loop playback).
    static func tail(of buf: AVAudioPCMBuffer, from seconds: Double) -> AVAudioPCMBuffer? {
        let start = AVAudioFrameCount(seconds * buf.format.sampleRate)
        guard start < buf.frameLength, let src = buf.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength - start),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = buf.frameLength - start
        let stride = buf.format.isInterleaved ? Int(buf.format.channelCount) : 1
        let chans = buf.format.isInterleaved ? 1 : Int(buf.format.channelCount)
        for c in 0..<chans {
            (dst[c]).update(from: src[c] + Int(start) * stride, count: Int(out.frameLength) * stride)
        }
        return out
    }

    /// Switch songs: quick fade out, then the new one fades in.
    func step(_ dir: Int) {
        guard !muted, tracks.count > 1 else { return }
        let next = (current + dir + tracks.count) % tracks.count
        current = next
        fade(to: 0, over: 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if self.current == next { self.start(next, fadeIn: 0.8) } }
    }
    func applyVolume() { musicNode.volume = musicOn ? musicVolume : 0; if musicOn && !musicNode.isPlaying && engine.isRunning { musicNode.play() } }
    func fade(to v: Float, over secs: Double) {
        let start = musicNode.volume, steps = 30
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs * Double(i) / Double(steps)) {
                self.musicNode.volume = start + (v - start) * Float(i) / Float(steps)
            }
        }
    }
    func shutdown() { musicNode.stop(); engine.stop(); sfx.values.forEach { $0.stop() } }
    func play(_ name: String) {
        guard !muted, soundsOn, let p = sfx[name] else { return }
        p.currentTime = 0; p.volume = soundVolume; p.play()
    }
}

// MARK: - Game settings (nxnative launcher.json) + launcher's own settings

struct Row: Identifiable {
    enum Kind { case choice([(String, String)]), toggle(on: String, off: String), range(min: Double, max: Double, step: Double), action(() -> Void), info }
    let id: String, label: String, note: String, tab: String, kind: Kind, def: String
    var game: Bool   // true: a game setting (nxnative saved choice); false: launcher setting or action
}

final class Model: ObservableObject {
    let theme: Theme
    let res: URL
    let logo: NSImage?
    let backgrounds: [NSImage]
    let layerImages: [NSImage?]
    let audio: Audio
    @Published var gameURL: URL?
    @Published var bundleID = ""
    @Published var titleID = ""
    @Published var version = ""
    @Published var dlc = 0
    @Published var rows: [Row] = []
    @Published var values: [String: String] = [:]
    @Published var status = ""
    @Published var launching = false
    @Published var trackIndex = 0
    @Published var artBusy = false
    lazy var installer = Installer(self)
    /// Set by the view: rebuild the whole menu from the theme files (after the art step wrote new ones).
    var reload: () -> Void = {}

    /// The art maker shipped inside this launcher (Resources/kit) and which game recipe it runs.
    var kit: URL { res.appendingPathComponent("kit") }
    var recipe: String? {
        let r = (try? String(contentsOf: kit.appendingPathComponent("recipe"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return r.isEmpty || !FileManager.default.fileExists(atPath: kit.appendingPathComponent("make_theme.py").path) ? nil : r
    }
    var hasArt: Bool { logo != nil || !backgrounds.isEmpty || layerImages.contains { $0 != nil } }

    /// Read the logo, backdrops, music and menu sounds from the installed game (in the background), then reload.
    func refreshArt() {
        guard !artBusy, recipe != nil, gameURL != nil else { return }
        installer.addArt { ok in
            self.status = ok ? "" : "Couldn't add the art and music (details: ~/Library/Logs/nxnative-launcher/art.log). The game plays fine."
            if ok { self.reload() }
        }
    }

    static let tabs = ["GAME", "DISPLAY", "CONTROLS", "PERFORMANCE", "AUDIO", "CONTENT", "TOOLS"]
    static let tabOf: [String: String] = [
        "DM_LANG": "GAME", "DM_OPMODE": "GAME", "DM_FPS_TARGET": "GAME", "DM_FPS_HOLD": "GAME",
        "DM_RENDER_SCALE": "DISPLAY", "DM_DYNAMIC_RESOLUTION": "DISPLAY", "DM_FULLSCREEN": "DISPLAY",
        "DM_PRESENT_UPSCALE": "DISPLAY", "DM_GAME_UPSCALER": "DISPLAY", "DM_PICTURE": "DISPLAY", "DM_ASPECT": "DISPLAY",
        "DM_RUMBLE": "CONTROLS", "DM_RUMBLE_GAIN": "CONTROLS", "DM_RUMBLE_MIN": "CONTROLS",
        "DM_PAD_PRESS_TO_JOIN": "CONTROLS", "DM_SW2": "CONTROLS", "DM_TOUCH_FEEDBACK": "CONTROLS"]

    init() {
        let r = Bundle.main.resourceURL!
        let data = (try? Data(contentsOf: r.appendingPathComponent("theme.json"))) ?? Data("{}".utf8)
        let th = (try? JSONDecoder().decode(Theme.self, from: data)) ?? Theme()
        res = r; theme = th
        logo = th.logo.flatMap { NSImage(contentsOf: r.appendingPathComponent($0)) }
        backgrounds = th.backgrounds.compactMap { NSImage(contentsOf: r.appendingPathComponent($0)) }
        layerImages = th.layers.map { NSImage(contentsOf: r.appendingPathComponent($0.image)) }
        audio = Audio(theme: th, res: r)
        locateGame()
    }

    /// Where the game app lives: inside this launcher (Contents/Game), next to it, or where the player pointed us.
    var embeddedGameFolder: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Game") }

    /// A real nxnative game app: not this launcher itself, and its Info.plist names a game (DMTitleID).
    func isGameApp(_ url: URL) -> Bool {
        guard url.standardizedFileURL.resolvingSymlinksInPath() != Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        else { return false }
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        return (info?["DMTitleID"] as? String)?.isEmpty == false
    }

    func findGameApp() -> URL? {
        let fm = FileManager.default
        if let inside = try? fm.contentsOfDirectory(at: embeddedGameFolder, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" && isGameApp($0) }) { return inside }
        let p = theme.gameApp, base = Bundle.main.bundleURL.deletingLastPathComponent()
        if !p.isEmpty {
            let next = p.hasPrefix("/") ? URL(fileURLWithPath: p) : base.appendingPathComponent(p)
            if fm.fileExists(atPath: next.path) && isGameApp(next) { return next }
        }
        if let saved = UserDefaults.standard.string(forKey: "gameAppPath"), fm.fileExists(atPath: saved),
           isGameApp(URL(fileURLWithPath: saved)) { return URL(fileURLWithPath: saved) }
        return nil
    }

    func locateGame() {
        guard let url = findGameApp() else {
            gameURL = nil
            status = "Not installed yet: choose INSTALL and pick your game file."; buildRows([]); return
        }
        gameURL = url; status = ""
        let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) ?? [:]
        bundleID = info["CFBundleIdentifier"] as? String ?? ""
        titleID = info["DMTitleID"] as? String ?? ""
        version = info["CFBundleShortVersionString"] as? String ?? ""
        dlc = (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Resources/aoc").path).count) ?? 0
        var list: [[String: Any]] = []
        if let d = try? Data(contentsOf: url.appendingPathComponent("Contents/Resources/dm/launcher.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { list = j["settings"] as? [[String: Any]] ?? [] }
        buildRows(list)
    }

    func buildRows(_ list: [[String: Any]]) {
        func str(_ v: Any?) -> String { (v as? String) ?? (v as? NSNumber)?.stringValue ?? "" }
        var r: [Row] = list.map { s in
            let env = str(s["env"]), kind: Row.Kind
            switch str(s["kind"]) {
            case "toggle": kind = .toggle(on: str(s["on"]).isEmpty ? "1" : str(s["on"]), off: str(s["off"]).isEmpty ? "0" : str(s["off"]))
            case "range": kind = .range(min: (s["min"] as? NSNumber)?.doubleValue ?? 0, max: (s["max"] as? NSNumber)?.doubleValue ?? 1,
                                        step: (s["step"] as? NSNumber)?.doubleValue ?? 0.05)
            default: kind = .choice((s["options"] as? [[Any]] ?? []).map { (str($0.first), str($0.count > 1 ? $0[1] : $0.first)) })
            }
            return Row(id: env, label: str(s["label"]), note: str(s["note"]), tab: Model.tabOf[env] ?? "PERFORMANCE", kind: kind, def: str(s["default"]), game: true)
        }
        // Launcher's own settings
        r += [Row(id: "musicOn", label: "Menu music", note: "The game's title theme in this menu.", tab: "AUDIO", kind: .toggle(on: "1", off: "0"), def: "1", game: false),
              Row(id: "musicVolume", label: "Music volume", note: "Volume of the menu music.", tab: "AUDIO", kind: .range(min: 0, max: 1, step: 0.05), def: "0.5", game: false),
              Row(id: "soundsOn", label: "Menu sounds", note: "The game's cursor and confirm sounds in this menu.", tab: "AUDIO", kind: .toggle(on: "1", off: "0"), def: "1", game: false),
              Row(id: "soundVolume", label: "Sound volume", note: "Volume of the menu sounds.", tab: "AUDIO", kind: .range(min: 0, max: 1, step: 0.05), def: "0.5", game: false),
              Row(id: "keepOpen", label: "Keep launcher open", note: "Leave this menu open after the game starts.", tab: "TOOLS", kind: .toggle(on: "1", off: "0"), def: "0", game: false),
              Row(id: "openSaves", label: "Open save folder", note: "Your save files, in Finder.", tab: "TOOLS", kind: .action { [weak self] in if let s = self { NSWorkspace.shared.open(s.saveFolder) } }, def: "", game: false),
              Row(id: "openLog", label: "Open the game's log", note: "Useful when something goes wrong.", tab: "TOOLS", kind: .action { [weak self] in if let s = self { NSWorkspace.shared.open(s.logFile) } }, def: "", game: false),
              Row(id: "showApp", label: "Show game app in Finder", note: "The nxnative app this launcher starts.", tab: "TOOLS", kind: .action { [weak self] in if let u = self?.gameURL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }, def: "", game: false),
              Row(id: "getArt", label: "Get art and music from the game", note: "Reads the logo, pictures, music and menu sounds from your installed game again.", tab: "TOOLS", kind: .action { [weak self] in self?.refreshArt() }, def: "", game: false),
              Row(id: "reset", label: "Reset game settings to tested defaults", note: "Puts every game setting back to what nxnative tested.", tab: "TOOLS", kind: .action { [weak self] in self?.resetDefaults() }, def: "", game: false)]
        // Installed content: names from the theme, plus what the game app itself reports
        var info: [(String, String, String)] = []
        for (k, c) in theme.content.enumerated() { info.append(("content\(k)", c["label"] ?? "", c["value"] ?? "")) }
        if gameURL != nil {
            info.append(("detVersion", "Game version in app", version.isEmpty ? "unknown" : version))
            info.append(("detDLC", "DLC packs in app", dlc == 0 ? "none" : "\(dlc)"))
            info.append(("detTitle", "Title ID", titleID))
            if let d = (try? gameURL!.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                info.append(("detBuilt", "App built", d.formatted(date: .abbreviated, time: .shortened)))
            }
        }
        for (id, l, v) in info {
            r.append(Row(id: id, label: l, note: id.hasPrefix("det") ? "Read from the game app itself." : "Installed content packed into the game app.", tab: "CONTENT", kind: .info, def: "", game: false))
            values[id] = v
        }
        if recipe == nil || gameURL == nil { r.removeAll { $0.id == "getArt" } }
        rows = r
        for row in rows where row.def != "" {
            if row.game {
                values[row.id] = (CFPreferencesCopyAppValue("launcher.\(row.id)" as CFString, bundleID as CFString) as? String) ?? row.def
            } else {
                let v = UserDefaults.standard.object(forKey: row.id)
                values[row.id] = (v as? Bool).map { $0 ? "1" : "0" } ?? (v as? Double).map { String($0) } ?? row.def
            }
        }
    }

    func set(_ row: Row, _ v: String) {
        values[row.id] = v
        if row.game {
            let app = bundleID as CFString
            CFPreferencesSetAppValue("launcher.\(row.id)" as CFString, v == row.def ? nil : v as CFString, app)  // only non-defaults are kept
            CFPreferencesAppSynchronize(app)
        } else {
            if case .range = row.kind { UserDefaults.standard.set(Double(v) ?? 0, forKey: row.id) } else { UserDefaults.standard.set(v == "1", forKey: row.id) }
            audio.applyVolume()
        }
    }

    /// Step a row's value: +1 next, -1 previous (wraps for choices/toggles, clamps for ranges).
    func step(_ row: Row, _ dir: Int) {
        let cur = values[row.id] ?? row.def
        switch row.kind {
        case .choice(let opts):
            guard !opts.isEmpty else { return }
            let i = opts.firstIndex { $0.0 == cur } ?? 0
            set(row, opts[(i + dir + opts.count) % opts.count].0)
        case .toggle(let on, let off): set(row, cur == on ? off : on)
        case .range(let lo, let hi, let st):
            let v = min(hi, max(lo, (Double(cur) ?? lo) + Double(dir) * st))
            set(row, st < 1 ? String(format: "%.2f", v) : String(format: "%.0f", v))
        case .action(let f): f()
        case .info: break
        }
    }

    func display(_ row: Row) -> String {
        let cur = values[row.id] ?? row.def
        switch row.kind {
        case .choice(let opts): return opts.first { $0.0 == cur }?.1 ?? cur
        case .toggle(let on, _): return cur == on ? "On" : "Off"
        case .range(_, let hi, _): return hi <= 1.0001 ? "\(Int(((Double(cur) ?? 0) * 100).rounded()))%" : cur
        case .action: return ""
        case .info: return values[row.id] ?? ""
        }
    }

    func resetDefaults() { for r in rows where r.game { set(r, r.def) } }

    var musicLevel: Double { Double(values["musicVolume"] ?? "0.5") ?? 0.5 }
    var musicMuted: Bool { (values["musicOn"] ?? "1") != "1" }
    func setMusicLevel(_ v: Double) {
        if let r = rows.first(where: { $0.id == "musicVolume" }) { set(r, String(format: "%.2f", v)) }
        if musicMuted, let on = rows.first(where: { $0.id == "musicOn" }) { set(on, "1") }
    }
    func toggleMute() { if let on = rows.first(where: { $0.id == "musicOn" }) { set(on, musicMuted ? "1" : "0") } }

    var saveFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/nxnative/\(titleID)") }
    var logFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nxnative/\(titleID).log") }
    var keepOpen: Bool { UserDefaults.standard.bool(forKey: "keepOpen") }

    func play() {
        guard let url = gameURL, !launching else { audio.play("back"); return }
        launching = true; status = "Starting…"
        audio.play(theme.sounds["start"] != nil ? "start" : "select"); audio.fade(to: 0, over: 1.0)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.environment = ["DM_LAUNCHER": "0"]    // skip the game's own settings window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                DispatchQueue.main.async {
                    self.launching = false
                    if let err { self.status = "Couldn't start the game: \(err.localizedDescription)"; return }
                    self.status = ""
                    if !self.keepOpen { NSApp.terminate(nil) }
                }
            }
        }
    }
}

// MARK: - Input (keyboard + game controllers) routed to the view

enum Input { case up, down, left, right, ok, back, prevTab, nextTab }

final class InputHub: ObservableObject {
    var handler: ((Input) -> Void)?
    private var monitor: Any?
    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let h = self.handler else { return e }
            switch e.keyCode {
            case 126: h(.up); case 125: h(.down); case 123: h(.left); case 124: h(.right)
            case 36, 76, 49: h(.ok); case 53, 51: h(.back)
            default:
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "q", "[", ",": h(.prevTab); case "e", "]", ".": h(.nextTab)
                default: return e
                }
            }
            return nil
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            (n.object as? GCController).map { self?.attach($0) }
        }
        GCController.controllers().forEach(attach)
    }
    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    private func attach(_ c: GCController) {
        guard let p = c.extendedGamepad else { return }
        func on(_ b: GCControllerButtonInput, _ i: Input) { b.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.handler?(i) } } }
        on(p.dpad.up, .up); on(p.dpad.down, .down); on(p.dpad.left, .left); on(p.dpad.right, .right)
        on(p.buttonA, .ok); on(p.buttonB, .back); on(p.leftShoulder, .prevTab); on(p.rightShoulder, .nextTab)
        var stickReady = true
        p.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            if abs(x) < 0.3 && abs(y) < 0.3 { stickReady = true; return }
            guard stickReady else { return }; stickReady = false
            self?.handler?(abs(y) > abs(x) ? (y > 0 ? .up : .down) : (x > 0 ? .right : .left))
        }
    }
}

// MARK: - Views

/// Holds the menu; bumping the token rebuilds it from the theme files (used after new art was written).
struct Host: View {
    @State var token = 0
    var body: some View { RootView(onReload: { token += 1 }).id(token) }
}

struct RootView: View {
    var onReload: () -> Void = {}
    @StateObject var m = Model()
    @StateObject var input = InputHub()
    @State var menuIndex = 0
    @State var panel: String? = Placement.needsMove ? "MOVE" : ENV["LAUNCHER_PANEL"].flatMap { $0.isEmpty ? nil : $0 }       // nil, "SETTINGS", "TOOLS", "INSTALL", "MOVE"
    @State var slideTimer: Timer?
    @State var tab = "GAME"
    @State var rowIndex = 0
    @State var slide = 0
    @State var zoom = false
    var t: Theme { m.theme }
    var menu: [String] { m.gameURL == nil ? ["INSTALL", "SETTINGS", "QUIT"] : ["PLAY", "SETTINGS", "CONTENT", "TOOLS", "QUIT"] }

    func font(_ name: String, _ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .custom(name, size: size).weight(w) }

    var tabRows: [Row] { m.rows.filter { $0.tab == tab } }
    var visibleTabs: [String] { Model.tabs.filter { tb in m.rows.contains { $0.tab == tb } } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            mainMenu
            if panel == "MOVE" { MovePanel(t: t, close: { closePanel() }).transition(.opacity) }
            else if panel == "INSTALL" { InstallPanel(m: m, t: t, close: { closePanel() }).transition(.opacity) }
            else if panel != nil { settingsPanel.transition(.opacity) } else { statusBar }
            // Music controls stay reachable everywhere (bottom right, below any panel).
            VStack { Spacer(); HStack { Spacer(); musicControls } }.padding(.trailing, 60).padding(.bottom, panel == nil ? 36 : 22)
        }
        .frame(minWidth: 1200, maxWidth: .infinity, minHeight: 750, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .foregroundStyle(Color(hex: t.text))
        .onDisappear { slideTimer?.invalidate() }
        .onAppear {
            if panel?.uppercased() == "INSTALL" { m.installer.runChecks() }
            if let p = panel?.uppercased() { panel = p; tab = (p == "TOOLS" || p == "CONTENT") ? p : (visibleTabs.first ?? "GAME"); if let tb = ENV["LAUNCHER_TAB"]?.uppercased(), visibleTabs.contains(tb) { tab = tb } }
            input.handler = handle
            m.reload = { [m] in m.audio.shutdown(); slideTimer?.invalidate(); onReload() }
            if !Placement.needsMove { Placement.clearQuarantineInBackground() }
            if ENV["LAUNCHER_AUTOMOVE"] == "1" { FileHandle.standardError.write("move: \(Placement.moveAndRelaunch() ?? "ok") from \(Placement.bundle.path) needs=\(Placement.needsMove)\n".data(using: .utf8)!) }
            // A game is in but the launcher has no art yet (e.g. downloaded blank): fetch it from the game.
            if m.gameURL != nil && !m.hasArt && ENV["LAUNCHER_NO_AUTOART"] != "1" && ENV["LAUNCHER_SNAPSHOT"] == nil { m.refreshArt() }
            if ENV["LAUNCHER_INSTALL_AUTOSTART"] == "1" {   // self-test: wait for the checks, then install
                m.installer.runChecks()
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { tm in
                    let ins = m.installer
                    guard !ins.checking && !ins.checks.isEmpty else { return }
                    tm.invalidate()
                    FileHandle.standardError.write("checks: \(ins.checks.map { "\($0.id)=\($0.ok ? "ok" : $0.auto ? "auto" : "NO")" }) ready=\(ins.ready)\n".data(using: .utf8)!)
                    if ins.ready { ins.start() } else { exit(3) }
                }
            }
            startSlideshow()
            selfSnapshotIfAsked()
        }
    }

    // Full-window backdrop: slow crossfading slideshow with a gentle zoom, darkened toward the menu.
    var backdrop: some View {
        ZStack {
            Color(hex: t.shade)
            if let top = t.skyTop {
                LinearGradient(colors: [Color(hex: top), Color(hex: t.skyBottom ?? top)], startPoint: .top, endPoint: .bottom)
                ForEach(Array(t.layers.enumerated()), id: \.offset) { i, l in
                    if let img = m.layerImages[i] { LayerView(layer: l, image: img) }
                }
            }
            if !m.backgrounds.isEmpty {
                Color.clear.overlay(
                    Image(nsImage: m.backgrounds[slide % m.backgrounds.count]).resizable().interpolation(.high).scaledToFill()
                        .scaleEffect(zoom ? 1.08 : 1.0).blur(radius: 1.2)
                ).clipped().id(slide).transition(.opacity)
            }
            LinearGradient(stops: [.init(color: Color(hex: t.shade).opacity(0.88 * t.shadeStrength), location: 0),
                                   .init(color: Color(hex: t.shade).opacity(0.55 * t.shadeStrength), location: 0.45),
                                   .init(color: Color(hex: t.shade).opacity(0.10 * t.shadeStrength), location: 1)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, Color(hex: t.shade).opacity(0.75 * t.shadeStrength)], startPoint: .center, endPoint: .bottom)
        }
    }

    func startSlideshow() {
        guard m.backgrounds.count > 1 else { return }
        withAnimation(.linear(duration: t.slideSeconds)) { zoom = true }
        slideTimer = Timer.scheduledTimer(withTimeInterval: t.slideSeconds, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 1.6)) { slide += 1 }
            zoom = false
            withAnimation(.linear(duration: t.slideSeconds)) { zoom = true }
        }
    }

    var mainMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 86)
            if let p = t.presents {
                Text(p.uppercased()).font(font(t.labelFont, 22, .heavy)).tracking(1.5).foregroundStyle(Color(hex: t.text).opacity(0.92))
                    .shadow(color: .black.opacity(0.7), radius: 6).padding(.leading, 8)
            }
            if let logo = m.logo {
                Image(nsImage: logo).resizable().aspectRatio(contentMode: .fit).frame(width: CGFloat(t.logoWidth))
                    .shadow(color: .black.opacity(0.6), radius: 18, y: 6)
            } else {
                Text(t.name).font(font(t.menuFont, 64, .heavy))
            }
            Spacer().frame(height: 30)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(menu.indices, id: \.self) { i in menuItem(i) }
            }
            Spacer()
        }
        .padding(.leading, 110)
    }

    func menuItem(_ i: Int) -> some View {
        let sel = i == menuIndex && panel == nil
        return HStack(spacing: 0) {
            Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold)).opacity(sel ? 0.9 : 0).frame(width: 34)
            Text(menu[i]).font(font(t.menuFont, 38, .bold)).tracking(1)
                .padding(.leading, 26).frame(width: 520, height: 58, alignment: .leading)
                .foregroundStyle(sel ? Color(hex: t.accentText) : Color(hex: t.text))
                .background(
                    LinearGradient(colors: [Color(hex: t.accent).opacity(sel ? 0.97 : 0), Color(hex: t.accent2 ?? t.accent).opacity(sel ? 0.55 : 0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(sel ? 0.55 : 0), lineWidth: 1.5))
                        .shadow(color: Color(hex: t.glow ?? t.accent).opacity(sel && t.glow != nil ? 0.75 : 0), radius: 14))
                .shadow(color: .black.opacity(sel ? 0 : 0.8), radius: 4)
            Image(systemName: "chevron.right").font(.system(size: 18, weight: .bold)).opacity(sel ? 0.9 : 0).frame(width: 34)
        }
        .offset(x: -34)
        .contentShape(Rectangle())
        .onHover { h in if h && panel == nil && menuIndex != i { menuIndex = i; m.audio.play("move") } }
        .onTapGesture { menuIndex = i; activate() }
        .animation(.easeOut(duration: 0.12), value: menuIndex)
    }

    var statusBar: some View {
        VStack { Spacer()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    if m.installer.building {
                        Label("Installing… \(Int((m.installer.fraction ?? 0) * 100))%", systemImage: "arrow.down.circle")
                            .font(font(t.labelFont, 24, .semibold)).foregroundStyle(Color(hex: t.accent))
                    }
                    if m.artBusy {
                        Label("Adding the game's art and music…", systemImage: "paintpalette")
                            .font(font(t.labelFont, 24, .semibold)).foregroundStyle(Color(hex: t.accent))
                    }
                    if m.gameURL != nil {
                        Label(m.launching ? "Starting…" : "Game ready.", systemImage: "checkmark")
                            .font(font(t.labelFont, 24, .semibold)).foregroundStyle(Color(hex: t.accent))
                        Text("\(t.platform) • v\(m.version)\(m.dlc > 0 ? " • DLC \(m.dlc)" : "")")
                            .font(font(t.labelFont, 20, .medium)).foregroundStyle(Color(hex: t.dim))
                    }
                    if !m.status.isEmpty && !m.launching {
                        Text(m.status).font(font(t.bodyFont, 15, .medium)).foregroundStyle(Color(hex: t.accent))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 70).padding(.bottom, 36)
        }
    }

    // Bottom right: speaker button + volume slider, then the song switcher.
    @State var showVolume = false
    var musicControls: some View {
        HStack(spacing: 14) {
            if !m.audio.tracks.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: m.musicMuted ? "speaker.slash" : (m.musicLevel < 0.34 ? "speaker.wave.1" : m.musicLevel < 0.67 ? "speaker.wave.2" : "speaker.wave.3"))
                        .font(.system(size: 17, weight: .light)).frame(width: 36, height: 36)
                        .background(Circle().stroke(Color(hex: t.text).opacity(0.45), lineWidth: 1))
                        .contentShape(Circle())
                        .onTapGesture { m.toggleMute(); m.audio.play("move") }
                        .help(m.musicMuted ? "Unmute music" : "Mute music")
                    if showVolume {
                        Slider(value: Binding(get: { m.musicLevel }, set: { m.setMusicLevel($0) }), in: 0...1)
                            .frame(width: 120).tint(Color(hex: t.accent)).transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .onHover { h in withAnimation(.easeOut(duration: 0.15)) { showVolume = h } }
            }
            if m.audio.tracks.count > 1 { nowPlaying }
        }
        .foregroundStyle(Color(hex: t.text))
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    // Song switcher (bottom right): ‹ NOW PLAYING / title › in a thin font.
    var nowPlaying: some View {
        HStack(spacing: 18) {
            songArrow("chevron.left") { changeSong(-1) }
            VStack(alignment: .center, spacing: 3) {
                Text("NOW PLAYING  \(m.trackIndex + 1)/\(m.audio.tracks.count)")
                    .font(.custom(t.thinFont, size: 12).weight(.light)).tracking(2.5).foregroundStyle(Color(hex: t.dim))
                Text(m.audio.tracks[m.trackIndex].title.isEmpty ? "Track \(m.trackIndex + 1)" : m.audio.tracks[m.trackIndex].title)
                    .font(.custom(t.thinFont, size: 22).weight(.ultraLight)).foregroundStyle(Color(hex: t.text))
                    .lineLimit(1)
            }
            .frame(minWidth: 170)
            songArrow("chevron.right") { changeSong(1) }
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    func songArrow(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: icon).font(.system(size: 20, weight: .ultraLight))
            .foregroundStyle(Color(hex: t.text))
            .frame(width: 36, height: 36)
            .background(Circle().stroke(Color(hex: t.text).opacity(0.45), lineWidth: 1))
            .contentShape(Circle())
            .onTapGesture(perform: action)
    }

    func changeSong(_ dir: Int) { m.audio.play("move"); m.audio.step(dir); m.trackIndex = m.audio.current }

    // Dusklight-style panel: tab strip, rounded rows with LABEL left and value right, notes on the right.
    var settingsPanel: some View {
        ZStack {
            Color.black.opacity(0.35).onTapGesture { closePanel() }
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(visibleTabs, id: \.self) { tb in
                        Text(tb).font(font(t.labelFont, 21, .heavy)).tracking(0.5).lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(tb == tab ? Color(hex: t.text) : Color(hex: t.dim).opacity(0.75))
                            .padding(.horizontal, 18).frame(height: 62)
                            .background(tb == tab ? Color(hex: t.border).opacity(0.18) : .clear)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: t.border)).frame(height: tb == tab ? 4 : 0) }
                            .contentShape(Rectangle())
                            .onTapGesture { switchTab(to: tb) }
                    }
                    Spacer()
                    Image(systemName: "xmark").font(.system(size: 22, weight: .bold)).padding(.horizontal, 24)
                        .contentShape(Rectangle()).onTapGesture { closePanel() }
                }
                .background(Color(hex: t.panel).opacity(0.75))
                Rectangle().fill(Color(hex: t.border)).frame(height: 2)
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 10) { ForEach(Array(tabRows.enumerated()), id: \.1.id) { i, r in panelRow(r, i) } }
                            .padding(22)
                    }
                    .frame(width: 600)
                    Rectangle().fill(Color(hex: t.border).opacity(0.6)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 12) {
                        if tabRows.indices.contains(rowIndex) {
                            let r = tabRows[rowIndex]
                            Text(r.label.uppercased()).font(font(t.labelFont, 22, .heavy))
                            Text(r.note.isEmpty ? " " : r.note).font(font(t.bodyFont, 15, .regular)).foregroundStyle(Color(hex: t.dim))
                                .fixedSize(horizontal: false, vertical: true)
                            if r.game { Text("Default: \(defaultLabel(r))").font(font(t.bodyFont, 13, .medium)).foregroundStyle(Color(hex: t.dim).opacity(0.7)) }
                        }
                        Spacer()
                        Text("↑↓ choose   ←→ change   Q/E tabs   Esc close").font(font(t.bodyFont, 12, .medium)).foregroundStyle(Color(hex: t.dim).opacity(0.7))
                    }
                    .padding(26).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(Color(hex: t.panel).opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: t.border), lineWidth: 2))
            .frame(width: 1080, height: 600)
            .shadow(color: .black.opacity(0.6), radius: 30)
        }
    }

    func defaultLabel(_ r: Row) -> String {
        switch r.kind {
        case .choice(let o): return o.first { $0.0 == r.def }?.1 ?? r.def
        case .toggle(let on, _): return r.def == on ? "On" : "Off"
        default: return r.def
        }
    }

    func panelRow(_ r: Row, _ i: Int) -> some View {
        let sel = i == rowIndex
        let isAction: Bool = { if case .action = r.kind { return true }; return false }()
        let isInfo: Bool = { if case .info = r.kind { return true }; return false }()
        let isRange: Bool = { if case .range = r.kind { return true }; return false }()
        return HStack(spacing: 10) {
            if isAction {
                Text(r.label).font(font(t.labelFont, 21, .semibold)).frame(maxWidth: .infinity)
            } else {
                Text(r.label.uppercased()).font(font(t.labelFont, 20, .heavy))
                Spacer()
                if !isInfo { arrow("chevron.left") { rowIndex = i; m.step(r, -1); m.audio.play("move") } }
                Text(m.display(r)).font(font(t.labelFont, 21, .semibold)).frame(minWidth: isInfo ? 0 : 70, alignment: isInfo ? .trailing : .center)
                if !isInfo { arrow("chevron.right") { rowIndex = i; m.step(r, 1); m.audio.play("move") } }
            }
        }
        .padding(.horizontal, 22).frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 14).fill(sel ? Color(hex: t.border).opacity(0.22) : Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: t.border).opacity(sel ? 0.95 : 0.35), lineWidth: sel ? 2 : 1))
        .contentShape(Rectangle())
        .onHover { h in if h && rowIndex != i { rowIndex = i; m.audio.play("move") } }
        // Clicking the row: runs an action, or steps a choice/toggle forward. Ranges use the ‹ › arrows.
        .onTapGesture { rowIndex = i; if !isRange && !isInfo { m.step(r, 1); m.audio.play("select") } }
    }

    // ‹ › buttons beside a value (mouse: lower / raise, previous / next).
    func arrow(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: icon).font(.system(size: 16, weight: .heavy))
            .foregroundStyle(Color(hex: t.border))
            .frame(width: 30, height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }

    // MARK: input

    func handle(_ i: Input) {
        if panel == "MOVE" {
            if i == .ok { m.audio.play("select"); _ = Placement.moveAndRelaunch() } else if i == .back && !Placement.mustMove { closePanel() }
            return
        }
        if panel == "INSTALL" { if i == .back && !m.installer.building { closePanel() }; return }
        if panel == nil {
            switch i {
            case .up: menuIndex = (menuIndex + menu.count - 1) % menu.count; m.audio.play("move")
            case .down: menuIndex = (menuIndex + 1) % menu.count; m.audio.play("move")
            case .ok: activate()
            case .prevTab: changeSong(-1)      // L / Q / [ / , on the main menu: previous song
            case .nextTab: changeSong(1)       // R / E / ] / . on the main menu: next song
            default: break
            }
            return
        }
        let rows = tabRows
        switch i {
        case .up: if !rows.isEmpty { rowIndex = (rowIndex + rows.count - 1) % rows.count; m.audio.play("move") }
        case .down: if !rows.isEmpty { rowIndex = (rowIndex + 1) % rows.count; m.audio.play("move") }
        case .left: if rows.indices.contains(rowIndex) { m.step(rows[rowIndex], -1); m.audio.play("move") }
        case .right: if rows.indices.contains(rowIndex) { m.step(rows[rowIndex], 1); m.audio.play("move") }
        case .ok: if rows.indices.contains(rowIndex) { m.step(rows[rowIndex], 1); m.audio.play("select") }
        case .back: closePanel()
        case .prevTab, .nextTab:
            let tabs = visibleTabs, k = tabs.firstIndex(of: tab) ?? 0
            switchTab(to: tabs[(k + (i == .nextTab ? 1 : tabs.count - 1)) % tabs.count])
        }
    }

    func switchTab(to tb: String) { if tb != tab { tab = tb; rowIndex = 0; m.audio.play("move") } }
    func closePanel() { withAnimation(.easeOut(duration: 0.15)) { panel = nil }; m.audio.play("back") }

    func activate() {
        switch menu[menuIndex] {
        case "PLAY": m.play()
        case "INSTALL": m.audio.play("select"); m.installer.runChecks(); withAnimation(.easeOut(duration: 0.15)) { panel = "INSTALL" }
        case "SETTINGS": m.audio.play("select"); tab = visibleTabs.first ?? "GAME"; rowIndex = 0; withAnimation(.easeOut(duration: 0.15)) { panel = "SETTINGS" }
        case "CONTENT": m.audio.play("select"); tab = "CONTENT"; rowIndex = 0; withAnimation(.easeOut(duration: 0.15)) { panel = "CONTENT" }
        case "TOOLS": m.audio.play("select"); tab = "TOOLS"; rowIndex = 0; withAnimation(.easeOut(duration: 0.15)) { panel = "TOOLS" }
        default: m.audio.play("back"); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { NSApp.terminate(nil) }
        }
    }

    // Self-test of the real window (no screen capture).
    func selfSnapshotIfAsked() {
        guard let path = ENV["LAUNCHER_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ENV["LAUNCHER_SNAPSHOT_DELAY"] ?? "") ?? 2.0)) {
            guard let win = NSApp.windows.first(where: { $0.isVisible }), let view = win.contentView else { exit(2) }
            let b = view.bounds
            if let rep = view.bitmapImageRepForCachingDisplay(in: b) {
                view.cacheDisplay(in: b, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            FileHandle.standardError.write("window \(win.frame.size)\n".data(using: .utf8)!)
            exit(0)
        }
    }
}

// The app opens its own window (instead of SwiftUI's WindowGroup, which can decide to restore
// "no windows" after a session whose window was closed).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        let main = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem); NSApp.mainMenu = main
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 750),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Launcher"
        window.contentView = NSHostingView(rootView: Host())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
enum LauncherMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

// A layer of a scene backdrop: an image repeated across the window that drifts sideways.
struct Layer: Decodable {
    var image: String
    var top: Double = 0          // top edge, fraction of window height
    var height: Double = 0.4     // fraction of window height
    var drift: Double = 0        // seconds to scroll one tile (0 = still); negative = rightward
    var tint: String?            // draw the image's shape in this color (e.g. white clouds)
    var opacity: Double = 1
    enum K: String, CodingKey { case image, top, height, drift, tint, opacity }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        image = try c.decode(String.self, forKey: .image)
        top = try c.decodeIfPresent(Double.self, forKey: .top) ?? 0
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 0.4
        drift = try c.decodeIfPresent(Double.self, forKey: .drift) ?? 0
        tint = try c.decodeIfPresent(String.self, forKey: .tint)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }
}

struct LayerView: View {
    let layer: Layer
    let image: NSImage
    @State private var phase = false
    var body: some View {
        GeometryReader { g in
            let h = g.size.height * layer.height
            let tw = max(1, h * image.size.width / max(1, image.size.height))
            let count = Int(ceil(g.size.width / tw)) + 2
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    Group {
                        if let tint = layer.tint {
                            Image(nsImage: image).resizable().renderingMode(.template).foregroundStyle(Color(hex: tint))
                        } else {
                            Image(nsImage: image).resizable()
                        }
                    }
                    .frame(width: tw, height: h)
                }
            }
            .offset(x: layer.drift == 0 ? 0 : (phase ? (layer.drift > 0 ? -tw : 0) : (layer.drift > 0 ? 0 : -tw)),
                    y: g.size.height * layer.top)
            .opacity(layer.opacity)
            .onAppear {
                guard layer.drift != 0 else { return }
                withAnimation(.linear(duration: abs(layer.drift)).repeatForever(autoreverses: false)) { phase = true }
            }
        }
        .allowsHitTesting(false)
    }
}

struct Track: Decodable {
    var file: String
    var title: String
    var loopStart: Double? = nil   // seconds; the file plays once, then loops from here to its end
}

// MARK: - Installer: turn the player's own .nsp / .nup into the native game app, once

final class Installer: ObservableObject {
    /// What clicking a check does: run a command in Terminal, ask for the Mac password and run it, or open a page.
    enum Fix { case terminal(String), admin(String), open(URL) }
    /// auto: not there yet, but the install sets it up by itself.
    struct Check: Identifiable { let id: String; let ok: Bool; let detail: String; var fix: Fix? = nil; var value: String? = nil; var auto = false }
    weak var model: Model?
    @Published var checks: [Check] = []
    @Published var source: URL?
    @Published var keys: URL?
    @Published var building = false { didSet { model?.objectWillChange.send() } }
    @Published var fraction: Double? { didSet { model?.objectWillChange.send() } }
    @Published var stage = ""
    @Published var eta = ""
    @Published var log: [String] = []
    @Published var error = ""
    @Published var finished = false
    @Published var checking = false
    @Published var notice = ""
    @Published var artAdded = false
    private var userChoseKeys = false
    private var process: Process?
    let home = FileManager.default.homeDirectoryForCurrentUser
    var nxnative: URL { home.appendingPathComponent("nxnative") }

    init(_ m: Model) {
        model = m; keys = Installer.findKeys(home)
        if let s = ENV["LAUNCHER_INSTALL_SOURCE"] { source = URL(fileURLWithPath: s) }   // self-test hook
        if let k = ENV["LAUNCHER_INSTALL_KEYS"] { keys = URL(fileURLWithPath: k); userChoseKeys = true }   // self-test hook
    }

    var needsKeys: Bool {
        guard let s = source else { return false }
        let exts = ["nsp", "xci", "nsz", "xcz"]
        if exts.contains(s.pathExtension.lowercased()) { return true }
        if s.hasDirectoryPath, let items = try? FileManager.default.contentsOfDirectory(atPath: s.path) {
            return items.contains { exts.contains(($0 as NSString).pathExtension.lowercased()) }
        }
        return false
    }
    var ready: Bool { source != nil && !checking && (!needsKeys || keys != nil) && !checks.isEmpty && checks.allSatisfy { $0.ok || $0.auto } && !building }

    /// Every prod.keys in the usual places, newest first (highest master key); key values are never read out.
    static func allKeys(_ home: URL) -> [URL] {
        let dirs = ["Documents/Games/Switch", "Documents/Games", ".switch", "Documents", "Downloads", "Desktop"].map { home.appendingPathComponent($0) }
        var found: [(URL, Int)] = []
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            where f.lastPathComponent.lowercased().hasPrefix("prod") && (f.lastPathComponent.lowercased().contains(".keys") || f.pathExtension == "keys") {
                let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
                let n = text.components(separatedBy: "\n").compactMap { line -> Int? in
                    guard line.hasPrefix("master_key_") else { return nil }
                    return Int(line.dropFirst(11).prefix(2), radix: 16)
                }.max() ?? -1
                found.append((f, n))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// The game files nxnative will read for this choice (a .nsp and its update/DLC beside it, or a folder's).
    var packages: [URL] {
        guard let s = source else { return [] }
        let exts = ["nsp", "xci", "nsz", "xcz"], fm = FileManager.default
        let folder = s.hasDirectoryPath ? s : s.deletingLastPathComponent()
        guard s.hasDirectoryPath || exts.contains(s.pathExtension.lowercased()) else { return [] }
        let files = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("._") }
        return Array(Set(files + (s.hasDirectoryPath ? [] : [s]))).sorted { $0.path < $1.path }
    }
    var nxExtract: URL { nxnative.appendingPathComponent("dm/tools/nx_extract_bin/nx_extract") }

    /// nx_extract <keys> --keys <packages>: can these keys open every file of this game?
    func keyTest(_ k: URL, _ pkgs: [URL]) -> (ok: Bool, message: String) {
        let out = run(nxExtract, [k.path, "--keys"] + pkgs.map(\.path)).1
        if out.contains("the keys open all") { return (true, "") }
        let red = out.components(separatedBy: "\n").first { $0.hasPrefix("[RED]") } ?? out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, red.replacingOccurrences(of: "[RED] ", with: ""))
    }

    /// Plain-language advice for nx_extract's key message.
    static func keyAdvice(_ msg: String, tried: [String]) -> String {
        let triedText = tried.count > 1 ? " (Tried: \(tried.joined(separator: ", ")).)" : ""
        if let r = msg.range(of: #"master key (\w+), which came with ([^)]+)\)"#, options: .regularExpression) {
            let inner = String(msg[r]).replacingOccurrences(of: ")", with: "")
            let fw = inner.components(separatedBy: "came with ").last ?? "a newer firmware"
            return "Your keys are too old for this game: it needs keys from Switch \(fw) or later. Update your Switch to \(fw)+, dump prod.keys again with the same tool, then choose the new file here.\(triedText)"
        }
        if msg.contains("title key") {
            return "This copy needs its title key: put the matching title.keys (dumped from the same Switch) next to your prod.keys, then Recheck.\(triedText)"
        }
        return msg.isEmpty ? "These keys could not open the game.\(triedText)" : msg + triedText
    }

    func run(_ exe: URL, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = exe; p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error.localizedDescription)") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit(); return (p.terminationStatus, out)
    }

    /// nx_extract <keys> --contents: what these files are (base game, update, DLC) and whether they belong together.
    func contentsSummary(_ k: URL, _ pkgs: [URL]) -> (ok: Bool, text: String) {
        let out = run(nxExtract, [k.path, "--contents"] + pkgs.map(\.path)).1
        var apps = Set<String>(), patches: [String] = [], dlc = 0
        for line in out.components(separatedBy: "\n") {
            let f = line.split(separator: " ")
            guard f.count == 4, f[0] == "content" else { continue }
            switch f[1] {
            case "Application": apps.insert(String(f[2]))
            case "Patch": patches.append("v\(f[3])")
            case "AddOnContent": dlc += 1
            default: break
            }
        }
        if apps.isEmpty && patches.isEmpty && dlc == 0 { return (true, "") }   // nothing listed: leave it to the build
        if apps.count > 1 { return (false, "These files are from \(apps.count) different games. Keep each game in its own folder.") }
        if apps.isEmpty { return (false, "Only an update or DLC was found, not the base game. Put the base game file in the same folder.") }
        var parts = ["Base game"]
        if !patches.isEmpty { parts.append("update \(patches.sorted().last!)") }
        if dlc > 0 { parts.append("\(dlc) DLC") }
        return (true, parts.joined(separator: " + "))
    }

    /// The newest prod.keys in the usual places (highest master key wins; key values are never read out).
    static func findKeys(_ home: URL) -> URL? {
        let dirs = ["Documents/Games/Switch", "Documents/Games", ".switch", "Documents", "Downloads"].map { home.appendingPathComponent($0) }
        var best: (URL, Int)?
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            where f.lastPathComponent.lowercased().hasPrefix("prod.keys") || f.lastPathComponent.lowercased().hasPrefix("prod") && f.pathExtension == "keys" {
                let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
                let n = text.components(separatedBy: "\n").compactMap { line -> Int? in
                    guard line.hasPrefix("master_key_") else { return nil }
                    return Int(line.dropFirst(11).prefix(2), radix: 16)
                }.max() ?? -1
                if best == nil || n > best!.1 { best = (f, n) }
            }
        }
        return best?.0
    }

    func shell(_ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        var env = ProcessInfo.processInfo.environment; env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"; p.environment = env
        do { try p.run() } catch { return (-1, "") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit(); return (p.terminationStatus, out)
    }

    func runChecks() {
        guard !checking else { return }
        checking = true; notice = ""
        let src = source, chosen = userChoseKeys ? keys : nil, keysNow = keys
        DispatchQueue.global(qos: .userInitiated).async {
            var c: [Check] = []
            let xc = self.shell(["xcode-select", "-p"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
            let xcOK = xc.contains("Xcode") && FileManager.default.fileExists(atPath: xc)   // selected AND actually there
            let xcInstalled = FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
            c.append(Check(id: "Xcode", ok: xcOK,
                detail: xcOK ? "Installed and selected" : xcInstalled ? "Installed but not set up yet. Click here to finish it (asks for your Mac password)." :
                    "Not installed. Click here to get it from the App Store (free), open it once when it's done, then come back.",
                fix: xcOK ? nil : xcInstalled ? .admin("xcode-select -s /Applications/Xcode.app && xcodebuild -license accept && xcodebuild -runFirstLaunch")
                    : .open(URL(string: "macappstore://apps.apple.com/app/id497799835")!)))
            let metal = self.shell(["xcrun", "-f", "metal"]).0 == 0
            c.append(Check(id: "Metal compiler", ok: metal, detail: metal ? "Installed" : (xcOK ? "Downloaded for you during the install" : "Comes with Xcode: set up Xcode first."),
                           auto: !metal && xcOK))
            let fm = FileManager.default
            if !Tools.hasBrew {
                c.append(Check(id: "Homebrew", ok: false,
                    detail: "Needed for a few free tools. Click here to install it in Terminal (asks for your Mac password), then come back.",
                    fix: .terminal("/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")))
            } else {
                let missing = Tools.missingFormulas()
                c.append(Check(id: "Tools", ok: missing.isEmpty, detail: missing.isEmpty ? "Homebrew tools ready" : "Installed for you: \(missing.joined(separator: ", "))", auto: !missing.isEmpty))
            }
            let cloned = fm.fileExists(atPath: Tools.nxnative.appendingPathComponent("scripts/build_ipa_from_nsp.py").path)
            let nx = cloned && Tools.pythonWithBuildDeps() != nil
            let canAuto = xcOK && Tools.hasBrew
            c.append(Check(id: "nxnative", ok: nx,
                detail: nx ? "~/nxnative" : !canAuto ? "Set up Xcode and Homebrew first; then nxnative is set up for you." :
                    cloned ? "Its Python setup is made for you during the install" : "Downloaded to ~/nxnative for you during the install",
                auto: !nx && canAuto))
            if self.model?.recipe != nil && !Tools.artReady {
                c.append(Check(id: "Art & music", ok: false, detail: "Tools to read the game's art and music: set up for you after the install", auto: true))
            }
            var pickedKeys = keysNow
            if let s = src {
                let size = Installer.size(of: s)
                let free = (try? Bundle.main.bundleURL.deletingLastPathComponent()
                    .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
                let need = Int64(size) * 2 + 10_000_000_000
                c.append(Check(id: "Free space", ok: Int64(free) >= need,
                               detail: "\(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)) free, about \(ByteCountFormatter.string(fromByteCount: need, countStyle: .file)) needed"))
                let pkgs = self.packages
                if !pkgs.isEmpty {   // a .nsp/.xci game: test the keys against these very files
                    let candidates = chosen.map { [$0] } ?? Installer.allKeys(self.home)
                    if candidates.isEmpty {
                        c.append(Check(id: "Keys", ok: false, detail: "No prod.keys found. Dump it from your own Switch, put it in Documents/Games/Switch, then Recheck (or click KEYS to choose it)."))
                    } else if !fm.fileExists(atPath: self.nxExtract.path) {
                        pickedKeys = candidates.first
                        c.append(Check(id: "Keys", ok: true, detail: "Can't test without nxnative's extractor; using \(candidates[0].lastPathComponent)", value: candidates[0].lastPathComponent))
                    } else {
                        var firstFail = "", tried: [String] = []
                        pickedKeys = nil
                        for k in candidates {
                            tried.append(k.lastPathComponent)
                            let r = self.keyTest(k, pkgs)
                            if r.ok { pickedKeys = k; break }
                            if firstFail.isEmpty { firstFail = r.message }
                        }
                        if let k = pickedKeys {
                            c.append(Check(id: "Keys", ok: true, detail: "Opens every file of this game", value: k.lastPathComponent))
                            let sum = self.contentsSummary(k, pkgs)
                            if !sum.text.isEmpty { c.append(Check(id: "Packages", ok: sum.ok, detail: sum.ok ? "\(pkgs.count) file\(pkgs.count == 1 ? "" : "s")" : sum.text, value: sum.ok ? sum.text : "✗")) }
                        } else {
                            pickedKeys = chosen ?? candidates.first
                            c.append(Check(id: "Keys", ok: false, detail: Installer.keyAdvice(firstFail, tried: tried), value: "✗"))
                        }
                    }
                }
            }
            DispatchQueue.main.async { self.keys = pickedKeys; self.checks = c; self.checking = false }
        }
    }

    func fix(_ c: Check) {
        guard let f = c.fix else { return }
        switch f {
        case .open(let u):
            NSWorkspace.shared.open(u)
            notice = "Opened the App Store. Install Xcode, open it once, then come back here."
        case .terminal(let cmd):
            try? FileManager.default.createDirectory(at: Tools.support, withIntermediateDirectories: true)
            let file = Tools.support.appendingPathComponent("fix-\(c.id.lowercased()).command")
            let script = "#!/bin/zsh\nclear\necho 'Setting up \(c.id) for your game launcher…'\necho\n\(cmd)\necho\necho 'Done. Close this window and go back to the launcher.'\n"
            try? script.write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
            notice = "Opened Terminal. Follow it (it may ask for your Mac password), then come back: this checks again by itself."
        case .admin(let cmd):
            notice = "Enter your Mac password in the box that appears… (this can take a minute)"
            DispatchQueue.global(qos: .userInitiated).async {
                let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let r = Tools.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", "do shell script \"\(esc)\" with administrator privileges"])
                DispatchQueue.main.async {
                    self.notice = r.0 == 0 ? "Done." : r.1.contains("-128") ? "Cancelled." : "That didn't work: \(r.1.trimmingCharacters(in: .whitespacesAndNewlines))"
                    self.runChecks()
                }
            }
        }
    }

    static func size(of url: URL) -> UInt64 {
        if !url.hasDirectoryPath { return (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0 }
        var total: UInt64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let f = e?.nextObject() as? URL { total += UInt64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    func chooseSource() {
        let p = NSOpenPanel(); p.title = "Choose your game file (.nsp, .nup, .xci) or its folder"
        p.canChooseFiles = true; p.canChooseDirectories = true; p.allowsMultipleSelection = false
        if p.runModal() == .OK { source = p.url; runChecks() }
    }
    func chooseKeys() {
        let p = NSOpenPanel(); p.title = "Choose your prod.keys"; p.canChooseFiles = true; p.canChooseDirectories = false
        if p.runModal() == .OK { keys = p.url; userChoseKeys = true; runChecks() }
    }
    /// Already built somewhere else: move that game app into this launcher.
    func locateExisting() {
        let p = NSOpenPanel(); p.title = "Choose the built game app"; p.canChooseFiles = true; p.canChooseDirectories = false
        p.allowedContentTypes = [.application]
        guard p.runModal() == .OK, let app = p.url, let m = model else { return }
        try? FileManager.default.createDirectory(at: m.embeddedGameFolder, withIntermediateDirectories: true)
        let dest = m.embeddedGameFolder.appendingPathComponent(app.lastPathComponent)
        do { try FileManager.default.moveItem(at: app, to: dest) } catch {
            UserDefaults.standard.set(app.path, forKey: "gameAppPath")   // other volume: just remember where it is
        }
        m.locateGame(); finished = m.gameURL != nil
    }

    var workDir: URL {
        let name = (model?.theme.name ?? "Game").replacingOccurrences(of: "/", with: "-")
        return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("\(name) (build files)")
    }

    func start() {
        guard ready, let s = source else { return }
        UserDefaults.standard.set(s.path, forKey: "installSource")
        error = ""; log = []; fraction = 0; stage = "Getting ready…"; eta = ""; building = true; artAdded = false
        let needMetal = checks.contains { $0.id == "Metal compiler" && !$0.ok }
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = self.setUp(metal: needMetal, artOnly: false)
            DispatchQueue.main.async {
                if ok { self.build(s) } else { self.building = false; if self.error.isEmpty { self.error = "Setup stopped. See the log." } }
            }
        }
    }

    /// One-time setup of everything the player shouldn't have to do by hand: the Metal compiler, Homebrew
    /// tools, nxnative itself and a Python with its packages. Runs on a background queue; false on failure.
    func setUp(metal: Bool, artOnly: Bool) -> Bool {
        func say(_ line: String) { DispatchQueue.main.async { self.addLog(line) } }
        func step(_ title: String, _ exe: URL, _ args: [String]) -> Bool {
            DispatchQueue.main.async { self.stage = title }
            say("$ \(exe.lastPathComponent) \(args.joined(separator: " "))")
            let r = Tools.run(exe, args, line: say)
            if r.0 != 0 { DispatchQueue.main.async { self.error = "\(title.replacingOccurrences(of: "…", with: "")) didn't work (exit \(r.0)). See the log, then try again." } }
            return r.0 == 0
        }
        if metal && !artOnly {
            guard step("Getting the Metal compiler (one time)…", URL(fileURLWithPath: "/usr/bin/xcodebuild"), ["-downloadComponent", "MetalToolchain"]) else { return false }
        }
        let missing = Tools.missingFormulas(artOnly: artOnly)
        if !missing.isEmpty {
            guard Tools.hasBrew else { DispatchQueue.main.async { self.error = "Homebrew is needed first (see the checks)." }; return false }
            guard step("Installing free tools with Homebrew (one time)…", Tools.brew, ["install"] + missing) else { return false }
        }
        if !artOnly && !FileManager.default.fileExists(atPath: Tools.nxnative.appendingPathComponent("scripts/build_ipa_from_nsp.py").path) {
            guard step("Downloading nxnative (one time)…", URL(fileURLWithPath: "/usr/bin/git"),
                       ["clone", "--depth", "1", "https://github.com/seedds/nxnative.git", Tools.nxnative.path]) else { return false }
        }
        if !Tools.artReady || (!artOnly && Tools.pythonWithBuildDeps() == nil) {
            if !FileManager.default.isExecutableFile(atPath: Tools.venvPython.path) {
                guard let base = Tools.basePython() else { DispatchQueue.main.async { self.error = "No Python 3.12 or newer found." }; return false }
                try? FileManager.default.createDirectory(at: Tools.support, withIntermediateDirectories: true)
                guard step("Setting up Python (one time)…", base, ["-m", "venv", Tools.support.appendingPathComponent("venv").path]) else { return false }
            }
            guard step("Installing Python packages (one time)…", Tools.venvPython,
                       ["-m", "pip", "install", "--disable-pip-version-check", "-q"] + Tools.buildPackages + Tools.artPackages) else { return false }
        }
        return true
    }

    /// The game's logo, backdrops, music and menu sounds, read from the installed game into this launcher.
    func addArt(then done: @escaping (Bool) -> Void) {
        guard let m = model, let recipe = m.recipe, m.gameURL != nil else { done(false); return }
        m.artBusy = true
        if building { stage = "Adding the game's art and music…"; fraction = 1; eta = "" }
        let bundle = Bundle.main.bundleURL, res = m.res, kit = m.kit
        var cover: URL?
        if let src = UserDefaults.standard.string(forKey: "installSource").map({ URL(fileURLWithPath: $0) }) {
            let dir = src.hasDirectoryPath ? src : src.deletingLastPathComponent()
            cover = [dir, dir.deletingLastPathComponent()].map { $0.appendingPathComponent("imgs/covers/cover.jpg") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            let keep: (String) -> Void = { l in lines.append(l); DispatchQueue.main.async { self.addLog(l) } }
            var ok = self.setUp(metal: false, artOnly: true)
            if ok {
                var args = [kit.appendingPathComponent("make_theme.py").path, recipe, bundle.path, "--out", res.path]
                if let c = cover { args += ["--cover", c.path] }
                let r = Tools.run(Tools.venvPython, args, env: ["NXNATIVE": Tools.nxnative.path], line: keep)
                ok = r.0 == 0
            }
            let logDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/nxnative-launcher")
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(to: logDir.appendingPathComponent("art.log"), atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                m.artBusy = false
                if ok {
                    self.artAdded = true
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: bundle.path)
                    NSWorkspace.shared.noteFileSystemChanged(bundle.path)
                    if let icon = NSImage(contentsOf: res.appendingPathComponent("AppIcon.icns")) { NSApp.applicationIconImage = icon }
                } else {
                    self.error = ""
                    self.addLog("Couldn't add the art and music (log: ~/Library/Logs/nxnative-launcher/art.log). The game is installed and plays fine.")
                }
                done(ok)
            }
        }
    }

    private func build(_ s: URL) {
        guard let m = model else { building = false; return }
        stage = "Starting…"
        let fm = FileManager.default
        try? fm.createDirectory(at: m.embeddedGameFolder, withIntermediateDirectories: true)
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        // A hand-made profile shipped with the theme (e.g. 60 fps settings) goes in before the first build.
        if let prof = m.theme.profile, let tid = m.theme.titleID {
            let dst = workDir.appendingPathComponent("profile/\(tid)")
            if !fm.fileExists(atPath: dst.appendingPathComponent("game.tsv").path) {
                try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                for f in (try? fm.contentsOfDirectory(at: m.res.appendingPathComponent(prof), includingPropertiesForKeys: nil)) ?? [] {
                    try? fm.copyItem(at: f, to: dst.appendingPathComponent(f.lastPathComponent))
                }
            }
        }
        let out = m.embeddedGameFolder.appendingPathComponent("\(m.theme.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "")).app")
        // nxnative takes a .nup file or a folder. For a single .nsp/.xci, link it and any other game files
        // beside it (its update, its DLC) into a folder of their own.
        var input = s
        let gameExts = ["nsp", "xci", "nsz", "xcz"]
        if !s.hasDirectoryPath && gameExts.contains(s.pathExtension.lowercased()) {
            input = workDir.appendingPathComponent("input")
            try? fm.removeItem(at: input)
            try? fm.createDirectory(at: input, withIntermediateDirectories: true)
            let siblings = ((try? fm.contentsOfDirectory(at: s.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
                .filter { gameExts.contains($0.pathExtension.lowercased()) }
            for f in Set(siblings + [s]) { try? fm.createSymbolicLink(at: input.appendingPathComponent(f.lastPathComponent), withDestinationURL: f) }
        }
        var args = [nxnative.appendingPathComponent("scripts/build_ipa_from_nsp.py").path, input.path,
                    "--platform", "mac-app", "--progress", "json", "--work-dir", workDir.path, "-o", out.path]
        if needsKeys, let k = keys { args += ["-k", k.path] }
        let p = Process()
        p.executableURL = Tools.pythonWithBuildDeps() ?? nxnative.appendingPathComponent(".venv/bin/python")
        p.arguments = args
        p.currentDirectoryURL = nxnative
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        var pending = Data()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 10) {
                let line = pending.subdata(in: pending.startIndex..<nl); pending.removeSubrange(pending.startIndex...nl)
                DispatchQueue.main.async { self?.handle(line) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                if proc.terminationStatus != 0 { self.building = false }
                if ENV["LAUNCHER_INSTALL_AUTOSTART"] == "1" && proc.terminationStatus != 0 {   // self-test: report and quit
                    FileHandle.standardError.write("install exit \(proc.terminationStatus) app=none error=\(self.error)\n".data(using: .utf8)!)
                    exit(1)
                }
                if proc.terminationStatus == 0 {
                    self.fraction = 1; self.stage = "Installed"; self.model?.locateGame()
                    // Like the rest of the setup: the launcher is the only menu, so turn off nxnative's own window.
                    if let app = self.model?.gameURL, let tid = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["DMTitleID"] as? String) {
                        let dir = self.home.appendingPathComponent("Library/Application Support/nxnative/\(tid)")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let env = dir.appendingPathComponent("env.txt")
                        let text = (try? String(contentsOf: env, encoding: .utf8)) ?? ""
                        if !text.contains("DM_LAUNCHER=") { try? (text + (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "DM_LAUNCHER=0\n").write(to: env, atomically: true, encoding: .utf8) }
                    }
                    self.addArt { art in
                        // nxnative's work folder is only needed during the build (it can be many GB).
                        if ENV["LAUNCHER_KEEP_BUILD_FILES"] != "1" && (try? FileManager.default.removeItem(at: self.workDir)) != nil {
                            self.addLog("Cleaned up the build files.")
                        }
                        self.building = false; self.stage = "Installed"
                        self.finished = self.model?.gameURL != nil
                        self.model?.audio.play("select")
                        if ENV["LAUNCHER_INSTALL_AUTOSTART"] == "1" {   // self-test: report and quit
                            FileHandle.standardError.write("install exit 0 app=\(self.model?.findGameApp()?.path ?? "none") art=\(art)\n".data(using: .utf8)!)
                            exit(0)
                        }
                    }
                } else if self.error.isEmpty {
                    self.error = proc.terminationStatus == 15 ? "Install cancelled." : "The build stopped (exit \(proc.terminationStatus)). See the log."
                }
            }
        }
        do { try p.run(); process = p } catch { building = false; self.error = "Couldn't start nxnative: \(error.localizedDescription)" }
    }

    private var stageK = 1, stageN = 1
    private func handle(_ line: Data) {
        guard let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let ev = j["ev"] as? String else {
            if let s = String(data: line, encoding: .utf8), !s.isEmpty { addLog(s) }; return
        }
        switch ev {
        case "stage":
            stageK = j["k"] as? Int ?? stageK; stageN = max(1, j["n"] as? Int ?? stageN)
            stage = "Step \(stageK) of \(stageN): \(j["name"] as? String ?? "")"
            fraction = Double(stageK - 1) / Double(stageN)
        case "progress":
            if let f = j["frac"] as? Double { fraction = (Double(stageK - 1) + f) / Double(stageN) }
            if let e = j["eta"] as? Double, e > 1 {
                let m = Int(e) / 60, s = Int(e) % 60
                eta = m >= 60 ? "about \(m / 60) h \(m % 60) min left in this step" : "about \(m) min \(s) s left in this step"
            } else { eta = "" }
        case "stage_end": fraction = Double(stageK) / Double(stageN)
        case "say":
            let msg = j["msg"] as? String ?? ""
            addLog(msg)
            if msg.hasPrefix("[RED] ") && !msg.contains("provisional") { error = String(msg.dropFirst(6)) }
        default: break
        }
    }
    private func addLog(_ s: String) { log.append(s); if log.count > 200 { log.removeFirst(log.count - 200) } }

    func cancel() { process?.terminate() }
}

struct InstallPanel: View {
    @ObservedObject var m: Model
    let t: Theme
    let close: () -> Void
    @ObservedObject var ins: Installer
    init(m: Model, t: Theme, close: @escaping () -> Void) { self.m = m; self.t = t; self.close = close; self.ins = m.installer }

    func font(_ name: String, _ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .custom(name, size: size).weight(w) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            VStack(spacing: 0) {
                HStack {
                    Text("INSTALL \(t.name.uppercased())").font(font(t.labelFont, 22, .heavy)).padding(.leading, 26)
                    Spacer()
                    if !ins.building { Image(systemName: "xmark").font(.system(size: 22, weight: .bold)).padding(.horizontal, 24)
                        .contentShape(Rectangle()).onTapGesture(perform: close) }
                }
                .frame(height: 62).background(Color(hex: t.panel).opacity(0.75))
                Rectangle().fill(Color(hex: t.border)).frame(height: 2)
                HStack(spacing: 0) {
                    VStack(spacing: 10) {
                        row("GAME FILE", ins.source?.lastPathComponent ?? "Choose…", ok: ins.source != nil) { if !ins.building { ins.chooseSource() } }
                        if ins.needsKeys {
                            let kc = ins.checks.first { $0.id == "Keys" }
                            row("KEYS", kc?.value ?? ins.keys?.lastPathComponent ?? "Choose…", ok: kc?.ok ?? (ins.keys != nil), detail: kc?.detail ?? "Click to choose your prod.keys") { if !ins.building { ins.chooseKeys() } }
                        }
                        ForEach(ins.checks.filter { $0.id != "Keys" }) { c in
                            row(c.id.uppercased(), c.value ?? (c.ok ? "✓" : c.auto ? "AUTO" : "✗"), ok: c.ok || c.auto, detail: c.detail, action: c.fix == nil ? nil : { ins.fix(c) })
                        }
                        HStack {
                            if ins.checking { ProgressView().controlSize(.small); Text("Checking…").font(font(t.bodyFont, 12, .medium)).foregroundStyle(Color(hex: t.dim)) }
                            else if !ins.notice.isEmpty { Text(ins.notice).font(font(t.bodyFont, 11, .medium)).foregroundStyle(Color(hex: t.accent)).lineLimit(2) }
                            Spacer()
                            Text("↻ RECHECK").font(font(t.labelFont, 13, .heavy)).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().stroke(Color(hex: t.border), lineWidth: 1))
                                .contentShape(Capsule()).onTapGesture { if !ins.building { m.audio.play("move"); ins.runChecks() } }
                                .opacity(ins.building ? 0.4 : 1)
                        }
                        Spacer()
                        if ins.building || ins.fraction != nil { progress }
                        actionButton
                    }
                    .padding(22).frame(width: 600)
                    Rectangle().fill(Color(hex: t.border).opacity(0.6)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(ins.finished ? "INSTALLED" : "HOW THIS WORKS").font(font(t.labelFont, 20, .heavy))
                        Text(ins.finished ? (ins.artAdded ? "All done. Press DONE to see the game's art and hear its music, then PLAY." : "All done. Close this and press PLAY.") :
                             "Pick your own game file. It is turned into a native Mac game once (game code rewritten for macOS, graphics converted for Metal) and placed inside this launcher, then its logo, pictures and music are added here. After that, just press PLAY.\n\nAnything marked AUTO is set up for you during the install. A first install takes from a few minutes to a few hours, depending on the game.")
                            .font(font(t.bodyFont, 14, .regular)).foregroundStyle(Color(hex: t.dim)).fixedSize(horizontal: false, vertical: true)
                        if !ins.error.isEmpty { Text(ins.error).font(font(t.bodyFont, 13, .semibold)).foregroundStyle(Color(hex: t.accent)) }
                        Text("LOG").font(font(t.labelFont, 13, .heavy)).foregroundStyle(Color(hex: t.dim)).padding(.top, 6)
                        ScrollView { Text(ins.log.suffix(14).joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(hex: t.dim)).frame(maxWidth: .infinity, alignment: .leading) }
                        Text("Already built? Locate the game app…").font(font(t.bodyFont, 13, .medium)).underline()
                            .foregroundStyle(Color(hex: t.border)).onTapGesture { if !ins.building { ins.locateExisting() } }
                    }
                    .padding(24).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .background(Color(hex: t.panel).opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: t.border), lineWidth: 2))
            .frame(width: 1080, height: 620)
            .shadow(color: .black.opacity(0.6), radius: 30)
        }
        // Back from Terminal, the App Store or a password box: look again by itself.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !ins.building && !ins.finished { ins.runChecks() }
        }
    }

    func row(_ label: String, _ value: String, ok: Bool, detail: String = "", action: (() -> Void)?) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(font(t.labelFont, 18, .heavy))
                if !detail.isEmpty { Text(detail).font(font(t.bodyFont, 11, .regular)).foregroundStyle(Color(hex: ok ? t.dim : t.accent)).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Text(value).font(font(t.labelFont, 18, .semibold)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(ok ? Color(hex: t.text) : Color(hex: t.accent))
        }
        .padding(.horizontal, 20).padding(.vertical, 8).frame(minHeight: 52)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: t.border).opacity(ok ? 0.35 : 0.8), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ins.stage).font(font(t.labelFont, 15, .semibold)).lineLimit(1)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.35))
                    Capsule().fill(LinearGradient(colors: [Color(hex: t.accent), Color(hex: t.accent2 ?? t.accent)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: g.size.width * CGFloat(ins.fraction ?? 0))
                }
            }.frame(height: 12)
            Text("\(Int((ins.fraction ?? 0) * 100))%  \(ins.eta)").font(font(t.bodyFont, 12, .medium)).foregroundStyle(Color(hex: t.dim))
        }
    }

    var actionButton: some View {
        let label = ins.finished ? "DONE" : ins.building ? "CANCEL" : "BUILD & INSTALL"
        let enabled = ins.finished || ins.building || ins.ready
        return Text(label).font(font(t.menuFont, 24, .bold))
            .foregroundStyle(Color(hex: t.accentText))
            .frame(maxWidth: .infinity).frame(height: 56)
            .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: t.accent), Color(hex: t.accent2 ?? t.accent)], startPoint: .leading, endPoint: .trailing)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onTapGesture {
                if ins.finished { if ins.artAdded { m.reload() } else { close() } } else if ins.building { ins.cancel() } else if ins.ready { m.audio.play("select"); ins.start() } else { m.audio.play("back") }
            }
    }
}

// MARK: - Tools the install needs (found, or set up for the player)

enum Tools {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let nxnative = home.appendingPathComponent("nxnative")
    static let support = home.appendingPathComponent("Library/Application Support/nxnative-launcher")
    static var venvPython: URL { support.appendingPathComponent("venv/bin/python") }
    static let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
    static var hasBrew: Bool { FileManager.default.isExecutableFile(atPath: brew.path) }
    /// Homebrew formulas, by the program each one installs: the build needs the first three, the art step the last two.
    static let buildFormulas = [("xcodegen", "xcodegen"), ("zstd", "zstd"), ("glslang", "glslangValidator")]
    static let artFormulas = [("vgmstream", "vgmstream-cli"), ("ffmpeg", "ffmpeg")]
    static func missingFormulas(artOnly: Bool = false) -> [String] {
        var f = (artOnly ? artFormulas : buildFormulas + artFormulas)
            .filter { !FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/\($0.1)") }.map(\.0)
        if basePython() == nil && (artOnly || pythonWithBuildDeps() == nil) && !FileManager.default.isExecutableFile(atPath: venvPython.path) { f.append("python@3.13") }
        return f
    }
    static let buildPackages = ["lz4", "capstone>=5,<6", "fonttools", "nsz", "zbic", "backports.zstd; python_version < '3.14'"]
    static let artPackages = ["Pillow>=11", "UnityPy>=1.25,<2"]

    static func runs(_ py: URL, _ code: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: py.path) && run(py, ["-c", code]).0 == 0
    }
    /// A Python that can run nxnative's build: its own venv, or the launcher's.
    static func pythonWithBuildDeps() -> URL? {
        [nxnative.appendingPathComponent(".venv/bin/python"), venvPython].first { runs($0, "import lz4, capstone, fontTools, nsz") }
    }
    static var artReady: Bool { runs(venvPython, "import PIL, UnityPy") }
    /// An Apple silicon Python 3.12+ to make the launcher's own venv from.
    static func basePython() -> URL? {
        ["/opt/homebrew/bin/python3.14", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3"]
            .map { URL(fileURLWithPath: $0) }
            .first { runs($0, "import sys, platform; sys.exit(sys.version_info < (3, 12) or platform.machine() != 'arm64')") }
    }

    /// Run a program to the end; `line` gets each output line as it comes.
    @discardableResult
    static func run(_ exe: URL, _ args: [String], env extra: [String: String] = [:], line: ((String) -> Void)? = nil) -> (Int32, String) {
        let p = Process(); p.executableURL = exe; p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"; env["PYTHONUNBUFFERED"] = "1"
        extra.forEach { env[$0.key] = $0.value }
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        var all = Data(), pending = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            all.append(chunk); pending.append(chunk)
            while let nl = pending.firstIndex(of: 10) {
                let l = String(decoding: pending.subdata(in: pending.startIndex..<nl), as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                if !l.isEmpty { line?(l) }
            }
        }
        if !pending.isEmpty { line?(String(decoding: pending, as: UTF8.self)) }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: all, as: UTF8.self))
    }
}

// MARK: - Where the launcher lives (a downloaded app must leave Downloads before it can install a game inside itself)

enum Placement {
    static var bundle: URL { Bundle.main.bundleURL }
    /// macOS runs a freshly downloaded app from a hidden read-only copy ("App Translocation").
    static var translocated: Bool { bundle.path.contains("/AppTranslocation/") }
    static var readOnly: Bool { (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false }
    static var inDownloads: Bool {
        bundle.standardizedFileURL.path.hasPrefix(Tools.home.appendingPathComponent("Downloads").path + "/")
    }
    static let needsMove = ENV["LAUNCHER_FORCE_MOVE"] == "1" || translocated || readOnly || inDownloads
    static var mustMove: Bool { translocated || readOnly }

    /// The real place of a translocated app (Security framework's SecTranslocateCreateOriginalPathForURL).
    static func originalURL() -> URL {
        guard translocated, let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let sym = dlsym(h, "SecTranslocateCreateOriginalPathForURL") else { return bundle }
        typealias F = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let f = unsafeBitCast(sym, to: F.self)
        return (f(bundle as CFURL, nil)?.takeRetainedValue()).map { $0 as URL } ?? bundle
    }
    static var destinationFolder: URL {
        if let d = ENV["LAUNCHER_MOVE_TO"] { return URL(fileURLWithPath: d) }
        let apps = URL(fileURLWithPath: "/Applications")
        return FileManager.default.isWritableFile(atPath: apps.path) ? apps : Tools.home.appendingPathComponent("Applications")
    }

    /// Move (or copy, from a read-only disk) this launcher to Applications, clear its download flag and reopen it
    /// from there. Returns an error message, or nil when the new copy is opening.
    static func moveAndRelaunch() -> String? {
        let fm = FileManager.default, src = originalURL(), folder = destinationFolder
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = src.deletingPathExtension().lastPathComponent
        var dest = folder.appendingPathComponent("\(name).app"), n = 2
        while fm.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(name) \(n).app"); n += 1 }
        do {
            if readOnly || !fm.isWritableFile(atPath: src.deletingLastPathComponent().path) { try fm.copyItem(at: src, to: dest) }
            else { try fm.moveItem(at: src, to: dest) }
        } catch {
            return "Couldn't move it (\(error.localizedDescription)). Drag it into your Applications folder in Finder, then open it again."
        }
        clearQuarantine(dest)
        for v in ["LAUNCHER_AUTOMOVE", "LAUNCHER_FORCE_MOVE", "LAUNCHER_MOVE_TO"] { unsetenv(v) }   // the new copy starts clean
        let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in DispatchQueue.main.async { NSApp.terminate(nil) } }
        return nil
    }

    /// macOS already checked this launcher when it first opened; clearing the download flag keeps it from checking
    /// again each time the game or its art is added inside it.
    static func clearQuarantine(_ url: URL) {
        guard getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 else { return }
        Tools.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", url.path])
    }
    static func clearQuarantineInBackground() {
        let b = bundle
        DispatchQueue.global(qos: .utility).async { clearQuarantine(b) }
    }
}

struct MovePanel: View {
    let t: Theme
    let close: () -> Void
    @State var error = ""
    func font(_ name: String, _ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .custom(name, size: size).weight(w) }
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(alignment: .leading, spacing: 18) {
                Text("ONE QUICK STEP").font(font(t.labelFont, 22, .heavy))
                Text(Placement.mustMove
                     ? "macOS is running this launcher from a temporary, read-only copy, so it can't install your game yet. Move it to your Applications folder and it reopens from there."
                     : "This launcher is in your Downloads folder. Move it to Applications so your game can be installed inside it and you can find it later.")
                    .font(font(t.bodyFont, 17, .regular)).foregroundStyle(Color(hex: t.dim)).fixedSize(horizontal: false, vertical: true)
                if !error.isEmpty { Text(error).font(font(t.bodyFont, 14, .semibold)).foregroundStyle(Color(hex: t.accent)).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 14) {
                    Text("MOVE TO APPLICATIONS").font(font(t.menuFont, 22, .bold)).foregroundStyle(Color(hex: t.accentText))
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: t.accent), Color(hex: t.accent2 ?? t.accent)], startPoint: .leading, endPoint: .trailing)))
                        .contentShape(Rectangle())
                        .onTapGesture { error = Placement.moveAndRelaunch() ?? "" }
                    if !Placement.mustMove {
                        Text("NOT NOW").font(font(t.menuFont, 20, .bold)).frame(width: 160, height: 54)
                            .background(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: t.border), lineWidth: 1.5))
                            .contentShape(Rectangle()).onTapGesture(perform: close)
                    }
                }
            }
            .padding(34).frame(width: 640)
            .background(Color(hex: t.panel).opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: t.border), lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 30)
        }
    }
}
