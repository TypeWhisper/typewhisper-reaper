-- @description TypeWhisper: Cut quotes from transcript
-- @version 0.2.0
-- @author TypeWhisper
-- @website https://www.typewhisper.com
-- @changelog
--   0.2.0
--   - Asks where the quotes go: a new project tab, or this project after everything
--     else, so they no longer play at the same time as the recording.
--   - A new run replaces the quotes and cut markers of the last one, also when the
--     quotes track was deleted in between.
--   - Cut ends between two close words go into the quietest stretch of the gap, so the
--     next word stays out even when its timing starts too late.
--   - The report names cuts where the speech runs through, and shows what was said
--     for passages matched with small differences.
--   - Shares its code with "Cut quotes from manuscript" (lib/quotes.lua).
--   - Also reads the word timestamps next to the recording
--     ("<recording>.timestamps.json") when the project has none.
-- @about
--   Cuts the passages you marked in a transcript into finished quotes on their own
--   track.
--
--   1. Transcribe the interview with "TypeWhisper: Transcribe selected items".
--      It writes "<recording> - transcript.txt" next to the project.
--   2. Open that file in any text editor and put [[ and ]] around each passage you
--      want as a quote. Passages with the same number, such as [[1: ...]] at minute 12
--      and [[1: ...]] at minute 22, become one quote in the order they appear.
--   3. Save the file and run this script.
--
--   Each quote starts in the pause before its first word and ends in the pause after
--   its last word. The cut points are checked against the audio, so a last syllable
--   that the transcript timing misses is kept. Quotes get short fades; the joints of a
--   combined quote get a crossfade and a "Cut" marker. Quotes are named after their
--   first and last words.
--
--   Needs word timestamps, for example TypeWhisper 1.8.2 with Parakeet or ElevenLabs
--   Scribe, and lib/quotes.lua next to this script.

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]") or "."
local loaded, Q = pcall(dofile, script_dir .. "/lib/quotes.lua")
if not loaded then
  reaper.ShowMessageBox("lib/quotes.lua is missing next to this script. Copy the whole TypeWhisper folder.\n\n" ..
    tostring(Q), "TypeWhisper", 0)
  return
end

-- Text of one marked passage, without the transcript's timestamps and speaker labels.
local function clean_passage(text)
  text = text:gsub("%[%d+:%d+:%d+%]", " ")
  text = text:gsub("^%s*%u:%s", " "):gsub("\n%s*%u:%s", "\n")
  return Q.trim(text:gsub("%s+", " "))
end

-- Marked passages of a transcript file: text, quote number and the time of the line.
local function marked_passages(transcript)
  local passages = {}
  for start_pos, inner in transcript:gmatch("()%[%[(.-)%]%]") do
    local before = transcript:sub(1, start_pos)
    local h, m, s
    for hh, mm, ss in before:gmatch("%[(%d+):(%d+):(%d+)%]") do h, m, s = hh, mm, ss end
    local near = h and (tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)) or nil
    local number, rest = inner:match("^%s*(%d+)%s*:%s*(.*)$")
    passages[#passages + 1] = {
      text = clean_passage(rest or inner),
      group = number and tonumber(number) or nil,
      near = near,
    }
  end
  return passages
end

local function main()
  local dir = Q.project_dir()
  local plan, notes = {}, {}

  for _, rec in ipairs(Q.recordings()) do
    local stem = Q.strip_extension(Q.basename(rec.path))
    local transcript = Q.read_file(dir .. "/" .. stem .. " - transcript.txt")
    if transcript and transcript:find("%[%[") then
      local words = Q.load_words(dir, rec)
      if not words then
        notes[#notes + 1] = stem .. ": no word timestamps. Transcribe it again with TypeWhisper 1.8.2 and an engine with word timings (Parakeet, ElevenLabs Scribe)."
      else
        local quotes, by_group = {}, {}
        for _, p in ipairs(marked_passages(transcript)) do
          local first, last, exact = Q.find_words(words, Q.tokens(p.text), p.near)
          if not first then
            notes[#notes + 1] = stem .. ": not found: „" .. p.text:sub(1, 80) .. "“"
          else
            if not exact then
              notes[#notes + 1] = stem .. ": differs from what was said:\n    marked: „" .. p.text ..
                "“\n    said:   „" .. Q.words_text(words, first, last) .. "“"
            end
            local piece = { first = first, last = last }
            if p.group and by_group[p.group] then
              table.insert(by_group[p.group].pieces, piece)
            else
              local quote = { pieces = { piece }, rec = rec, words = words }
              quotes[#quotes + 1] = quote
              if p.group then by_group[p.group] = quote end
            end
          end
        end
        for _, q in ipairs(quotes) do plan[#plan + 1] = q end
      end
    end
  end

  if #plan == 0 then
    local hint = "No marked passages found.\n\nTranscribe the interview first, then put [[ and ]] around the passages in \"<recording> - transcript.txt\" next to the project and run this script again."
    if #notes > 0 then hint = table.concat(notes, "\n") .. "\n\n" .. hint end
    Q.msg(hint)
    return
  end

  local names = Q.names_for(plan[1].rec)
  Q.place(plan, {
    track_name = names.track,
    mark_key = "TypeWhisper_quotes",
    mark_value = "transcript",
    -- Version 0.1 marked nothing: its track is the one with the plain quotes name.
    legacy_track = function(n)
      for i = 0, reaper.CountTracks(0) - 1 do
        local t = reaper.GetTrack(0, i)
        local _, name = reaper.GetTrackName(t)
        local _, mark = reaper.GetSetMediaTrackInfo_String(t, "P_EXT:TypeWhisper_quotes", "", false)
        if name == n.track and mark == "" then return t end
      end
    end,
    marker_key = "transcript_markers",
    undo = "TypeWhisper: Cut quotes from transcript",
    intro = #plan .. " quote(s) ready.",
  }, notes)
end

main()
