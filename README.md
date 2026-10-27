# Glyph Time

**See where your hours go.** A quiet count-up on the edge of your screen, a nudge every 30
minutes, every session saved to your vault as plain files.

Its page is [glyph.fru.dev/time](https://glyph.fru.dev/time). Part of the
[Glyph family](https://glyph.fru.dev) by [fru.dev](https://fru.dev): Glyph Studio, Glyph Jot,
Glyph Ibis and Glyph Rig, plus the tools Glyph Arena, Glyph Cast and Glyph Time.

## Install

Download [Glyph-Time.dmg](https://github.com/fru-dev3/glyph-time/releases/latest/download/Glyph-Time.dmg)
and drag Glyph Time to Applications. It is signed and notarized by Apple. Needs macOS 26 on
Apple silicon. It lives in the menu bar and on the right edge of the screen; there is no Dock icon.

## Use

- **Start** from the clock on the right edge (hover it), the menu bar, or `Control-Option-T` from
  anywhere. The same keys pause and resume. Nothing ever takes the focus from the app you are in.
- **The clock** rests as a small count with a dot: green while it runs, a hollow ring while
  paused. Hover it for the project, the time and three controls: pause or resume, stop, more.
- **Projects** are optional. Unnamed, a session takes the repo or folder of the terminal or editor
  in front (with Accessibility allowed), else the app's name, shown dimmed as a guess. Name it any
  time from the clock's More menu or the menu bar.
- **Nudges**: every 30 minutes (Settings: 15 to 90, or never) the clock slides out with "1 h on
  acme-api" and two answers, Keep going or Stop. Left alone it fades back after 8 seconds, and the
  next one is skipped.
- **Count down** 15, 25, 50 or 90 minutes from More or the menu bar. At zero it says so and keeps
  counting the time over (`+3:12`) until you stop.
- **Away**: five minutes without a key or the pointer (Settings: 2 to 15, or never), the screen
  locked or the Mac asleep pause the clock, dated when you left. Back within 30 minutes, it carries
  on; longer, the session ends when you left. A pause you made yourself stays until you resume.
- **Today**: the menu bar lists today's projects and their time, from every device.

## Where sessions go

One line per start, pause, resume, name, nudge and stop, appended to
`<folder>/<YYYY-MM>.<device>.jsonl`. Each device writes only its own file, so a folder synced
between Macs never conflicts; readers merge the files by time. The file is the timer: quit, crash
or restart and the clock picks up where the lines say.

```
{"device":"Laptop","event":"start","host":"laptop-local","project":"acme-api","source":"repo","ts":"2026-10-27T09:12:04-05:00"}
{"event":"pause","host":"laptop-local","reason":"idle","ts":"2026-10-27T09:40:00-05:00"}
{"event":"resume","host":"laptop-local","ts":"2026-10-27T09:43:10-05:00"}
{"answer":"keep","event":"nudge","host":"laptop-local","minutes":30,"ts":"2026-10-27T09:45:14-05:00"}
{"event":"stop","host":"laptop-local","minutes":85,"ts":"2026-10-27T10:40:12-05:00"}
```

Only the project name and the front app's bundle id are kept: never a window title, a URL or
anything you typed. Choose the folder in Settings:

- a **Glyph Studio vault**: sessions in `data/apps/time/sessions/`, and a short Markdown summary
  (today, this week, last week by project, this week by device) at
  `data/domains/time/source/apps/time/summary.md`, where Studio and your agents read it;
- any other folder: `.glyph-time/sessions/` inside it;
- none: `~/Library/Application Support/Glyph Time/sessions/`.

## Build

```sh
./scripts/build.sh --install     # builds "Glyph Time.app" with SwiftPM (no Xcode), copies it to /Applications
```

The session format is `TimeLog` in GlyphCore's GlyphVault (`Packages/GlyphCore`), shared with
every Glyph app that records time.

## Test

```sh
cat Packages/GlyphCore/Sources/GlyphVault/TimeLog.swift TimeLogCheck.swift | swift -   # the format
./scripts/ui-check.sh <out dir>                                                           # the app
```

The UI check runs the real app twice (a plain folder, then a stand-in vault). It clicks the edge
clock's own buttons with mouse events sent to its panel, reads the session file after every step,
and saves a picture of each state in `<out dir>`: start, pause, resume, naming, nudges (answered,
ignored, the next one skipped), a countdown to zero and past it, idle within and past 30 minutes,
screen lock, sleep and wake, a session left open in the file, no burst of nudges on launch, the
menu bar's items, the shortcut, hiding the clock, Settings, and the summary. Nudges, countdowns
and idle run on a fast clock. It needs no permission.

## How it is built

Swift and SwiftUI, one small package. A non-activating `NSPanel` on every Space and over
full-screen apps for the clock, `NSStatusItem` for the menu bar, Carbon's hotkey (no
Accessibility needed for it), `CGEventSource` for idle time.

| File | What it does |
|---|---|
| `Clock.swift` | the timer: every action appends a line; the open session is folded back from the file |
| `Edge.swift` | the clock on the screen's edge: tab, count, open card, nudge |
| `Watch.swift` | sleep, lock and idle; the project guess from the front window |
| `App.swift` | launch, menu bar, the name prompt, the shortcut |
| `Store.swift` | where the files go, and the vault summary |
| `SettingsView.swift`, `UITest.swift` | settings, and the UI check above |

## Versions

- **0.1.2** (2026-10-27): branded. The runner in the menu bar and at the top of the clock, office
  green for the running state, the main control and a line filling toward the next nudge (a ring on
  the small count), a green tab when idle, light and dark panels, the icon and name atop the menu
  and Settings.
- **0.1.1** (2026-10-27): the Glyph Time icon is now the runner: the family figure mid-stride
  with a stopwatch for a head, chosen for the family. Nothing else changed.
- **0.1.0** (2026-10-27): first release. The edge clock, nudges, countdowns, idle, lock and
  sleep, projects guessed from the front repo, the menu bar with today's projects, sessions as
  plain files and a summary for Glyph Studio.

## License

MIT. See [LICENSE](LICENSE).
