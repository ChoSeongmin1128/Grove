# Nero brand mark

`mark.svg` is the canonical mark, selected from 23-B r7 A. All sizes retain the same geometry and orientation.

- Four identical modules, rotated by 90 degrees around (256, 256).
- Horizontal/vertical step spacing and terminal band thickness: 64 units.
- Outer circular arc radius: 96. Small circular corner radius: 16.
- Colors: `#174D39`, `#78B987`.

Run `npm run prepare:icons` from `apps/desktop` to regenerate the checked-in desktop assets with the pinned Tauri CLI. No additional image package is required.

The application icon is colored. macOS uses a monochrome template for its menu bar; Windows uses monochrome tray images selected from the window's reported theme and refreshed on theme-change events. Windows taskbar and application themes can be configured separately; actual tray contrast still requires a Windows check.
