# dmgbuild settings for AnyDoor-<version>.dmg. dmgbuild executes this file with a
# `defines` dict from its -D options; build with scripts/release/dmg.sh, which
# passes -D app=<path to AnyDoor.app>.
#
# The layout reproduces the DMGs shipped by the create-dmg flow (3.7.0 through
# 4.2.7 are identical), measured from their .DS_Store: dmgbuild writes it directly,
# without Finder or AppleScript, so it is deterministic on headless runners.
# check_dmg_layout.py asserts the same values independently; change both together.
#
# Iloc positions are icon centers in Finder's window coordinates. They are the
# values Finder stored, not create-dmg's CLI arguments (--app-drop-link 380 170
# became Iloc (400, 197); AnyDoor.app was auto-placed at (115, 64)).

from __future__ import annotations

import os.path

_defines: dict[str, str] = globals().get("defines", {})
_app = _defines.get("app")
if not _app:
    raise ValueError("dmg_settings.py needs -D app=<path to the .app bundle>")
_app = _app.rstrip("/")
_app_name = os.path.basename(_app)

# Image: UDZO with zlib level 9 on HFS+, as create-dmg produced.
format = "UDZO"
compression_level = 9
filesystem = "HFS+"

files = [_app]
symlinks = {"Applications": "/Applications"}

# Window: {{10, 700}, {540, 320}} with every bar hidden.
window_rect = ((10, 700), (540, 320))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

# Icon view on a plain white background (no image), labels below the icons.
default_view = "icon-view"
background = None
icon_size = 96
text_size = 16
arrange_by = None
label_pos = "bottom"
show_icon_preview = True
show_item_info = False
grid_offset = (0, 0)
grid_spacing = 100

icon_locations = {
    _app_name: (115, 64),
    "Applications": (400, 197),
}
