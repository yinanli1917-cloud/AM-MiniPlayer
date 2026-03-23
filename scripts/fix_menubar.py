#!/usr/bin/env python3
"""
Fix macOS 26 ControlCenter trackedApplications database.

macOS 26 stores "Allow in Menu Bar" state in a binary plist inside:
  ~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist

The 'trackedApplications' key contains pairs of entries: a header (bundle ID)
followed by a location entry (isAllowed, menuItemLocations).

When a bundle ID changes (e.g., MusicMiniPlayer → nanoPod), stale references
in menuItemLocations cause the system to place the status item at x=-1 (off-screen).

Fix: remove stale entries and any corrupted nanoPod entry, so the system
re-registers it fresh on next launch.
"""
import plistlib
import os
import sys

PLIST_PATH = os.path.expanduser(
    "~/Library/Group Containers/group.com.apple.controlcenter"
    "/Library/Preferences/group.com.apple.controlcenter.plist"
)

STALE_IDS = {
    "com.yinanli.MusicMiniPlayer",
}

NANOPOD_BUNDLE = "com.yinanli.nanoPod"


def get_entry_id(entry):
    if "bundle" in entry:
        return entry["bundle"].get("_0", "")
    if "adhocBinary" in entry:
        return entry["adhocBinary"].get("_0", {}).get("relative", "")
    return ""


def is_stale(entry_id):
    for stale in STALE_IDS:
        if stale in entry_id:
            return True
    if "MusicMiniPlayer" in entry_id and "nanoPod" not in entry_id:
        return True
    return False


def fix():
    if not os.path.exists(PLIST_PATH):
        print("ControlCenter plist not found — nothing to fix")
        return False

    with open(PLIST_PATH, "rb") as f:
        data = plistlib.load(f)

    if "trackedApplications" not in data:
        print("No trackedApplications key — nothing to fix")
        return False

    tracked = plistlib.loads(data["trackedApplications"])
    cleaned = []
    changed = False
    i = 0

    while i < len(tracked):
        entry = tracked[i]
        entry_id = get_entry_id(entry)

        # Remove stale MusicMiniPlayer entries
        if is_stale(entry_id):
            print(f"  Removing stale: {entry_id}")
            # Skip header + location pair
            i += 2 if (i + 1 < len(tracked) and "location" in tracked[i + 1]) else 1
            changed = True
            continue

        # Remove nanoPod entry so system re-registers fresh
        if entry_id == NANOPOD_BUNDLE:
            print(f"  Removing nanoPod (will re-register on launch)")
            i += 2 if (i + 1 < len(tracked) and "location" in tracked[i + 1]) else 1
            changed = True
            continue

        # Fix cross-contamination in other apps' menuItemLocations
        if "menuItemLocations" in entry:
            locs = entry["menuItemLocations"]
            fixed = [loc for loc in locs if not is_stale(get_entry_id(loc))]
            if len(fixed) != len(locs):
                print(f"  Fixed cross-contamination in {get_entry_id(entry)}")
                entry["menuItemLocations"] = fixed if fixed else [{"bundle": {"_0": get_entry_id(entry)}}]
                changed = True

        cleaned.append(entry)
        i += 1

    if not changed:
        print("  No stale entries found — database is clean")
        return False

    data["trackedApplications"] = plistlib.dumps(cleaned, fmt=plistlib.FMT_BINARY)
    with open(PLIST_PATH, "wb") as f:
        plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

    print(f"  Cleaned: {len(tracked)} → {len(cleaned)} entries")
    return True


if __name__ == "__main__":
    print("Fixing macOS 26 menu bar database...")
    if fix():
        print("Done — restart ControlCenter: killall ControlCenter")
    else:
        print("No changes needed")
