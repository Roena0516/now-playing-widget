# dmgbuild settings for PearNowPlaying-macOS.dmg (used by `./macos/build.sh --dmg`).
# The background (Resources/dmg-background.tiff, made by Tools/make-art.swift) is drawn for a 640 x 400 window
# with the app at (160, 200) and the Applications link at (480, 200).
import os

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
resources = defines["resources"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(resources, "AppIcon.icns")
background = os.path.join(resources, "dmg-background.tiff")

# Finder counts the title bar (29) in the window height, and the path bar (30) when the user has it turned on
# (a global Finder setting a DMG can't switch off). Leaving room for both keeps the 400pt background from
# scrolling; without a path bar there is a thin strip under the background instead.
window_rect = ((200, 160), (640, 459))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    os.path.basename(app): (160, 200),
    "Applications": (480, 200),
}
