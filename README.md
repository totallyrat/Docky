# Docky

A Dynamic Island for the Mac (and Windows — see [Docky for Windows](#docky-for-windows)). A black capsule lives at the top of your screen and morphs, with
iPhone-style spring animations, to show what's playing, running timers, alarms and reminders,
and your Mac's lock state.

`Docky.dmg` contains two apps:

| App | What it is |
| --- | --- |
| **Docky** | The island itself. Runs in the background (no Dock icon) with an optional menu bar item. |
| **Docky Settings** | A System Settings-style app for tweaking the island. |

## Install

1. Open `build/Docky.dmg` and drag **Docky** and **Docky Settings** into Applications.
2. Open **Docky**. The island springs open once to say hello.
3. Open **Docky Settings** to turn on *Open Docky at login* and adjust the rest.

The apps are ad-hoc signed. On the Mac that built them they open normally. On another Mac,
right-click → **Open** the first time, or allow them in System Settings → Privacy & Security.

## Using the island

- **Hover** over the island and it grows slightly to show it's listening.
- **Swipe down with two fingers** while hovering (or click) to open it. Swipe up, press Esc,
  move the pointer away or click elsewhere to close it.
- **Volume & brightness**: hover over the indicator to keep it up, then scroll or drag up/down
  (or click along the slider) to change the level.
- **Tuck Now Playing away**: swipe or drag inward on the compact island — up from below, or from
  either side toward the middle. Swipe or drag outward (left or right) to bring it back.
- **Tabs** at the top switch between **Now Playing**, **Timers** and **Reminders & Alarms**.
- **Now Playing**: artwork, title, artist, a scrubbable progress bar, and previous / play-pause / next.
  It works with Music, Spotify, Podcasts, browsers, and anything else that reports to macOS Now Playing.
  The compact island shows artwork, the scrolling title and a waveform tinted from the artwork.
- **Timers**: scroll, drag or click the chevrons on the dials, or tap a preset. Run several at once.
  While music plays, a running timer splits off into its own bubble beside the island.
- **Reminders & Alarms**: press **+** to add a reminder (with *In 15 min*, *In 1 hour*, *Tonight*,
  *Tomorrow* or a custom time) or an alarm (time, label, repeat days). When one is due, the island
  expands with Snooze / Stop or Later / Done and plays a sound.
- **Clipboard**: drag files (or text and images) onto the island and it opens the Clipboard tab.
  Files stay on the shelf until you remove them; drag them back out into any app, double-click to
  open, or drop onto **Share** (or click it) for AirDrop, Messages, Mail and more.
- **Calendar**: the next seven days from Apple Calendar — including Google, iCloud and Exchange
  accounts added to macOS — with a Join button for Zoom / Meet / Teams links.
- **System indicators**: volume, brightness, Focus on/off, AirPods and other Bluetooth devices,
  drives, and plugging in your Mac all show in the island. With Accessibility access Docky takes
  over the volume and brightness keys, so the macOS overlay no longer appears.
- **One thing at a time**: start a video and your music pauses; start music and the video pauses
  (Settings → Now Playing).
- **Fullscreen apps**: the island tucks away while a fullscreen app is in front and comes back
  when you point at the top of the screen. Alarms, timers and reminders always show.
- **Intro**: each time Docky opens, a glow races up the edges of the screen throwing sparks,
  "Docky" blooms in the middle, and the island drops in wearing the same glow for three seconds.
- **Settings** opens out of the island itself (gear button, right-click menu or menu bar) and
  shrinks back into it when closed.
- **Lock screen**: while the Mac is locked the island shows a lock. Unlock with Touch ID or your
  password and the lock springs open before the island tucks away.
- **Right-click** the island (or use the menu bar item) for New Timer, New Reminder, Settings and Quit.

## Settings

Only show music (music apps always; other apps only 1–5 minute media, so Shorts stay out),
show/hide the song title, hide in fullscreen apps, play the intro, island style (automatic / notch-hugging / floating), display, size, animation feel
(Smooth / Snappy / Bouncy), hover growth, hide when idle, swipe/click/hover-to-open, close delay,
haptics, Now Playing options, alert sounds (including synthesized *Radar* and *Chime*), snooze
length, 24-hour time, lock screen, launch at login, and menu bar icon.

## Building

Only the Xcode Command Line Tools are needed.

```bash
./build.sh                 # universal (Apple silicon + Intel) apps + build/Docky.dmg
ARCHS=arm64 ./build.sh     # faster, native only
SKIP_DMG=1 ./build.sh      # apps only, in build/Products
```

### Keeping permissions across rebuilds

macOS remembers permissions (Accessibility, Calendar, Bluetooth) per code signature. Ad-hoc
signatures change with every build, so each rebuild would need permissions granted again. Run
`Tools/make-signing-identity.sh` once to create a local "Docky Local Signing" certificate;
`build.sh` then signs with it automatically and permissions stick.

## How it works

- **Window**: a borderless, non-activating `NSPanel` above the menu bar on every Space. It only
  takes the mouse while the pointer is over the island; everywhere else clicks pass straight through.
- **Animation**: the whole island is one SwiftUI layout value animated with a spring. The shape
  is a true capsule when compact and eases into Apple's continuous corners as it grows, so it
  never pops. Content swaps use a blur + scale transition. The waveform and scrolling titles run
  on Core Animation, so the app uses roughly 0% CPU while music plays.
- **Now Playing**: since macOS 15.4 the private MediaRemote framework only answers Apple-signed
  processes. Docky loads a tiny bridge (`Sources/MediaBridge/MediaBridge.m`) into `/usr/bin/perl`,
  an Apple platform binary, and streams JSON over a pipe. Nothing leaves your Mac.
- **Lock screen**: the panel is moved into a private SkyLight space at the level macOS uses for
  lock screen notifications, and lock/unlock come from `com.apple.screenIsLocked` / `…Unlocked`.
- **Data**: timers, alarms and reminders are saved to `~/Library/Application Support/Docky/clock.json`.
  Preferences are shared between both apps through the `com.totallyrat.docky.shared` defaults domain.

## Project layout

```
Sources/
  Shared/         preferences + IPC shared by both apps
  Docky/          the island (App, Island, Services, Views)
  DockySettings/  the settings app
  MediaBridge/    Objective-C MediaRemote bridge hosted by perl
Tools/            icon renderer and alert-sound synthesizer used by build.sh
windows/Docky/    the Windows version (C#, WPF)
```

Private APIs (MediaRemote, SkyLight) mean Docky can't ship on the Mac App Store, and a future
macOS update could break Now Playing or the lock screen island.

## Docky for Windows

`windows/Docky` is a native Windows version (Windows 10 2004 or later, Windows 11) written in C#
and WPF. It's one self-contained `Docky.exe`: no installer and no .NET install needed.

**Get it:** download `Docky.exe` from the repository's Releases (or the *Docky-Windows* artifact
of the latest **Windows** Actions run), put it anywhere (e.g. `Documents\Docky`) and open it.
Windows SmartScreen warns about apps from unknown publishers the first time: click
**More info → Run anyway**. Turn on *Start Docky with Windows* in setup or Settings.

What it does, matching the Mac version:

- The island at the top centre of the screen with the same spring morphs, hover growth, scroll /
  click / drag-down to open, and drag inwards / outwards to tuck Now Playing away and back.
- Now Playing for anything in the Windows media flyout (Spotify, browsers, Media Player…), with
  artwork tint, scrubbing, "only music", hide title, track-change peek and auto-pause of other media.
- Timers, Pomodoro (focus / break / long break / rounds, warm screen glow and "Time for a break"
  until the break ends or the island is put away), reminders and alarms — all made in the island.
- Calendar tab from iCal links (Google, Outlook, iCloud), Clipboard tab (drag files in and out,
  Share zone), launch intro, and the setup walkthrough inside the island.
- Volume, brightness, Do not disturb, Bluetooth, drives and charging indicators. With *Replace the
  Windows volume pop-up* on, the volume keys show only in the island. Point at a level indicator
  and scroll or drag to adjust it.
- Docky Settings window and a tray icon (left-click for Settings, right-click for more).

Windows limits: there's no island on the lock screen (apps can't draw there), Windows' own
brightness pop-up can't be hidden, and calendars use iCal links rather than account sign-in.

**Build:** `dotnet publish windows/Docky/Docky.csproj -c Release -r win-x64 --self-contained
-p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true`. It also builds on a Mac
(`EnableWindowsTargeting`). The **Windows** GitHub Actions workflow publishes `Docky.exe` and runs
`Docky.exe --demo <folder>`, which walks through every state with made-up data and saves a
screenshot of each.
