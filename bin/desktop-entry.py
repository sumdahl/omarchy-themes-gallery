#!/usr/bin/env python3
"""Install the Apps-launcher entry for gotar.omarchy-themes.

Makes the gallery searchable from Super+Space like any app. Written once;
an existing file is the user's, except that one with an Icon= we wrote is
upgraded and marked. Panel.qml deletes marked files when the plugin unloads
(disable / `omarchy plugin remove`), since the host has no uninstall hook.
"""
import os
import pathlib
import re

ICON = str(pathlib.Path(__file__).resolve().parent.parent / "icon.png")
# Icons earlier versions wrote; only these are upgraded in place.
OLD_ICONS = {"preferences-desktop-wallpaper"}
# Ownership marker; Panel.qml's cleanup only removes files carrying it.
MARKER = "X-Omarchy-Plugin=gotar.omarchy-themes"

ENTRY = """[Desktop Entry]
Type=Application
Name=Themes Gallery
GenericName=Theme gallery
Comment=Browse thousands of wallpapers x 5 variants and apply any as an Omarchy theme
Exec=omarchy-shell shell toggle gotar.omarchy-themes '{}'
TryExec=omarchy-shell
Icon={icon}
Terminal=false
StartupNotify=false
Categories=Settings;DesktopSettings;
Keywords=theme;omarchy;wallpaper;gallery;colors;
{marker}
"""
# StartupNotify=false: Exec only toggles a window in the running shell.


def main():
    data = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    dst = pathlib.Path(data) / "applications" / "gotar.omarchy-themes.desktop"
    if dst.is_symlink():
        return 0
    if dst.exists():
        text = dst.read_text()
        m = re.search(r"^Icon=(.*)$", text, re.M)
        if not m or m.group(1) not in OLD_ICONS | {ICON}:
            return 0  # the user's own entry: leave it alone
        new = text[:m.start(1)] + ICON + text[m.end(1):]
        if not re.search("^" + re.escape(MARKER) + "$", new, re.M):
            new = new.rstrip("\n") + "\n" + MARKER + "\n"
        if new == text:
            return 0
        text = new
    else:
        text = ENTRY.replace("{icon}", ICON).replace("{marker}", MARKER)
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(".tmp")
    tmp.write_text(text)
    os.replace(tmp, dst)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
