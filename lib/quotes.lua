-- Shared code of the TypeWhisper quote scripts ("Cut quotes from transcript" and
-- "Cut quotes from manuscript"): word timestamps, finding passages, cut points from the
-- audio and placing the quotes. Not an action of its own; the scripts load it.

local M = {}

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

M.GAP_BETWEEN_QUOTES = 2.0   -- seconds of silence between quotes on the track
M.GAP_AFTER_CONTENT = 5.0    -- seconds between the end of the project's content and the first quote
M.MAX_LEAD_IN = 0.30         -- longest pause kept before the first word
M.MAX_TAIL = 0.40            -- longest pause kept after the last word
M.FADE = 0.010               -- fade in and out of every quote
M.CROSSFADE = 0.030          -- crossfade at the joints of a combined quote
-- Names in German when the interview track's language is German.
M.NAMES = {
  en = { track = "Quotes", cut = "Cut" },
  de = { track = "O-Töne", cut = "Schnitt" },
}

------------------------------------------------------------------------

M.SCRIPT_NAME = "TypeWhisper"

function M.msg(text)
  reaper.ShowMessageBox(text, M.SCRIPT_NAME, 0)
end

function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

function M.trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.basename(path)
  return (path:match("([^/]+)$") or path)
end

function M.strip_extension(name)
  return (name:gsub("%.[^%.]+$", ""))
end

function M.clock(seconds)
  return string.format("%d:%04.1f", math.floor(seconds / 60), seconds % 60)
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
M.json_decode = json_decode

------------------------------------------------------------------------
-- Matching text to words
------------------------------------------------------------------------

M.UPPER_TO_LOWER = { {"Ä", "ä"}, {"Ö", "ö"}, {"Ü", "ü"}, {"É", "é"}, {"È", "è"}, {"À", "à"} }
local PUNCTUATION = { "“", "”", "„", "«", "»", "‚", "‘", "’", "…", "–", "—" }

-- Lowercase, without punctuation, so "Damals," matches "damals". Multi-byte characters
-- are replaced as whole strings; Lua patterns work on bytes.
function M.normalize(word)
  for _, pair in ipairs(M.UPPER_TO_LOWER) do word = word:gsub(pair[1], pair[2]) end
  for _, mark in ipairs(PUNCTUATION) do word = word:gsub(mark, "") end
  word = word:lower():gsub("%p", "")
  return word
end

function M.tokens(text)
  local out = {}
  for word in text:gmatch("%S+") do
    local n = M.normalize(word)
    if n ~= "" then out[#out + 1] = n end
  end
  return out
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
-- so small edits do not matter. With several matches, the one closest to `near_time`
-- wins. Returns first, last, exact.
function M.find_words(words, passage_tokens, near_time)
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
  local first_two = n > 1 and (passage_tokens[1] .. passage_tokens[2]) or nil
  local last_two = n > 1 and (passage_tokens[n - 1] .. passage_tokens[n]) or nil

  -- When the stretch is anchored on the passage's second word, the first one may be
  -- written as one word where the transcript has two ("TypeWhisper", "Type Whisper").
  -- Then the stretch takes those words in, so the cut does not fall inside the name.
  local function extend_start(i)
    if norms[i] == passage_tokens[1] or norms[i] == first_two then return i end
    local joined = ""
    for k = 1, 3 do
      if i - k < 1 then break end
      joined = norms[i - k] .. joined
      if joined == passage_tokens[1] then return i - k end
    end
    return i
  end
  local function extend_end(j)
    if norms[j] == passage_tokens[n] or norms[j] == last_two then return j end
    local joined = ""
    for k = 1, 3 do
      if j + k > #words then break end
      joined = joined .. norms[j + k]
      if joined == passage_tokens[n] then return j + k end
    end
    return j
  end

  for i = 1, #words do
    -- The stretch starts with the passage's first or second word, or with both written
    -- as one word.
    local start_ok = norms[i] == passage_tokens[1] or (n > 1 and (norms[i] == passage_tokens[2] or norms[i] == first_two))
    if start_ok then
      for j = math.max(i, i + n - 1 - slack), math.min(#words, i + n - 1 + slack) do
        local end_ok = norms[j] == passage_tokens[n]
          or (n > 1 and (norms[j] == passage_tokens[n - 1] or norms[j] == last_two))
        if end_ok then
          local stretch = {}
          for k = i, j do stretch[#stretch + 1] = norms[k] end
          local score = common_words(stretch, passage_tokens) / math.max(n, #stretch)
          if score >= 0.7 then consider(extend_start(i), extend_end(j), score) end
        end
      end
    end
  end
  if best then return best[1], best[2], false end
  return nil
end

function M.words_text(words, first, last)
  local out = {}
  for k = first, last do out[#out + 1] = words[k].text end
  return table.concat(out, " ")
end

-- Short name of a quote after its first and last words.
function M.quote_name(words, pieces)
  local first, last = pieces[1], pieces[#pieces]
  local total = 0
  for _, p in ipairs(pieces) do total = total + (p.last - p.first + 1) end
  if total <= 7 then
    local all = {}
    for _, p in ipairs(pieces) do all[#all + 1] = M.words_text(words, p.first, p.last) end
    return table.concat(all, " ")
  end
  return M.words_text(words, first.first, math.min(first.first + 3, first.last)) .. " … " ..
    M.words_text(words, math.max(last.last - 2, last.first), last.last)
end

------------------------------------------------------------------------
-- Recordings and their word timestamps
------------------------------------------------------------------------

function M.project_dir()
  local _, project_file = reaper.EnumProjects(-1)
  if project_file and project_file ~= "" then return project_file:match("^(.*)/[^/]+$") end
  return reaper.GetProjectPath("")
end

-- Every audio source used in the project, with the track of one item that plays it.
function M.recordings()
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

function M.dirname(path)
  return path:match("^(.*)/[^/]+$") or "."
end

-- "<recording>.timestamps.json" next to the recording, as the TypeWhisper app and the
-- transcription script write it.
function M.timestamps_beside(audio_path)
  return M.dirname(audio_path) .. "/" .. M.strip_extension(M.basename(audio_path)) .. ".timestamps.json"
end

-- Word timestamps from a TypeWhisper result file (the API's verbose JSON), or nil.
-- Also returns the language of the result.
function M.read_words(path)
  local raw = M.read_file(path)
  if not raw then return nil end
  local ok, result = pcall(json_decode, raw)
  if not ok or type(result) ~= "table" or type(result.words) ~= "table" then return nil end
  local words = {}
  for _, w in ipairs(result.words) do
    local text = M.trim(w.word or w.text)
    if text ~= "" and w.start and w["end"] then
      words[#words + 1] = { text = text, norm = M.normalize(text), start = w.start, ["end"] = w["end"] }
    end
  end
  if #words == 0 then return nil end
  return words, type(result.language) == "string" and result.language or nil
end

-- Word timestamps of a recording in the project: the transcription script's latest
-- result in this project first (the transcript file was made from it), then the file
-- next to the recording. Sets rec.words and rec.language; returns rec.words.
function M.load_words(dir, rec)
  for _, path in ipairs({ dir .. "/TypeWhisper/latest/" .. M.basename(rec.path) .. ".json",
    M.timestamps_beside(rec.path) }) do
    local words, language = M.read_words(path)
    if words then rec.words, rec.language = words, language; return words end
  end
  return nil
end

-- Track and marker names in the language of the recording: its track's setting, or
-- the language of its transcript.
function M.names_for(rec)
  local language = ""
  if rec.track then
    local _, value = reaper.GetSetMediaTrackInfo_String(rec.track, "P_EXT:TypeWhisper_language", "", false)
    language = value or ""
  end
  if language == "" then language = rec.language or "" end
  return M.NAMES[language:sub(1, 2)] or M.NAMES.en
end

------------------------------------------------------------------------
-- Cut points from the audio
------------------------------------------------------------------------

local WINDOW = 0.010

-- Loudness (RMS) of 10 ms windows of a source file between two times (source time).
-- `rec.take` plays the whole file from its start, so take time equals source time.
local function window_levels(rec, from, to)
  local rate = 16000
  local levels = {}
  if to - from < WINDOW then return levels end
  local accessor = reaper.CreateTakeAudioAccessor(rec.take)
  local count = math.floor((to - from) / WINDOW)
  local samples = math.floor(rate * WINDOW)
  local buffer = reaper.new_array(samples)
  for i = 0, count - 1 do
    local t = from + i * WINDOW
    buffer.clear()
    reaper.GetAudioAccessorSamples(accessor, rate, 1, t, samples, buffer)
    local sum = 0
    for s = 1, samples do sum = sum + buffer[s] * buffer[s] end
    levels[#levels + 1] = { time = t, rms = math.sqrt(sum / samples) }
  end
  reaper.DestroyAudioAccessor(accessor)
  return levels
end

-- Windows count as quiet up to three times the level of the quietest one.
local function quiet_threshold(levels)
  local quiet = math.huge
  for _, l in ipairs(levels) do quiet = math.min(quiet, l.rms) end
  return math.max(quiet * 3, 0.001)
end

-- Start of a part: in the quiet stretch before its first word, 30 ms before the sound
-- starts (a soft onset the timing missed stays in), at most MAX_LEAD_IN before the word.
-- When the previous word is closer than that, the search ends at that word and the cut
-- stays in the middle of a short quiet stretch, so the previous word stays out even
-- when its timing ends too early.
function M.cut_start(rec, words, first)
  local word_start = words[first].start
  local earliest = math.max(0, word_start - M.MAX_LEAD_IN)
  local bounded = false
  if first > 1 and words[first - 1]["end"] > earliest then
    earliest, bounded = math.min(word_start, words[first - 1]["end"]), true
  end
  local levels = window_levels(rec, earliest, word_start)
  if #levels == 0 then return earliest end
  local threshold = quiet_threshold(levels)
  local last = #levels
  while levels[last].rms > threshold do last = last - 1 end
  local first_quiet = last
  while first_quiet > 1 and levels[first_quiet - 1].rms <= threshold do first_quiet = first_quiet - 1 end
  local run_start, run_end = levels[first_quiet].time, levels[last].time + WINDOW
  local cut = math.max(earliest, run_end - 0.03)
  if bounded then cut = math.max(cut, (run_start + run_end) / 2) end
  return cut
end

-- End of a part: in the quiet stretch after its last word, 30 ms after the sound ends
-- (a last syllable the timing cut off stays in), at most MAX_TAIL after the word.
-- When the next word is closer than that, the search ends at that word and the cut
-- stays in the middle of a short quiet stretch, so the next word stays out even when
-- its timing starts too late.
function M.cut_end(rec, words, last)
  local word_end = words[last]["end"]
  local latest = word_end + M.MAX_TAIL
  local bounded = false
  if last < #words and words[last + 1].start < latest then
    latest, bounded = math.max(word_end, words[last + 1].start), true
  end
  local levels = window_levels(rec, word_end, latest)
  if #levels == 0 then return latest end
  local threshold = quiet_threshold(levels)
  local first = 1
  while levels[first].rms > threshold do first = first + 1 end
  local last_quiet = first
  while last_quiet < #levels and levels[last_quiet + 1].rms <= threshold do last_quiet = last_quiet + 1 end
  local run_start, run_end = levels[first].time, levels[last_quiet].time + WINDOW
  local cut = math.min(latest, run_start + 0.03)
  if bounded then cut = math.min(cut, (run_start + run_end) / 2) end
  return cut
end

-- True when speech runs through a cut point: the level right at the cut is close to the
-- speech around it, less than 25 dB below the loudest moment within a second, and more
-- than 20 dB above the quietest. Such a cut has no pause to hide in and should be
-- listened to. A short pause inside a sentence, such as at a comma, is quiet enough.
local function hard_cut(rec, t)
  local around = window_levels(rec, math.max(0, t - 1), t + 1)
  local quiet, loud, at = math.huge, 0, 0
  for _, l in ipairs(around) do
    quiet = math.min(quiet, l.rms)
    loud = math.max(loud, l.rms)
    if l.time >= t - 0.0101 and l.time < t + 0.0099 then at = math.max(at, l.rms) end
  end
  return #around > 0 and at > 0.002 and at > quiet * 10 and at > loud * 0.056
end

------------------------------------------------------------------------
-- Placing the quotes
------------------------------------------------------------------------

-- Cut markers made by the last run, stored in the project as "number@position".
local function load_markers(key)
  local own = {}
  local found, stored = reaper.GetProjExtState(0, M.SCRIPT_NAME, key)
  for id, pos in (stored or ""):gmatch("(%d+)@([%d%.]+)") do own[tonumber(id)] = tonumber(pos) end
  return own, found ~= 0
end

-- Cuts the quotes of `plan` and puts them on the script's own track.
--
-- plan: list of { rec, words, pieces = { { first, last }, ... }, title = optional prefix,
--   label = optional prefix for notes }; rec.path is the recording, rec.track a track
--   that plays it (optional) and rec.language the language of its transcript (optional).
-- opts:
--   track_name   name of a new quotes track
--   mark_key     P_EXT key that marks the script's own track, mark_value its value
--   legacy_track optional function returning a track from a version without the mark
--   marker_key   project key for the record of the cut markers
--   undo         undo text
--   intro        first line of the question where the quotes go
-- notes: list the report notes are added to.
--
-- Asks whether the quotes go into a new project tab or into this project after
-- everything else. In this project a new run replaces the quotes and cut markers of the
-- last one and leaves everything else alone. Returns false when the user cancelled.
function M.place(plan, opts, notes)
  local names = M.names_for(plan[1].rec)
  local answer = reaper.ShowMessageBox(opts.intro .. "\n\n" ..
    "Yes: put them in a new project tab.\n" ..
    "No: put them in this project, on the track \"" .. opts.track_name ..
    "\" after everything else (replacing the quotes from the last run).",
    M.SCRIPT_NAME, 3)
  if answer ~= 6 and answer ~= 7 then return false end
  local new_project = answer == 6

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Cut points first, in this project, from a temporary track that plays each file
  -- whole, so take time equals source time.
  reaper.InsertTrackAtIndex(reaper.CountTracks(0), false)
  local scratch = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
  for _, q in ipairs(plan) do
    local rec = q.rec
    if not rec.take then
      local item = reaper.AddMediaItemToTrack(scratch)
      local take = reaper.AddTakeToMediaItem(item)
      local source = reaper.PCM_Source_CreateFromFile(rec.path)
      reaper.SetMediaItemTake_Source(take, source)
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", 0)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", reaper.GetMediaSourceLength(source))
      rec.take = take
    end
  end
  for _, q in ipairs(plan) do
    for k, piece in ipairs(q.pieces) do
      piece.from = M.cut_start(q.rec, q.words, piece.first)
      piece.to = M.cut_end(q.rec, q.words, piece.last)
      local part = #q.pieces > 1 and (" part " .. k) or ""
      for _, edge in ipairs({ { piece.from, "start" }, { piece.to, "end" } }) do
        if hard_cut(q.rec, edge[1]) then
          notes[#notes + 1] = (q.label or M.quote_name(q.words, q.pieces)) .. part .. ", " .. edge[2] ..
            ": no pause at the cut, the speech runs through. Listen to it."
        end
      end
    end
  end
  for _, q in ipairs(plan) do q.rec.take = nil end
  reaper.DeleteTrack(scratch)

  -- The script's own track from the last run: emptied, and its cut markers removed,
  -- also when the user deleted the track in between.
  local track
  if not new_project then
    for i = 0, reaper.CountTracks(0) - 1 do
      local t = reaper.GetTrack(0, i)
      local _, mark = reaper.GetSetMediaTrackInfo_String(t, "P_EXT:" .. opts.mark_key, "", false)
      if mark == opts.mark_value then track = t end
    end
    if not track and opts.legacy_track then track = opts.legacy_track(names) end
    local from, to = math.huge, -math.huge
    if track then
      for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
        local it = reaper.GetTrackMediaItem(track, i)
        local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        from, to = math.min(from, pos), math.max(to, pos + reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
        reaper.DeleteTrackMediaItem(track, it)
      end
    end
    local own, recorded = load_markers(opts.marker_key)
    local _, markers, regions = reaper.CountProjectMarkers(0)
    for i = markers + regions - 1, 0, -1 do
      local _, isrgn, pos, _, name, index = reaper.EnumProjectMarkers3(0, i)
      local mine = recorded and own[index] and math.abs(own[index] - pos) < 0.001
        -- Projects from before the record: the cut markers within the old quotes' range.
        or (not recorded and pos >= from - 0.001 and pos <= to + 0.001)
      if not isrgn and name == names.cut and mine then reaper.DeleteProjectMarker(0, index, false) end
    end
  end

  -- End of everything else in the project (recordings, other quote tracks), so the
  -- quotes never play at the same time as anything already there.
  local content_end = 0
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    if reaper.GetMediaItem_Track(item) ~= track then
      content_end = math.max(content_end, reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        + reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
    end
  end

  if new_project then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("TypeWhisper: Prepare quotes", -1)
    reaper.Main_OnCommand(40859, 0) -- File: New project tab
    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
  end
  if not track then
    reaper.InsertTrackAtIndex(reaper.CountTracks(0), true)
    track = reaper.GetTrack(0, reaper.CountTracks(0) - 1)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", opts.track_name, true)
  end
  reaper.GetSetMediaTrackInfo_String(track, "P_EXT:" .. opts.mark_key, opts.mark_value, true)

  local position = (new_project or content_end == 0) and 0 or (content_end + M.GAP_AFTER_CONTENT)
  local report, total, new_markers = {}, 0, {}
  for _, q in ipairs(plan) do
    local name = (q.title or "") .. M.quote_name(q.words, q.pieces)
    local quote_start = position
    for index, piece in ipairs(q.pieces) do
      local joined = index > 1
      if joined then
        position = position - M.CROSSFADE
        local at = position + M.CROSSFADE / 2
        local id = reaper.AddProjectMarker2(0, false, at, 0, names.cut, -1, 0)
        if id and id >= 0 then new_markers[#new_markers + 1] = string.format("%d@%.6f", id, at) end
      end
      local item = reaper.AddMediaItemToTrack(track)
      local take = reaper.AddTakeToMediaItem(item)
      reaper.SetMediaItemTake_Source(take, reaper.PCM_Source_CreateFromFile(q.rec.path))
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", piece.from)
      reaper.SetMediaItemInfo_Value(item, "D_POSITION", position)
      reaper.SetMediaItemInfo_Value(item, "D_LENGTH", piece.to - piece.from)
      reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", joined and M.CROSSFADE or M.FADE)
      reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", index < #q.pieces and M.CROSSFADE or M.FADE)
      reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", index == 1 and name or (name .. " (" .. index .. ")"), true)
      position = position + (piece.to - piece.from)
    end
    total = total + (position - quote_start)
    report[#report + 1] = string.format("%s (%s%s)", name, M.clock(position - quote_start),
      #q.pieces > 1 and (", " .. #q.pieces .. " parts") or "")
    position = position + M.GAP_BETWEEN_QUOTES
  end

  -- "-" keeps an empty record apart from a project that has none yet.
  reaper.SetProjExtState(0, M.SCRIPT_NAME, opts.marker_key, #new_markers > 0 and table.concat(new_markers, ",") or "-")

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock(opts.undo, -1)
  reaper.SetExtState(M.SCRIPT_NAME, "last_quotes", tostring(#plan), false)

  local _, track_name = reaper.GetTrackName(track)
  local text = #plan .. " quote(s), " .. M.clock(total) .. " in total, on \"" .. track_name .. "\":\n\n" .. table.concat(report, "\n")
  if #notes > 0 then text = text .. "\n\nCheck:\n" .. table.concat(notes, "\n") end
  M.msg(text)
  return true
end

return M
