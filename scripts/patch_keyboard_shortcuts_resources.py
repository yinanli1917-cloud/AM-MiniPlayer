#!/usr/bin/env python3
"""Make KeyboardShortcuts find its resource bundle inside a signed nanoPod.app.

SwiftPM's generated `Bundle.module` accessor only looks in two places:
  1. `Bundle.main.bundleURL/<Pkg>_<Target>.bundle` -- for an .app that is the
     app ROOT, where codesign refuses any extra file ("unsealed contents present
     in the bundle root"; a symlink is refused too);
  2. the absolute `.build/...` path of the machine that compiled it.
Anywhere else it calls fatalError. KeyboardShortcuts reads `Bundle.module` for its
localized strings the moment `KeyboardShortcuts.Recorder` is built (Settings ->
Shortcuts), so a distributed nanoPod crashes there
(sindresorhus/KeyboardShortcuts#231).

build_app.sh copies the bundle into Contents/Resources (sealed by codesign) and
runs this script around `swift build` to reroute KeyboardShortcuts' single
`.module` lookup: Contents/Resources first, SwiftPM's accessor as the fallback
(keeps `swift test` / `swift run` working). Same approach as steipete/Trimmy's
packaging patch.

Usage: patch_keyboard_shortcuts_resources.py apply|restore <KeyboardShortcuts checkout>
Fails closed if upstream changes the lookup, so a dependency bump cannot
silently reintroduce the crash.
"""

import subprocess
import sys
from pathlib import Path

RELATIVE_PATH = "Sources/KeyboardShortcuts/Utilities.swift"
ORIGINAL = "NSLocalizedString(self, bundle: .module, comment: self)"
PATCHED = "NSLocalizedString(self, bundle: .nanoPodKeyboardShortcutsResources, comment: self)"
ACCESSOR = '''
// nanoPod packaging patch (scripts/patch_keyboard_shortcuts_resources.py): resolve the
// resource bundle from the signed app's Contents/Resources before SwiftPM's accessor.
private extension Bundle {
	static let nanoPodKeyboardShortcutsResources: Bundle = Bundle.main
		.url(forResource: "KeyboardShortcuts_KeyboardShortcuts", withExtension: "bundle")
		.flatMap(Bundle.init(url:)) ?? .module
}
'''


def pristine_source(checkout: Path) -> str:
    return subprocess.run(
        ["git", "-C", str(checkout), "show", f"HEAD:{RELATIVE_PATH}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def write_if_changed(path: Path, text: str) -> None:
    # Only touch the file when content differs, so repeated builds do not force a
    # recompile of KeyboardShortcuts.
    if path.read_text() != text:
        path.chmod(path.stat().st_mode | 0o200)
        path.write_text(text)


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in ("apply", "restore"):
        raise SystemExit(__doc__)
    mode, checkout = sys.argv[1], Path(sys.argv[2])
    target = checkout / RELATIVE_PATH
    source = pristine_source(checkout)

    if mode == "restore":
        write_if_changed(target, source)
        return

    if source.count(ORIGINAL) != 1:
        raise SystemExit(
            f"❌ KeyboardShortcuts' resource lookup changed upstream ({target}); "
            "review scripts/patch_keyboard_shortcuts_resources.py before shipping."
        )
    write_if_changed(target, source.replace(ORIGINAL, PATCHED) + ACCESSOR)


if __name__ == "__main__":
    main()
