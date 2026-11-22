// Controllers: what's connected, a button tester, pairing help, and the nxnative controller switches
// the launcher passes to the game when it starts it.
//
// Connected pads come from Apple's controller support (GameController) plus the IOKit registry, read
// without opening any device (so no Input Monitoring prompt): the registry gives the connection
// (Bluetooth / USB) and finds pads the game reads as raw HID gamepads, which GameController doesn't list.
//
// Button names follow nxnative (dm/host/pad_apple.h): a Nintendo pad (Switch Pro Controller, Joy-Con)
// maps name for name; any other pad maps by position, as on a Switch: right A, bottom B, top X, left Y.

import SwiftUI
import AppKit
import GameController
import IOKit
import IOKit.hid

struct PadInfo { let id: String, name: String, detail: String, note: String }

enum Pads {
    struct HIDDevice { let product: String, vendor: Int, transport: String, gamepad: Bool }

    /// Every HID device in the IOKit registry (properties only; nothing is opened).
    static func hidDevices() -> [HIDDevice] {
        var out: [HIDDevice] = [], it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &it) == KERN_SUCCESS else { return out }
        defer { IOObjectRelease(it) }
        while true {
            let s = IOIteratorNext(it)
            if s == 0 { break }
            defer { IOObjectRelease(s) }
            func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
            let pairs = prop(kIOHIDDeviceUsagePairsKey) as? [[String: Any]] ?? []
            let page = (prop(kIOHIDPrimaryUsagePageKey) as? NSNumber)?.intValue ?? 0, usage = (prop(kIOHIDPrimaryUsageKey) as? NSNumber)?.intValue ?? 0
            // Generic Desktop joystick (4), gamepad (5) or multi-axis controller (8)
            let isPad = (page == 1 && [4, 5, 8].contains(usage)) || pairs.contains {
                ($0[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue == 1 && [4, 5, 8].contains(($0[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue ?? 0)
            }
            out.append(HIDDevice(product: prop(kIOHIDProductKey) as? String ?? "", vendor: (prop(kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0,
                                 transport: prop(kIOHIDTransportKey) as? String ?? "", gamepad: isPad))
        }
        return out
    }

    static func connection(_ transport: String) -> String {
        transport.hasPrefix("Bluetooth") ? "Bluetooth" : transport.isEmpty ? "" : transport.uppercased() == "USB" ? "USB" : transport
    }

    /// A Nintendo pad: its buttons are read by their printed labels (pad_apple.h's dm_pad_labelled).
    static func labelled(_ c: GCController) -> Bool {
        let cat = c.productCategory
        return cat.contains("Switch Pro") || cat.contains("Joy-Con") || cat.contains("Pro Controller")
    }

    static func gamepads() -> [GCController] { GCController.controllers().filter { $0.extendedGamepad != nil } }

    static func list() -> [PadInfo] {
        let hid = hidDevices()
        var out: [PadInfo] = [], matched = Set<String>()
        for (i, c) in gamepads().enumerated() {
            let name = c.vendorName ?? c.productCategory
            let h = hid.first { $0.gamepad && !$0.product.isEmpty && !matched.contains($0.product) && ($0.product == name || name.contains($0.product) || $0.product.contains(name)) }
            if let h { matched.insert(h.product) }
            var parts: [String] = []
            if let tr = h.map({ connection($0.transport) }), !tr.isEmpty { parts.append(tr) }
            if let b = c.battery, b.batteryState != .unknown {
                parts.append("\(Int((b.batteryLevel * 100).rounded()))%" + (b.batteryState == .charging ? " charging" : b.batteryState == .full ? " full" : ""))
            }
            let layout = labelled(c) ? "Its buttons match their labels: A is A."
                                     : "Its buttons work by position, like a Switch's: the right button is A and the bottom one is B."
            out.append(PadInfo(id: "pad\(i)", name: name, detail: parts.isEmpty ? "Connected" : parts.joined(separator: " · "),
                               note: "\(c.productCategory), player \(i + 1) when the game starts. \(layout) Choose Test buttons to try it."))
        }
        for h in hid where h.gamepad && isEkipad(h) && !matched.contains(h.product) {
            matched.insert(h.product)
            out.append(PadInfo(id: "padeki\(out.count)", name: "Ekipad (iPhone)", detail: "Virtual pad",
                               note: "Your iPhone, through Ekipad's virtual gamepad. The launcher gives the game its button layout at Play (A right, B bottom, X top, Y left, as on a Switch), with analog sticks. This menu and Test buttons don't respond to it: use the keyboard or another pad here."))
        }
        for h in hid where h.gamepad && !h.product.isEmpty && !matched.contains(h.product) {
            matched.insert(h.product)
            let conn = connection(h.transport)
            out.append(PadInfo(id: "padhid\(out.count)", name: h.product, detail: conn.isEmpty ? "Direct" : "\(conn) · direct",
                               note: "macOS doesn't list this one as a game controller, so the game reads it directly. It works in the game, with full sticks; this menu and Test buttons may not respond to it."))
        }
        // An 8BitDo USB adapter in its PC (XInput) mode shows up as keyboard/mouse only.
        let eightBitDo = 0x2DC8
        if hid.contains(where: { $0.vendor == eightBitDo }) && !hid.contains(where: { $0.vendor == eightBitDo && $0.gamepad })
            && !gamepads().contains(where: { ($0.vendorName ?? "").contains("8BitDo") }) {
            out.append(PadInfo(id: "pad8bitdo", name: "8BitDo USB adapter", detail: "Can't be used",
                               note: "The adapter is in its PC-only mode, which macOS sees as a keyboard and mouse, so games can't use it. Pair the controller over Bluetooth instead (see Pairing help); keep the adapter for a PC."))
        }
        if out.isEmpty {
            out.append(PadInfo(id: "padnone", name: "No controller", detail: "Keyboard only",
                               note: "Turn on a controller and connect it over Bluetooth or USB; it shows up here. See Pairing help for each kind."))
        }
        return out
    }

    /// Ekipad's generic virtual pad (VID 1209, "Ekipad Pad N"): read by the game as a raw HID gamepad.
    static func isEkipad(_ h: HIDDevice) -> Bool { h.product.hasPrefix("Ekipad") || (h.vendor == 0x1209 && h.product.localizedCaseInsensitiveContains("ekipad")) }
    /// Ekipad numbers its buttons Switch-style (1 A, 2 B, 3 X, 4 Y, 5/6 L/R, 7/8 ZL/ZR, 9/10 stick clicks, 11 +, 12 -);
    /// nxnative's raw-pad default is 8BitDo's numbering, so the game gets this map while an Ekipad pad is connected
    /// (DM_HID_MAP applies to every raw pad; another raw pad at the same time would follow it too).
    static func ekipadEnvironment() -> [String: String] {
        guard hidDevices().contains(where: { $0.gamepad && isEkipad($0) }) else { return [:] }
        return ["DM_HID_MAP": "A=1,B=2,X=3,Y=4,L=5,R=6,ZL=7,ZR=8,LS=9,RS=10,PLUS=11,MINUS=12"]
    }

    static let remapURL = URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")!
    static let bluetoothURL = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
}

/// nxnative controller switches the launcher passes to the game as environment variables
/// (only when changed from nxnative's default, so the game's own defaults stand otherwise).
enum PadOptions {
    struct Option { let env: String, label: String, note: String, def: String }
    static let all: [Option] = [
        Option(env: "DM_SW2", label: "Switch 2 controllers",
               note: "Lets the game use Joy-Con 2 and Pro Controller 2 over Bluetooth. Start the game, then hold the controller's small Sync button until its lights sweep. After that, any button wakes it. macOS asks for Bluetooth access the first time.", def: "0"),
        Option(env: "DM_MOTION", label: "Motion controls",
               note: "Gyro aiming and tilt from a DualSense, DualShock 4 or Switch 2 controller, in games that use motion. Turn off if the camera drifts.", def: "1"),
        Option(env: "DM_PAD_IDENTICAL", label: "Same pads, own players",
               note: "Two identical controllers (like two Pro Controllers over USB) each get their own player. Off: macOS's single listing is used.", def: "1"),
        Option(env: "DM_PAD_MERGE", label: "All pads are player 1",
               note: "Any connected controller (and the keyboard) controls player 1. Handy for handing over or switching pads in a one-player game. Turns off Press a button to join.", def: "0")]
    static func key(_ env: String) -> String { "env.\(env)" }
    /// The switches to pass to the game, skipping any the game's own settings already cover.
    static func environment(skip: Set<String>) -> [String: String] {
        var e: [String: String] = [:]
        for o in all where !skip.contains(o.env) {
            guard let on = UserDefaults.standard.object(forKey: key(o.env)) as? Bool else { continue }
            let v = on ? "1" : "0"
            if v != o.def { e[o.env] = v }
        }
        return e
    }
}

// MARK: - Button tester

struct PadSnapshot {
    var name = "", labelled = false, count = 0
    var pressed: Set<String> = []
    var ls = CGPoint.zero, rs = CGPoint.zero
    var lt: Float = 0, rt: Float = 0
    var glyph: [String: String] = [:]   // Switch button → the pad's own SF Symbol for it
}

struct PadTestPanel: View {
    let t: Theme
    let close: () -> Void
    @State private var s = PadSnapshot()
    @State private var timer: Timer?
    @State private var holdStart: Date?
    @State private var hold: Double = 0
    func font(_ name: String, _ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .custom(name, size: size).weight(w) }

    static func read() -> PadSnapshot {
        var s = PadSnapshot()
        let pads = Pads.gamepads()
        s.count = pads.count
        guard let c = GCController.current.flatMap({ $0.extendedGamepad != nil ? $0 : nil }) ?? pads.first, let g = c.extendedGamepad else { return s }
        s.name = c.vendorName ?? c.productCategory
        s.labelled = Pads.labelled(c)
        var map: [(String, GCControllerButtonInput?)] = s.labelled
            ? [("A", g.buttonA), ("B", g.buttonB), ("X", g.buttonX), ("Y", g.buttonY)]
            : [("A", g.buttonB), ("B", g.buttonA), ("X", g.buttonY), ("Y", g.buttonX)]
        map += [("L", g.leftShoulder), ("R", g.rightShoulder), ("ZL", g.leftTrigger), ("ZR", g.rightTrigger),
                ("−", g.buttonOptions), ("+", g.buttonMenu), ("HOME", g.buttonHome),
                ("L3", g.leftThumbstickButton), ("R3", g.rightThumbstickButton),
                ("UP", g.dpad.up), ("DOWN", g.dpad.down), ("LEFT", g.dpad.left), ("RIGHT", g.dpad.right)]
        for (n, b) in map {
            guard let b else { continue }
            if b.isPressed { s.pressed.insert(n) }
            if let sym = b.sfSymbolsName { s.glyph[n] = sym }
        }
        s.ls = CGPoint(x: CGFloat(g.leftThumbstick.xAxis.value), y: CGFloat(g.leftThumbstick.yAxis.value))
        s.rs = CGPoint(x: CGFloat(g.rightThumbstick.xAxis.value), y: CGFloat(g.rightThumbstick.yAxis.value))
        s.lt = g.leftTrigger.value; s.rt = g.rightTrigger.value
        return s
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 20) {
                HStack {
                    Text("TEST BUTTONS").font(font(t.labelFont, 24, .heavy))
                    Spacer()
                    Image(systemName: "xmark").font(.system(size: 22, weight: .bold)).contentShape(Rectangle()).onTapGesture(perform: close)
                }
                if s.name.isEmpty {
                    Spacer()
                    Text("Connect a controller, then press any button.").font(font(t.bodyFont, 20, .semibold))
                    Text("Pads the game reads directly (marked \"direct\" in the list) don't show here, but still work in the game.")
                        .font(font(t.bodyFont, 14, .regular)).foregroundStyle(Color(hex: t.dim)).multilineTextAlignment(.center)
                    Spacer()
                } else {
                    Text(s.name + (s.count > 1 ? "  (the last one you pressed, of \(s.count))" : ""))
                        .font(font(t.bodyFont, 17, .semibold)).foregroundStyle(Color(hex: t.dim))
                    HStack(alignment: .top, spacing: 40) {
                        VStack(spacing: 14) {
                            HStack { trigger("ZL", s.lt); chip("L") }
                            diamond(top: "UP", left: "LEFT", right: "RIGHT", bottom: "DOWN", arrows: true)
                            stick("L3", s.ls)
                        }
                        VStack(spacing: 14) {
                            HStack(spacing: 10) { chip("−"); chip("HOME"); chip("+") }
                            Text(s.labelled ? "This pad's buttons match their labels."
                                            : "This pad works by position, like a Switch:\nright = A, bottom = B, top = X, left = Y.")
                                .font(font(t.bodyFont, 14, .regular)).foregroundStyle(Color(hex: t.dim)).multilineTextAlignment(.center)
                                .frame(width: 260)
                        }
                        VStack(spacing: 14) {
                            HStack { chip("R"); trigger("ZR", s.rt) }
                            diamond(top: "X", left: "Y", right: "A", bottom: "B", arrows: false)
                            stick("R3", s.rs)
                        }
                    }
                    Text("Big letters: the Switch button the game gets. Small icon: the button on your pad. Want a different layout? Use Remap buttons.")
                        .font(font(t.bodyFont, 13, .regular)).foregroundStyle(Color(hex: t.dim))
                }
                HStack {
                    Text(hold > 0 ? "Keep holding…" : "Close: hold your pad's back button for 2 seconds, or press Esc.")
                        .font(font(t.bodyFont, 13, .medium)).foregroundStyle(Color(hex: t.dim).opacity(0.8))
                    if hold > 0 { ProgressView(value: hold).frame(width: 120).tint(Color(hex: t.accent)) }
                }
            }
            .padding(30).frame(width: 980, height: 600)
            .background(Color(hex: t.panel).opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: t.border), lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 30)
        }
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
                s = PadTestPanel.read()
                // The pad's own back button (GameController's buttonB) held 2 s closes the tester.
                let back = Pads.gamepads().contains { $0.extendedGamepad?.buttonB.isPressed == true }
                if back { if holdStart == nil { holdStart = Date() } } else { holdStart = nil }
                hold = holdStart.map { min(1, Date().timeIntervalSince($0) / 2) } ?? 0
                if hold >= 1 { holdStart = nil; hold = 0; close() }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    func chip(_ n: String, wide: Bool = false) -> some View {
        let on = s.pressed.contains(n)
        return VStack(spacing: 2) {
            Text(n == "HOME" ? "⌂" : n).font(font(t.labelFont, n.count > 2 ? 14 : 20, .heavy))
            if let g = s.glyph[n], !["UP", "DOWN", "LEFT", "RIGHT"].contains(n) { Image(systemName: g).font(.system(size: 12, weight: .semibold)).opacity(0.85) }
        }
        .foregroundStyle(on ? Color(hex: t.accentText) : Color(hex: t.text))
        .frame(width: 62, height: 50)
        .background(RoundedRectangle(cornerRadius: 12).fill(on ? Color(hex: t.accent) : Color.black.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: t.border).opacity(on ? 1 : 0.4), lineWidth: 1.5))
    }

    func arrowChip(_ n: String) -> some View {
        let on = s.pressed.contains(n)
        let icon = ["UP": "arrowtriangle.up.fill", "DOWN": "arrowtriangle.down.fill", "LEFT": "arrowtriangle.left.fill", "RIGHT": "arrowtriangle.right.fill"][n] ?? "circle"
        return Image(systemName: icon).font(.system(size: 18, weight: .bold))
            .foregroundStyle(on ? Color(hex: t.accentText) : Color(hex: t.text))
            .frame(width: 50, height: 46)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color(hex: t.accent) : Color.black.opacity(0.3)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: t.border).opacity(on ? 1 : 0.4), lineWidth: 1.5))
    }

    @ViewBuilder func diamond(top: String, left: String, right: String, bottom: String, arrows: Bool) -> some View {
        VStack(spacing: 4) {
            if arrows { arrowChip(top) } else { chip(top) }
            HStack(spacing: arrows ? 50 : 62) {
                if arrows { arrowChip(left); arrowChip(right) } else { chip(left); chip(right) }
            }
            if arrows { arrowChip(bottom) } else { chip(bottom) }
        }
    }

    func trigger(_ n: String, _ v: Float) -> some View {
        let on = s.pressed.contains(n)
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3))
            RoundedRectangle(cornerRadius: 10).fill(Color(hex: t.accent).opacity(0.85)).frame(height: max(0, CGFloat(v)) * 50)
            Text(n).font(font(t.labelFont, 18, .heavy)).foregroundStyle(on ? Color(hex: t.accentText) : Color(hex: t.text)).padding(.bottom, 14)
        }
        .frame(width: 62, height: 50)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: t.border).opacity(on ? 1 : 0.4), lineWidth: 1.5))
    }

    func stick(_ press: String, _ p: CGPoint) -> some View {
        let on = s.pressed.contains(press), r: CGFloat = 46
        return ZStack {
            Circle().fill(Color.black.opacity(0.3))
            Circle().stroke(Color(hex: t.border).opacity(on ? 1 : 0.4), lineWidth: 1.5)
            Circle().fill(on ? Color(hex: t.accent) : Color(hex: t.text)).frame(width: 22, height: 22)
                .offset(x: p.x * (r - 12), y: -p.y * (r - 12))
            Text(press == "L3" ? "L" : "R").font(font(t.labelFont, 11, .heavy)).foregroundStyle(Color(hex: t.dim)).offset(y: r + 12)
        }
        .frame(width: r * 2, height: r * 2)
    }
}

// MARK: - Pairing help

struct PairHelpPanel: View {
    let t: Theme
    let close: () -> Void
    func font(_ name: String, _ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .custom(name, size: size).weight(w) }

    static let guides: [(String, String)] = [
        ("Xbox controller", "Hold the small pair button on top until the Xbox logo flashes quickly. Then, in System Settings → Bluetooth, click Connect next to it. Older Xbox One pads without Bluetooth (no plastic around the logo) work over USB only on some Macs."),
        ("PlayStation (DualSense, DualShock 4)", "Hold Create (or Share) and the PS button together until the light bar flashes, then click Connect in Bluetooth settings. Motion controls work with both."),
        ("Switch Pro Controller, Joy-Con", "Hold the small sync button until the lights run back and forth, then click Connect in Bluetooth settings. A Pro Controller also works over USB. Their buttons match their labels in games."),
        ("Switch 2 (Joy-Con 2, Pro Controller 2)", "They don't appear in Bluetooth settings. Turn on Switch 2 controllers in this tab, start the game, then hold the controller's Sync button until its lights sweep. After that, pressing any button connects it."),
        ("8BitDo", "Use Bluetooth: put the controller in its Switch or Bluetooth mode (see its manual), hold Pair for about 3 seconds, then click Connect in Bluetooth settings. The USB adapter's PC mode shows up on a Mac as a keyboard and mouse, so games can't use it."),
        ("Ekipad (iPhone as a controller)", "Open Ekipad Host on the Mac and Ekipad on the iPhone, and choose its virtual gamepad (the generic style, not keyboard). It shows up as Ekipad at the top of this tab, and the launcher sets its buttons for the game when you press Play."),
        ("Something not working?", "Check it here first: it should appear at the top of the Controls tab and light up in Test buttons. If buttons feel swapped, use Remap buttons (macOS's controller settings). To quit a game with a controller, hold its Home button for 2 seconds.")]

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("PAIRING HELP").font(font(t.labelFont, 24, .heavy))
                    Spacer()
                    Image(systemName: "xmark").font(.system(size: 22, weight: .bold)).contentShape(Rectangle()).onTapGesture(perform: close)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(PairHelpPanel.guides, id: \.0) { g in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(g.0.uppercased()).font(font(t.labelFont, 15, .heavy))
                                Text(g.1).font(font(t.bodyFont, 13.5, .regular)).foregroundStyle(Color(hex: t.dim)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                HStack(spacing: 14) {
                    Text("OPEN BLUETOOTH SETTINGS").font(font(t.menuFont, 19, .bold)).foregroundStyle(Color(hex: t.accentText))
                        .frame(maxWidth: .infinity).frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: t.accent), Color(hex: t.accent2 ?? t.accent)], startPoint: .leading, endPoint: .trailing)))
                        .contentShape(Rectangle()).onTapGesture { NSWorkspace.shared.open(Pads.bluetoothURL) }
                    Text("CLOSE").font(font(t.menuFont, 19, .bold)).frame(width: 150, height: 50)
                        .background(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: t.border), lineWidth: 1.5))
                        .contentShape(Rectangle()).onTapGesture(perform: close)
                }
                Text("A / Return: open Bluetooth settings   B / Esc: close").font(font(t.bodyFont, 12, .medium)).foregroundStyle(Color(hex: t.dim).opacity(0.7))
            }
            .padding(28).frame(width: 900, height: 620)
            .background(Color(hex: t.panel).opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: t.border), lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 30)
        }
    }
}
