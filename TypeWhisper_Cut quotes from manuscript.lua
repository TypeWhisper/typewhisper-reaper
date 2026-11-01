-- @description TypeWhisper: Cut quotes from manuscript
-- @version 0.1.0
-- @author Marcus Schuler, TypeWhisper
-- @website https://www.typewhisper.com
-- @about
--   Cuts the quotes of a radio or podcast manuscript into finished quotes, in the order
--   of the manuscript. Write the manuscript in Obsidian, any Markdown editor or as plain
--   text, and put each quote under a label line, the way radio manuscripts do anyway:
--
--     O-Ton Dohmke:
--     „Ich glaube, der größte Unterschied ist, dass man nicht zum Notar gehen muss.“
--
--   The label can also be "Quote Name:" or carry the quote on the same line. Markdown
--   emphasis (*, **, ***), highlights (==) and quote marks are ignored.
--   "…" (or "...") inside a quote is a cut: the parts are joined with a crossfade and a
--   "Cut" marker, also when they lie minutes apart. "…" at the very start or end of a
--   quote only marks a fragment and is not a cut.
--   Small differences to what was said, such as a corrected name, are fine; the report
--   lists them, so the manuscript can be brought in line.
--
--   Needs the interview transcribed with "TypeWhisper: Transcribe selected items"
--   (0.2.1 or later) in this project, which keeps the word timestamps in
--   TypeWhisper/latest/ next to the project, and lib/quotes.lua next to this script.
--   Run it again after editing the manuscript: it replaces the quotes it made before
--   and leaves everything else alone.

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

-- Spellings of the label line before a quote, lowercased: "O-Ton Dohmke:", "Quote Dohmke:".
local QUOTE_LABELS = { "o-ton", "o-töne", "quote", "soundbite", "sound bite" }

------------------------------------------------------------------------

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]") or "."
local loaded, Q = pcall(dofile, script_dir .. "/lib/quotes.lua")
if not loaded then
  reaper.ShowMessageBox("lib/quotes.lua is missing next to this script. Copy the whole TypeWhisper folder.\n\n" ..
    tostring(Q), "TypeWhisper", 0)
  return
end

-- A manuscript line without Markdown decoration: block quote marker, emphasis (*, _),
-- highlight (==) and non-breaking or typographic hyphens written as "-".
local function plain(line)
  line = line:gsub("^%s*>%s?", "")
  line = line:gsub("==", ""):gsub("[%*_]", "")
  line = line:gsub("\226\128\145", "-"):gsub("\226\128\144", "-")  -- U+2011, U+2010
  return Q.trim(line)
end

local function lower(s)
  for _, pair in ipairs(Q.UPPER_TO_LOWER) do s = s:gsub(pair[1], pair[2]) end
  return s:lower()
end

-- "O-Ton Jeremy Crane, Gründer von PocketOS: „…“" -> label "Jeremy Crane", rest "„…“".
local function quote_label(line)
  local text = plain(line)
  local low = lower(text)
  for _, label in ipairs(QUOTE_LABELS) do
    if low:sub(1, #label) == label then
      local colon = text:find(":", #label + 1, true)
      if colon then
        local who = Q.trim(text:sub(#label + 1, colon - 1))
        who = Q.trim(who:match("^([^,]*)") or who)
        return who, Q.trim(text:sub(colon + 1))
      end
    end
  end
  return nil
end

-- The parts of one quote, split at "…" cuts. "…" at the start or end only marks a fragment.
local function quote_parts(text)
  text = text:gsub("%[%s*…%s*%]", "…"):gsub("%(%s*…%s*%)", "…")
  text = text:gsub("%[%s*%.%.%.%s*%]", "…"):gsub("%(%s*%.%.%.%s*%)", "…"):gsub("%.%.%.", "…")
  local parts = {}
  for piece in (text .. "…"):gmatch("(.-)…") do
    local t = Q.tokens(piece)
    if #t > 0 then parts[#parts + 1] = { text = Q.trim(piece), tokens = t } end
  end
  return parts
end

-- Quotes of a manuscript in their order: who, the full text and its parts.
local function manuscript_quotes(manuscript)
  manuscript = manuscript:gsub("\r\n", "\n")
  manuscript = manuscript:gsub("^%-%-%-\n.-\n%-%-%-\n", "")  -- YAML front matter
  local lines, quotes = {}, {}
  for line in (manuscript .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local i = 1
  while i <= #lines do
    local who, rest = quote_label(lines[i])
    if who then
      local body = {}
      if rest ~= "" then body[1] = rest end
      local j = i + 1
      if #body == 0 then
        while j <= #lines and plain(lines[j]) == "" do j = j + 1 end
        while j <= #lines and plain(lines[j]) ~= "" and not quote_label(lines[j])
          and not plain(lines[j]):match(":$") do
          body[#body + 1] = plain(lines[j]); j = j + 1
        end
      end
      local text = Q.trim(table.concat(body, " "))
      if text ~= "" then
        local parts = quote_parts(text)
        if #parts > 0 then quotes[#quotes + 1] = { who = who, text = text, parts = parts } end
      end
      i = math.max(j, i + 1)
    else
      i = i + 1
    end
  end
  return quotes
end

-- Text for the report, without the quote marks around it.
local function bare(text)
  for _, mark in ipairs({ "„", "“", "”", "\"", "»", "«", "‚", "‘" }) do
    text = text:gsub("^%s*" .. mark, ""):gsub(mark .. "%s*$", "")
  end
  return Q.trim(text)
end

-- Word timestamps of every recording in the project that the transcribe script has seen.
local function recordings_with_words(dir)
  local list = {}
  for _, rec in ipairs(Q.recordings()) do
    rec.words = Q.load_words(dir, rec)
    if rec.words then list[#list + 1] = rec end
  end
  return list
end

-- Finds the parts of a quote: the first part in any recording (an exact match wins),
-- the further parts in the same recording, preferring the match nearest the part before.
local function locate(quote, recs)
  local rec, pieces, notes = nil, {}, {}
  for _, r in ipairs(recs) do
    local first, last, exact = Q.find_words(r.words, quote.parts[1].tokens, nil)
    if first and (not rec or (exact and not pieces[1].exact)) then
      rec = r; pieces[1] = { first = first, last = last, exact = exact }
      if exact then break end
    end
  end
  if not rec then return nil, { "not found: „" .. bare(quote.parts[1].text):sub(1, 70) .. "“" } end
  for k = 2, #quote.parts do
    local near = rec.words[pieces[k - 1].last]["end"]
    local first, last, exact = Q.find_words(rec.words, quote.parts[k].tokens, near)
    if not first then return nil, { "part " .. k .. " not found: „" .. bare(quote.parts[k].text):sub(1, 70) .. "“" } end
    pieces[k] = { first = first, last = last, exact = exact }
  end
  for k, p in ipairs(pieces) do
    if not p.exact then
      notes[#notes + 1] = "differs from what was said" .. (#pieces > 1 and (" (part " .. k .. ")") or "") ..
        ":\n    manuscript: „" .. bare(quote.parts[k].text) .. "“\n    said:       „" .. Q.words_text(rec.words, p.first, p.last) .. "“"
    end
  end
  return { rec = rec, words = rec.words, pieces = pieces }, notes
end

-- Short, stable key for project data that belongs to one manuscript file.
local function file_key(path)
  local h = 5381
  for i = 1, #path do h = (h * 33 + path:byte(i)) & 0xFFFFFFFF end
  return string.format("%08x", h)
end

local function main()
  local dir = Q.project_dir()

  -- The manuscript: the file chooser opens with the one used last in this project.
  local _, last_file = reaper.GetProjExtState(0, Q.SCRIPT_NAME, "manuscript")
  local ok, file = reaper.GetUserFileNameForRead(last_file or "", "Manuscript with the quotes", "md")
  if not ok or not file or file == "" then return end
  local manuscript = Q.read_file(file)
  if not manuscript then Q.msg("Cannot read " .. file); return end
  reaper.SetProjExtState(0, Q.SCRIPT_NAME, "manuscript", file)

  local quotes = manuscript_quotes(manuscript)
  if #quotes == 0 then
    Q.msg("No quotes found in " .. Q.basename(file) .. ".\n\nPut each quote under a label line such as\n\nO-Ton Dohmke:\n„…“")
    return
  end
  local recs = recordings_with_words(dir)
  if #recs == 0 then
    Q.msg("No word timestamps in this project.\n\nTranscribe the interview first with \"TypeWhisper: Transcribe selected items\" (0.2.1 or later), with an engine that reports word timings (ElevenLabs Scribe, Parakeet).")
    return
  end

  local plan, notes = {}, {}
  for n, quote in ipairs(quotes) do
    local found, quote_notes = locate(quote, recs)
    for _, note in ipairs(quote_notes) do notes[#notes + 1] = "O" .. n .. " " .. quote.who .. ": " .. note end
    if found then
      found.label = "O" .. n .. " " .. quote.who
      found.title = found.label .. ": "
      plan[#plan + 1] = found
    end
  end
  if #plan == 0 then Q.msg("None of the " .. #quotes .. " quotes was found.\n\n" .. table.concat(notes, "\n")); return end

  local names = Q.names_for(plan[1].rec.track)
  Q.place(plan, {
    track_name = names.track .. " – " .. Q.strip_extension(Q.basename(file)),
    mark_key = "TypeWhisper_manuscript",
    mark_value = file,
    marker_key = "manuscript_markers_" .. file_key(file),
    undo = "TypeWhisper: Cut quotes from manuscript",
    intro = #plan .. " of " .. #quotes .. " quote(s) found in " .. Q.basename(file) .. ".",
  }, notes)
end

main()
