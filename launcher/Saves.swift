// Saves, profiles, player name, cheats, mods, play time and the crash notice.
//
// Everything here works on nxnative's own files (docs/frontends.md), in the game's folder
// ~/Library/Application Support/nxnative/<title ID>:
//   save/ (+ save_device, save.users, save_userN)  the save; a profile's lives in profiles/<name>/save
//   launcher-backups/<profile>/<date>/               this launcher's backups (never nxnative's save-backups)
//   cheats/<build ID>.txt + .enabled, .cheats-off-<title ID>   Atmosphère cheat files and toggles
//   mods/<name>/ (romfs/ inside, or the files themselves)      passed as DM_ROMFS_OVERLAY
// The launcher only touches saves while the game isn't running.

import SwiftUI
import AppKit

// MARK: - Folders

extension Model {
    /// LAUNCHER_DATA_ROOT (self-tests only) stands in for ~/Library/Application Support/nxnative.
    var gameFolder: URL {
        (ENV["LAUNCHER_DATA_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/nxnative"))
            .appendingPathComponent(titleID)
    }
    var profilesFolder: URL { gameFolder.appendingPathComponent("profiles") }
    var backupsFolder: URL { gameFolder.appendingPathComponent("launcher-backups") }
    var cheatsFolder: URL { gameFolder.appendingPathComponent("cheats") }
    var modsFolder: URL { gameFolder.appendingPathComponent("mods") }

    /// "" is the main save; anything else is a folder in profiles/.
    var profile: String {
        let p = UserDefaults.standard.string(forKey: "profile") ?? ""
        return p.isEmpty || FileManager.default.fileExists(atPath: profilesFolder.appendingPathComponent(p).path) ? p : ""
    }
    var profileName: String { profile.isEmpty ? "Main" : profile }
    var activeSave: URL { profile.isEmpty ? gameFolder.appendingPathComponent("save") : profilesFolder.appendingPathComponent(profile).appendingPathComponent("save") }
    var profiles: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profilesFolder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var gameRunning: Bool { !bundleID.isEmpty && !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    static func safeName(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        return String(t.prefix(40))
    }
}

// MARK: - Save backups

struct SaveBackup { let url: URL, date: Date, reason: String }

extension Model {
    /// The items that make up a save at `save`: the folder itself, save_device, save.users, save_userN (never .work/.new/.sync/.pull/-backups).
    func saveItems(_ save: URL) -> [URL] {
        let dir = save.deletingLastPathComponent(), base = save.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0 == base || $0 == base + ".users" || ($0.hasPrefix(base + "_") && !$0.contains(".")) }
                    .map { dir.appendingPathComponent($0) }
    }

    func hasFiles(_ items: [URL]) -> Bool {
        items.contains { item in
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &dir) else { return false }
            if !dir.boolValue { return true }
            let e = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.isRegularFileKey])
            while let u = e?.nextObject() as? URL { if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { return true } }
            return false
        }
    }

    /// Sizes and dates of every file in the save: equal fingerprints mean nothing changed since that backup.
    func fingerprint(_ items: [URL]) -> String {
        var parts: [String] = []
        for item in items {
            let e = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            var list: [URL] = [item]
            while let u = e?.nextObject() as? URL { list.append(u) }
            for u in list {
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                parts.append("\(u.lastPathComponent)|\(v?.fileSize ?? -1)|\(Int(v?.contentModificationDate?.timeIntervalSince1970 ?? 0))")
            }
        }
        return parts.sorted().joined(separator: "\n")
    }

    var profileBackups: URL { backupsFolder.appendingPathComponent(profileName) }

    func backups() -> [SaveBackup] {
        let dir = profileBackups
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { n -> SaveBackup? in
            let u = dir.appendingPathComponent(n)
            guard let d = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return nil }
            let reason = (try? String(contentsOf: u.appendingPathComponent(".reason"), encoding: .utf8)) ?? ""
            return SaveBackup(url: u, date: d, reason: reason)
        }.sorted { $0.date > $1.date }
    }

    /// Copy (or, with `move`, move) the current save into a new backup. nil when there was nothing to back up
    /// or nothing changed since the last backup (unless `force`).
    @discardableResult
    func backupSave(reason: String, force: Bool = false, move: Bool = false) -> URL? {
        let items = saveItems(activeSave)
        guard hasFiles(items) else { return nil }   // an empty save folder (a new profile) has nothing to keep
        let fp = fingerprint(items)
        if !force, let last = backups().first, (try? String(contentsOf: last.url.appendingPathComponent(".fingerprint"), encoding: .utf8)) == fp { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        var dest = profileBackups.appendingPathComponent(f.string(from: Date())), n = 2
        while FileManager.default.fileExists(atPath: dest.path) { dest = profileBackups.appendingPathComponent(f.string(from: Date()) + " \(n)"); n += 1 }
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for item in items {
                let to = dest.appendingPathComponent(item.lastPathComponent)
                if move { try FileManager.default.moveItem(at: item, to: to) } else { try FileManager.default.copyItem(at: item, to: to) }   // APFS: a clone, instant
            }
            try fp.write(to: dest.appendingPathComponent(".fingerprint"), atomically: true, encoding: .utf8)
            try reason.write(to: dest.appendingPathComponent(".reason"), atomically: true, encoding: .utf8)
        } catch { status = "Couldn't back up the save: \(error.localizedDescription)"; return nil }
        // Keep the newest 10 of this launcher's own backups.
        for old in backups().dropFirst(10) { try? FileManager.default.removeItem(at: old.url) }
        return dest
    }

    /// Put a backup's save in place; the current one becomes a backup first. Returns an error message.
    func restore(_ b: SaveBackup) -> String? {
        if gameRunning { return "Quit the game first, then restore." }
        let current = saveItems(activeSave)
        if hasFiles(current) && backupSave(reason: "Before restoring", force: true, move: true) == nil { return status.isEmpty ? "Couldn't set the current save aside." : status }
        for empty in saveItems(activeSave) where !hasFiles([empty]) { try? FileManager.default.removeItem(at: empty) }   // only empty folders are left here
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: b.url.path)) ?? []).filter { !$0.hasPrefix(".") }
        do {
            try FileManager.default.createDirectory(at: activeSave.deletingLastPathComponent(), withIntermediateDirectories: true)
            for n in names { try FileManager.default.copyItem(at: b.url.appendingPathComponent(n), to: activeSave.deletingLastPathComponent().appendingPathComponent(n)) }
        } catch { return "Couldn't restore: \(error.localizedDescription). Your previous save is in the backups list." }
        return nil
    }

    /// Replace the save with a folder or .zip from another tool (JKSV, an emulator's export). The current save is backed up first.
    func importSave(from src: URL) -> String? {
        if gameRunning { return "Quit the game first, then import." }
        let fm = FileManager.default
        var root = src
        var tmp: URL?
        if src.pathExtension.lowercased() == "zip" {
            let t = fm.temporaryDirectory.appendingPathComponent("save-import-\(UUID().uuidString)")
            tmp = t
            let p = Tools.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", src.path, t.path])
            guard p.0 == 0 else { return "Couldn't open that zip file." }
            root = t
        }
        defer { if let tmp { try? fm.removeItem(at: tmp) } }
        // A single folder inside (as most exports have) is the save itself.
        var names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") && $0 != "__MACOSX" }
        while names.count == 1, (try? root.appendingPathComponent(names[0]).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              !(names[0].lowercased().hasSuffix(".bin")) {
            root = root.appendingPathComponent(names[0])
            names = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }
        }
        guard !names.isEmpty else { return "That folder is empty." }
        if hasFiles(saveItems(activeSave)) && backupSave(reason: "Before importing", force: true, move: true) == nil { return status.isEmpty ? "Couldn't set the current save aside." : status }
        for empty in saveItems(activeSave) where !hasFiles([empty]) { try? fm.removeItem(at: empty) }
        do {
            try fm.createDirectory(at: activeSave, withIntermediateDirectories: true)
            for n in names { try fm.copyItem(at: root.appendingPathComponent(n), to: activeSave.appendingPathComponent(n)) }
        } catch { return "Couldn't import: \(error.localizedDescription). Your previous save is in the backups list." }
        return nil
    }

    func chooseSaveToImport() {
        let p = NSOpenPanel()
        p.message = "Choose a save folder or .zip exported from another tool (like JKSV). Your current save is backed up first."
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowedContentTypes = [.zip, .folder]
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        confirm("IMPORT THIS SAVE?", "It replaces the save of profile \(profileName). The current save is backed up first, so you can restore it from the backups list.", ok: "IMPORT") { [weak self] in
            guard let self else { return }
            self.status = self.importSave(from: u) ?? "Save imported into profile \(self.profileName)."
            self.reloadRows()
        }
    }

    func showBackups() {
        let list = backups()
        guard !list.isEmpty else { notice("NO BACKUPS YET", "A backup is made before each Play (when the save changed), or choose Back up now."); return }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        listPanel = ListSpec(title: "RESTORE A BACKUP", note: "Profile \(profileName). The current save is backed up before it's replaced.",
                             items: list.map { (f.string(from: $0.date), $0.reason) }) { [weak self] i in
            guard let self else { return }
            let b = list[i]
            self.confirm("RESTORE THIS BACKUP?", "\(f.string(from: b.date)) replaces the save of profile \(self.profileName). The current save is backed up first.", ok: "RESTORE") {
                self.status = self.restore(b) ?? "Backup from \(f.string(from: b.date)) restored."
            }
        }
        requestPanel = "LIST"
    }
}

// MARK: - Profiles and player name

extension Model {
    func newProfile() {
        guard let name = prompt("New save profile", "A name for it (for example a person's name). Each profile keeps its own save.", "").map(Model.safeName), !name.isEmpty else { return }
        guard name.lowercased() != "main", !profiles.contains(name) else { status = "There's already a profile named \(name)."; return }
        let save = profilesFolder.appendingPathComponent(name).appendingPathComponent("save")
        do { try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true) } catch { status = "Couldn't make the profile: \(error.localizedDescription)"; return }
        let copy = hasFiles(saveItems(activeSave))
        let finish: (Bool) -> Void = { [weak self] withCopy in
            guard let self else { return }
            if withCopy, let items = Optional(self.saveItems(self.activeSave)) {
                try? FileManager.default.removeItem(at: save)
                for item in items { try? FileManager.default.copyItem(at: item, to: save.deletingLastPathComponent().appendingPathComponent(item.lastPathComponent)) }
            }
            UserDefaults.standard.set(name, forKey: "profile")
            self.status = "Profile \(name) made and chosen. " + (withCopy ? "It starts from a copy of the save." : "The game starts a new save in it.")
            self.reloadRows()
        }
        if copy {
            message = MessageSpec(title: "START \(name.uppercased()) FROM…", text: "A new, empty save, or a copy of profile \(profileName)'s save?",
                                  buttons: [("EMPTY SAVE", { finish(false) }), ("COPY OF \(profileName.uppercased())", { finish(true) })])
            requestPanel = "MESSAGE"
        } else { finish(false) }
    }

    /// The profile's environment: its own save, the shared shader list, and no cloud sync (cloud saves keep one save per game).
    func profileEnvironment() -> [String: String] {
        guard !profile.isEmpty else { return [:] }
        return ["DM_SAVE": activeSave.path, "DM_PSO_USER": gameFolder.appendingPathComponent("pso_user.tsv").path, "DM_SAVE_SYNC": "0"]
    }

    func prompt(_ title: String, _ text: String, _ value: String, limit: Int = 40) -> String? {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = value
        a.accessoryView = field; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    func chooseCloudFolder() {
        let p = NSOpenPanel()
        p.message = "Choose a folder in iCloud Drive (or any synced folder). Use the same folder on your other Mac or iPhone; each game keeps one file there."
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        setGamePref("cloudSaves.folder", u.path as CFString)
        status = "Cloud saves on, through \(Model.folderLabel(u.path)). If both saves changed, the game asks which to keep."
        reloadRows()
    }
    func cloudFolder() -> String { (CFPreferencesCopyAppValue("cloudSaves.folder" as CFString, bundleID as CFString) as? String) ?? "" }
    func setGamePref(_ key: String, _ value: CFPropertyList?) {
        guard !bundleID.isEmpty else { return }
        CFPreferencesSetAppValue(key as CFString, value, bundleID as CFString); CFPreferencesAppSynchronize(bundleID as CFString)
    }

    /// The launcher is the game's only menu: nxnative's own window stays off (its "Show this window at launch"),
    /// but its cloud-save question still comes when both saves changed. Older launchers used DM_LAUNCHER=0 in env.txt,
    /// which skipped that question too, so that line goes.
    func quietGameWindow() {
        setGamePref("window.show", kCFBooleanFalse)
        let env = gameFolder.appendingPathComponent("env.txt")
        guard let text = try? String(contentsOf: env, encoding: .utf8), text.contains("DM_LAUNCHER=0") else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.trimmingCharacters(in: .whitespaces) != "DM_LAUNCHER=0" }
        try? kept.joined(separator: "\n").write(to: env, atomically: true, encoding: .utf8)
    }
}

// MARK: - Cheats

struct Cheat { let name: String, label: String }

extension Model {
    /// The game's build ID (cheat files are named after it), learned from its log.
    var buildID: String {
        if let b = UserDefaults.standard.string(forKey: "buildID.\(version)"), !b.isEmpty { return b }
        let logs = [logFile, logFile.deletingPathExtension().appendingPathExtension("prev.log")]
        for l in logs {
            guard let text = try? String(contentsOf: l, encoding: .utf8) else { continue }
            if let r = text.range(of: "build ([0-9A-F]{16})", options: .regularExpression) {
                let b = String(text[r].suffix(16)); UserDefaults.standard.set(b, forKey: "buildID.\(version)"); return b
            }
        }
        return ""
    }
    var cheatFile: URL? {
        let b = buildID
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cheatsFolder.path)) ?? []).filter { $0.lowercased().hasSuffix(".txt") }
        if !b.isEmpty, let n = names.first(where: { $0.uppercased() == b + ".TXT" }) { return cheatsFolder.appendingPathComponent(n) }
        if b.isEmpty && names.count == 1 { return cheatsFolder.appendingPathComponent(names[0]) }
        return nil
    }
    var cheatsOffFlag: URL { cheatsFolder.appendingPathComponent(".cheats-off-\(titleID)") }

    /// The toggleable cheats of a file: [Name] entries with code under them, duplicates as "Name #2" (masters {..} always run).
    func cheats(in file: URL) -> [Cheat] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var out: [Cheat] = [], seen: [String: Int] = [:], current: String?, hasCode = false
        func close() { if let c = current, hasCode { let k = (seen[c] ?? 0) + 1; seen[c] = k; out.append(Cheat(name: k > 1 ? "\(c) #\(k)" : c, label: c)) } }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") { close(); current = String(line.dropFirst().dropLast()); hasCode = false }
            else if line.hasPrefix("{") { close(); current = nil }
            else if !line.isEmpty, line.first?.isHexDigit == true { hasCode = true }
        }
        close()
        return out
    }
    func enabledCheats(_ file: URL) -> Set<String> {
        let t = (try? String(contentsOf: file.deletingPathExtension().appendingPathExtension("enabled"), encoding: .utf8)) ?? ""
        return Set(t.split(whereSeparator: \.isNewline).map { String($0) })
    }
    func setCheat(_ name: String, on: Bool, file: URL) {
        var set = enabledCheats(file)
        if on { set.insert(name) } else { set.remove(name) }
        let order = cheats(in: file).map(\.name).filter { set.contains($0) }
        try? (order.joined(separator: "\n") + (order.isEmpty ? "" : "\n")).write(to: file.deletingPathExtension().appendingPathExtension("enabled"), atomically: true, encoding: .utf8)
    }

    func importCheats() {
        let p = NSOpenPanel()
        p.message = "Choose a cheat file (.txt, Atmosphère format). Files from cheat sites are named after the game's build ID."
        p.allowedContentTypes = [.plainText]; p.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        let stem = u.deletingPathExtension().lastPathComponent.uppercased()
        let isBuild = stem.count == 16 && stem.allSatisfy(\.isHexDigit)
        let name = isBuild ? stem : (buildID.isEmpty ? u.deletingPathExtension().lastPathComponent : buildID)
        do {
            try FileManager.default.createDirectory(at: cheatsFolder, withIntermediateDirectories: true)
            let dest = cheatsFolder.appendingPathComponent(name + ".txt")
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: u, to: dest)
        } catch { status = "Couldn't add the cheats: \(error.localizedDescription)"; return }
        let b = buildID
        status = isBuild && !b.isEmpty && stem != b ? "Added, but this file is for build \(stem) and your game is \(b): its cheats won't run." : "Cheats added. Turn on the ones you want, then play."
        reloadRows()
    }

    func cheatRows() -> [Row] {
        var r: [Row] = []
        guard !titleID.isEmpty else { return r }
        let off = FileManager.default.fileExists(atPath: cheatsOffFlag.path)
        if let f = cheatFile {
            let list = cheats(in: f), on = enabledCheats(f)
            r.append(Row(id: "cheatsMaster", label: "Cheats", note: "Turns every cheat of this game on or off, keeping your choices below. Changes apply at the next Play.", tab: "MODS",
                         kind: .toggle(on: "1", off: "0"), def: "1", game: false, apply: { [weak self] v in
                guard let self else { return }
                if v == "1" { try? FileManager.default.removeItem(at: self.cheatsOffFlag) }
                else { try? FileManager.default.createDirectory(at: self.cheatsFolder, withIntermediateDirectories: true); FileManager.default.createFile(atPath: self.cheatsOffFlag.path, contents: nil) }
            }))
            values["cheatsMaster"] = off ? "0" : "1"
            for (i, c) in list.enumerated() {
                let id = "cheat\(i)"
                r.append(Row(id: id, label: c.name, note: "A cheat from \(f.lastPathComponent). Applies at the next Play. Cheats can break saves: back up first.", tab: "MODS",
                             kind: .toggle(on: "1", off: "0"), def: "0", game: false, apply: { [weak self] v in self?.setCheat(c.name, on: v == "1", file: f) }))
                values[id] = on.contains(c.name) ? "1" : "0"
            }
            if FileManager.default.fileExists(atPath: cheatsFolder.appendingPathComponent(".cheats-running-\(titleID)").path) && !gameRunning {
                r.append(Row(id: "cheatsSafe", label: "Safe mode", note: "The game crashed last time with cheats on, so the next start runs with every cheat off. Turn them back on in the game's Cheats menu, or here.", tab: "MODS", kind: .info, def: "", game: false))
                values["cheatsSafe"] = "after a crash"
            }
        }
        r.append(Row(id: "cheatsImport", label: "Add a cheat file", note: buildID.isEmpty
                        ? "Atmosphère-format .txt. Play the game once first, so the launcher learns which version you have."
                        : "Atmosphère-format .txt for build \(buildID) (cheat files are named after it).", tab: "MODS", kind: .action { [weak self] in self?.importCheats() }, def: "", game: false))
        return r
    }
}

// MARK: - Mods (file replacements through DM_ROMFS_OVERLAY)

extension Model {
    var mods: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: modsFolder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    var enabledMods: Set<String> { Set(UserDefaults.standard.stringArray(forKey: "mods.enabled") ?? []) }

    /// The folder whose files replace the game's: romfs/ inside the mod, an Atmosphère tree, or the mod folder itself.
    func modRoot(_ name: String) -> URL {
        let m = modsFolder.appendingPathComponent(name), fm = FileManager.default
        for c in ["romfs", "atmosphere/contents/\(titleID)/romfs", "contents/\(titleID)/romfs", "\(titleID)/romfs"] {
            let u = m.appendingPathComponent(c); if fm.fileExists(atPath: u.path) { return u }
        }
        return m
    }
    func modHasCode(_ name: String) -> Bool {
        let fm = FileManager.default, m = modsFolder.appendingPathComponent(name)
        return ["exefs", "atmosphere/contents/\(titleID)/exefs", "contents/\(titleID)/exefs", "\(titleID)/exefs"].contains { fm.fileExists(atPath: m.appendingPathComponent($0).path) }
    }
    func modEnvironment() -> [String: String] {
        let on = enabledMods
        let roots = mods.filter { on.contains($0) }.map { modRoot($0).path }.filter { !$0.contains(":") }
        return roots.isEmpty ? [:] : ["DM_ROMFS_OVERLAY": roots.joined(separator: ":")]
    }

    func importMod() {
        let p = NSOpenPanel()
        p.message = "Choose a mod folder or .zip. Mods that replace game files work; code mods (exefs) don't."
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowedContentTypes = [.zip, .folder]
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        let name = Model.safeName(u.deletingPathExtension().lastPathComponent)
        let dest = modsFolder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: modsFolder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            if u.pathExtension.lowercased() == "zip" {
                guard Tools.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", u.path, dest.path]).0 == 0 else { status = "Couldn't open that zip file."; return }
                try? FileManager.default.removeItem(at: dest.appendingPathComponent("__MACOSX"))
                // A zip holding one folder: use what's inside.
                let inner = ((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []).filter { !$0.hasPrefix(".") }
                if inner.count == 1, inner[0] != "romfs", inner[0] != "atmosphere", inner[0] != "contents",
                   (try? dest.appendingPathComponent(inner[0]).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    let tmp = modsFolder.appendingPathComponent(".tmp-\(UUID().uuidString)")
                    try FileManager.default.moveItem(at: dest.appendingPathComponent(inner[0]), to: tmp)
                    try FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: tmp, to: dest)
                }
            } else { try FileManager.default.copyItem(at: u, to: dest) }
        } catch { status = "Couldn't add the mod: \(error.localizedDescription)"; return }
        var on = enabledMods; on.insert(name); UserDefaults.standard.set(Array(on), forKey: "mods.enabled")
        status = modHasCode(name) ? "Added \(name). It also has code changes (exefs), which nxnative can't load; only its file changes are used."
                                  : "Added and turned on \(name). It applies at the next Play."
        reloadRows()
    }

    func modRows() -> [Row] {
        guard !titleID.isEmpty else { return [] }
        let on = enabledMods
        var r: [Row] = mods.enumerated().map { i, name in
            let id = "mod\(i)"
            values[id] = on.contains(name) ? "1" : "0"
            let code = modHasCode(name) ? " It also has code changes (exefs), which nxnative can't load." : ""
            return Row(id: id, label: name, note: "A mod in your game's mods folder. When two mods change the same file, the one higher in this list wins.\(code) Mods that need new shaders may not work.",
                       tab: "MODS", kind: .toggle(on: "1", off: "0"), def: "0", game: false, apply: { v in
                var s = Set(UserDefaults.standard.stringArray(forKey: "mods.enabled") ?? [])
                if v == "1" { s.insert(name) } else { s.remove(name) }
                UserDefaults.standard.set(Array(s), forKey: "mods.enabled")
            })
        }
        r.append(Row(id: "modImport", label: "Add a mod", note: "A folder or .zip of replacement files (a romfs folder, or an Atmosphère layout). It's copied into the game's mods folder.", tab: "MODS", kind: .action { [weak self] in self?.importMod() }, def: "", game: false))
        r.append(Row(id: "modOpen", label: "Open mods folder", note: "Each folder in it is one mod. Delete a folder to remove that mod.", tab: "MODS", kind: .action { [weak self] in
            guard let self else { return }
            try? FileManager.default.createDirectory(at: self.modsFolder, withIntermediateDirectories: true); NSWorkspace.shared.open(self.modsFolder) }, def: "", game: false))
        return r
    }
}

// MARK: - Play time and the crash notice

extension Model {
    var totalPlay: Double { UserDefaults.standard.double(forKey: "playSeconds") }
    var lastPlayed: Date? { UserDefaults.standard.object(forKey: "lastPlayed") as? Date }
    static func duration(_ s: Double) -> String {
        let m = Int(s / 60), h = m / 60
        return h > 0 ? "\(h) h \(m % 60) min" : m > 0 ? "\(m) min" : s > 0 ? "under a minute" : "not yet"
    }

    /// The game's exit code, from the last line its launcher writes to the log ("launcher: the host exited with N").
    func exitCode(since start: Date) -> Int? {
        guard let d = (try? logFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d >= start.addingTimeInterval(-2),
              let h = try? FileHandle(forReadingFrom: logFile) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 8192 ? size - 8192 : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        guard let r = tail.range(of: "the host exited with -?[0-9]+", options: [.regularExpression, .backwards]) else { return nil }
        return Int(tail[r].split(separator: " ").last ?? "")
    }

    /// Called when the game app ends: count the time, say so if it crashed, come back (or quit).
    func gameEnded(started: Date) {
        let secs = Date().timeIntervalSince(started)
        UserDefaults.standard.set(totalPlay + secs, forKey: "playSeconds")
        UserDefaults.standard.set(Date(), forKey: "lastPlayed")
        let code = exitCode(since: started)
        let crashed = code.map { $0 != 0 } ?? false
        if !crashed && UserDefaults.standard.string(forKey: "afterGame") == "quit" { NSApp.terminate(nil); return }
        NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
        audio.fade(to: audio.musicOn ? audio.musicVolume : 0, over: 1.0)
        reloadRows()
        status = "Played \(Model.duration(secs)). Total: \(Model.duration(totalPlay))."
        if crashed, let code {
            let why: String
            switch code {
            case 70: why = "macOS stopped the game's graphics work. This can happen after the Mac sleeps, or when it runs low on memory. Your last in-game save is safe."
            case 134: why = "The game stopped with an error (code 134). Progress since your last in-game save is lost."
            default: why = "The game closed unexpectedly (code \(code)). Progress since your last in-game save is lost."
            }
            message = MessageSpec(title: "THE GAME STOPPED", text: why + " The log has the details, useful for a bug report.",
                                  buttons: [("OPEN LOG", { [weak self] in if let s = self { NSWorkspace.shared.open(s.logFile) } }), ("OK", {})])
            requestPanel = "MESSAGE"
        }
    }
}

// MARK: - Controller-friendly list and message panels

struct ListSpec { let title: String, note: String, items: [(String, String)], choose: (Int) -> Void }
struct MessageSpec { let title: String, text: String, buttons: [(String, () -> Void)] }

extension Model {
    func confirm(_ title: String, _ text: String, ok: String, _ go: @escaping () -> Void) {
        message = MessageSpec(title: title, text: text, buttons: [(ok, go), ("CANCEL", {})]); requestPanel = "MESSAGE"
    }
    func notice(_ title: String, _ text: String) { message = MessageSpec(title: title, text: text, buttons: [("OK", {})]); requestPanel = "MESSAGE" }
}

struct ListPanel: View {
    let t: Theme
    let spec: ListSpec
    @Binding var index: Int
    let choose: (Int) -> Void
    let close: () -> Void
    func font(_ name: String, _ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .custom(name, size: size).weight(w) }
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(spec.title).font(font(t.labelFont, 24, .heavy)); Spacer()
                    Image(systemName: "xmark").font(.system(size: 22, weight: .bold)).contentShape(Rectangle()).onTapGesture(perform: close)
                }
                Text(spec.note).font(font(t.bodyFont, 15, .regular)).foregroundStyle(Color(hex: t.dim))
                ScrollViewReader { sv in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(spec.items.enumerated()), id: \.offset) { i, it in
                                HStack {
                                    Text(it.0).font(font(t.labelFont, 19, .semibold)); Spacer()
                                    Text(it.1).font(font(t.bodyFont, 15, .regular)).foregroundStyle(Color(hex: t.dim))
                                }
                                .padding(.horizontal, 20).frame(height: 48)
                                .background(RoundedRectangle(cornerRadius: 12).fill(i == index ? Color(hex: t.border).opacity(0.22) : Color.black.opacity(0.25)))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: t.border).opacity(i == index ? 0.95 : 0.35), lineWidth: i == index ? 2 : 1))
                                .contentShape(Rectangle()).id(i)
                                .onHover { h in if h { index = i } }
                                .onTapGesture { index = i; choose(i) }
                            }
                        }
                    }
                    .onChange(of: index) { _, i in withAnimation { sv.scrollTo(i) } }
                }
                Text("↑↓ choose   A / Return pick   B / Esc back").font(font(t.bodyFont, 12, .medium)).foregroundStyle(Color(hex: t.dim).opacity(0.7))
            }
            .padding(30).frame(width: 760, height: 560)
            .background(Color(hex: t.panel).opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: t.border), lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 30)
        }
    }
}

struct MessagePanel: View {
    let t: Theme
    let spec: MessageSpec
    @Binding var index: Int
    let press: (Int) -> Void
    func font(_ name: String, _ size: CGFloat, _ w: Font.Weight = .bold) -> Font { .custom(name, size: size).weight(w) }
    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(alignment: .leading, spacing: 18) {
                Text(spec.title).font(font(t.labelFont, 22, .heavy))
                Text(spec.text).font(font(t.bodyFont, 17, .regular)).foregroundStyle(Color(hex: t.dim)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    ForEach(Array(spec.buttons.enumerated()), id: \.offset) { i, b in
                        Text(b.0).font(font(t.menuFont, 19, .bold))
                            .foregroundStyle(i == index ? Color(hex: t.accentText) : Color(hex: t.text))
                            .frame(maxWidth: .infinity).frame(height: 52)
                            .background(RoundedRectangle(cornerRadius: 12).fill(i == index
                                ? AnyShapeStyle(LinearGradient(colors: [Color(hex: t.accent), Color(hex: t.accent2 ?? t.accent)], startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Color.black.opacity(0.25))))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: t.border), lineWidth: 1.5))
                            .contentShape(Rectangle())
                            .onHover { h in if h { index = i } }
                            .onTapGesture { press(i) }
                    }
                }
            }
            .padding(34).frame(width: 660)
            .background(Color(hex: t.panel).opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color(hex: t.border), lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 30)
        }
    }
}

// MARK: - Keep the game inside out of Apple's Games app

extension Model {
    /// The nxnative app inside this launcher (Contents/Game) carries the games category, so macOS lists it in the
    /// Games app next to the launcher once it has run. Move the category aside (DMOriginalCategory) and re-sign it ad hoc,
    /// once, in the background; Play waits for it.
    func tuckGameIfNeeded() {
        guard let g = gameURL, g.path.hasPrefix(embeddedGameFolder.path) else { return }
        let plist = g.appendingPathComponent("Contents/Info.plist")
        guard let d = NSMutableDictionary(contentsOf: plist), let cat = d["LSApplicationCategoryType"] as? String else { return }
        tucking = true
        DispatchQueue.global(qos: .utility).async {
            d.removeObject(forKey: "LSApplicationCategoryType"); d["DMOriginalCategory"] = cat
            if d.write(to: plist, atomically: true) {
                _ = Tools.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", g.path])
                _ = Tools.run(URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"), ["-u", g.path])
            }
            DispatchQueue.main.async { self.tucking = false }
        }
    }
}

// MARK: - Self-test (LAUNCHER_SELFTEST=saves with LAUNCHER_DATA_ROOT=<scratch folder>): runs the file logic, prints PASS/FAIL, quits

extension Model {
    func selfTestSaves() {
        guard let root = ENV["LAUNCHER_DATA_ROOT"], !titleID.isEmpty else { print("FAIL needs LAUNCHER_DATA_ROOT and a game"); exit(2) }
        let fm = FileManager.default, ud = UserDefaults.standard
        var fails = 0
        func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { fails += 1 } }
        func write(_ u: URL, _ t: String) { try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try? t.write(to: u, atomically: true, encoding: .utf8) }
        func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "<none>" }
        try? fm.removeItem(at: URL(fileURLWithPath: root).appendingPathComponent(titleID))
        for k in ["profile", "mods.enabled", "buildID.\(version)", "playerName"] { ud.removeObject(forKey: k) }

        let save = activeSave
        write(save.appendingPathComponent("a.bin"), "v1"); write(save.deletingLastPathComponent().appendingPathComponent("save_device/d.bin"), "dev")
        check(backupSave(reason: "t1") != nil, "first backup made")
        check(backupSave(reason: "t2") == nil, "unchanged save not backed up again")
        Thread.sleep(forTimeInterval: 1.1)
        write(save.appendingPathComponent("a.bin"), "v2")
        check(backupSave(reason: "t3") != nil && backups().count == 2, "changed save backed up (2 backups)")
        check(fm.fileExists(atPath: backups()[0].url.appendingPathComponent("save_device/d.bin").path), "device save included")
        let oldest = backups().last!
        Thread.sleep(forTimeInterval: 1.1)
        check(restore(oldest) == nil && read(save.appendingPathComponent("a.bin")) == "v1", "restore brings back v1")
        check(backups().count == 3 && backups()[0].reason == "Before restoring", "current save kept before restoring")
        let src = URL(fileURLWithPath: root).appendingPathComponent("import-src/Export 2026/b.bin")
        write(src, "imported")
        Thread.sleep(forTimeInterval: 1.1)
        check(importSave(from: src.deletingLastPathComponent().deletingLastPathComponent()) == nil, "import ran")
        check(read(save.appendingPathComponent("b.bin")) == "imported" && !fm.fileExists(atPath: save.appendingPathComponent("a.bin").path), "imported save replaced the old one")
        for i in 0..<12 { write(save.appendingPathComponent("n.bin"), "\(i)"); backupSave(reason: "loop", force: true); Thread.sleep(forTimeInterval: 1.05) }
        check(backups().count == 10, "only the newest 10 backups kept (\(backups().count))")

        ud.set("ABCDEF0123456789", forKey: "buildID.\(version)")
        write(cheatsFolder.appendingPathComponent("ABCDEF0123456789.txt"), "[Inf HP]\n04000000 0011 00000001\n\n{Master}\n04000000 0022 1\n[Section label]\n\n[Inf HP]\n04000000 0033 2\n[Money]\n04000000 0044 3\n")
        let f = cheatFile
        check(f != nil, "cheat file found by build ID")
        if let f {
            let names = cheats(in: f).map(\.name)
            check(names == ["Inf HP", "Inf HP #2", "Money"], "cheats parsed: \(names)")
            setCheat("Money", on: true, file: f); setCheat("Inf HP", on: true, file: f); setCheat("Money", on: false, file: f)
            check(read(f.deletingPathExtension().appendingPathExtension("enabled")) == "Inf HP\n", ".enabled written")
        }

        write(modsFolder.appendingPathComponent("Mod A/romfs/x.txt"), "x"); write(modsFolder.appendingPathComponent("Mod B/y.txt"), "y")
        write(modsFolder.appendingPathComponent("Mod C/atmosphere/contents/\(titleID)/romfs/z.txt"), "z")
        ud.set(["Mod A", "Mod B", "Mod C"], forKey: "mods.enabled")
        let ov = modEnvironment()["DM_ROMFS_OVERLAY"] ?? ""
        check(ov == [modsFolder.appendingPathComponent("Mod A/romfs").path, modsFolder.appendingPathComponent("Mod B").path,
                     modsFolder.appendingPathComponent("Mod C/atmosphere/contents/\(titleID)/romfs").path].joined(separator: ":"), "mod overlay: \(ov)")

        try? fm.createDirectory(at: profilesFolder.appendingPathComponent("Sam/save"), withIntermediateDirectories: true)
        ud.set("Sam", forKey: "profile")
        let pe = profileEnvironment()
        check(pe["DM_SAVE"] == profilesFolder.appendingPathComponent("Sam/save").path && pe["DM_SAVE_SYNC"] == "0", "profile environment")
        check(!hasFiles(saveItems(activeSave)) && backupSave(reason: "x") == nil, "empty profile has nothing to back up")
        if let b = { ud.set("", forKey: "profile"); return backups().first }() {
            ud.set("Sam", forKey: "profile")
            try? fm.createDirectory(at: profileBackups.appendingPathComponent("x"), withIntermediateDirectories: true)
            try? fm.removeItem(at: profileBackups.appendingPathComponent("x"))
            check(restore(b) == nil && hasFiles(saveItems(activeSave)), "restore into an empty profile")
        }
        ud.set("Ghost", forKey: "profile")
        check(profile == "", "missing profile falls back to Main")

        for k in ["profile", "mods.enabled", "buildID.\(version)", "playerName"] { ud.removeObject(forKey: k) }
        print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
        exit(fails == 0 ? 0 : 1)
    }
}
