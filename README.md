<div align="center">

# macshot

**Screenshots that file themselves.**

A native macOS menu-bar app that catches every screenshot the moment you take it and lets you drop it into the right Desktop folder from a clean floating panel. No more `Screenshot 2026-…​.png` piling up on your desktop.

Built like the paid tools. Priced like open source: free.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI · AppKit](https://img.shields.io/badge/SwiftUI-·_AppKit-1575F9)
![License MIT](https://img.shields.io/badge/License-MIT-2ea44f)
![No dependencies](https://img.shields.io/badge/dependencies-0-444)

<br>

<img src="docs/hover.png" width="540" alt="macshot floating panel with Copy and Save">

</div>

## The problem it solves

You take a screenshot. It drops onto your Desktop with a name only a machine could love. A week later your Desktop is a wall of them.

macshot fixes the last step. The instant a screenshot is saved, a panel appears in the corner. Hover it, hit **Save**, pick a folder. The file moves to `~/Desktop/<folder>/` and your Desktop stays clean.

## Features

**It appears instantly.** macshot detects the shot the moment the file finishes writing, so the panel is there as fast as macOS can hand it over. No artificial delay.

**At rest, it's just your screenshot.** No borders, no chrome. The real shot, sitting in the corner.

<img src="docs/resting.png" width="430" alt="A screenshot resting in the bottom-right corner">

**Hover to reveal the controls.** A frosted-glass panel rises over a softly blurred preview: Copy, Save, Markup, Share. Monochrome, no glow, no noise.

**Your folders, not your clutter.** The picker starts with one option, Desktop. It never lists your whole Desktop. It only remembers the folders *you* make through it, so the list stays yours.

<img src="docs/picker.png" width="430" alt="The folder picker showing the Desktop baseline">

**Create a folder as you type.** Type a name, press Return, and macshot makes the folder on your Desktop and files the shot into it. Next time, it's there to search.

<img src="docs/create.png" width="430" alt="Type a name to create a new folder">

**Stack them.** Take a few in a row and they stack neatly in the corner, newest on top, each at its real proportions. File them whenever you're ready. Dismiss one and the rest slide down to fill the gap.

<img src="docs/stack-rest.png" width="320" alt="Two screenshots stacked in the corner">

**It stays on your Mac.** No account, no cloud, no telemetry. macshot moves files on your own disk. Nothing leaves.

## Install

Hand this to your coding agent (Claude Code, Cursor, Codex, and friends) and let it do the setup:

```
Clone https://github.com/Entrepenulian/macshot, run ./build-app.sh, move
macshot.app to /Applications, and open it.
```

## Using it

1. Take a screenshot the way you always do (`⌘⇧4`, `⌘⇧3`, etc.).
2. The panel appears in the bottom-right.
3. Hover it, hit **Save**, and pick or create a folder. Done.

Not ready to file it? Ignore the panel and the shot stays on your Desktop like normal. macshot never deletes anything — it only moves a file when you choose a folder.

Menu-bar icon → **Catch the latest screenshot** pops the panel on your most recent shot, handy for trying it without taking a new one.

## How it works

- **Detection:** watches your screenshot folder and fires the instant a new capture's file is complete (it checks the file's end-of-file marker rather than guessing with a delay).
- **The panel:** a borderless, non-activating window that floats over whatever you're doing without stealing focus.
- **Filing:** moves the file into `~/Desktop/<folder>`, creating the folder if it's new, and remembers it for next time.

## Build from source

```bash
swift build                    # debug build
swift run macshot              # run from the terminal
swift run macshot --selftest   # filing + detection self-tests
./build-app.sh                 # release .app bundle
```

## Project layout

```
Sources/macshot/
  main.swift              entry point + CLI flags
  AppController.swift     menu bar, wiring, login-item / thumbnail toggle
  ScreenshotWatcher.swift detects new screenshots the instant they finish
  FolderStore.swift       remembers your folders, creates + moves files
  Overlay.swift           the floating panel + the corner stack
  ShotView.swift          the SwiftUI glass UI
```

## Built with

Swift 6, SwiftUI + AppKit, Swift Package Manager. No third-party dependencies.

## License

[MIT](LICENSE). Use it, fork it, ship it.
