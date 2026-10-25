<div align="center">

<img src="docs/screenshots/smart-scan.png" alt="DevSweep Smart Scan" width="880">

# DevSweep

**A free, native macOS cleaner built for developers.**
Smart Scan, junk cleanup, privacy, memory, app management and clutter tools, plus a cleaner that
gets space back from old coding projects without ever touching your code.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#build-from-source)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)](#how-its-built)
[![Download](https://img.shields.io/github/v/release/vivek-ram/DevSweep?label=download&color=8B5CF6)](https://github.com/vivek-ram/DevSweep/releases/latest)

[**Download the DMG**](https://github.com/vivek-ram/DevSweep/releases/latest) ·
[Features](#features) · [Screenshots](#screenshots) · [Safety](#safety-first) · [Build from source](#build-from-source)

</div>

---

## Why

Most of the space on a developer's Mac isn't photos or movies. It's `node_modules`, Python virtual
environments, Rust `target/` folders, Xcode DerivedData, simulator runtimes, Docker layers,
downloaded AI models and package caches, spread across dozens of projects you haven't opened in
months. General-purpose cleaners don't understand any of that, and the good ones are expensive.

DevSweep does both: everything you'd expect from a premium Mac cleaner, and a project cleaner that
knows what's safe to rebuild, knows when you last *really* used a project, and saves your Python
packages to `requirements.txt` before a virtual environment goes.

> All screenshots in this README use built-in demo data, not a real Mac.

## Highlights

- **Smart Scan with a Mac Health score:** one button scans everything and tells you what's
  dragging your Mac down, with each reason linked to the page that fixes it.
- **Developer-aware:** finds rebuildable folders in idle projects, measures 20+ developer caches,
  and cleans Xcode, Homebrew, Docker, Ollama, nvm and Rust leftovers with each tool's own commands.
- **Safe by default:** everything goes to the Trash, your code is never touched, and virtual
  environments are only removed after you tick them.
- **Temperature and widgets:** see how hot your Mac is and which apps are heating it, live in
  the menu bar or on desktop widgets.
- **Native and light:** SwiftUI, no Electron. In the background it uses about 0% CPU, because its
  animations pause whenever the window is hidden or you're in another app.
- **Private:** no account, no analytics, no telemetry. The only network requests are the update
  checks you start.

## Features

### Smart Scan
One pass over projects, junk, storage, developer caches, app updates and browser traces (about 15
seconds for 100 GB / 1.4 million files). You get a **Mac Health score** out of 100, based on free
space, junk, idle projects, memory pressure and swap, battery wear, broken background items and a
full Trash. **Clean** removes only the junk marked safe; idle projects always go through a review
first.

### Cleanup
- **System Junk:** app caches (not Apple's own), **AI app clutter** (caches and logs of Claude,
  Cursor, Windsurf, ChatGPT, Perplexity, LM Studio, Ollama and the Codex, Gemini and Cursor CLIs,
  never your chats or projects), logs and crash reports, broken preference files, old installers,
  downloaded iPhone/iPad updates, old device backups, Mail downloads, and the Trash (external
  drives included). Safe items are pre-ticked; archives and backups never are.
- **Cloud Cleanup:** big iCloud Drive, Dropbox, Google Drive and OneDrive files that are also
  downloaded on this Mac. *Free Up* removes only the local copy; the file stays in the cloud.

### Protection
- **Privacy:** history, cookies, website data, session tabs and autofill entries for Safari,
  Chrome, Edge, Brave, Arc, Vivaldi, Opera and Firefox, per profile. Also clears the Apple-menu
  Recent Items and lists every **app permission** you've granted (camera, microphone, screen
  recording, Full Disk Access…) with a one-click *Remove Access*. Saved passwords and cards are
  never touched.
- **Protection status:** XProtect malware definitions, Gatekeeper, FileVault and the Firewall at a
  glance.

### Performance
- **Maintenance:** free up memory and purgeable space, remove local Time Machine snapshots, flush
  DNS, reindex Spotlight, run the periodic scripts, speed up Mail, rebuild the *Open With* menu,
  and clear font and Quick Look caches. Admin tasks share one macOS password prompt.
- **Memory:** live memory use broken down into apps, wired, compressed, cached files and swap, plus
  the apps using the most memory or CPU. Helper processes and browser tabs count toward their app,
  and every app gets a Quit button. *Free Up Memory* asks macOS to drop cached memory.
- **Temperature:** the CPU temperature and macOS's thermal state (cool, warm, hot), a live chart,
  the hottest sensor in each part of the Mac (CPU cores, chip, graphics, Neural Engine, SSD,
  battery), and the apps heating it up. Apps don't have a temperature of their own, so they're
  ranked by the power each one draws, in watts, as macOS accounts it per process. That's what
  makes the chip hot.
- **Login Items:** background agents and daemons with on/off switches. Ones whose program no
  longer exists are flagged.

### Applications
- **Uninstaller:** removes an app together with its caches, preferences, saved state and support
  files, and finds leftovers of apps you already deleted. Filter to unused, App Store or
  downloaded apps.
- **Updater:** newer versions from the App Store, each app's own Sparkle feed and Homebrew casks,
  with release notes.

### My Clutter
- **Storage Map:** every folder as a ring you can click into, biggest first, with Finder icons.
  Cloud-only files are never downloaded just to be measured.
- **Large Files:** everything over 50 MB, filterable by place, size and age, plus **Downloads**
  grouped by the app or website each file came from.
- **Duplicates:** byte-for-byte identical files (one copy is always kept) and **Similar Photos**
  (bursts, retakes and near-identical screenshots, with the sharpest one marked).

### Developer
- **Projects:** finds `node_modules`, Python virtual environments, Rust `target/`, `.next`, SwiftPM
  `.build`, Gradle `build/`, CocoaPods, Flutter output and `__pycache__` in projects you haven't
  touched for a while. Your code is never touched.
- **Developer Caches:** pip, uv, Poetry, npm, pnpm, Yarn, Bun, Playwright, Cargo, Go, Gradle,
  Maven, Xcode DerivedData and DeviceSupport, CocoaPods, Homebrew, Hugging Face and more.
- **Toolchains & Models:** unavailable simulators and old runtimes (`xcrun simctl`),
  `brew cleanup`, Docker build cache and unused images, Ollama models, LM Studio and Hugging Face
  models, old nvm/pyenv versions, extra Rust toolchains and old Gradle distributions, each removed
  with the tool's own command.

### Care
- **Auto-Clean** (weekly by default): clears app caches (skipping open apps), logs, old
  installers and DevSweep's own week-old Trash items, and also runs when free space drops below a
  threshold. It never touches your files, virtual environments, archives or the rest of your
  Trash. Every run is logged.
- **Screen & Keyboard Cleaning:** every display goes black and input is ignored while you wipe.
  Hold esc for two seconds to finish.
- **My Activity:** how much has been freed, where it came from, and a weekly chart.
- **Space history:** a 30-day free-space chart, plus a notification when a folder suddenly grows.

### Menu bar
Free space, CPU, memory, temperature, network and battery health at a glance. Click CPU, Memory or
Temperature to see the apps behind the number, eject connected drives, and get a nudge when the
Trash fills up. You can also show live readouts right in the menu bar (temperature, CPU, memory
and free space; pick them in *Settings → Automation*):

<p align="center"><img src="docs/screenshots/menubar-readout.png" alt="Menu bar readout" width="520"></p>

### Desktop widgets
Mac Health, Storage and Temperature widgets in small, medium and large sizes, for the desktop or
Notification Center.

1. Open DevSweep once, so it can write what the widgets show.
2. Right-click an empty part of the desktop and choose **Edit Widgets…**.
3. Search for **DevSweep**, pick a widget and a size, and drag it onto the desktop.

Clicking a widget opens that page in DevSweep. They refresh after every scan or clean and every
few minutes while placed; macOS limits how often widgets redraw, so for live numbers use the menu bar.
If a widget stays blank, open DevSweep: after an update it restarts the widget extension.

<p align="center"><img src="docs/screenshots/widgets.png" alt="Desktop widgets" width="880"></p>

## Screenshots

| | |
|---|---|
| ![Smart Scan, scanning](docs/screenshots/scanning.png) **Smart Scan** while scanning | ![Cleaning done](docs/screenshots/cleaning-done.png) **Cleaning**, with a live progress ring and confetti |
| ![System Junk](docs/screenshots/junk.png) **System Junk** | ![Projects](docs/screenshots/projects.png) **Projects**: idle, active and protected |
| ![Storage Map](docs/screenshots/storage-map.png) **Storage Map** | ![Large Files](docs/screenshots/large-files.png) **Large Files** |
| ![Memory](docs/screenshots/memory.png) **Memory** | ![Temperature](docs/screenshots/temperature.png) **Temperature** |
| ![Privacy](docs/screenshots/privacy.png) **Privacy** | ![Screen Cleaning](docs/screenshots/screen-cleaning.png) **Screen & Keyboard Cleaning** |
| ![Uninstaller](docs/screenshots/uninstaller.png) **Uninstaller** | ![Updater](docs/screenshots/updater.png) **Updater** |
| ![Duplicates](docs/screenshots/duplicates.png) **Duplicates** | ![Cloud Cleanup](docs/screenshots/cloud.png) **Cloud Cleanup** |
| ![Maintenance](docs/screenshots/maintenance.png) **Maintenance** | ![Login Items](docs/screenshots/login-items.png) **Login Items** |
| ![Developer Caches](docs/screenshots/caches.png) **Developer Caches** | ![Toolchains & Models](docs/screenshots/devtools.png) **Toolchains & Models** |
| ![Auto-Clean](docs/screenshots/auto-clean.png) **Auto-Clean** | ![My Activity](docs/screenshots/activity.png) **My Activity** |

<p align="center">
<img src="docs/screenshots/menubar.png" alt="Menu bar panel" width="290">&nbsp;&nbsp;
<img src="docs/screenshots/menubar-heat.png" alt="Menu bar panel, heat" width="290"><br>
<b>Menu bar</b>: click a gauge to see the apps behind it
</p>

## Install

1. Download **DevSweep-1.1.0.dmg** from the [latest release](https://github.com/vivek-ram/DevSweep/releases/latest).
2. Open it and drag **DevSweep** into **Applications**.
3. Open DevSweep. It suggests the folders where your projects live; pick them and press
   **Start Scanning**.

Requires macOS 14 Sonoma or later, on Apple silicon or Intel.

> **First launch.** DevSweep is signed with a Developer ID but not yet notarized by Apple, so macOS
> blocks it the first time you open it. Go to **System Settings → Privacy & Security** and click **Open Anyway**,
> or run:
> ```bash
> xattr -dr com.apple.quarantine /Applications/DevSweep.app
> ```

**Full Disk Access (recommended).** For a complete scan, allow it under *Settings → General → Mac
scan → Allow…*. Without it, DevSweep skips app containers, the Trash, Safari, Mail and the
permissions list, rather than macOS asking about each app.

## Safety first

- **Your code is never touched.** Only exact, well-known folder names are removed, and only next to
  the file that proves what they are: `target` needs a `Cargo.toml` beside it, `build` needs
  `build.gradle` or `pubspec.yaml`, a venv needs `pyvenv.cfg`, and so on. Every folder is checked
  again right before removal.
- **Virtual environments need your OK.** Each venv is unticked in the review until you tick it,
  and automatic cleaning never removes one. Before a venv goes, its packages are written to
  `requirements.txt`, read straight from the environment's metadata so it works even if the
  Python it was built with is gone. Your own `requirements.txt` is never overwritten; a
  differing list goes to `requirements-snapshot.txt` instead.
- **Node projects without a lockfile** get `node_modules.snapshot.json` with the exact installed
  versions.
- **The Trash by default.** Removed folders and files go to the Trash. *Free Trash Space* deletes
  only what DevSweep put there, never the rest of your Trash.
- **Passwords stay out of it.** Saved browser passwords and cards are never touched, and admin
  tasks ask for your password in macOS's own prompt, which DevSweep never sees.
- **Protect anything.** Protect a project from the Projects list, or drop an empty
  `.devsweep-keep` file into any folder to protect it and everything below it.

## How "idle" is decided

A project is idle when, for longer than your retention period (30 days by default):

- none of its own files changed (rebuildable folders, `.DS_Store` and the like are ignored),
- nothing was installed or built in it, and
- no editor opened it. VS Code, Cursor, Windsurf and other VS Code-based editors, Xcode, JetBrains
  IDEs and Claude Code sessions all count.

That last check matters: running code doesn't change any files, so a tool you use every day
without editing it would otherwise look abandoned. Optional **low-space mode** halves the retention
period while the disk has less than 20 GB free.

## Privacy

DevSweep has no account, no analytics and no telemetry, and it works offline. The only network
requests are the update checks in **Updater**: Apple's public App Store lookup, the update feeds
your apps already use (Sparkle), and Homebrew.

## Command line

The app ships a CLI at `DevSweep.app/Contents/Helpers/devsweep`:

```bash
ln -s /Applications/DevSweep.app/Contents/Helpers/devsweep /usr/local/bin/devsweep
```

```bash
devsweep scan ~/Developer                          # projects and what's idle
devsweep clean ~/Developer --days 60               # dry run: shows the plan
devsweep clean ~/Developer --days 60 --yes         # move idle folders to the Trash (venvs kept)
devsweep clean ~/Developer --yes --include-venvs   # …venvs too, packages saved first
devsweep snapshot path/to/.venv                    # print a venv as requirements.txt
devsweep caches | storage | junk | dupes | tools   # caches, disk usage, junk, duplicates, toolchains
devsweep apps | leftovers | login-items            # apps, leftovers, background items
devsweep top | heat | stats | maintenance          # memory & CPU hogs, temperatures, system stats, purgeable space
devsweep privacy | updates | cloud | downloads     # browser traces, updates, cloud copies, downloads
```

## Build from source

You need macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`); full Xcode isn't
required.

```bash
git clone https://github.com/vivek-ram/DevSweep.git
cd DevSweep
scripts/build-app.sh             # → build/DevSweep.app
scripts/build-app.sh --install   # …and copy it to /Applications and open it
scripts/make-dmg.sh              # → build/DevSweep-<version>.dmg (Apple silicon + Intel)
scripts/test.sh                  # unit tests (Swift Testing)
```

The build signs with your **Developer ID Application** certificate when you have one (or whatever
`SIGN_IDENTITY` names) and falls back to ad-hoc signing. Everything works ad-hoc except the
desktop widgets: macOS only runs a sandboxed widget extension whose signature carries a Team ID.

Regenerate the screenshots from demo data with:

```bash
swift build && .build/debug/DevSweep --render-demo docs/screenshots
```

## How it's built

| Part | What's in it |
|---|---|
| `Sources/DevSweepCore` | Everything that reads or changes the disk, with no UI: the project scanner and retention rules, venv/Node snapshots, the cleaner, storage and junk scanners, duplicates and similar photos, privacy, maintenance, updates, process and system sampling, and Mac Health. |
| `Sources/DevSweep` | The SwiftUI app: one `@Observable` store per module, the views, the theme (module colours, glass cards, the Core Animation background) and the menu bar extra. |
| `Sources/devsweep-cli` | The command-line tool. |
| `Sources/DevSweepWidgets`, `Sources/DevSweepWidgetUI` | The WidgetKit extension and its views. The extension is sandboxed and only reads a snapshot the app writes to `~/Library/Application Support/DevSweep/Widget`. |
| `Tests/DevSweepCoreTests` | 74 tests on temporary fixture folders, covering scanning, retention, snapshots, cleaning safety, junk rules, privacy, health, temperature, updates and more. |

Some details:

- Disk scanning uses `fts` with cloud-file materialisation turned off, so measuring iCloud Drive or
  Dropbox never downloads anything.
- Sizes are what removal actually frees: allocated blocks, with hard-linked files (pnpm, uv)
  counted only when every link is inside the folder.
- Memory per app sums each process's physical footprint and groups helpers by the app macOS holds
  responsible for them. Power per app comes from the energy macOS accounts to each process.
- Temperatures are read from the Mac's own sensors through IOKit's HID event system, the way
  macOS's tools do; Intel Macs that don't expose them still show the thermal state.
- The SwiftPM-built widget extension is linked with `NSExtensionMain` as its entry point, as Xcode
  does. Entered at `main`, WidgetKit sets up and returns, and the extension exits before macOS can
  talk to it.

## What it doesn't do (and why)

- **Strip language files or universal binaries from apps:** editing an app's bundle breaks its
  code signature.
- **Its own malware scanner:** that needs a constantly maintained threat database, and macOS's
  XProtect already covers it. DevSweep shows XProtect's status instead.
- **Email cleanup for Gmail or Outlook:** it would need OAuth access to your mailbox.
- **"Repair disk permissions":** that has been obsolete since OS X El Capitan.
