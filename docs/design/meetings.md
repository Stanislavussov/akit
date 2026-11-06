# Meetings: record a call or a talk, get the text, a summary and the tasks

Status: designed 2026-11-06 (grilled with the user); steps 0–5 built and checked on a real
recording the same day (mic + system sound in headphones and through the speakers, OpenRouter with
Gemini 2.5 Flash-Lite, the user: "works great"). Branch `meetings-recorder`, released v2026.11.06-2.

Code: `Meetings/` (its own Swift package: `MeetingsCore`, `MeetingsAudio`, `MeetingsUI`,
`Tests/MeetingsCoreTests`, `App/` for `Meetings.app`), `AKit/Meetings/` (the Crepe editor and the
snapshot states), guide `docs/guides/meetings.ru.md`.

## Goal

One click starts a recording, one click stops it. Everything the Mac hears is recorded: the
user's microphone (also a talk in the room) and the sound of the system (the other people in
Teams, Zoom or Meet, also when the user wears headphones). After Stop the recording becomes one
Markdown file: summary, decisions, tasks and the transcript with times and speakers.

Cost (OpenRouter prices of 2026-11-06, 60 hours a month = 3 h × 20 days):

| Model | per hour | 40 h | 60 h |
|---|---|---|---|
| `google/gemini-2.5-flash-lite` | ~$0.04 | ~$1.6 | ~$2.4 |
| `google/gemini-3.5-flash-lite` | ~$0.065 | ~$2.6 | ~$3.9 |
| `google/gemini-3.1-flash-lite` | ~$0.076 | ~$3.0 | ~$4.5 |
| `google/gemini-2.5-flash` | ~$0.145 | ~$5.8 | ~$8.7 |

One hour of audio is counted as ~115,200 input tokens (32 per second, Gemini) and ~12,000
output tokens of text. The real cost comes from the API's answer (M11), so step 0 checks the
estimate.

Not a meeting bot that joins the call, not live captions, not recording all day.

## Decisions

| # | Topic | Decision |
|---|---|---|
| M1 | Isolation | Its own Swift package `Meetings/` at the repo root (`Package.swift`, `Sources/MeetingsCore`, `Sources/MeetingsUI`, `Tests/`), with no dependency on `AKitCore`. AKit imports only `MeetingsUI` (one arrow). A second app target `Meetings` in `project.yml` runs the same UI on its own, so moving the folder into a new repo is the whole extraction. `make test` runs its tests too |
| M2 | Sound | Always two sources together: the microphone (`AVAudioEngine`, voice processing on, so the sound from the speakers is not recorded twice) and the system output (a Core Audio process tap of all output, macOS 14.2+; the app's target is 15.0). The tap takes the sound before it goes to the headphones, so headphones work |
| M3 | Start | Only by the user: Record and Stop on the Meetings screen (and a keyboard shortcut in the app). No auto start, no recording all day |
| M4 | No visible sign | Asked by the user (they share their screen): no menu bar item, no red or glowing button, no window that comes forward. While it records, only the Meetings screen shows a plain elapsed time. The orange microphone dot of macOS cannot be hidden by any app; in a call it is on anyway. Step 0 checks whether macOS shows a sign for the system tap too |
| M5 | Files | Its own folder, by default `~/Meetings` (a setting), not in `~/.akit`: `~/Meetings/YYYY-MM-DD/HHmm/` with `meeting.json` (state, speakers, segments, cost), `summary.md`, `transcript.md` (made from the JSON), `tabs/<name>.md` and `audio/`. Settings shared by AKit and `Meetings.app` are in `~/Library/Application Support/Meetings/settings.json`. The package knows nothing about AKit; AKit can read the folder later (Open) |
| M6 | Safe recording | The audio is written in 5-minute pieces while it records, so a crash or a sleep loses at most the open piece. A recording that was not stopped is found at the next start and offered for transcription |
| M7 | Audio kept | The audio pieces (mixed mono AAC, ~30 MB per hour) are moved to the Trash 14 days after the recording; the text stays. A recording can be transcribed again while its audio is there |
| M8 | Provider | OpenRouter only (the user's choice), plain HTTPS to `https://openrouter.ai/api/v1/chat/completions` with an `input_audio` part (base64; the format the model takes). No SDK: OpenRouter has no Swift one, and the API is OpenAI-compatible |
| M9 | Key | The user pastes the OpenRouter key once; it is kept in the Keychain (the package's own item), never shown, logged or written to a file |
| M10 | Models | Settings → Model is a Picker filled from `GET /api/v1/models`: models whose `input_modalities` has `audio` and whose output is text, sorted by the estimated price of one hour (from `pricing.audio` and `pricing.completion`), each row with that price. Recommended rows are marked: the Gemini Flash-Lite family (cheap, good at Czech). Default `google/gemini-2.5-flash-lite`. The summary uses the same model unless a second Picker (text models) says otherwise |
| M11 | Cost | Each call stores the tokens and the cost from the answer's `usage`. `meeting.md` keeps the sum; the screen shows the month's total. A monthly limit (setting, default $10) stops new calls, not recordings |
| M12 | Two tracks, one upload | The two sources are mixed into one track, so each minute is paid once. While it records, the package marks when the microphone carries speech (a level gate on the mic before mixing). Those spans go into the prompt as hints: "in these spans the speaker is Me". The other voices are Speaker 1, 2, …; the model splits them. A talk in the room goes through the mic only; the model splits those voices too |
| M13 | Chunks | The audio is sent in pieces of up to 30 minutes, one call each, in order; each answer is JSON segments `{start, speaker, text}` with times from the start of the recording. A failed piece is retried alone |
| M14 | Language | The transcript stays in the language spoken; the prompt says "most likely Czech, may also be Russian or English". Summary, decisions and tasks are written in the chosen language, Czech by default (Settings → Language, a Picker) |
| M15 | Result | After the last piece one text call over the transcript writes: a title, a summary of 3–5 sentences, decisions, tasks (`- [ ] Me: …`, `- [ ] Speaker 2: …`). Speakers can be renamed after the recording; the file is rewritten with the names |
| M16 | Screen | In AKit: Work → Meetings. In `Meetings.app`: the same view in its window. A list of days and meetings (title, length, cost, state: recording, waiting, transcribing, done, failed). A meeting opens on its tabs (M17), with Rename Speakers…, Transcribe Again, Show in Finder, Move to Trash… |
| M18 | Links | Asked by the user the same day ("a shortcut as for the notebook"): `akit://meetings` opens the screen; `akit://meetings/record`, `/stop` and `/toggle` act without switching AKit's screen, then give the focus back to the app that was in front (M4). A Raycast quicklink with a hotkey on `/toggle` is the one-key Record/Stop. With the window closed, macOS opens it first |
| M19 | Review round | 2026-11-06 code review: one model per app (closing the window keeps the recording; a released recorder stops its devices); `flock` locks `audio/.recording.lock` and `.processing.lock`, so AKit and `Meetings.app` never take each other's live recording or send its audio twice; the microphone restarts on `AVAudioEngineConfigurationChange`, the tap on a new output with retries, a failure shows on screen; every source counts from the recording's common host time and gaps become silence, so pieces stay in step; the processor resumes from the next untranscribed piece and saves only its own fields; Summary is locked while it records or transcribes, and a user-edited summary moves to an own tab `Notes` before a new one replaces it; an unreadable raw part is left out and named in the meeting's warnings; Quit stops a running recording first |
| M20 | Tracks | Asked by the user after the first real recordings: a talk in the room and a call in the headphones at once, two people talking together. The mixer keeps each source's own track beside the mix (`mic-NNN.aac`, `sys-NNN.aac`) and the spans in which the system sound carried speech (`others`). Settings → Tracks: **Auto** (default) sends a 30-minute chunk as two tracks when the mic's and the system's speech overlap for ≥ 3 s, else the mix; **Mixed** always the mix (1×); **Separate** always two tracks (2×). A two-track chunk is two calls: the mic track (Me, room voices R1, R2 …, Me hints) and the system track (S1, S2 …, never Me); the lines are merged by time. Every prompt asks for both lines where two people talk at once. Changes M12's "one upload" only where voices overlap |
| M17 | Tabs | Asked by the user the same day: a meeting is not "a recording" but its tabs. Summary first (summary, decisions, tasks), then Transcript, then the user's own tabs: plain Markdown pages (notes, links), added, renamed and removed like the Notebook's tabs. Own tabs are files `tabs/<name>.md` in the meeting's folder, never sent to a model. Summary is editable too (its section of `meeting.md`); Transcript is read only. The editor comes from the host app: AKit passes its Crepe editor (the Notebook's), `Meetings.app` a plain Markdown text editor, so the package needs no web bundle |

## Pages

`summary.md` (editable, the Summary tab):

```markdown
## Summary
3–5 sentences

## Decisions
- …

## Tasks
- [ ] Me: …
- [ ] Jana: …
```

`transcript.md` (written from `meeting.json`, speakers by their names):

```markdown
# Sync with the team

[00:00] **Me**: …

[00:12] **Jana**: …
```

## Steps

| Step | What | Check |
|---|---|---|
| 0 | Spike on this Mac: mic + system tap with headphones and with speakers (voice processing), the permission prompts, which signs macOS shows while it records; one 5-minute Czech sample through OpenRouter: tokens per second, cost, quality of the Me hints | notes in this doc, no code kept |
| 1 | Package skeleton, `make test` runs it; MeetingsCore: folder layout, `meeting.md` write and read, the 14-day Trash rule | tests with a fake home |
| 2 | Recorder: both sources, 5-minute pieces, mixing, mic speech spans, recovery of an unstopped recording | tests on recorded sample buffers; manual run |
| 3 | OpenRouter: Keychain key, the models list and its sorting, chunked transcription, the summary call, cost and the monthly limit | tests against a fake server |
| 4 | MeetingsUI: list, open recording, settings, Rename Speakers | `make snapshot` with a made-up `~/Meetings` |
| 5 | Into AKit (Work → Meetings) and the `Meetings` app target; guide `docs/guides/meetings.ru.md` | snapshot, guide screenshots from a made-up home |

## Open

- Open from the review, for step 0's device run: whether the IOProc's input holds only the tap's
  stream when the output device also has inputs (a USB headset, AirPods), and whether a call's
  Bluetooth profile changes the aggregate's rate while the tap's format stays.

- AKit reads `~/Meetings`: tasks into the Notebook, a line per meeting into the Work Log.
- A global hotkey for Record/Stop without bringing AKit forward.
- The `:batch` models OpenRouter lists (cheaper, slower), if they take audio this way.
- The user chose a cloud model also for work meetings; the work Mac's policy is the user's call.
