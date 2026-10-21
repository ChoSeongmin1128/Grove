from pathlib import Path

_app = Path(defines["app"]).resolve()
if _app.suffix != ".app" or not (_app / "Contents/Info.plist").is_file():
    raise ValueError("A built application bundle is required")

format = "UDZO"
filesystem = "HFS+"
files = [(str(_app), "Nero.app")]
symlinks = {"Applications": "/Applications"}

window_rect = ((200, 160), (560, 320))
default_view = "icon-view"
icon_locations = {"Nero.app": (156, 142), "Applications": (404, 142)}
icon_size = 96
text_size = 14
label_pos = "bottom"
arrange_by = None
background = "#ffffff"

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_item_info = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False
hide_extensions = ["Nero.app"]
