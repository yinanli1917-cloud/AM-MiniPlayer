/**
 * [INPUT]: Reads/writes group.com.apple.controlcenter.plist (in Group Containers)
 * [OUTPUT]: Exports MenuBarHealer.healIfNeeded() — call before NSStatusItem creation
 * [POS]: Self-heal for macOS 26 ControlCenter trackedApplications corruption (postmortem 009)
 *
 * Why:
 *   When a user installs nanoPod for the first time (or upgraded from the old
 *   MusicMiniPlayer bundle ID), macOS 26's ControlCenter database can place the
 *   NSStatusItem at x=-1 (off-screen, bottom-left of menu bar). The legacy fix
 *   was scripts/fix_menubar.py running on the developer's Mac at build time —
 *   which never reached end users. This Swift port runs on every Mac, every
 *   launch, idempotently.
 *
 * Strategy:
 *   - Decode trackedApplications (a binary plist nested inside the outer plist)
 *   - Remove any stale com.yinanli.MusicMiniPlayer header+location pairs
 *   - Strip MusicMiniPlayer references from other apps' menuItemLocations
 *   - Only restart ControlCenter if we actually changed something
 */

import Foundation

public enum MenuBarHealer {

    private static let plistPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/group.com.apple.controlcenter"
            + "/Library/Preferences/group.com.apple.controlcenter.plist"
    }()

    private static let staleBundleFragments: Set<String> = ["MusicMiniPlayer"]
    private static let ownBundleID: String = "com.yinanli.nanoPod"

    /// Inspect ControlCenter's trackedApplications, remove stale entries, restart
    /// ControlCenter only if changes were made. Safe to call on every launch.
    public static func healIfNeeded() {
        guard FileManager.default.fileExists(atPath: plistPath) else { return }

        do {
            let url = URL(fileURLWithPath: plistPath)
            let data = try Data(contentsOf: url)

            var format = PropertyListSerialization.PropertyListFormat.binary
            guard var outer = try PropertyListSerialization.propertyList(
                from: data, options: [.mutableContainersAndLeaves], format: &format
            ) as? [String: Any] else { return }

            guard let trackedData = outer["trackedApplications"] as? Data else { return }

            var innerFormat = PropertyListSerialization.PropertyListFormat.binary
            guard let trackedRaw = try PropertyListSerialization.propertyList(
                from: trackedData, options: [.mutableContainersAndLeaves], format: &innerFormat
            ) as? [[String: Any]] else { return }

            let (cleaned, changed) = clean(entries: trackedRaw)
            guard changed else { return }

            let newTrackedData = try PropertyListSerialization.data(
                fromPropertyList: cleaned, format: .binary, options: 0
            )
            outer["trackedApplications"] = newTrackedData

            let newOuterData = try PropertyListSerialization.data(
                fromPropertyList: outer, format: .binary, options: 0
            )
            try newOuterData.write(to: url, options: .atomic)

            restartControlCenter()
        } catch {
            // Fail silent — heal is best-effort, app must still launch
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Cleaning logic (mirrors fix_menubar.py)
    // ──────────────────────────────────────────────

    /// Exposed for unit tests — pure function, no I/O.
    public static func _cleanForTests(entries: [[String: Any]]) -> (cleaned: [[String: Any]], changed: Bool) {
        return clean(entries: entries)
    }

    private static func clean(entries: [[String: Any]]) -> (cleaned: [[String: Any]], changed: Bool) {
        var result: [[String: Any]] = []
        var changed = false
        var i = 0

        while i < entries.count {
            var entry = entries[i]
            let id = entryID(entry)

            // Stale MusicMiniPlayer header → drop header + paired location entry
            if isStale(id) {
                let pairCount = (i + 1 < entries.count && entries[i + 1]["location"] != nil) ? 2 : 1
                i += pairCount
                changed = true
                continue
            }

            // Strip stale references from this entry's menuItemLocations
            if var locs = entry["menuItemLocations"] as? [[String: Any]] {
                let originalCount = locs.count
                locs.removeAll { isStale(entryID($0)) }
                if locs.count != originalCount {
                    entry["menuItemLocations"] = locs.isEmpty
                        ? [["bundle": ["_0": id]]]
                        : locs
                    changed = true
                }
            }

            result.append(entry)
            i += 1
        }

        return (result, changed)
    }

    private static func entryID(_ entry: [String: Any]) -> String {
        if let bundle = entry["bundle"] as? [String: Any],
           let id = bundle["_0"] as? String {
            return id
        }
        if let adhoc = entry["adhocBinary"] as? [String: Any],
           let inner = adhoc["_0"] as? [String: Any],
           let rel = inner["relative"] as? String {
            return rel
        }
        return ""
    }

    private static func isStale(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        if id == ownBundleID { return false }
        for fragment in staleBundleFragments where id.contains(fragment) {
            return true
        }
        return false
    }

    // ──────────────────────────────────────────────
    // MARK: - ControlCenter restart
    // ──────────────────────────────────────────────

    private static func restartControlCenter() {
        for name in ["ControlCenter", "cfprefsd"] {
            let task = Process()
            task.launchPath = "/usr/bin/killall"
            task.arguments = [name]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
        }
    }
}
