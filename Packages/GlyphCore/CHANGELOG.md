# Changelog

GlyphCore follows semantic versioning (the number is in `VERSION`). A change that alters
the on-disk format or breaks the public API is a major version, a new API a minor one, a
fix a patch. Every change gets a line here, so an app can see what moved before it updates.

## 0.3.0 (2026-10-27)

- GlyphVault: `TimeLog`, `TimeEvent` and `TimeSession`, Glyph Time's session format: one JSON line
  per start, name, pause, resume, nudge and stop in `<YYYY-MM>.<device>.jsonl`, each device its
  own file. `sessions` folds the lines (a start while one is open closes it), `totals` sums by
  project, `summary` writes the Markdown read for Glyph Studio, `clock` and `span` format time.
  New files only; nothing existing changed. Check: `Time/TimeLogCheck.swift`.

## 0.2.0 (2026-10-26)

- GlyphCapture: `Diarizer` finds who spoke when, on device (FluidAudio 0.17.7, Apache-2.0,
  with pyannote Community-1 models, CC-BY-4.0, downloaded once). `Transcriber.transcribe`
  takes its `turns` and splits each heard sentence where the speaker changes, by word times.
  `Waveform.peaks` reads a recording's loudness outline for drawing.
- GlyphVault: `SpeakerTurn` (cleaned and numbered `S1`, `S2`...), `Transcript.split`,
  `Transcript.name(of:)` ("Speaker 2" until named) and `talkTime`. `transcript.txt` names
  unnamed voices "Speaker N". The format is unchanged: `speaker` and `speakers` were there.

## 0.1.2 (2026-10-25)

- GlyphVault: `meta.json` gains `device`, the machine a recording was made on (the
  computer's name, `ThisDevice.name`). Optional: older files read as before, and
  `createConversation(device:)` takes another name (tests use a made-up one).

## 0.1.1 (2026-10-25)

- GlyphAI: notes keep only action items the conversation states. Placeholders the model
  writes into an empty list ("None", "N/A", "No other action items mentioned") are dropped
  from decisions and actions.

## 0.1.0 (2026-10-25)

First version, from JotCore (the vault reader Jot Studio started from).

- Products: `GlyphVault`, `GlyphCapture`, `GlyphAI`, and `GlyphCore` re-exporting all three.
- GlyphVault: the Memosa vault reader (field-for-field parity with Memosa's reader) and a
  writer in the exact format: conversations with dated slugs, meta.json, transcript.json and
  transcript.txt, notes.md, task toggles, rename, move, trash into `.memosa/trash` (never
  deletes), folders; People and Accounts notes with rename rewriting every link; links
  through aliases; suggestions; tasks across the vault; `Library` (`@Observable`) following
  the folder on disk. Golden files pin the format.
- GlyphCapture: `Recorder` (mic and the Mac's sound into one AAC .m4a, levels, pause,
  safe stop, feedable for tests), `Transcriber` (SpeechAnalyzer on the device, names as
  context, model download with progress), `Permissions`.
- GlyphAI: `Summarizer` (summary, decisions, action items with owner and due date, long calls
  in parts) and `LinkSuggester`, with Apple's on-device model.
