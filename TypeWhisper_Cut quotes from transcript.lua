-- @description TypeWhisper: Cut quotes from transcript
-- @version 0.1.0
-- @author TypeWhisper
-- @website https://www.typewhisper.com
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
--   Scribe.

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

local GAP_BETWEEN_QUOTES = 2.0   -- seconds of silence between quotes on the track
local MAX_LEAD_IN = 0.30         -- longest pause kept before the first word
local MAX_TAIL = 0.40            -- longest pause kept after the last word
local FADE = 0.010               -- fade in and out of every quote
local CROSSFADE = 0.030          -- crossfade at the joints of a combined quote
-- Names in German when the interview track's language is German.
local NAMES = {
  en = { track = "Quotes", cut = "Cut" },
  de = { track = "O-Töne", cut = "Schnitt" },
}

------------------------------------------------------------------------

local SCRIPT_NAME = "TypeWhisper"

local function msg(text)
  reaper.ShowMessageBox(text, SCRIPT_NAME, 0)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function basename(path)
  return (path:match("([^/]+)$") or path)
end

local function strip_extension(name)
  return (name:gsub("%.[^%.]+$", ""))
end

------------------------------------------------------------------------
-- Minimal JSON decoder (same as in the transcription script)
------------------------------------------------------------------------

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)) end
  if cp < 0x10000 then
    return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end
  return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
    0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

local function json_decode(str)
  local pos = 1
  local function skip() pos = str:find("[^ \t\r\n]", pos) or (#str + 1) end
  local parse_value
  local function parse_string()
    pos = pos + 1
    local out = {}
    while true do
      local c = str:sub(pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local e = str:sub(pos + 1, pos + 1)
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        if e == "u" then
          local cp = tonumber(str:sub(pos + 2, pos + 5), 16)
          pos = pos + 6
          if cp >= 0xD800 and cp <= 0xDBFF and str:sub(pos, pos + 1) == "\\u" then
            local lo = tonumber(str:sub(pos + 2, pos + 5), 16)
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            pos = pos + 6
          end
          out[#out + 1] = utf8_char(cp)
        else
          out[#out + 1] = map[e] or e
          pos = pos + 2
        end
      else
        local next_special = str:find('["\\]', pos) or (#str + 1)
        out[#out + 1] = str:sub(pos, next_special - 1)
        pos = next_special
      end
    end
    return table.concat(out)
  end
  function parse_value()
    skip()
    local c = str:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1; skip()
      if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        skip(); local key = parse_string(); skip()
        pos = pos + 1
        obj[key] = parse_value(); skip()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "}" then return obj end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1; skip()
      if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parse_value(); skip()
        local d = str:sub(pos, pos); pos = pos + 1
        if d == "]" then return arr end
      end
    elseif c == '"' then return parse_string()
    elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then error("unexpected character at " .. pos) end
      pos = pos + #num
      return tonumber(num)
    end
  end
  return parse_value()
end

------------------------------------------------------------------------
-- Matching marked text to words
------------------------------------------------------------------------

local UPPER_TO_LOWER = { {"Ä", "ä"}, {"Ö", "ö"}, {"Ü", "ü"}, {"É", "é"}, {"È", "è"}, {"À", "à"} }
local PUNCTUATION = { "“", "”", "„", "«", "»", "‚", "‘", "’", "…", "–", "—" }

-- Lowercase, without punctuation, so "Damals," matches "damals". Multi-byte characters
-- are replaced as whole strings; Lua patterns work on bytes.
local function normalize(word)
  for _, pair in ipairs(UPPER_TO_LOWER) do word = word:gsub(pair[1], pair[2]) end
  for _, mark in ipairs(PUNCTUATION) do word = word:gsub(mark, "") end
  word = word:lower():gsub("%p", "")
  return word
end

local function tokens(text)
  local out = {}
  for word in text:gmatch("%S+") do
    local n = normalize(word)
    if n ~= "" then out[#out + 1] = n end
  end
  return out
end

-- Text of one marked passage, without the transcript's timestamps and speaker labels.
local function clean_passage(text)
  text = text:gsub("%[%d+:%d+:%d+%]", " ")
  text = text:gsub("^%s*%u:%s", " "):gsub("\n%s*%u:%s", "\n")
  return trim(text:gsub("%s+", " "))
end

-- Length of the longest common subsequence of two token lists.
local function common_words(a, b)
  local previous, current = {}, {}
  for j = 0, #b do previous[j] = 0 end
  for i = 1, #a do
    current[0] = 0
    for j = 1, #b do
      if a[i] == b[j] then current[j] = previous[j - 1] + 1
      else current[j] = math.max(previous[j], current[j - 1]) end
    end
    previous, current = current, previous
  end
  return previous[#b]
end

-- Finds the words of a passage. Prefers an exact match; otherwise the stretch of words
-- that starts and ends like the passage and shares most of its words (at least 70 %),
-- so small edits do not matter. With several matches, the one closest to the passage's
-- position in the transcript wins.
local function find_words(words, passage_tokens, near_time)
  local n = #passage_tokens
  if n == 0 then return nil end
  local best, best_score, best_distance
  local function consider(first, last, score)
    local distance = near_time and math.abs(words[first].start - near_time) or 0
    if not best or score > best_score + 1e-9
      or (math.abs(score - best_score) < 1e-9 and distance < best_distance) then
      best, best_score, best_distance = { first, last }, score, distance
    end
  end

  for i = 1, #words - n + 1 do
    local ok = true
    for k = 1, n do
      if words[i + k - 1].norm ~= passage_tokens[k] then ok = false; break end
    end
    if ok then consider(i, i + n - 1, 1) end
  end
  if best then return best[1], best[2], true end

  local slack = math.max(2, math.floor(n * 0.3))
  local norms = {}
  for i = 1, #words do norms[i] = words[i].norm end
  for i = 1, #words do
    -- The stretch starts with the passage's first or second word.
    local start_ok = norms[i] == passage_tokens[1] or (n > 1 and norms[i] == passage_tokens[2])
    if start_ok then
      for j = math.max(i, i + n - 1 - slack), math.min(#words, i + n - 1 + slack) do
        local end_ok = norms[j] == passage_tokens[n] or (n > 1 and norms[j] == passage_tokens[n - 1])
        if end_ok then
          local stretch = {}
          for k = i, j do stretch[#stretch + 1] = norms[k] end
          local score = common_words(stretch, passage_tokens) / math.max(n, #stretch)
          if score >= 0.7 then consider(i, j, score) end
        end
      end
    end
  end
  if best then return best[1], best[2], false end
  return nil
end

------------------------------------------------------------------------
-- Cut points from the audio
------------------------------------------------------------------------

-- Loudness (RMS) of 10 ms windows of a source file between two times (source time).
-- `source.take` plays the whole file from its start, so take time equals source time.
local function window_levels(source, from, to)
  local rate = 16000
  local window = 0.010
  local levels = {}
  if to - from < window then return levels end
  local accessor = reaper.CreateTakeAudioAccessor(source.take)
  local count = math.floor((to - from) / window)
  local samples = math.floor(rate * window)
  local buffer = reaper.new_array(samples)
  for i = 0, count - 1 do
    local t = from + i * window
    buffer.clear()
    reaper.GetAudioAccessorSamples(accessor, rate, 1, t, samples, buffer)
    local sum = 0
    for s = 1, samples do sum = sum + buffer[s] * buffer[s] end
    levels[#levels + 1] = { time = t, rms = math.sqrt(sum / samples) }
  end
  reaper.DestroyAudioAccessor(accessor)
  return levels
end

-- Start of the quote: in the pause before the first word, moved earlier while there is
-- still sound (a soft onset the timing missed), at most MAX_LEAD_IN before the word.
local function cut_start(source, words, first)
  local word_start = words[first].start
  local earliest = math.max(0, word_start - MAX_LEAD_IN)
  -- Stay at least 30 ms after the previous word, so its decay is not in the quote.
  if first > 1 then earliest = math.min(word_start, math.max(earliest, words[first - 1]["end"] + 0.03)) end
  local levels = window_levels(source, earliest, word_start)
  if #levels == 0 then return earliest end
  local quiet = math.huge
  for _, l in ipairs(levels) do quiet = math.min(quiet, l.rms) end
  local threshold = math.max(quiet * 3, 0.001)
  local cut = earliest
  for i = #levels, 1, -1 do
    if levels[i].rms <= threshold then cut = levels[i].time; break end
  end
  return math.max(earliest, cut - 0.02)
end

-- End of the quote: in the pause after the last word, moved later while there is still
-- sound (a last syllable the timing cut off), at most MAX_TAIL after the word.
local function cut_end(source, words, last)
  local word_end = words[last]["end"]
  -- Stay at least 30 ms before the next word, so its onset is not in the quote.
  local next_start = last < #words and words[last + 1].start or math.huge
  local latest = math.max(word_end, math.min(word_end + MAX_TAIL, next_start - 0.03))
  local levels = window_levels(source, word_end, latest)
  if #levels == 0 then return latest end
  local quiet = math.huge
  for _, l in ipairs(levels) do quiet = math.min(quiet, l.rms) end
  local threshold = math.max(quiet * 3, 0.001)
  for _, l in ipairs(levels) do
    if l.rms <= threshold then return math.min(latest, math.max(word_end, l.time + 0.03)) end
  end
  return latest
end

------------------------------------------------------------------------
-- Recordings in the project
------------------------------------------------------------------------

local function project_dir()
  local _, project_file = reaper.EnumProjects(-1)
  if project_file and project_file ~= "" then return project_file:match("^(.*)/[^/]+$") end
  return reaper.GetProjectPath("")
end

-- Every audio source used in the project, with the track of one item that plays it.
local function recordings()
  local list, seen = {}, {}
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local src = reaper.GetMediaItemTake_Source(take)
      local path = reaper.GetMediaSourceFileName(reaper.GetMediaSourceParent(src) or src)
      if path and path ~= "" and not seen[path] then
        seen[path] = true
        list[#list + 1] = { path = path, track = reaper.GetMediaItem_Track(item) }
      end
    end
  end
  return list
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

local function quote_name(words, pieces)
  local first, last = pieces[1], pieces[#pieces]
  local head, tail = {}, {}
  for i = first.first, math.min(first.first + 3, first.last) do head[#head + 1] = words[i].text end
  for i = math.max(last.last - 2, last.first), last.last do tail[#tail + 1] = words[i].text end
  local total = 0
  for _, p in ipairs(pieces) do total = total + (p.last - p.first + 1) end
  if total <= 7 then
    local all = {}
    for _, p in ipairs(pieces) do for i = p.first, p.last do all[#all + 1] = words[i].text end end
    return table.concat(all, " ")
  end
  return table.concat(head, " ") .. " … " .. table.concat(tail, " ")
end

------------------------------------------------------------------------
-- Main
------------------------------------------------------------------------

local function main()
  local dir = project_dir()
  local plan, problems = {}, {}

  for _, rec in ipairs(recordings()) do
    local stem = strip_extension(basename(rec.path))
    local transcript = read_file(dir .. "/" .. stem .. " - transcript.txt")
    if transcript and transcript:find("%[%[") then
      local raw = read_file(dir .. "/TypeWhisper/latest/" .. basename(rec.path) .. ".json")
      local ok, result = pcall(json_decode, raw or "")
      local words = {}
      if ok and type(result) == "table" and type(result.words) == "table" then
        for _, w in ipairs(result.words) do
          local text = trim(w.word or w.text)
          if text ~= "" and w.start and w["end"] then
            words[#words + 1] = { text = text, norm = normalize(text), start = w.start, ["end"] = w["end"] }
          end
        end
      end
      if #words == 0 then
        problems[#problems + 1] = stem .. ": no word timestamps. Transcribe it again with TypeWhisper 1.8.2 and an engine with word timings (Parakeet, ElevenLabs Scribe)."
      else
        local quotes, by_group = {}, {}
        for _, p in ipairs(marked_passages(transcript)) do
          local first, last, exact = find_words(words, tokens(p.text), p.near)
          if not first then
            problems[#problems + 1] = stem .. ": not found: \"" .. p.text:sub(1, 80) .. "\""
          else
            if not exact then
              problems[#problems + 1] = stem .. ": matched with small differences: \"" .. p.text:sub(1, 60) .. "\""
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
    if #problems > 0 then hint = table.concat(problems, "\n") .. "\n\n" .. hint end
    msg(hint)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local _, language = reaper.GetSetMediaTrackInfo_String(plan[1].rec.track, "P_EXT:TypeWhisper_language", "", false)
  local names = NAMES[(language or ""):sub(1, 2)] or NAMES.en

  -- The quotes track: reuse it, or add it at the end.
  local track
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(t)
    if name == names.track then track = t end
  end
  if not track then
    reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
    track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", names.track, true)
  end
  local position = 0
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local it = reaper.GetTrackMediaItem(track, i)
    position = math.max(position, reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") + GAP_BETWEEN_QUOTES)
  end

  -- A temporary item per recording that plays the whole file from its start, for the
  -- audio analysis at the cut points. Removed again below.
  local analysis = {}
  for _, quote in ipairs(plan) do
    local rec = quote.rec
    if not rec.take then
      local item = reaper.AddMediaItemToTrack(track)
      local take = reaper.AddTakeToMediaItem(item)
      local source = reaper.PCM_Source_CreateFromFile(rec.path)
      reaper.SetMediaItemTake_Source(take, source)
      local length = reaper.GetMediaSourceLength(source)
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
      rec.take = take
      analysis[#analysis + 1] = item
    end
  end

  local report = {}
  for _, quote in ipairs(plan) do
    local name = quote_name(quote.words, quote.pieces)
    local quote_start = position
    for index, piece in ipairs(quote.pieces) do
      local from = cut_start(quote.rec, quote.words, piece.first)
      local to = cut_end(quote.rec, quote.words, piece.last)
      local joined = index > 1
      if joined then
        position = position - CROSSFADE
        reaper.AddProjectMarker2(0, false, position + CROSSFADE / 2, 0, names.cut, -1, 0)
      end

      local item = reaper.AddMediaItemToTrack(track)
      local take = reaper.AddTakeToMediaItem(item)
      reaper.SetMediaItemTake_Source(take, reaper.PCM_Source_CreateFromFile(quote.rec.path))
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", from)
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", position)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", to - from)
      reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", joined and CROSSFADE or FADE)
      reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", index < #quote.pieces and CROSSFADE or FADE)
      reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", index == 1 and name or (name .. " (" .. index .. ")"), true)
      position = position + (to - from)
    end
    report[#report + 1] = string.format("%s (%.1f s%s)", name, position - quote_start,
      #quote.pieces > 1 and (", " .. #quote.pieces .. " parts") or "")
    position = position + GAP_BETWEEN_QUOTES
  end

  for _, item in ipairs(analysis) do reaper.DeleteTrackMediaItem(track, item) end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("TypeWhisper: Cut quotes from transcript", -1)
  reaper.SetExtState(SCRIPT_NAME, "last_quotes", tostring(#plan), false)

  local text = #plan .. " quote(s) on track \"" .. names.track .. "\":\n\n" .. table.concat(report, "\n")
  if #problems > 0 then text = text .. "\n\nNotes:\n" .. table.concat(problems, "\n") end
  msg(text)
end

main()
