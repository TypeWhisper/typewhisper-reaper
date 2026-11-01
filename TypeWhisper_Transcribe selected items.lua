-- @description TypeWhisper: Transcribe selected items
-- @version 0.2.1
-- @author TypeWhisper
-- @website https://www.typewhisper.com
-- @changelog
--   0.2.1
--   - Speaker labels also with word timestamps: words take the speaker of the
--     segment they lie in (the API returns speakers per segment only).
--   - Inside a sentence only a pause of SENTENCE_PAUSE_SECONDS starts a new region,
--     so regions end at sentence ends instead of breathing pauses.
--   - A new run only replaces the regions this script created, identified by their
--     region numbers stored in the project. Your own regions stay, whatever color.
--     In projects from 0.2.0 the color decides once more on the first run.
--   - Keeps the latest transcript of each recording for "TypeWhisper: Cut quotes
--     from transcript".
--   0.2.0
--   - Long recordings: TypeWhisper reads the file directly, no upload limit.
--   - Each source file is transcribed once, even when it is cut into many
--     items, and the result is cached next to the project.
--   - Regions follow sentences and speaker changes; very short pieces are
--     joined with their neighbour. Uses word timestamps when available.
--   - Item notes only contain what is audible in the item.
--   - Language per track, optional speaker labels (A:, B:), progress window.
--   - Transcript files with timestamps and a program text in timeline order.
--   - Running the script again replaces the regions it created before.
-- @about
--   Sends the audio of the selected items to the TypeWhisper app on this Mac
--   and adds the transcript to the project: regions on the timeline, the
--   audible text in each item's notes, and transcript files next to the
--   project. REAPER stays usable while TypeWhisper works in the background.
--
--   Requirements:
--   - TypeWhisper for macOS is running.
--   - Settings > Advanced > API Server is turned on.
--   - Regions need an engine with timestamps (for example Parakeet or
--     WhisperKit). Engines without timestamps only fill the transcript file.
--   - Speaker labels need TypeWhisper Premium.

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

local ASK_EACH_RUN = true         -- show the settings dialog before each run
local CREATE_REGIONS = true
local WRITE_ITEM_NOTES = true
local WRITE_TRANSCRIPT_FILES = true
local USE_CACHE = true            -- reuse earlier results for unchanged files
local MIN_REGION_SECONDS = 1.0    -- shorter regions are joined with a neighbour
local MAX_PAUSE_SECONDS = 1.0     -- short regions are only joined across pauses up to this
local SENTENCE_PAUSE_SECONDS = 3.0 -- inside a sentence, only a pause this long starts a new region
local REGION_COLOR = reaper.ColorToNative(74, 144, 226) | 0x1000000

------------------------------------------------------------------------

local SCRIPT_NAME = "TypeWhisper"
local HOME = os.getenv("HOME") or ""
local DISCOVERY_FILES = {
  HOME .. "/Library/Application Support/TypeWhisper/api-discovery.json",
  HOME .. "/Library/Application Support/TypeWhisper-Dev/api-discovery.json",
}

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

local function write_file(path, data)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  return true
end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
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

local function timestamp(seconds)
  seconds = math.max(0, math.floor(seconds + 0.5))
  return string.format("%02d:%02d:%02d", seconds // 3600, (seconds % 3600) // 60, seconds % 60)
end

-- Small, stable string hash for cache file names (djb2).
local function hash(s)
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) & 0xFFFFFFFF end
  return string.format("%08x", h)
end

------------------------------------------------------------------------
-- Minimal JSON (decode: objects, arrays, strings, numbers, true/false/null)
------------------------------------------------------------------------

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
  end
  if cp < 0x10000 then
    return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  end
  return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F),
    0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

local function json_decode(str)
  local pos = 1

  local function skip()
    pos = str:find("[^ \t\r\n]", pos) or (#str + 1)
  end

  local parse_value

  local function parse_string()
    pos = pos + 1 -- opening quote
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
      pos = pos + 1
      skip()
      if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
      while true do
        skip()
        local key = parse_string()
        skip()
        pos = pos + 1 -- colon
        obj[key] = parse_value()
        skip()
        local d = str:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      skip()
      if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
      while true do
        arr[#arr + 1] = parse_value()
        skip()
        local d = str:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
      end
    elseif c == '"' then
      return parse_string()
    elseif str:sub(pos, pos + 3) == "true" then
      pos = pos + 4; return true
    elseif str:sub(pos, pos + 4) == "false" then
      pos = pos + 5; return false
    elseif str:sub(pos, pos + 3) == "null" then
      pos = pos + 4; return nil
    else
      local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" then error("unexpected character at " .. pos) end
      pos = pos + #num
      return tonumber(num)
    end
  end

  return parse_value()
end

local function json_string(s)
  s = tostring(s):gsub('[%c"\\]', function(c)
    local map = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    return map[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. s .. '"'
end

------------------------------------------------------------------------
-- Settings dialog (language per track, engine/model/speakers per project)
------------------------------------------------------------------------

local function track_language(track)
  local _, value = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:TypeWhisper_language", "", false)
  return trim(value)
end

local function project_setting(key)
  local _, value = reaper.GetProjExtState(0, SCRIPT_NAME, key)
  return trim(value)
end

-- Returns the settings for this run, or nil when the user cancelled.
local function ask_settings(tracks)
  local languages, first = {}, nil
  for _, track in ipairs(tracks) do
    local lang = track_language(track)
    languages[lang] = true
    first = first or lang
  end
  local count = 0
  for _ in pairs(languages) do count = count + 1 end
  local language_default = count > 1 and "per track" or (first ~= "" and first or "auto")

  local settings = {
    language = language_default,
    engine = project_setting("engine"),
    model = project_setting("model"),
    speakers = project_setting("speakers") == "y",
  }

  if ASK_EACH_RUN then
    local defaults = table.concat({
      settings.language, settings.engine, settings.model, settings.speakers and "y" or "n",
    }, ",")
    local ok, csv = reaper.GetUserInputs("TypeWhisper", 4,
      "Language (de, en, auto),Engine (empty = app),Model (empty = app),Speakers A:/B: (y/n),extrawidth=160",
      defaults)
    if not ok then return nil end
    local values = {}
    for value in (csv .. ","):gmatch("([^,]*),") do values[#values + 1] = trim(value) end
    settings.language = values[1] ~= "" and values[1]:lower() or "auto"
    settings.engine = values[2] or ""
    settings.model = values[3] or ""
    settings.speakers = (values[4] or ""):lower():sub(1, 1) == "y"
  end

  reaper.SetProjExtState(0, SCRIPT_NAME, "engine", settings.engine)
  reaper.SetProjExtState(0, SCRIPT_NAME, "model", settings.model)
  reaper.SetProjExtState(0, SCRIPT_NAME, "speakers", settings.speakers and "y" or "n")
  if settings.language ~= "per track" then
    local stored = settings.language == "auto" and "" or settings.language
    for _, track in ipairs(tracks) do
      reaper.GetSetMediaTrackInfo_String(track, "P_EXT:TypeWhisper_language", stored, true)
    end
  end
  return settings
end

------------------------------------------------------------------------
-- TypeWhisper API
------------------------------------------------------------------------

local function temp_base()
  local dir = os.getenv("TMPDIR") or "/tmp/"
  if dir:sub(-1) ~= "/" then dir = dir .. "/" end
  return string.format("%stypewhisper-reaper-%d-%d", dir, os.time(), math.random(100000, 999999))
end

-- Runs a shell script from a temp file. REAPER's ExecProcess does not use a
-- shell, so a script file avoids quoting problems with paths and spaces.
-- timeout_ms: -1 = run in the background, otherwise wait up to that long.
local function run_shell(script, timeout_ms)
  local path = temp_base() .. ".sh"
  write_file(path, script .. "\nrm -f " .. shell_quote(path) .. "\n")
  return reaper.ExecProcess('/bin/sh "' .. path .. '"', timeout_ms)
end

local function header_file(token)
  if not token or token == "" then return nil end
  local path = temp_base() .. ".headers"
  write_file(path, "Authorization: Bearer " .. token .. "\n")
  return path
end

-- Both the TypeWhisper app and a development build may have left a discovery
-- file behind. Use the first one whose server accepts its token.
local function find_api()
  local fallback
  for _, path in ipairs(DISCOVERY_FILES) do
    local ok, doc = pcall(json_decode, read_file(path) or "")
    if ok and type(doc) == "table" and doc.port then
      fallback = fallback or doc
      local headers = header_file(doc.token)
      local script = string.format(
        "/usr/bin/curl -s -o /dev/null -w '%%{http_code}' --max-time 3 %s http://127.0.0.1:%d/v1/models",
        headers and ("-H @" .. shell_quote(headers)) or "", doc.port)
      if headers then script = script .. "; rm -f " .. shell_quote(headers) end
      local output = run_shell(script, 5000) or ""
      if output:match("200%s*$") then return doc.port, doc.token end
    end
  end
  if fallback then return fallback.port, fallback.token end
  return 8978, nil
end

-- Starts curl in the background. The .done file appears once curl has
-- finished and contains "<curl exit code> <http status>".
-- mode "path": TypeWhisper reads the file itself (no size limit).
-- mode "upload": the file is uploaded (older TypeWhisper versions, 256 MB).
local function start_request(api, job, mode)
  local base = temp_base()
  job.out, job.done = base .. ".json", base .. ".done"
  local headers = header_file(api.token)
  local header_args = headers and ("-H @" .. shell_quote(headers)) or ""
  local s = job.settings
  local curl

  if mode == "path" then
    local fields = {
      '"path":' .. json_string(job.path),
      '"response_format":"verbose_json"',
      '"timestamp_granularities":["word","segment"]',
    }
    if s.language ~= "" then fields[#fields + 1] = '"language":' .. json_string(s.language) end
    if s.engine ~= "" then fields[#fields + 1] = '"engine":' .. json_string(s.engine) end
    if s.model ~= "" then fields[#fields + 1] = '"model":' .. json_string(s.model) end
    if s.speakers then fields[#fields + 1] = '"detect_speakers":true' end
    local body = base .. ".body"
    write_file(body, "{" .. table.concat(fields, ",") .. "}")
    curl = string.format(
      "/usr/bin/curl -sS --max-time 14400 %s -H 'Content-Type: application/json' --data-binary @%s " ..
      "-o %s -w '%%{http_code}' http://127.0.0.1:%d/v1/transcribe/local-file?await_download=1",
      header_args, shell_quote(body), shell_quote(job.out), api.port)
    job.cleanup = "rm -f " .. shell_quote(body) .. "\n"
  else
    local fields = {
      "-F " .. shell_quote("file=@" .. job.path), "-F response_format=verbose_json",
      "-F 'timestamp_granularities[]=word'", "-F 'timestamp_granularities[]=segment'",
    }
    if s.language ~= "" then fields[#fields + 1] = "-F " .. shell_quote("language=" .. s.language) end
    if s.engine ~= "" then fields[#fields + 1] = "-F " .. shell_quote("engine=" .. s.engine) end
    if s.model ~= "" then fields[#fields + 1] = "-F " .. shell_quote("model=" .. s.model) end
    if s.speakers then fields[#fields + 1] = "-F detect_speakers=true" end
    curl = string.format(
      "/usr/bin/curl -sS --max-time 14400 %s %s -o %s -w '%%{http_code}' http://127.0.0.1:%d/v1/transcribe?await_download=1",
      header_args, table.concat(fields, " "), shell_quote(job.out), api.port)
    job.cleanup = ""
  end

  -- curl prints the HTTP status; keep it next to its exit code.
  local script = "status=$(" .. curl .. ")\nrc=$?\n" .. job.cleanup ..
    (headers and ("rm -f " .. shell_quote(headers) .. "\n") or "") ..
    string.format('echo "$rc $status" > %s && mv %s %s\n',
      shell_quote(job.done .. ".tmp"), shell_quote(job.done .. ".tmp"), shell_quote(job.done))
  run_shell(script, -1)
end

------------------------------------------------------------------------
-- Turning words and segments into regions
------------------------------------------------------------------------

local function ends_sentence(text)
  return text:match("[%.%?!…]%s*[\"'”“»«)]*%s*$") ~= nil
end

-- units: list of {start, finish, text, speaker} in source time.
-- Groups them into sentences, splits at speaker changes and long pauses,
-- then joins very short groups with a neighbour of the same speaker.
local function build_groups(units)
  local groups, current = {}, nil
  local function close()
    if current then groups[#groups + 1] = current end
    current = nil
  end

  for _, u in ipairs(units) do
    -- A group is always mid-sentence here (it closes at a sentence end), so a breathing
    -- pause does not split it; only a speaker change or a long pause does.
    if current and (u.speaker ~= current.speaker or u.start - current.finish > SENTENCE_PAUSE_SECONDS) then
      close()
    end
    if not current then
      current = { start = u.start, finish = u.finish, speaker = u.speaker, parts = {} }
    end
    current.finish = math.max(current.finish, u.finish)
    current.parts[#current.parts + 1] = u.text
    if ends_sentence(u.text) then close() end
  end
  close()

  local merged = {}
  for _, g in ipairs(groups) do
    local prev = merged[#merged]
    local short = g.finish - g.start < MIN_REGION_SECONDS
    local prev_short = prev and (prev.finish - prev.start < MIN_REGION_SECONDS)
    if prev and prev.speaker == g.speaker and g.start - prev.finish <= MAX_PAUSE_SECONDS
      and (short or prev_short) then
      prev.finish = g.finish
      for _, p in ipairs(g.parts) do prev.parts[#prev.parts + 1] = p end
    else
      merged[#merged + 1] = g
    end
  end

  for _, g in ipairs(merged) do
    g.text = trim(table.concat(g.parts, " "):gsub("%s+", " "))
  end
  return merged
end

-- Speaker labels ("Speaker 1", "speaker_0", ...) become A, B, C in order of
-- first appearance within one source file.
local function speaker_letters(result)
  local letters, next_code = {}, string.byte("A")
  local function letter(label)
    if not label or label == "" then return nil end
    if not letters[label] then
      letters[label] = string.char(next_code)
      next_code = math.min(next_code + 1, string.byte("Z"))
    end
    return letters[label]
  end
  return letter
end

-- Units of one source file, in source time. Prefers word timestamps.
local function source_units(result, with_speakers)
  local letter = speaker_letters(result)
  local units = {}
  local words = type(result.words) == "table" and result.words or {}
  if #words > 0 then
    -- The API returns speakers per segment only. Words take the speaker of the segment
    -- they lie in, or of the nearer segment when they fall in a gap.
    local segs, si = result.segments or {}, 1
    local function segment_speaker(t)
      while segs[si] and (segs[si]["end"] or 0) < t do si = si + 1 end
      local seg, prev = segs[si], segs[si - 1]
      if seg and (seg.start or 0) <= t then return seg.speaker end
      if prev and (not seg or t - (prev["end"] or 0) <= (seg.start or 0) - t) then return prev.speaker end
      return seg and seg.speaker or nil
    end
    for _, w in ipairs(words) do
      local text = trim(w.word or w.text)
      if text ~= "" and w.start and w["end"] then
        local speaker = nil
        if with_speakers then
          speaker = w.speaker
          if not speaker or speaker == "" then speaker = segment_speaker((w.start + w["end"]) / 2) end
          speaker = letter(speaker)
        end
        units[#units + 1] = { start = w.start, finish = w["end"], text = text, speaker = speaker }
      end
    end
    return units, "words"
  end
  for _, seg in ipairs(result.segments or {}) do
    local text = trim(seg.text)
    if text ~= "" and seg.start and seg["end"] then
      units[#units + 1] = { start = seg.start, finish = seg["end"], text = text,
        speaker = with_speakers and letter(seg.speaker) or nil }
    end
  end
  return units, (#units > 0) and "segments" or "none"
end

local function labeled(g)
  return g.speaker and (g.speaker .. ": " .. g.text) or g.text
end

------------------------------------------------------------------------
-- Items
------------------------------------------------------------------------

local function collect_items()
  local items, tracks, seen = {}, {}, {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local src = reaper.GetMediaItemTake_Source(take)
      local parent = reaper.GetMediaSourceParent(src)
      local path = reaper.GetMediaSourceFileName(parent or src)
      if path and path ~= "" then
        local track = reaper.GetMediaItem_Track(item)
        if not seen[track] then seen[track] = true; tracks[#tracks + 1] = track end
        items[#items + 1] = {
          item = item,
          track = track,
          path = path,
          pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
          len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
          offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
          rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
        }
      end
    end
  end
  return items, tracks
end

local function project_dir()
  local _, project_file = reaper.EnumProjects(-1)
  if project_file and project_file ~= "" then
    return project_file:match("^(.*)/[^/]+$"), strip_extension(basename(project_file))
  end
  return reaper.GetProjectPath(""), "Untitled"
end

-- Units of a source that are audible in the item, mapped to project time.
local function item_groups(entry, units)
  local window_start = entry.offset
  local window_end = entry.offset + entry.len * entry.rate
  local inside = {}
  for _, u in ipairs(units) do
    local mid = (u.start + u.finish) / 2
    if mid >= window_start and mid <= window_end then inside[#inside + 1] = u end
  end
  local groups = build_groups(inside)
  local item_end = entry.pos + entry.len
  for _, g in ipairs(groups) do
    g.proj_start = math.max(entry.pos, entry.pos + (g.start - entry.offset) / entry.rate)
    g.proj_end = math.min(item_end, entry.pos + (g.finish - entry.offset) / entry.rate)
  end
  return groups
end

-- Number and start of each region this script created, stored in the project, so a new
-- run replaces only those and never touches regions the user made. The start guards
-- against REAPER reusing the number of a deleted region for a new one.
-- Projects where 0.2.0 already ran have no record yet (0.2.0 only stored its settings);
-- there the color decides once. In a project the script never ran in, nothing counts
-- as its region yet.
local function load_own_regions(ran_before)
  local own = {}
  local found, list = reaper.GetProjExtState(0, SCRIPT_NAME, "regions")
  for id, pos in (list or ""):gmatch("(%d+)@([%d%.]+)") do own[tonumber(id)] = tonumber(pos) end
  return own, found ~= 0, found == 0 and ran_before
end

local function save_own_regions(own)
  local entries = {}
  for id, pos in pairs(own) do entries[#entries + 1] = string.format("%d@%.3f", id, pos) end
  table.sort(entries)
  -- "-" keeps an empty record apart from a 0.2.0 project that has none.
  reaper.SetProjExtState(0, SCRIPT_NAME, "regions", #entries > 0 and table.concat(entries, ",") or "-")
end

-- Removes regions this script created earlier inside the item's range.
local function remove_old_regions(entry, own, recorded, legacy)
  local item_end = entry.pos + entry.len
  local _, markers, regions = reaper.CountProjectMarkers(0)
  for i = markers + regions - 1, 0, -1 do
    local _, isrgn, pos, rgnend, _, index, color = reaper.EnumProjectMarkers3(0, i)
    local ours = recorded and own[index] and math.abs(own[index] - pos) < 0.002
      or (legacy and color == REGION_COLOR)
    if isrgn and ours and pos >= entry.pos - 0.001 and rgnend <= item_end + 0.001 then
      reaper.DeleteProjectMarker(0, index, true)
      own[index] = nil
    end
  end
end

------------------------------------------------------------------------
-- Progress window
------------------------------------------------------------------------

local progress = { started = reaper.time_precise(), lines = {} }

local function progress_open()
  gfx.init("TypeWhisper", 460, 96)
  gfx.setfont(1, "Helvetica", 15)
end

local function progress_draw()
  if gfx.getchar() < 0 then return end -- window closed; keep working
  gfx.set(0.12, 0.13, 0.16, 1)
  gfx.rect(0, 0, gfx.w, gfx.h, 1)
  gfx.set(0.9, 0.92, 0.95, 1)
  local y = 14
  for _, line in ipairs(progress.lines) do
    gfx.x, gfx.y = 16, y
    gfx.drawstr(line)
    y = y + 22
  end
  gfx.update()
end

local function progress_set(...)
  progress.lines = { ... }
  progress_draw()
end

------------------------------------------------------------------------
-- Main
------------------------------------------------------------------------

local function main()
  local items, tracks = collect_items()
  if #items == 0 then
    msg("Select one or more audio items first.")
    return
  end

  -- Read before the dialog stores the settings: did the script run in this project before?
  local ran_before = reaper.GetProjExtState(0, SCRIPT_NAME, "speakers") ~= 0
  local settings = ask_settings(tracks)
  if not settings then return end

  local api = {}
  api.port, api.token = find_api()

  local dir, project_name = project_dir()
  local cache_dir = dir .. "/TypeWhisper"
  reaper.RecursiveCreateDirectory(cache_dir, 0)

  -- One job per source file and language.
  local jobs, by_key = {}, {}
  for _, entry in ipairs(items) do
    local language = settings.language
    if language == "per track" then language = track_language(entry.track) end
    if language == "auto" then language = "" end
    local job_settings = { language = language, engine = settings.engine,
      model = settings.model, speakers = settings.speakers }
    local key = table.concat({ entry.path, tostring(file_size(entry.path) or 0), language,
      settings.engine, settings.model, settings.speakers and "s" or "" }, "|")
    local job = by_key[key]
    if not job then
      job = { path = entry.path, key = key, settings = job_settings, entries = {},
        cache = cache_dir .. "/" .. strip_extension(basename(entry.path)) .. "-" .. hash(key) .. ".json" }
      by_key[key] = job
      jobs[#jobs + 1] = job
    end
    job.entries[#job.entries + 1] = entry
  end

  progress_open()
  local index, from_cache, warnings, speaker_warning = 0, 0, {}, false

  local function finish()
    reaper.Undo_BeginBlock()
    local region_count, program = 0, {}
    local own, recorded, legacy = load_own_regions(ran_before)

    for _, job in ipairs(jobs) do
      if job.result then
        local units, kind = source_units(job.result, job.settings.speakers)
        if kind == "none" then
          warnings[#warnings + 1] = basename(job.path) ..
            ": the engine returned no timestamps, so there are no regions or item notes. " ..
            "The text is in the transcript file."
        end

        if job.raw then
          reaper.RecursiveCreateDirectory(cache_dir .. "/latest", 0)
          write_file(cache_dir .. "/latest/" .. basename(job.path) .. ".json", job.raw)
        end

        if WRITE_TRANSCRIPT_FILES then
          local lines = {}
          if kind == "none" then
            lines[1] = trim(job.result.text)
          else
            for _, g in ipairs(build_groups(units)) do
              lines[#lines + 1] = "[" .. timestamp(g.start) .. "] " .. labeled(g)
            end
          end
          write_file(dir .. "/" .. strip_extension(basename(job.path)) .. " - transcript.txt",
            table.concat(lines, "\n") .. "\n")
        end

        for _, entry in ipairs(job.entries) do
          local groups = (kind == "none") and {} or item_groups(entry, units)
          if CREATE_REGIONS and kind ~= "none" then
            remove_old_regions(entry, own, recorded, legacy)
            for _, g in ipairs(groups) do
              if g.proj_end > g.proj_start then
                local id = reaper.AddProjectMarker2(0, true, g.proj_start, g.proj_end, labeled(g), -1, REGION_COLOR)
                if id and id >= 0 then own[id] = g.proj_start end
                region_count = region_count + 1
              end
            end
          end
          local texts = {}
          for _, g in ipairs(groups) do texts[#texts + 1] = labeled(g) end
          if WRITE_ITEM_NOTES and kind ~= "none" then
            reaper.GetSetMediaItemInfo_String(entry.item, "P_NOTES", table.concat(texts, "\n"), true)
          end
          program[#program + 1] = { pos = entry.pos, track = entry.track, text = table.concat(texts, " ") }
        end
      end
    end

    if CREATE_REGIONS then save_own_regions(own) end

    if WRITE_TRANSCRIPT_FILES and #program > 0 then
      table.sort(program, function(a, b) return a.pos < b.pos end)
      local lines = {}
      for _, p in ipairs(program) do
        local _, track_name = reaper.GetTrackName(p.track)
        lines[#lines + 1] = string.format("[%s] %s: %s", timestamp(p.pos), track_name, p.text)
      end
      write_file(dir .. "/" .. project_name .. " - program text.txt", table.concat(lines, "\n") .. "\n")
    end

    reaper.Undo_EndBlock("TypeWhisper: Transcribe items", -1)
    reaper.UpdateArrange()
    reaper.SetExtState(SCRIPT_NAME, "last_status",
      string.format("done items=%d files=%d cached=%d regions=%d", #items, #jobs, from_cache, region_count), false)

    progress_set(string.format("Done: %d items, %d regions.", #items, region_count),
      string.format("%d file(s), %d from cache. Transcripts are in:", #jobs, from_cache), dir)
    if #warnings > 0 then msg(table.concat(warnings, "\n\n")) end
    local close_at = reaper.time_precise() + 4
    local function linger()
      progress_draw()
      if reaper.time_precise() < close_at and gfx.getchar() >= 0 then reaper.defer(linger) else gfx.quit() end
    end
    linger()
  end

  local next_job

  local function fail(text)
    reaper.SetExtState(SCRIPT_NAME, "last_status", "error", false)
    gfx.quit()
    msg(text)
  end

  local function poll()
    local job = jobs[index]
    if not reaper.file_exists(job.done) then
      local elapsed = math.floor(reaper.time_precise() - progress.started)
      progress_set(string.format("Transcribing file %d of %d", index, #jobs),
        basename(job.path), string.format("%d:%02d elapsed. REAPER stays usable.", elapsed // 60, elapsed % 60))
      reaper.defer(poll)
      return
    end

    local rc, status = (read_file(job.done) or ""):match("(%-?%d+)%s+(%d*)")
    rc, status = tonumber(rc) or -1, tonumber(status) or 0
    local body = read_file(job.out) or ""
    os.remove(job.done)
    os.remove(job.out)

    if rc ~= 0 then
      return fail("Could not reach TypeWhisper (curl exit code " .. rc .. ").\n\n" ..
        "Make sure TypeWhisper is running and Settings > Advanced > API Server is turned on.")
    end

    local ok, result = pcall(json_decode, body)
    if job.mode == "path" and (status == 404 or (status == 400 and body:find("File not found", 1, true))) then
      -- Older TypeWhisper without the local-file endpoint, or a sandboxed app
      -- that cannot read the file: upload it instead.
      job.mode = "upload"
      start_request(api, job, "upload")
      reaper.defer(poll)
      return
    end
    if not ok or type(result) ~= "table" then
      return fail("TypeWhisper sent an unexpected response (HTTP " .. status .. "):\n\n" .. body:sub(1, 500))
    end
    if result.error then
      local text = tostring(type(result.error) == "table" and result.error.message or result.error)
      if job.settings.speakers and (status == 403 or text:find("Premium", 1, true)) then
        -- Speaker detection needs Premium: transcribe without speakers instead.
        job.settings.speakers = false
        job.cache = job.cache:gsub("%-%x+%.json$", "") .. "-" .. hash(job.key:gsub("|s$", "|")) .. ".json"
        if not speaker_warning then
          speaker_warning = true
          warnings[#warnings + 1] = "Speaker labels need TypeWhisper Premium. The transcript has no speakers."
        end
        start_request(api, job, job.mode)
        reaper.defer(poll)
        return
      end
      if status == 413 then
        text = text .. "\n\nThe file is too large to upload. Update TypeWhisper so it can read the file directly."
      end
      return fail("TypeWhisper error for " .. basename(job.path) .. ":\n\n" .. text)
    end

    job.result, job.raw = result, body
    if USE_CACHE then write_file(job.cache, body) end
    next_job()
  end

  function next_job()
    index = index + 1
    if index > #jobs then return finish() end
    local job = jobs[index]
    local cached = USE_CACHE and read_file(job.cache)
    if cached then
      local ok, result = pcall(json_decode, cached)
      if ok and type(result) == "table" and not result.error then
        job.result, job.raw = result, cached
        from_cache = from_cache + 1
        return next_job()
      end
    end
    job.mode = "path"
    start_request(api, job, "path")
    reaper.defer(poll)
  end

  reaper.SetExtState(SCRIPT_NAME, "last_status", "running", false)
  next_job()
end

math.randomseed(os.time())
main()
