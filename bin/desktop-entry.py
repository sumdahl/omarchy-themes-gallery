#!/usr/bin/env python3
"""Install the Apps-launcher entry for sumiran.theme-gallery.

Makes the gallery searchable from Super+Space like any app. Written once;
an existing file is the user's, except that an Icon= we wrote earlier is upgraded.
"""
import os
import pathlib
import re

ICON = str(pathlib.Path(__file__).resolve().parent.parent / "icon.png")
# Icons earlier versions wrote; only these are upgraded in place.
OLD_ICONS = {"preferences-desktop-wallpaper"}

ENTRY = """[Desktop Entry]
Type=Application
Name=Themes Gallery
GenericName=Theme gallery
Comment=Browse thousands of wallpapers x 5 variants and apply any as an Omarchy theme
Exec=omarchy-shell shell toggle sumiran.theme-gallery '{}'
TryExec=omarchy-shell
Icon={icon}
Terminal=false
StartupNotify=false
Categories=Settings;DesktopSettings;
Keywords=theme;omarchy;wallpaper;gallery;colors;
"""
# StartupNotify=false: Exec only toggles a window in the running shell.


def main():
    data = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    dst = pathlib.Path(data) / "applications" / "sumiran.theme-gallery.desktop"
    if dst.is_symlink():
        return 0
    if dst.exists():
        text = dst.read_text()
        m = re.search(r"^Icon=(.*)$", text, re.M)
        if not m or m.group(1) not in OLD_ICONS:
            return 0  # the user's own entry: leave it alone
        text = text[:m.start(1)] + ICON + text[m.end(1):]
    else:
        text = ENTRY.replace("{icon}", ICON)
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_suffix(".tmp")
    tmp.write_text(text)
    os.replace(tmp, dst)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
