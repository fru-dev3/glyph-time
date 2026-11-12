# Glyph Time

**See where your hours go.** A quiet count-up on the edge of your screen, a nudge every 30
minutes, every session saved to your vault as plain files.

Its page is [glyph.fru.dev/time](https://glyph.fru.dev/time). Part of the
[Glyph family](https://glyph.fru.dev) by [fru.dev](https://fru.dev): Glyph Bot, Glyph Jot,
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
- **Sounds**: a soft tick every 15 minutes, a different sound on the half hour, a bigger one on
  the hour (Settings: on or off). The green line, ring and border turn orange in the second hour and
  red after two, so a long session shows at a glance.
- **Nudges**: every 30 minutes (Settings: 15 to 90, or never) the clock slides out with "1 h on
  acme-api" and two answers, Keep going or Stop. Left alone it fades back after 8 seconds, and the
  next one is skipped.
- **Count down** 15, 25, 50 or 90 minutes from More or the menu bar. At zero it says so and keeps
  counting the time over (`+3:12`) until you stop.
- **Away**: five minutes without a key or the pointer (Settings: 2 to 15, or never), the screen
  locked or the Mac asleep pause the clock, dated when you left. Back within 30 minutes, it carries
  on; longer, the session ends when you left. A pause you made yourself stays until you resume.
- **Today**: the menu bar lists today's projects and their time, from every device. Click one to
  start again.
- **Recent**: with nothing running, the open clock and the menu bar list your last five projects,
  with today's and the total time. A click starts a new session on one, never reopens the old.
  Right-click one on the clock (or hold Option in the menu) to hide it from Recent; it keeps its
  sessions, is listed under Hidden (menu bar, Settings) and comes back when you start it again.
  Hiding is a line in the session file, so every device agrees.
- **Say it** (dictate first): the mic on the edge clock (beside Start) or Start by Voice in the
  menu bar. Tap, say "Acme deck for the next 10 minutes", "stop", "pause", "remind me at 3 PM,
  studying, 15 minutes before" or "wake me up at 6 AM on weekdays", tap again. The clock says what it
  understood for a few seconds, with Undo. Words are heard on the Mac, never kept. The name prompt
  has Talk; History's session editor has one long green bar at the top: say "that was Acme from 9
  to 11" and the project, start and end fill in (they flash green); Save writes them.
- **History** (`Command-Y` in the menu bar, History... on the clock's More menu, a click on the Dock
  icon while the clock or a window is open, or the Dock menu): where the hours went. Today, a
  week, a month or any days, with back and forward. Total (and how it moved since the period
  before), sessions, the average session, the top project; the day as a time line or the days as
  bars split by project; by project, by initiative or by Glyph Omega goal; twelve weeks; Compare
  against the period before; every session. Click a session to fix its project, start or end, or
  delete it (Undo for six seconds); right-click to start it again. Click a project for its page:
  total, sessions, average, last worked, its twelve weeks, Start Again, Rename (the pencil by its
  name: type it or say it, and every session of it takes the new name, on every device, the phone
  too), its initiative, its links to Glyph CRM and Omega, Hide or Show in Recent, and Suggest for
  Glyph CRM. Export the period as
  CSV or Markdown into `exports/` beside the sessions. Sessions from every device, the phone too.
- **Where your time went** (History, any period): the top apps, the top sites and each project's top
  windows, as green bars with each one's time and share. It needs Track apps and tabs (below).
- **Track apps and tabs** (Settings, opt-in; on by default only when the folder is a Glyph Bot
  vault): while you are at the Mac, session or not, the app in front, its window's title
  (Accessibility) and, in Safari and Chrome (Brave and Edge too), the front tab's title and site
  (Automation: macOS asks once per browser). Away (the same idle time as the clock), locked or
  asleep, nothing is recorded. A running session's project goes on each stretch. Private and
  incognito windows keep only the app's name. **Never record** lists apps (by name or bundle id) and
  sites (with their subdomains) that leave no line at all; it starts with the password apps.
- **Filed deadlines**: in a Glyph Bot vault, the due, expiry and renewal dates the document filer
  writes into each filed document's note ring as a notification, once each: 7 days before at 09:00
  (or on the day at 09:00 when that has passed), for dates in the next 90 days. Read at launch and
  every 6 hours; a document taken back takes its reminder with it. Mac only for now.
- **Screen captures** (Settings, off until you choose): a screenshot every 5, 10, 15 or 30 minutes
  (JPEG, 1280 wide), or a 12-second clip at 2 frames a second (H.264) instead. Screen Recording is
  asked for only when you turn it on. Only while you are at the Mac, never with a private window or
  a never-record app in front, and never past the daily limit (100 MB to 1 GB, 200 MB by default):
  over it, captures skip; nothing is ever deleted. Settings shows today's size, and Move Captures
  Older Than 30 Days to Archive moves those days into `archived-<date>/captures/` beside them.

## Where sessions go

One line per start, pause, resume, name, nudge, stop, hide and show, appended to
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

A session keeps only the project name and the front app's bundle id: never a window title, a URL
or anything you typed. Choose the folder in Settings:

- a **Glyph Bot vault**: sessions in `data/apps/time/sessions/`, and a short Markdown summary
  (today, this week, last week by project, this week by device) at
  `data/domains/time/source/apps/time/summary.md`, where Studio and your agents read it;
- any other folder: `.glyph-time/sessions/` inside it;
- none, or the folder is away: `~/Library/Application Support/Glyph Time/`, as an outbox and never
  as a second store. The same holds for any folder that stops being the one in use: a plain folder
  that later gains a vault, and a folder you point away from in Settings. Glyph Time remembers
  every folder it has written to and folds all of them into the one in use, so changing your mind
  about where sessions live never leaves hours behind. What was written while the folder was away folds into it the moment it is
  back: sessions and activity line by line into the file of the same name (the same line never
  twice), and everything else as whole files (a capture, a project note, an export) carried over
  only into a name that is free. A name already taken is left where it is rather than merged: two
  versions of a note cannot be joined without guessing, and the wrong guess drops what you wrote. A file waiting is taken away only
  once its bytes are in the folder, so a fold cut short strands its lines again instead of losing
  them.

## What Track apps and tabs keeps

Only with Track apps and tabs on (an opt-in: Settings), and only in your folder: one line per
stretch on one thing, written when it ends, to `activity/<YYYY-MM-DD>.<device>.jsonl` beside the
sessions (`data/apps/time/activity/` in a vault). Each Mac writes its own file. The app's name and
bundle id, the window's title (cut at 160 characters), a browser tab's site (the host, never the
full URL), the session's project, and `private: true` for a private window (then no title or
site). Never what you typed, never a page's contents. Captures go to
`captures/<YYYY-MM-DD>/<HHmmss>.<device>.jpg` (or `.mp4`) with a line of their own (`kind`,
`file`, `bytes`). Nothing is uploaded anywhere; the files go where your folder syncs. In a vault,
the summary for Studio adds today's top apps and sites.

```
{"app":"Safari","bundle":"com.apple.Safari","domain":"example.com","end":"2026-10-27T09:14:10-05:00","host":"laptop-local","project":"acme-api","start":"2026-10-27T09:12:04-05:00","title":"Example Domain"}
{"app":"Preview","bytes":182044,"end":"2026-10-27T09:15:00-05:00","file":"captures/2026-10-27/091500.laptop-local.jpg","host":"laptop-local","kind":"shot","start":"2026-10-27T09:15:00-05:00"}
```

To do: a short label for each capture, read on the Mac (Vision's text recognition, then Apple's
on-device model as in GlyphCore's `Summarizer`), written beside it, in the background only on
power and when the Mac is idle. Not built yet.

Fixing the record is a line too, never a rewrite: an `edit` line names a session by its `id` (its
device and first start) with a new `project`, `start` or `end`; `delete` and `undelete` take it out
and bring it back. Any device may write them, in its own file.

```
{"event":"edit","host":"laptop-local","id":"iphone-15-pro 2026-10-27T09:12:04-05:00","start":"2026-10-27T09:00:00-05:00","ts":"2026-10-28T08:01:00-05:00"}
```

Renaming a project is a line too, never a rewrite: `{"event":"rename","project":"old-name",
"label":"new-name"}`. Every session of it reads as the new name, whenever it ran, and the project's
note moves with it.

History keeps a small note per project beside the sessions, `projects/<name>.md`, front matter only:
`project:`, `initiative:` (a label to group by) and `entities:` (Glyph CRM ids such as
`product/acme`, and Omega goals as `goal/g-1a2b3c`, the family's convention, so Glyph CRM can add
ids when you accept a suggestion). Suggest for Glyph CRM appends a pending line to
`data/apps/crm/proposals/<YYYY-MM>.jsonl` (`source: time`); nothing is written to an entity page.

## Build

```sh
./scripts/build.sh --install     # builds "Glyph Time.app" with SwiftPM (no Xcode), copies it to /Applications
```

The session format is `TimeLog` in GlyphCore's GlyphVault (`Packages/GlyphCore`), shared with
every Glyph app that records time.

## Test

```sh
cat Packages/GlyphCore/Sources/GlyphVault/TimeLog.swift TimeLogCheck.swift | swift -   # the format
cat Packages/GlyphCore/Sources/GlyphVault/Spoken.swift Shared/VoiceParse.swift Shared/Schedule.swift VoiceParseCheck.swift | swift -   # what a sentence means
cat Sources/GlyphTime/Activity.swift Shared/FiledReminders.swift ActivityCheck.swift | swift -                      # apps, tabs, captures
cat Packages/GlyphCore/Sources/GlyphVault/{Spoken,TimeLog}.swift Shared/{VoiceParse,Schedule,TimeAnswer}.swift TimeAnswerCheck.swift | swift -   # the chat's own answers
./scripts/ui-check.sh <out dir>                                                           # the app
```

The words, numbers, weekdays, months and clock reading live in GlyphCore (`GlyphVault/Spoken.swift`,
shared with Glyph Well's past-tense `Recall`), so the checks cat that file first. The sentence check reads 45 sentences (real ones, fillers, recognizer slips like "7 30 AM", and the
calendar: in 5 minutes, at 3, tonight, next Tuesday, November 3, the 15th, half past seven, quarter to
nine, midnight, weekdays, weekends, every other day, every 2 hours until 6 pm, the first Monday of
the month, for the next month, for two weeks, until Friday, until December 15, this week only,
starting next Monday) against a fixed now, and checks each one's first and last time. The same
sentences through Apple's on-device model (needs Apple Intelligence and Xcode's toolchain):

```sh
cat Packages/GlyphCore/Sources/GlyphVault/Spoken.swift Shared/VoiceParse.swift Shared/Schedule.swift Shared/VoiceModel.swift VoiceParseCheck.swift VoiceModelCheck.swift > /tmp/v.swift
swiftc -D MODEL_CHECK -o /tmp/v /tmp/v.swift && /tmp/v
```

The UI check runs the real app twice (a plain folder, then a stand-in vault). It clicks the edge
clock's own buttons with mouse events sent to its panel, reads the session file after every step,
and saves a picture of each state in `<out dir>`: start, pause, resume, naming, nudges (answered,
ignored, the next one skipped), a countdown to zero and past it, idle within and past 30 minutes,
screen lock, sleep and wake, activity (made-up fronts through the real tracker: spans, private
windows, the never list, away and lock, the capture limit and archive, Settings' new controls
pressed for real, History's insights), a session left open in the file, no burst of nudges on launch, the
menu bar's items, the shortcut, hiding the clock, Settings, and the summary. Nudges, countdowns
and idle run on a fast clock. It needs no permission and raises no prompt: activity is fed
made-up windows (never the real screen or a browser) and no capture is taken. It runs beside an
installed Glyph Time and never quits it; a run that hangs ends itself after 10 minutes.

## How it is built

Swift and SwiftUI, one small package. A non-activating `NSPanel` on every Space and over
full-screen apps for the clock, `NSStatusItem` for the menu bar, Carbon's hotkey (no
Accessibility needed for it), `CGEventSource` for idle time.

| File | What it does |
|---|---|
| `Clock.swift` | the timer: every action appends a line; the open session is folded back from the file |
| `Edge.swift` | the clock on the screen's edge: tab, count, open card, nudge |
| `Watch.swift` | sleep, lock and idle; the project guess from the front window |
| `Activity.swift` | Track apps and tabs: spans, the never list and private windows, the files, the insights' arithmetic, the capture limit and archive (Foundation only; `ActivityCheck.swift`) |
| `Tracking.swift`, `Insights.swift` | reading the front window and tab, screen captures (ScreenCaptureKit), History's Where your time went |
| `App.swift` | launch, menu bar, the name prompt, the shortcut |
| `Store.swift` | where the files go, and the vault summary |
| `SettingsView.swift`, `UITest.swift` | settings, and the UI check above |
| `HistoryWindow.swift`, `HistoryUITest.swift` | the History window, its project notes, exports and CRM suggestions; its UI check |
| `../Shared/History.swift`, `../Shared/HistoryViews.swift` | History's arithmetic and screens, the same files on the Mac and the iPhone |

## Versions

- **0.1.15** (2026-10-30): reminders an agent on this Mac asks for (`glyphcore-report run time request_reminder`)
  ring here: Glyph Time takes them from `data/apps/time/requests.<this Mac>.jsonl` within a minute and answers on
  their id; alarms and timers wait for the iPhone.
- **0.1.18** (2026-10-31): rename a project. The pencil by its name on its page renames it
  everywhere: one `rename` line, every session of it on every device, its note and its place on
  Recent. The same page, and the same rename, on the iPhone. The History window now says its name
  in the title bar. A fix written in History (a rename, an edit, a delete) is folded back into the
  running session straight away, so the edge clock and the menu agree with the file.
- **0.1.14** (2026-10-29): where your time went, and filed documents' deadlines ring (see Use). Track apps and tabs (opt-in; on by default in a
  vault) keeps the app, window title and browser tab site while you are at the Mac, with a never
  list and private windows kept to the app; History shows the top apps, sites and each project's
  windows; the summary for Studio adds today's apps and sites. Screen captures every 5 to 30
  minutes, screenshots or short clips, off until chosen, with a daily size limit and Move to Archive.
- **0.1.13** (2026-10-29): History's session rows read "10:28 AM to 11:50 AM" (the device is the
  symbol; its name was cut off), and an empty period is one symbol and one line.
- **0.1.12** (2026-10-28): a countdown's end rings every 5 seconds for up to a minute and "Time is up"
  stays until answered. Saying it understands the calendar. "Remind me to take a break in 5
  minutes" is one alarm in 5 minutes named Take a break; "wake me up every day at 7:30 a.m." one
  alarm at 7:30 every day named Wake up; "every Monday, Wednesday and Friday for the next month"
  stops after the month. Days, times and ends are read by rules that are exact about numbers and
  the calendar; Apple's on-device model reads what they can't, and every date it gives is checked.
  A missing time is asked for, and the answer completes the sentence. Filler words never become a name.
- **0.1.9** (2026-10-28): dictate first. Say what to time on the edge clock or from the menu bar
  (timers with a duration, stop, pause, reminders and alarms with a warning before), Talk in the
  name prompt, a long talk bar in the session editor, the initiative mic. Uses GlyphCore's
  GlyphCapture (`LiveDictation`, `DictateButton`).
- **0.1.8** (2026-10-28): History, a window for where your hours go (see Use). Settings shows the
  build, the vault and the folders History uses. Fixes: a project hidden in the second it started
  stays hidden; a session under a minute reads in seconds, not "0 min".
- **0.1.7** (2026-10-27): Recent projects. The open clock lists your last five projects under Start,
  the menu bar too (plus All Projects and Hidden); a click starts a new session on one, and the
  name prompt suggests every project as you type. Right-click (or Option in the menu) hides one;
  Settings can hide projects untouched for 30 days.
- **0.1.6** (2026-10-27): dragging the open clock no longer folds it mid-drag.
- **0.1.5** (2026-10-27): put the clock anywhere on the screen: it stays exactly where you drop it,
  never under the menu bar or the Dock. Keep it open while a session runs, or minimize it to the icon
  and time: the button at its top right, Keep Clock Open in the menu bar, or Control Option M.
- **0.1.4** (2026-10-27): Glyph Time is in the Dock as well as the menu bar. Settings can hide either
  one (never both). A click on the Dock icon opens the clock; a second click opens Settings.
- **0.1.3** (2026-10-27): the clock is redesigned: one column, even spacing, and the Glyph Time icon
  at the edge when closed, with a green ring while it runs. Drag it to either edge; it remembers
  where. Double-click or Reset Clock Position puts it back.
- **0.1.2** (2026-10-27): branded. The runner in the menu bar and at the top of the clock, office
  green for the running state, the main control and a line filling toward the next nudge (a ring on
  the small count), a green tab when idle, light and dark panels, the icon and name atop the menu
  and Settings.
- **0.1.1** (2026-10-27): the Glyph Time icon is now the runner: the family figure mid-stride
  with a stopwatch for a head, chosen for the family. Nothing else changed.
- **0.1.0** (2026-10-27): first release. The edge clock, nudges, countdowns, idle, lock and
  sleep, projects guessed from the front repo, the menu bar with today's projects, sessions as
  plain files and a summary for Glyph Bot.

## License

MIT. See [LICENSE](LICENSE).

## On the iPhone

Glyph Time for the iPhone is its own app (since 2026-10-27; it was a Time area in the Glyph
iPhone app). It opens on the timer and writes the same lines, in its own
`<YYYY-MM>.iphone-<model>.jsonl`, sent whole over your private network into the same sessions
folder. This app merges every file there, so phone sessions show in Today and in the summary.
Alarm and reminder lines are kept but not folded into sessions.

The iPhone has the same History as a tab (1.0.1): every device's sessions, read from the hub's
`GET /time` with the project notes from `GET /time-projects` (read-only, cached for offline), so it
shows the Macs' hours too. Fixes and deletes are lines in the phone's own file. Initiatives and
links are set on the Mac; export shares a CSV or Markdown file. Settings (the timer's top-right
gear since 1.0.4; it was a tab) shows the version and build, where the sessions go and the Recent choice.

Talk first (1.0.2): the big talk button on the timer (GlyphCore's `TalkButton`; it steps aside while
you type). Say "set a reminder for 3 PM today, studying, remind me 15 minutes before", "I'm working
on the Acme deck for the next 10 minutes, remind me", "wake me up at 6 AM on weekdays", a project
name, "stop" or "pause"; what it understood shows just above the talk button with Undo, and it is done with the same
alarm and reminder code as the buttons. The alarm sheet and the session editor open with one long
talk bar that fills their fields; the running clock's mic renames by voice. Typing still works
everywhere.

Understanding (1.0.3): one sentence is one item, said back in full ("Alarm: Wake up, Mon Wed Fri at
6:45 AM, until Nov 27", with Undo). `Shared/VoiceParse.swift` reads the words into slots (what, a
short title, the timing as phrases), `Shared/Schedule.swift` works out and checks the dates against
now and the time zone (once, weekly days, every N days, every N hours in a window, the nth weekday
of the month, a start and an end), and `Shared/VoiceModel.swift` asks Claude through the hub's
receiver (`VoiceForm.read`); every phrase Claude sends back must be in the sentence and readable by
the same code, or it is dropped. On the Mac, Apple's on-device model still reads what the rules
can't make out; on the iPhone nothing does (1.0.21): what the rules read is done at once and
everything else waits for Claude. Something missing ("remind me to call Ken") is one question; the next
thing said answers it. An item with an end or an unusual repeat is put on the schedule as its next
24 times, topped up each time the app opens; plain ones stay one AlarmKit alarm (weekly) or one
notification per day. A running timer is one row: its time, project, Pause and Stop.

Filed deadlines (1.0.5): documents filed into the vault by GlyphCore's filer (agents, Glyph Jot's
scanner) ring on the phone too, as they do on the Mac: each due, expiry or renewal date in the next 90
days, 7 days before at 09:00 (or on the day when that has passed), once. The phone has no vault, so it
reads the Expiring list (`data/domains/records/memory/expiring.md`) through the hub's existing
`GET /crm/file` each time it comes to the front; `FiledReminders` (now in `Shared/`) plans both.
Check: `cat Sources/GlyphTime/Activity.swift Shared/FiledReminders.swift ActivityCheck.swift | swift -`.
