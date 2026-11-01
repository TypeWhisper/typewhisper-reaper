# TypeWhisper for REAPER

Three ReaScripts: one transcribes your recordings with TypeWhisper, the other two cut finished quotes from them, either from passages you mark in the transcript or straight from the quotes in your manuscript.

## Transcribe selected items

![Transcript as regions on the REAPER timeline](assets/regions.png)

A ReaScript that sends the selected audio items to TypeWhisper on your Mac and adds the transcript to your REAPER project. REAPER stays usable while TypeWhisper works in the background.

- Regions on the timeline, formed from sentences and speaker changes, placed at the right time even for trimmed or moved items
- The audible text of each item in its notes
- A transcript file per recording (`<recording> - transcript.txt`, with timestamps and speakers) and a program text of all selected items in timeline order (`<project> - program text.txt`), both next to the project
- Running it again replaces only the regions it created before (your own regions stay, whatever their color); unchanged files come from the cache (`TypeWhisper/` next to the project)
- The word timestamps next to the recording as `<recording>.timestamps.json`, the same file the TypeWhisper app writes, so the quote scripts find them in any project
- Optional: a Markdown transcript per recording for Obsidian, `<recording> - transcript.md`, in a folder you set as `MARKDOWN_FOLDER` at the top of the script, for example your vault. Its frontmatter names the recording and its timestamps; the text has a paragraph per speaker turn with time and speaker. See [Manuscript, transcript and recording](#manuscript-transcript-and-recording).
- A transcript you edited, for example with `[[ ]]` marks for the quote script, is kept on a new run instead of being overwritten

## Requirements

- TypeWhisper for macOS, running
- Settings > Advanced > API Server turned on
- An engine with timestamps for regions and item notes, for example Parakeet or WhisperKit. Engines without timestamps only fill the transcript file.
- Speaker labels (A:, B:) need TypeWhisper Premium

## Installation

1. Copy the three `TypeWhisper_*.lua` scripts and the `lib` folder into one folder, for example `~/Library/Application Support/REAPER/Scripts/TypeWhisper/`. The two quote scripts load `lib/quotes.lua` from next to themselves.
2. In REAPER, open Actions > Show action list > New action > Load ReaScript and choose each `TypeWhisper_*.lua` file.
3. Optional: assign a keyboard shortcut or toolbar button.

## Usage

Select one or more audio items and run `Script: TypeWhisper_Transcribe selected items.lua`. A short dialog asks for:

- **Language**: `de`, `en`, … or `auto`. Stored per track. With items on tracks with different languages it shows `per track`.
- **Engine** and **Model**: empty uses the TypeWhisper settings, for example `parakeet` and `parakeet-tdt-0.6b-v3`.
- **Speakers**: `y` adds A:, B: to regions and notes.

Further settings (regions, notes, files, cache, minimum region length, pause length) are at the top of the script.

## Cut quotes from transcript

![Quotes cut from the marked transcript, with a cut marker at the joint](assets/quotes.png)

Cuts the passages you marked in a transcript into finished quotes on their own track ("Quotes", or "O-Töne" when the interview track is set to German).

1. Transcribe the interview with "Transcribe selected items" (version 0.2.1 or later). It writes `<recording> - transcript.txt` next to the project and keeps the word timestamps in `TypeWhisper/latest/`.
2. Open the transcript in any text editor and put `[[` and `]]` around each passage you want as a quote. Passages with the same number, for example `[[1: We didn't know back then]]` at minute 12 and `[[1: how big it would get]]` at minute 22, become one quote in the order they appear.
3. Save the file and run `Script: TypeWhisper_Cut quotes from transcript.lua`.

What it does:

- Finds each passage by its words. Small edits in the passage are fine; the script reports passages it matched with differences or could not find.
- Starts each quote in the pause before its first word and ends it in the pause after its last word. The cut points are checked against the audio, so a soft onset or a last syllable that the transcript timing misses stays in, and the neighbouring words stay out.
- Adds 10 ms fades, a 30 ms crossfade at the joints of a combined quote and a "Cut" ("Schnitt") marker at each joint.
- Names each quote after its first and last words, for example "We didn't know … how big it would get".
- Asks where the quotes go: into a new project tab, or into this project after everything else, so they never play at the same time as the recording.
- Running it again replaces the quotes and cut markers from the last run, also when you deleted the quotes track in between. Everything else stays.
- Reports passages that differ from what was said and cuts where the speech runs through without a pause, so you can listen to those.

Needs word timestamps: TypeWhisper 1.8.2 with an engine that reports them, such as Parakeet or ElevenLabs Scribe.

## Cut quotes from manuscript

Cuts the quotes of a radio or podcast manuscript in the order of the manuscript. There is nothing to mark: the manuscript is the cut list. Write it in Obsidian, any Markdown editor or as plain text, with each quote under a label line, the way radio manuscripts look anyway:

```markdown
**Host:**
Anna Miller opened her bakery ten years ago. The hardest part came later:

**Quote Miller, baker:**
*"The first year was easy. The second one almost ended it."*

Quote Miller:
"We had no idea how expensive flour would get … and still, we never closed a single day."
```

1. Link the transcript note in the manuscript's frontmatter (see below), or transcribe the interview with "Transcribe selected items" in the project.
2. Run `Script: TypeWhisper_Cut quotes from manuscript.lua` and choose the manuscript (`.md` or `.txt`).

What it does:

- Finds every quote under a label line: `Quote Name:`, `O-Ton Name:` or `Soundbite Name:`, with the quote below or on the same line. Markdown emphasis, highlights and quote marks don't matter; other labels such as `Overvoice:` are skipped.
- `…` (or `...`) inside a quote is a cut, as usual in radio: the parts are joined with a crossfade and a "Cut" marker, even when they lie minutes apart. `…` at the very start or end only marks a fragment.
- Small differences to what was said are fine, for example a corrected name. The report lists each one, manuscript against what was said, so the manuscript can be brought in line.
- Names the quotes O1, O2, … with the speaker from the label and puts them on a track named after the manuscript, in a new project tab or after everything else in this project.
- Run it again after editing the manuscript: it replaces its quotes and cut markers from the last run and leaves everything else alone. Each manuscript gets its own track.

Cutting, fades and the report work as in "Cut quotes from transcript".

### Manuscript, transcript and recording

The manuscript script finds the interview through links, so it also works in an empty project and no matter whether the transcript comes from the TypeWhisper app or from REAPER:

```markdown
---
interview: "[[MixPre-001 - transcript]]"
---
```

The manuscript's frontmatter links the transcript note. The note's frontmatter names the recording and its word timestamps:

```markdown
---
audio: "/Volumes/MixPre/MixPre-001.wav"
timestamps: "/Volumes/MixPre/MixPre-001.timestamps.json"
duration: 3612.4
language: "de"
---

**[00:12:03] A:** …
```

"Transcribe selected items" writes such notes when `MARKDOWN_FOLDER` is set. Links work as in Obsidian: `[[name]]`, `[[folder/name]]`, `[[name|alias]]`, found anywhere in the vault. A manuscript can link several interviews. When a file has moved, the script also looks for it by name next to the note. Without a link it uses the recordings in the project and their timestamps.

## Notes

- Each source file is transcribed once, even when it is cut into many items.
- Long recordings: TypeWhisper reads the file directly, there is no size limit. Older TypeWhisper versions fall back to an upload of up to 256 MB.
- The language setting is a hint. Parakeet can still switch languages in mixed or unclear passages.
- macOS only.

## Changes

- Transcribe selected items 0.3.0: word timestamps next to the recording (`<recording>.timestamps.json`); optional Markdown transcript for Obsidian with the recording and its timestamps in the frontmatter (`MARKDOWN_FOLDER`); keeps transcripts you edited instead of overwriting them.
- Cut quotes from manuscript 0.2.0: finds the interview through the manuscript's frontmatter link to the transcript note, also in an empty project; also finds the timestamps next to the recording.
- Cut quotes from manuscript 0.1.0: first version, by Marcus Schuler.
- Cut quotes from transcript 0.2.0: asks whether the quotes go into a new project tab or after everything else in the project; a new run replaces the quotes and cut markers of the last one; a cut between two close words goes into the quiet stretch of the gap, so the next word stays out even when its timing starts too late; names written as one word where the transcript has two ("TypeWhisper", "Type Whisper") are matched completely; the report shows what was said and names cuts without a pause; also reads the timestamps next to the recording when the project has none. Shares its code with the manuscript script (`lib/quotes.lua`).
- Transcribe selected items 0.2.2: no doubled regions in projects where an early 0.2.1 variant stored region numbers without their start.
- Cut quotes from transcript 0.1.0: first version.
- Transcribe selected items 0.2.1: speaker labels also with word timestamps (words take the speaker of their segment); inside a sentence only a pause of 3 seconds starts a new region, so regions end at sentence ends instead of breathing pauses; a new run replaces only the regions this script created (stored by region number and start in the project), not every region in its color; keeps the latest transcript of each recording for the quote script.
- Transcribe selected items 0.2.0: direct file access instead of upload, one request per source file with cache, sentence-based regions, item notes with only the audible text, language per track, speaker labels, progress window, transcript and program text files, replaces its own regions on a new run.
- Transcribe selected items 0.1.0: first version.

## Contributors

- [Marcus Schuler](https://schuler.media) ([@MarcusSchuler](https://x.com/MarcusSchuler) on X): tested the scripts on real radio productions, contributed the speaker labels with word timestamps and the region record in 0.2.1, the placement of the quotes in 0.2.0 of "Cut quotes from transcript" and the script "Cut quotes from manuscript".

## License

MIT, see [LICENSE](LICENSE).
