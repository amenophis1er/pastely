# Changelog

Each version has a section. The release workflow reads the section matching the tag and uses it for both the GitHub release notes and the update dialog in the app.

## Unreleased

- Items can carry a label. ⇧⌘P, or "Pin with label…" in a row's menu, names the item and pins it; the label replaces the preview in the list and the menu bar, and search matches it. Clear the text to remove a label. Unpinning keeps it. Labels are encrypted like everything else.

## 0.1.2

Images paste into terminals the way Claude Code and Codex expect.

- An image pasted into Terminal, iTerm, Ghostty, Warp, kitty, Alacritty or WezTerm is sent with ⌃V, which is how Claude Code, Codex and similar tools take images. Text still pastes with ⌘V. The list lives in Settings › General › Terminals; add VS Code or Cursor there if you want the same in their integrated terminal.
- ⌃↩ in the history panel, or "Paste with ⌃V" in a row's menu, forces ⌃V for any item in any app.
- A second copy of Pastely quits itself if one is already running.

## 0.1.1

Menu bar polish, a hover preview, and a way to report problems from inside the app.

- Hover a row in the menu bar menu to see a preview card: the full image, or the text of a clip, with its source app and age.
- Menu rows paste straight into the app you were in. Option-click a row to open it in the history panel.
- Image rows in the menu are titled by the text recognized in them, skipping fragments, instead of "Image (27 KB)".
- Report a Problem, in Settings, About: describe what happened and send it with a visible diagnostics block. Nothing from your clipboard is included, and your email, if you give one, stays private.
- Settings restyled to match the rest of the app, with chip tabs, and tall enough that nothing scrolls.
- The history panel warns in its footer when the Accessibility permission is missing, since pasting needs it.
- Double-click pastes reliably, including on rows that were not selected yet.
- Windows opened from the menu bar now come to the front.
- Dev builds show an indigo menu bar icon and use their own bundle id, so they never collide with the installed app.

## 0.1.0

The first release of Pastely, a light, local-only clipboard manager for macOS.

- History panel on ⇧⌘V, opening next to your cursor. Fuzzy search, filters for text, images, files and pinned items, live preview, keyboard-first flow.
- Text, rich text, images and file references.
- On-device text recognition for images: search finds words inside screenshots, and ⇧↩ pastes the recognized text.
- Encrypted history (AES-GCM, key in your login keychain). Concealed copies from password managers are never recorded. Ignore list by app. Retention by count and age.
- Welcome screen on first launch for the shortcut, the Accessibility permission and launch at login.
- Automatic updates through Sparkle from GitHub Releases.
- `pastely://` URL scheme for launchers and scripts.
