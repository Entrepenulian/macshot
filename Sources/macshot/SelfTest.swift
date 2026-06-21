import Foundation
import AppKit

/// Deterministic, side-effect-free checks of the filing + detection logic.
/// Run with:  swift run macshot --selftest
enum SelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ cond: Bool, _ msg: String) {
            print((cond ? "  ✓ " : "  ✗ ") + msg); if !cond { ok = false }
        }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("macshot-selftest-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        print("FolderStore")
        let key = "macshotSelfTest-\(UUID().uuidString)"
        let store = FolderStore(root: tmp, defaultsKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        check(store.savedFolders().isEmpty, "starts with zero saved folders (no Desktop enumeration)")
        check(store.desktopFolder().isRoot && store.desktopFolder().name == "Desktop", "Desktop baseline is present")

        let shot = tmp.appendingPathComponent("Screenshot 2026-06-20.png")
        fm.createFile(atPath: shot.path, contents: Data([0x89, 0x50, 0x4E, 0x47]))

        let receipts = try? store.createFolder(named: "Receipts")
        check(receipts != nil && fm.fileExists(atPath: receipts!.path), "createFolder makes the directory")
        check(store.savedFolders().contains { $0.name == "Receipts" }, "created folder is remembered")

        if let r = receipts {
            let dest = try? store.move(shot, into: r, baseName: "My Receipt")
            check(dest != nil && fm.fileExists(atPath: dest!.path), "moves the file into the folder")
            check(!fm.fileExists(atPath: shot.path), "removes the source from the Desktop root")
            check(dest?.lastPathComponent == "My Receipt.png", "applies the rename → \(dest?.lastPathComponent ?? "nil")")
        }

        _ = try? store.createFolder(named: "Taxes 2026")
        check(store.savedFolders().first?.name == "Taxes 2026",
              "most-recent folder is first → \(store.savedFolders().map { $0.name })")

        let a = tmp.appendingPathComponent("dup-a.png"); fm.createFile(atPath: a.path, contents: Data([1]))
        let b = tmp.appendingPathComponent("dup-b.png"); fm.createFile(atPath: b.path, contents: Data([2]))
        if let r = receipts {
            let d1 = try? store.move(a, into: r, baseName: "same")
            let d2 = try? store.move(b, into: r, baseName: "same")
            check(d1?.lastPathComponent == "same.png" && d2?.lastPathComponent == "same 2.png",
                  "resolves name collisions → \(d2?.lastPathComponent ?? "nil")")
        }

        // quick-save recents: every save target (incl. Desktop) is recorded, newest first, distinct
        check(store.recentFolders().isEmpty, "recents start empty")
        store.rememberSave(store.desktopFolder())
        if let r = receipts { store.rememberSave(Folder(id: r.path, name: "Receipts", url: r, count: 0)) }
        store.rememberSave(store.desktopFolder())   // re-saving bumps to front, no duplicate
        let recents = store.recentFolders()
        check(recents.count == 2, "recents are distinct → \(recents.map { $0.name })")
        check(recents.first?.name == "Desktop", "most-recent save is first → \(recents.first?.name ?? "nil")")
        check(store.recentFolders(max: 1).count == 1, "recents respect the max")

        let tinyImg = NSImage(size: NSSize(width: 4, height: 4))
        let qsEmpty = ShotModel(image: tinyImg, fileName: "x", ext: "png",
                                folders: [store.desktopFolder()], recentFolders: [])
        check(qsEmpty.quickFolders.count == 1 && qsEmpty.quickFolders.first?.isRoot == true,
              "quick-save falls back to Desktop when there are no recents")
        let qsRecent = ShotModel(image: tinyImg, fileName: "x", ext: "png",
                                 folders: [store.desktopFolder()], recentFolders: recents)
        check(qsRecent.quickFolders.count == 2, "quick-save shows the recents → \(qsRecent.quickFolders.count)")

        // delete: the corner trash button moves the screenshot out of its folder (to Trash)
        let toDelete = tmp.appendingPathComponent("Screenshot to delete.png")
        fm.createFile(atPath: toDelete.path, contents: Data([1, 2, 3]))
        var trashed: NSURL?
        let didTrash = (try? fm.trashItem(at: toDelete, resultingItemURL: &trashed)) != nil
        check(didTrash && !fm.fileExists(atPath: toDelete.path), "delete moves the screenshot out of its folder")
        if let t = trashed as URL? { try? fm.removeItem(at: t) }    // clean up the trashed test file

        print("PinStore")
        let pinStore = PinStore(root: tmp.appendingPathComponent("pinroot"))
        let pa = tmp.appendingPathComponent("Pin A.png"); fm.createFile(atPath: pa.path, contents: Data([1, 2, 3]))
        let pb = tmp.appendingPathComponent("Pin B.png"); fm.createFile(atPath: pb.path, contents: Data([4, 5, 6]))
        check(pinStore.pins().isEmpty, "pin store starts empty")
        let pinnedA = pinStore.pin(pa)
        _ = pinStore.pin(pb)
        check(pinStore.pins().count == 2, "pinning keeps copies → \(pinStore.pins().count)")
        check(fm.fileExists(atPath: pa.path), "the original screenshot is left in place after pinning")
        if let pinnedA {
            pinStore.unpin(pinnedA)
            if let trashDir = try? fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                for item in (try? fm.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil)) ?? []
                where item.lastPathComponent.hasPrefix("Pin A") { try? fm.removeItem(at: item) }
            }
        }
        check(pinStore.pins().count == 1, "unpin removes a pin → \(pinStore.pins().count)")

        print("ScreenshotWatcher")
        let watchDir = tmp.appendingPathComponent("watch")
        try? fm.createDirectory(at: watchDir, withIntermediateDirectories: true)
        let watcher = ScreenshotWatcher(directory: watchDir)
        var detected: [String] = []
        var createdAt: Date?
        var latencyMs = -1.0
        watcher.onNewScreenshot = { url in
            detected.append(url.lastPathComponent)
            if url.lastPathComponent == "Screenshot live.png", let c = createdAt, latencyMs < 0 {
                latencyMs = Date().timeIntervalSince(c) * 1000
            }
        }
        watcher.start()
        let pngComplete = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
                                0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])  // PNG header + IEND
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            createdAt = Date()
            fm.createFile(atPath: watchDir.appendingPathComponent("Screenshot live.png").path, contents: pngComplete)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            fm.createFile(atPath: watchDir.appendingPathComponent("random-photo.png").path, contents: pngComplete)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(1.6))
        watcher.stop()
        check(detected.contains("Screenshot live.png"), "detects a new screenshot → \(detected)")
        check(latencyMs >= 0 && latencyMs < 120, "detection latency \(Int(latencyMs))ms (was ~300ms)")
        check(!detected.contains("random-photo.png"), "ignores non-screenshot images")

        print(ok ? "\nSELFTEST PASS" : "\nSELFTEST FAIL")
        return ok
    }
}
