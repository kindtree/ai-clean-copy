-- claude-copy/clean.lua: Pure text-processing logic for cleaning
-- Claude Code clipboard artifacts. No Hammerspoon dependencies.

local M = {}

-- ═══════════════════════════════════════════════════════════════
-- Configuration
-- ═══════════════════════════════════════════════════════════════

local config = {
  minNonEmptyLines = 1,
  minMarginCoverage = 0.50,
  stripOnlyThreshold = 2,
  fullCleanThreshold = 7,
  noPipeFullCleanThreshold = 6,
  noPipeMinWrappedPairsForFull = 2,
  wrapMinLineLength = 24,
  wrapSimilarityDelta = 12,
  wrapJoinSlack = 15,
  wrapMinInferredWidth = 40,
}

-- Full set of keywords that identify a line as code-like.
-- Used by isCodeLikeLine() / startsWithCodeKeyword().
local codeKeywords = {
  "async",
  "await",
  "case",
  "catch",
  "class",
  "const",
  "def",
  "else",
  "elseif",
  "enum",
  "export",
  "finally",
  "for",
  "from",
  "function",
  "if",
  "impl",
  "import",
  "interface",
  "let",
  "local",
  "package",
  "private",
  "protected",
  "public",
  "return",
  "struct",
  "switch",
  "try",
  "type",
  "var",
  "while",
}

-- Subset of codeKeywords used to detect line-number prefixes.
-- Kept tighter to avoid false positives (e.g. "42 else" is ambiguous,
-- "42 const" almost certainly has a line number prefix).
local lineNumberKeywords = {
  "async",
  "await",
  "catch",
  "class",
  "const",
  "def",
  "enum",
  "export",
  "for",
  "function",
  "if",
  "import",
  "interface",
  "let",
  "local",
  "return",
  "struct",
  "try",
  "type",
  "var",
  "while",
}

-- ═══════════════════════════════════════════════════════════════
-- UTF-8 / Display Width Utilities
--
-- Terminal wrapping happens at display columns, not bytes. CJK
-- characters occupy 2 columns but 3 bytes in UTF-8, so all wrap
-- heuristics must measure display width, never byte length.
-- ═══════════════════════════════════════════════════════════════

-- Decode the UTF-8 codepoint starting at byte offset i.
-- Malformed sequences fall back to (lead byte, length 1) so bad
-- clipboard data can never crash the pipeline.
local function decodeCodepoint(s, i)
  local b1 = s:byte(i)
  if not b1 then return nil, 1 end
  if b1 < 0x80 then return b1, 1 end
  local len, cp
  if b1 >= 0xF0 then len, cp = 4, b1 - 0xF0
  elseif b1 >= 0xE0 then len, cp = 3, b1 - 0xE0
  elseif b1 >= 0xC0 then len, cp = 2, b1 - 0xC0
  else return b1, 1 end
  for k = i + 1, i + len - 1 do
    local b = s:byte(k)
    if not b or b < 0x80 or b >= 0xC0 then return b1, 1 end
    cp = cp * 0x40 + (b - 0x80)
  end
  return cp, len
end

-- East Asian Wide / Fullwidth (wcwidth-lite: CJK, kana, hangul,
-- fullwidth forms, CJK punctuation and extensions).
local function isWideCp(cp)
  if not cp then return false end
  return (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0xA4CF)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE4F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
end

local function displayWidth(s)
  local w, i, n = 0, 1, #s
  while i <= n do
    local cp, len = decodeCodepoint(s, i)
    w = w + (isWideCp(cp) and 2 or 1)
    i = i + len
  end
  return w
end

local function firstCp(s)
  return (decodeCodepoint(s, 1))
end

local function lastCp(s)
  local n = #s
  if n == 0 then return nil end
  local i = n
  while i > 1 and i > n - 3 do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return (decodeCodepoint(s, i))
end

-- Sentence-final punctuation, ASCII and CJK.
local sentenceEndPunct = {
  [0x2E] = true, [0x21] = true, [0x3F] = true, [0x3A] = true, [0x3B] = true,
  [0x3002] = true, [0xFF01] = true, [0xFF1F] = true, [0xFF1A] = true, [0xFF1B] = true,
  [0x2026] = true,
}

local function endsWithSentencePunct(s)
  local cp = lastCp(s)
  return cp ~= nil and sentenceEndPunct[cp] == true
end

-- ═══════════════════════════════════════════════════════════════
-- Claude TUI Chrome Detection
--
-- Lines that are pure UI furniture (spinner summaries, expand
-- hints, separators). They carry no content and are dropped.
-- ═══════════════════════════════════════════════════════════════

local spinnerGlyphs = { "✻", "✽", "✢", "✳", "∗" }

local function isChromeLine(text)
  if text:match("%(ctrl%+o to expand%)%s*$") then return true end
  if text:match("%(esc to interrupt%)%s*$") then return true end
  -- Full-width TUI separator rows (─ repeated); 5+ chars avoids
  -- clashing with anything a human would write.
  if text:match("^─+$") and #text >= 15 then return true end
  for _, g in ipairs(spinnerGlyphs) do
    if text:sub(1, #g) == g then
      local rest = text:sub(#g + 1)
      -- "✻ Worked for 11s", "✻ Cogitated for 1m 5s", "✻ Baking…"
      if rest:match("^%s") and (rest:match(" for %d") or rest:match("…")) then
        return true
      end
    end
  end
  return false
end

-- ═══════════════════════════════════════════════════════════════
-- Text Utilities
-- ═══════════════════════════════════════════════════════════════

local function splitLines(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

-- A selection that starts mid-margin can capture a fragment of the
-- 2-space margin (e.g. " - item" with a single leading space). If
-- every other non-empty line carries the full margin, the first
-- line's partial leading whitespace is a selection artifact.
local function normalizePartialFirstLine(text)
  local lines = splitLines(text)
  local firstIdx = nil
  local others, othersWithMargin = 0, 0
  for idx, l in ipairs(lines) do
    if l:match("%S") then
      if not firstIdx then
        firstIdx = idx
      else
        others = others + 1
        if l:match("^  ") then othersWithMargin = othersWithMargin + 1 end
      end
    end
  end
  if not firstIdx or others == 0 or othersWithMargin ~= others then return text end
  local first = lines[firstIdx]
  if first:match("^  ") or not first:match("^%s") then return text end
  lines[firstIdx] = first:gsub("^%s+", "")
  return table.concat(lines, "\n")
end

-- ═══════════════════════════════════════════════════════════════
-- Line Classification
-- ═══════════════════════════════════════════════════════════════

local function isLineNumberPrefixed(line)
  if line:match("^%d+%s%s+%S") then return true end
  local num, rest = line:match("^(%d+)%s+(.+)$")
  if not num or not rest then return false end
  local n = tonumber(num)
  if not n or n < 1 or n > 999 then return false end

  for _, keyword in ipairs(lineNumberKeywords) do
    if rest:match("^" .. keyword .. "%f[%A]") then
      return true
    end
  end
  if rest:match("^//") or rest:match("^/%*") then return true end
  if rest:match("^[%[{(]") then return true end
  if rest:match("^[%a_][%w_]*%s*[%({=:.]") then return true end

  return false
end

-- "标题：值" — fullwidth-colon key-value pairs. Only when the colon
-- sits near the start (≤ ~8 CJK chars) with no space before it, so
-- prose sentences containing ： later on are not affected.
local function hasCJKKeyColon(line)
  local pos = line:find("：", 1, true)
  return pos ~= nil and pos <= 25 and not line:sub(1, pos - 1):match("%s")
end

-- 一 二 三 四 五 六 七 八 九 十
local cjkNumerals = {
  [0x4E00] = true, [0x4E8C] = true, [0x4E09] = true, [0x56DB] = true, [0x4E94] = true,
  [0x516D] = true, [0x4E03] = true, [0x516B] = true, [0x4E5D] = true, [0x5341] = true,
}

-- Numbered rows the way people type them, not only markdown's "1. ":
-- "1.xxx" (no space), "1．", "1、", "1)", "1）", "(1)", "（1）", "①",
-- "一、", "（一）". A dot followed by a digit is a number ("3.14").
-- Only for typed rows (see isStructuralLine): in a response, a wrapped
-- row can start with "(3)" or "一、" mid-sentence.
local function isNumberedItemLine(line)
  if line:match("^%d+%.%s")
    or line:match("^%d%d?%d?%.[^%d%s%.]")
    or line:match("^%d%d?%d?．")
    or line:match("^%d%d?%d?、")
    or line:match("^%d%d?%d?%)")
    or line:match("^%d%d?%d?）")
    or line:match("^%(%d%d?%d?%)")
    or line:match("^（%d%d?%d?）")
  then
    return true
  end
  local cp, len = decodeCodepoint(line, 1)
  if cp and cp >= 0x2460 and cp <= 0x2473 then return true end -- ① … ⑳
  local i, open = 1, cp == 0xFF08 -- （
  if open then
    i = i + len
    cp, len = decodeCodepoint(line, i)
  end
  local start = i
  while cp and cjkNumerals[cp] do
    i = i + len
    cp, len = decodeCodepoint(line, i)
  end
  if i == start then return false end
  if open then return cp == 0xFF09 end -- （一）
  return cp == 0x3001 -- 一、
end

-- A row that is nothing but a fence: ``` / ~~~ (with an optional
-- language) or the ''' / """ that people put around quoted text.
local function isFenceLine(line)
  return line:match("^```[%w_+%-]*%s*$") or line:match("^~~~[%w_+%-]*%s*$")
    or line:match("^'''%s*$") or line:match('^"""%s*$')
end

-- typed: the row was typed by the user (a prompt), so every numbered
-- form counts as a list head, not only markdown's "1. ".
local function isStructuralLine(line, typed)
  return line:match("^[%-%*%+] ")
    or line:match("^%d+%.%s")
    or (typed and isNumberedItemLine(line))
    or isFenceLine(line)
    or line:match("^%d+%s+[+%-]%s")
    or isLineNumberPrefixed(line)
    or line:match("^#+%s")
    or line:match("^[$#] ")
    or line:match("^%*%*")
    or line:match("^%-%-%-")
    or line:match("^___")
    or line:match("^%u[%w_]-:%s")
    or hasCJKKeyColon(line)
    or (line:match("^#%w") and not line:match("#%w+%s+#%w"))
end

-- Keywords that commonly start English sentences. When one of these
-- starts a line with no code syntax (brackets, semicolons, assignment),
-- treat as prose rather than code.
local ambiguousKeywords = {
  ["if"] = true, ["for"] = true, ["from"] = true, ["while"] = true,
  ["try"] = true, ["type"] = true, ["case"] = true, ["let"] = true,
}

local function startsWithCodeKeyword(line)
  for _, keyword in ipairs(codeKeywords) do
    if line:match("^%s*" .. keyword .. "%f[%A]") then
      if ambiguousKeywords[keyword] and not line:match("[%(%)%{%}%[%];=]") then
        return false
      end
      return true
    end
  end
  return false
end

local function isCodeLikeLine(line)
  if not line:match("%S") then return false end
  if line:match("^```") then return true end
  if isLineNumberPrefixed(line) then return true end
  if startsWithCodeKeyword(line) then return true end
  if line:match("^%s*//") or line:match("^%s*/%*") then return true end
  if line:match("^%s*%-%-") then return true end
  if line:match("^%s*[%{%}%[%]]%s*$") then return true end
  if line:match("^%s*[%w_%.:%[%]\"'`%-]+%s*=%s*[^=]") then return true end
  if line:match("[%{%};]") then return true end
  if line:match("=>") or line:match("::") then return true end
  if line:match("^%s*[%w_%.:]+%b()%s*$") then return true end
  if line:match("^%s*[%w_%.:]+%b()%s*[%{%:]%s*$") then return true end
  -- call followed only by a trailing lua-style comment
  if line:match("^%s*[%w_%.:]+%b()%s*%-%-") then return true end
  -- line of nothing but closing brackets: ")", "})", "]);" ...
  if line:match("^%s*[%)%]%}][%)%]%}%,;%s]*$") then return true end
  -- lua block terminators: "end", "end)", "end)," ...
  if line:match("^%s*end%s*[%)%]%}%,;]*%s*$") then return true end
  return false
end

local function isPromptLike(line)
  return line:match("^[$#] ")
    or line:match("^[%w_.-]+@[%w_.-]+[:~/%w%._%-]*[%$#] ")
    or line:match("^%[[^%]]+%][%$#] ")
end

local function isDiffLikeLine(line)
  return line:match("^@@")
    or line:match("^diff%s+%-%-git")
    or line:match("^index%s+[%w%.]+")
    or line:match("^%-%-%-")
    or line:match("^%+%+%+")
    or line:match("^%d+%s+[+%-]%s")
end

-- Agent-TUI content markers rendered at column 0:
--   Claude Code: "⏺ " response / tool-call bullet, "❯ " prompt echo
--   Codex CLI:   "• " response bullet,             "› " prompt echo
-- The text that follows sits at margin level, so marker lines are
-- treated as margined content with the marker removed.
local contentMarkers = { "⏺ ", "❯ ", "• ", "› " }
local QUOTE_BAR = "▎"

local function parseClaudeLine(rawLine)
  local line = rawLine:gsub("%s+$", "")

  local hadMarker, promptEcho = false, false
  for _, m in ipairs(contentMarkers) do
    if line:sub(1, #m) == m then
      line = line:sub(#m + 1)
      hadMarker = true
      promptEcho = m == "❯ " or m == "› "
      break
    end
  end

  local hasMargin = hadMarker
    or (line:match("^  ") ~= nil and line:match("%S") ~= nil)
  local hadPipe = line:match("^  │") ~= nil

  if hasMargin and not hadMarker then
    line = line:gsub("^  ", "", 1)
    line = line:gsub("^│ ?", "", 1)
  end

  -- "▎ quoted text": Claude Code draws a markdown blockquote as a dim
  -- U+258E bar per nesting level ("▎ ▎ " at depth 2) on every visual
  -- row, soft-wrapped continuations included. It is rendering, not
  -- content: left in, it also lands mid-sentence once rows are joined.
  local quoteDepth = 0
  while line:sub(1, #QUOTE_BAR) == QUOTE_BAR do
    line = line:sub(#QUOTE_BAR + 1):gsub("^ ", "", 1)
    quoteDepth = quoteDepth + 1
  end

  -- "⎿  result" tool-result marker (rendered inside the margin).
  local hadToolMarker = false
  if line:sub(1, 3) == "⎿" then
    line = line:gsub("^⎿%s*", "", 1)
    hadToolMarker = true
  end

  local nonEmpty = line:match("%S") ~= nil

  return {
    text = line,
    nonEmpty = nonEmpty,
    hasMargin = hasMargin,
    hadPipe = hadPipe or hadToolMarker,
    hadMarker = hadMarker,
    promptEcho = promptEcho,
    quoteDepth = quoteDepth,
    chrome = nonEmpty and isChromeLine(line) or false,
    width = displayWidth(line),
    indented = line:match("^    %S") ~= nil or line:match("^\t") ~= nil,
    -- Runs of 3+ internal (non-leading) spaces = column-aligned
    -- output (ls, ps, tables). Never a reflow candidate.
    tableLike = (line:gsub("^%s+", "")):find("   ", 1, true) ~= nil,
    codeLike = isCodeLikeLine(line),
  }
end

-- ═══════════════════════════════════════════════════════════════
-- Flattened Line Recovery
--
-- When the terminal copies numbered code (e.g. diff or editor
-- output), it can collapse multiple visual lines into a single
-- clipboard line. These functions detect and re-split them.
-- ═══════════════════════════════════════════════════════════════

local function collectLineNumberStarts(flat)
  local startsByPos = {}
  local diffStarts = 0

  local function addIfLineStart(pos)
    if pos <= 1 then return end
    if flat:sub(pos - 1, pos - 1):match("%s") then
      startsByPos[pos] = true
    end
  end

  -- Diff-style: "42 + " or "42 - "
  for pos in flat:gmatch("()%d+%s+[+%-]%s") do
    addIfLineStart(pos)
    diffStarts = diffStarts + 1
  end

  -- "42 keyword"
  for _, keyword in ipairs(lineNumberKeywords) do
    for pos, num in flat:gmatch("()(%d+)%s+" .. keyword .. "%f[%A]") do
      if tonumber(num) >= 1 and tonumber(num) <= 999 then
        addIfLineStart(pos)
      end
    end
  end

  -- "42 //" or "42 /*"
  for pos, num in flat:gmatch("()(%d+)%s+//") do
    if tonumber(num) >= 1 and tonumber(num) <= 999 then addIfLineStart(pos) end
  end
  for pos, num in flat:gmatch("()(%d+)%s+/%*") do
    if tonumber(num) >= 1 and tonumber(num) <= 999 then addIfLineStart(pos) end
  end

  -- "42 [", "42 {", "42 ("
  for pos, num in flat:gmatch("()(%d+)%s+[%[{(]") do
    if tonumber(num) >= 1 and tonumber(num) <= 999 then addIfLineStart(pos) end
  end

  -- "42 identifier(" or "42 identifier="
  for pos, num in flat:gmatch("()(%d+)%s+([%a_][%w_]*)([%({=:.])") do
    if tonumber(num) >= 1 and tonumber(num) <= 999 then addIfLineStart(pos) end
  end

  -- Chained line numbers: "42 43 + " (two numbers before diff marker)
  for pos, firstNum, sep in flat:gmatch("()(%d+)(%s+)%d+%s+[+%-]%s") do
    addIfLineStart(pos)
    addIfLineStart(pos + #firstNum + #sep)
  end

  -- Chained: "42 43  X" (two numbers, second followed by double-space + content)
  for pos, firstNum, sep in flat:gmatch("()(%d+)(%s+)%d+%s%s+%S") do
    addIfLineStart(pos)
    addIfLineStart(pos + #firstNum + #sep)
  end

  -- Chained: "42 43 keyword"
  for _, keyword in ipairs(lineNumberKeywords) do
    for pos, firstNum, sep in flat:gmatch("()(%d+)(%s+)%d+%s+" .. keyword .. "%f[%A]") do
      addIfLineStart(pos)
      addIfLineStart(pos + #firstNum + #sep)
    end
  end

  -- "42  X" (number, single space, double-space, content)
  for pos in flat:gmatch("()%d+%s%s+%S") do
    addIfLineStart(pos)
  end

  local starts = {}
  for pos in pairs(startsByPos) do
    starts[#starts + 1] = pos
  end
  table.sort(starts)
  return starts, diffStarts
end

local function hasPlausibleNumberProgression(flat, starts)
  if #starts < 3 then return false end

  local numbers = {}
  for _, pos in ipairs(starts) do
    local num = tonumber(flat:match("^(%d+)", pos))
    if num then numbers[#numbers + 1] = num end
  end
  if #numbers < 3 then return false end

  local plausible = 0
  for i = 2, #numbers do
    local delta = numbers[i] - numbers[i - 1]
    if delta >= 0 and delta <= 25 then
      plausible = plausible + 1
    end
  end

  return plausible >= math.max(2, math.floor((#numbers - 1) * 0.6))
end

local function recoverFlattenedNumberedLine(flat)
  -- Fast path: a flattened numbered line needs ≥3 embedded numbered
  -- segments, so short or digit-free lines can never qualify. This
  -- skips ~30 pattern scans per ordinary line on large clipboards.
  if #flat < 60 or not flat:find("%d") then return flat end

  local starts, diffStarts = collectLineNumberStarts(flat)
  if #starts < 3 then return flat end

  if diffStarts < 2 and not hasPlausibleNumberProgression(flat, starts) then
    return flat
  end

  local splitAt = {}
  for _, pos in ipairs(starts) do
    splitAt[pos] = true
  end

  local out = {}
  for i = 1, #flat do
    if splitAt[i] then out[#out + 1] = "\n" end
    out[#out + 1] = flat:sub(i, i)
  end

  local rebuilt = table.concat(out):gsub("^%s*\n", "")

  local normalized = {}
  for _, line in ipairs(splitLines(rebuilt)) do
    local trimmed = line:gsub("^%s+", "")
    if trimmed:match("^%d+%s") then
      normalized[#normalized + 1] = "  " .. trimmed
    else
      normalized[#normalized + 1] = line
    end
  end

  local finalLines = {}
  for _, line in ipairs(normalized) do
    local prefix, num = line:match("^(.-[%]%)};,])%s+(%d+)$")
    local n = tonumber(num)
    if prefix and n and n >= 1 and n <= 999 then
      finalLines[#finalLines + 1] = prefix
      finalLines[#finalLines + 1] = "  " .. tostring(n)
    else
      finalLines[#finalLines + 1] = line
    end
  end

  return table.concat(finalLines, "\n")
end

local function recoverFlattenedNumberedBlock(text)
  local lines = splitLines(text)
  if #lines == 0 then return text end

  local changed = false
  local rebuiltLines = {}
  for _, line in ipairs(lines) do
    local recovered = recoverFlattenedNumberedLine(line)
    if recovered ~= line then changed = true end
    rebuiltLines[#rebuiltLines + 1] = recovered
  end

  if not changed then return text end
  return table.concat(rebuiltLines, "\n")
end

-- ═══════════════════════════════════════════════════════════════
-- Clipboard Classification
--
-- Scores clipboard content on multiple signals to decide:
--   "full"  → strip margins + rejoin wrapped paragraphs
--   "strip" → strip margins only (no reflow)
--   "none"  → leave untouched
-- ═══════════════════════════════════════════════════════════════

local function classifyClaudeClipboard(text)
  text = normalizePartialFirstLine(text)
  local lines = splitLines(text)
  if #lines == 0 then
    return { mode = "none", score = 0 }
  end

  local nonEmpty = 0
  local marginLines = 0
  local pipeLines = 0
  local markerLines = 0
  local promptLike = 0
  local diffLike = 0
  local codeLike = 0
  local numberedLines = 0
  local markdownStructural = 0
  local wrappedPairs = 0
  local previousWrapCandidate = nil
  local previousListItem = nil
  local maxProseWidth = 0
  local firstLineNoMargin = false
  local seenFirstNonEmpty = false

  -- "- item" / "1. item" markdown list heads: their continuations
  -- wrap to plain margin level, so they are wrap sources too.
  local function isListItemLine(parsed)
    return not parsed.codeLike
      and (parsed.text:match("^[%-%*%+] ") ~= nil or parsed.text:match("^%d+%.%s") ~= nil)
  end

  for _, rawLine in ipairs(lines) do
    local parsed = parseClaudeLine(rawLine)

    if parsed.chrome then
      -- UI furniture: not content, but also not evidence against
      -- Claude-ness. Skip it entirely (acts as a paragraph break).
      previousWrapCandidate = nil
      previousListItem = nil
    elseif parsed.nonEmpty then
      nonEmpty = nonEmpty + 1
      if not seenFirstNonEmpty then
        seenFirstNonEmpty = true
        firstLineNoMargin = not parsed.hasMargin
      end
      if parsed.hasMargin then marginLines = marginLines + 1 end
      if parsed.hadPipe then pipeLines = pipeLines + 1 end
      if parsed.hadMarker then markerLines = markerLines + 1 end
      if isPromptLike(parsed.text) then promptLike = promptLike + 1 end
      if isDiffLikeLine(parsed.text) then diffLike = diffLike + 1 end
      if parsed.codeLike then codeLike = codeLike + 1 end
      if isLineNumberPrefixed(parsed.text) then numberedLines = numberedLines + 1 end
      local t = parsed.text
      if t:match("^%d+%.%s") or t:match("^[%-%*%+] ") or t:match("^#+%s") then
        markdownStructural = markdownStructural + 1
      end

      local isWrapCandidate = not parsed.codeLike
        and not parsed.tableLike
        and not isStructuralLine(parsed.text)
        and not isPromptLike(parsed.text)
        and not isLineNumberPrefixed(parsed.text)
        and not isDiffLikeLine(parsed.text)
        and parsed.width >= config.wrapMinLineLength

      if isWrapCandidate then
        if parsed.width > maxProseWidth then maxProseWidth = parsed.width end
        if previousWrapCandidate then
          local prevWidth = previousWrapCandidate.width
          local similarWidth = math.abs(prevWidth - parsed.width) <= config.wrapSimilarityDelta
          local previousLooksWrapped = not endsWithSentencePunct(previousWrapCandidate.text)
          local previousFillsWidth = maxProseWidth > 0 and prevWidth >= maxProseWidth - 5
          if (similarWidth or previousFillsWidth) and (previousLooksWrapped or previousFillsWidth) then
            wrappedPairs = wrappedPairs + 1
          end
        elseif previousListItem
          and not endsWithSentencePunct(previousListItem.text)
          and (previousListItem.width >= config.wrapMinInferredWidth
            or parsed.width >= config.wrapMinInferredWidth)
        then
          -- List item hard-wrapped into a margin-level continuation.
          -- Greedy word wrap can leave a very short head ("3. API")
          -- before a long CJK run, so either side being long counts.
          wrappedPairs = wrappedPairs + 1
        end
        previousWrapCandidate = parsed
        previousListItem = nil
      elseif parsed.nonEmpty
        and not parsed.codeLike
        and not parsed.tableLike
        and not isStructuralLine(parsed.text)
        and not isPromptLike(parsed.text)
        and parsed.width < config.wrapMinLineLength
      then
        -- Short tail after a long line: hard break at terminal width.
        local wrapSource = previousWrapCandidate or previousListItem
        if wrapSource and wrapSource.width >= config.wrapMinInferredWidth then
          wrappedPairs = wrappedPairs + 1
        end
        previousWrapCandidate = nil
        previousListItem = nil
      else
        previousWrapCandidate = nil
        previousListItem = isListItemLine(parsed) and parsed or nil
      end
    else
      previousWrapCandidate = nil
      previousListItem = nil
    end
  end

  if nonEmpty < config.minNonEmptyLines then
    return { mode = "none", score = 0 }
  end

  -- Partial copy: first line has no margin (selection started mid-line),
  -- but remaining lines do. Exclude the first line from coverage calc.
  local partialCopy = firstLineNoMargin and nonEmpty >= 2 and marginLines == (nonEmpty - 1)
  local coverageDenom = partialCopy and (nonEmpty - 1) or nonEmpty
  local marginCoverage = marginLines / coverageDenom
  if marginCoverage < config.minMarginCoverage then
    return { mode = "none", score = 0 }
  end

  if promptLike > 0 and pipeLines == 0 and diffLike == 0 then
    return { mode = "none", score = 0 }
  end

  -- Score: positive signals increase confidence, negative signals decrease.
  local score = 0

  if pipeLines > 0 then score = score + 5 end

  if marginCoverage >= 0.95 then score = score + 3
  elseif marginCoverage >= 0.85 then score = score + 2
  else score = score + 1
  end

  if diffLike >= 2 then score = score + 3
  elseif diffLike == 1 then score = score + 1
  end

  if wrappedPairs >= 3 then score = score + 3
  elseif wrappedPairs >= 2 then score = score + 2
  elseif wrappedPairs == 1 then score = score + 1
  end

  if promptLike > 0 then
    score = score - math.min(4, promptLike * 2)
  end

  if pipeLines == 0 and codeLike == nonEmpty and diffLike == 0 and wrappedPairs == 0 then
    score = score - 3
  end

  -- ⏺/❯ content markers are distinctive Claude TUI evidence.
  if markerLines > 0 then score = score + 2 end

  if numberedLines >= 2 then score = score + 2 end

  if markdownStructural >= 3 then score = score + 2
  elseif markdownStructural >= 2 then score = score + 1
  end

  if partialCopy then score = score + 1 end
  if marginCoverage < 0.75 then score = score - 1 end

  -- Decide mode from score.
  local mode = "none"
  if pipeLines > 0 then
    if score >= config.fullCleanThreshold then
      mode = "full"
    elseif score >= config.stripOnlyThreshold then
      mode = "strip"
    end
  else
    if numberedLines < 2
      and diffLike == 0
      and score >= config.noPipeFullCleanThreshold
      and wrappedPairs >= config.noPipeMinWrappedPairsForFull
      and codeLike < nonEmpty
    then
      mode = "full"
    elseif marginCoverage >= 0.95
      and codeLike == 0
      and wrappedPairs >= 1
      and numberedLines == 0
      and diffLike == 0
      and promptLike == 0
    then
      mode = "full"
    elseif score >= config.stripOnlyThreshold then
      mode = "strip"
    elseif marginCoverage >= 0.95 then
      mode = "strip"
    end
  end

  return {
    mode = mode,
    score = score,
    nonEmpty = nonEmpty,
    marginCoverage = marginCoverage,
    pipeLines = pipeLines,
    diffLike = diffLike,
    numberedLines = numberedLines,
    markdownStructural = markdownStructural,
    wrappedPairs = wrappedPairs,
  }
end

-- ═══════════════════════════════════════════════════════════════
-- Cleaning
-- ═══════════════════════════════════════════════════════════════

-- Strip uniform minimum indent from contiguous code blocks.
-- Handles extra box padding that some terminals preserve beyond
-- the 2-space margin and pipe character.
local function dedentCodeBlocks(lines)
  local i = 1
  while i <= #lines do
    if lines[i].nonEmpty and (lines[i].codeLike or lines[i].indented) then
      local blockStart = i
      local lastCodeLine = i
      local j = i + 1
      while j <= #lines do
        if lines[j].nonEmpty then
          if lines[j].codeLike or lines[j].indented then
            lastCodeLine = j
          else
            break
          end
        end
        j = j + 1
      end
      local blockEnd = lastCodeLine

      local minIndent = math.huge
      for k = blockStart, blockEnd do
        if lines[k].nonEmpty and not lines[k].text:match("^```") then
          local spaces = lines[k].text:match("^(%s*)")
          if #spaces < minIndent then minIndent = #spaces end
        end
      end

      if minIndent > 0 and minIndent < math.huge then
        for k = blockStart, blockEnd do
          if lines[k].nonEmpty then
            local spaces = lines[k].text:match("^(%s*)")
            if #spaces >= minIndent then
              lines[k].text = lines[k].text:sub(minIndent + 1)
              lines[k].indented = lines[k].text:match("^    %S") ~= nil
                or lines[k].text:match("^\t") ~= nil
            end
          end
        end
      end

      i = blockEnd + 1
    else
      i = i + 1
    end
  end
end

local function isProseRow(parsed)
  return parsed.nonEmpty and not parsed.chrome and not parsed.indented
    and not parsed.codeLike and not parsed.tableLike
end

local function inferWrapWidth(lines)
  local maxWidth = 0
  for _, parsed in ipairs(lines) do
    if isProseRow(parsed) and parsed.width > maxWidth then maxWidth = parsed.width end
  end
  return maxWidth
end

-- Rows of the user's own prompt: from a "❯ " / "› " echo until the
-- next response marker or chrome row. Each prompt counts its rows that
-- reach the wrap width: with fewer than two, the width may be nothing
-- but the length of its own longest typed line.
local function markPromptRows(lines, wrapWidth)
  local prompt = nil
  for _, l in ipairs(lines) do
    if l.promptEcho then
      prompt = { fullRows = 0 }
    elseif l.hadMarker or l.chrome then
      prompt = nil
    end
    l.prompt = prompt
    if prompt and isProseRow(l) and l.width >= wrapWidth - config.wrapJoinSlack then
      prompt.fullRows = prompt.fullRows + 1
    end
  end
end

-- Whole-line selections always capture whatever indent is left of
-- the content. Remove the indent shared by EVERY non-empty output
-- line (relative/nested indentation is preserved).
local function dedentCommon(linesArr)
  local minIndent = math.huge
  for _, l in ipairs(linesArr) do
    if l:match("%S") then
      local spaces = l:match("^ *")
      if #spaces < minIndent then minIndent = #spaces end
      if minIndent == 0 then return linesArr end
    end
  end
  if minIndent == math.huge then return linesArr end
  for k, l in ipairs(linesArr) do
    if l:match("%S") then
      linesArr[k] = l:sub(minIndent + 1)
    end
  end
  return linesArr
end

-- Full clean: strip margins, dedent code blocks, rejoin wrapped paragraphs.
local function cleanClaudeTUI(text)
  text = normalizePartialFirstLine(text)
  local lines = {}
  for _, rawLine in ipairs(splitLines(text)) do
    lines[#lines + 1] = parseClaudeLine(rawLine)
  end

  dedentCodeBlocks(lines)
  local wrapWidth = inferWrapWidth(lines)
  markPromptRows(lines, wrapWidth)

  -- Partial copy: first non-empty line lacks margin (selection started mid-line).
  -- Its apparent length is shorter than the wrap width, so skip the
  -- "short line = intentional break" heuristic for that first line.
  local firstLinePartial = false
  do
    local neCount, marginCount = 0, 0
    local firstHasNoMargin = false
    for _, l in ipairs(lines) do
      if l.nonEmpty then
        neCount = neCount + 1
        if l.hasMargin then marginCount = marginCount + 1 end
        if neCount == 1 then firstHasNoMargin = not l.hasMargin end
      end
    end
    firstLinePartial = firstHasNoMargin and neCount >= 2 and marginCount == (neCount - 1)
  end

  local result = {}
  local i = 1
  local atFirstLine = true
  while i <= #lines do
    local cur = lines[i]

    if cur.chrome then
      -- UI furniture: drop the line entirely.
    elseif not cur.nonEmpty then
      result[#result + 1] = ""
      atFirstLine = false
    elseif cur.indented or cur.codeLike or cur.tableLike then
      result[#result + 1] = cur.text
      atFirstLine = false
    else
      local para = cur.text
      local lastLineWidth = cur.width
      local lastLineText = cur.text
      local skipWidthCheck = atFirstLine and firstLinePartial
      -- A prompt's line breaks are typed. Its rows count as wrapped only
      -- when a second row reaches the wrap width too, so the width is
      -- the terminal's and not merely the longest line's.
      local typed = cur.prompt ~= nil
      local widthKnown = wrapWidth >= config.wrapMinInferredWidth
        and not (typed and cur.prompt.fullRows < 2)
      while i + 1 <= #lines do
        local nxt = lines[i + 1]
        if isFenceLine(lastLineText) then break end
        if not nxt.nonEmpty then break end
        if nxt.chrome then break end
        if nxt.indented then break end
        if nxt.codeLike then break end
        if nxt.tableLike then break end
        -- Quote rows only continue a quote paragraph of the same depth.
        if nxt.quoteDepth ~= cur.quoteDepth then break end
        if isStructuralLine(nxt.text, nxt.prompt ~= nil) then break end
        if not skipWidthCheck
          and widthKnown
          and lastLineWidth < wrapWidth - config.wrapJoinSlack then
          -- Rescue: the TUI wraps greedily at spaces, so a long next
          -- "word" (e.g. an unbroken CJK run after "3. API") explains
          -- a short previous line — that is still a wrap point.
          local firstWord = nxt.text:match("^%s*(%S+)") or ""
          if endsWithSentencePunct(lastLineText)
            or lastLineWidth + 1 + displayWidth(firstWord) <= wrapWidth then
            break
          end
        end
        -- No reliable wrap width. A prompt (narrow, or its longest row
        -- reached by no other row) shows no sign of wrapping, so its rows
        -- stay as typed. Elsewhere — narrow panes — a line ending in
        -- sentence-final punctuation is a complete sentence, not a wrap
        -- point. Common for short CJK list-like rows.
        if not skipWidthCheck and not widthKnown
          and (typed or endsWithSentencePunct(lastLineText)) then
          break
        end
        skipWidthCheck = false
        i = i + 1
        local nxtText = nxt.text:match("^%s*(.-)$")
        -- Separator: CJK has no space-based word boundaries — if
        -- either side of the join is a wide (CJK) char, join without
        -- a space so words like 修改 are never split as 修 改.
        -- Otherwise: a previous line with no spaces means the
        -- terminal hard-broke mid-word — also join without space.
        local separator
        if isWideCp(lastCp(lastLineText)) or isWideCp(firstCp(nxtText)) then
          separator = ""
        else
          separator = lastLineText:find(" ") and " " or ""
        end
        lastLineWidth = displayWidth(nxtText)
        lastLineText = nxtText
        para = para .. separator .. nxtText
      end
      result[#result + 1] = para
      atFirstLine = false
    end

    i = i + 1
  end

  -- Dropped chrome lines leave blank gaps: collapse runs of blank
  -- lines and trim blank edges.
  local out = {}
  for _, l in ipairs(result) do
    if l == "" then
      if #out > 0 and out[#out] ~= "" then out[#out + 1] = "" end
    else
      out[#out + 1] = l
    end
  end
  while #out > 0 and out[#out] == "" do table.remove(out) end

  return table.concat(dedentCommon(out), "\n")
end

-- Strip-only clean: remove margins and stray bare line numbers, no reflow.
local function cleanClaudeTUIStripOnly(text)
  text = normalizePartialFirstLine(text)
  local lines = {}
  for _, rawLine in ipairs(splitLines(text)) do
    lines[#lines + 1] = parseClaudeLine(rawLine)
  end

  dedentCodeBlocks(lines)

  local function isDiffOrNumbered(lineText)
    return isLineNumberPrefixed(lineText) or lineText:match("^%d+%s+[+%-]%s") ~= nil
  end

  local result = {}
  for i, parsed in ipairs(lines) do
    local lineText = parsed.text
    local bareLineNumber = lineText:match("^%d+$") ~= nil

    if parsed.chrome then
      -- UI furniture: drop.
    elseif bareLineNumber then
      local prev = (lines[i - 1] and lines[i - 1].text) or ""
      local nxt = (lines[i + 1] and lines[i + 1].text) or ""
      if not (isDiffOrNumbered(prev) or isDiffOrNumbered(nxt)) then
        result[#result + 1] = lineText
      end
    else
      result[#result + 1] = lineText
    end
  end

  return table.concat(dedentCommon(result), "\n")
end

-- ═══════════════════════════════════════════════════════════════
-- Box-Drawn Tables → CSV
--
-- Claude Code renders markdown tables with box-drawing borders:
--   ⏺ ┌──────┬──────┐
--     │ 建议 │ 数量 │
--     ├──────┼──────┤
--     │ 删 … │ 12   │
--     └──────┴──────┘
-- Pasted raw, the borders and alignment padding fall apart (CJK is
-- double width) and the gutter rule strips each row's leading │.
-- Any copied fragment of such a table (one row, a few rows, a
-- selection starting or ending mid-row) becomes CSV instead. Tables
-- too wide for the terminal are rendered by Claude as "列名: 内容"
-- records; those are left to the normal cleaner. Text the scorer
-- would not touch (code, plain text) is never converted either.
-- ═══════════════════════════════════════════════════════════════

local BAR = "│"
local tableJunctions = {
  "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼", "╭", "╮", "╰", "╯",
  "╞", "╡", "╪", "╔", "╗", "╚", "╝", "╠", "╣", "╦", "╩", "╬",
}
local junctionSet = {}
for _, j in ipairs(tableJunctions) do junctionSet[j] = true end
local innerJunctions = { "├", "┤", "┼", "╞", "╡", "╪", "╠", "╣", "╬" }
local tableRuleChars = { "─", "━", "═", "│", "║", " " }

local function containsAny(s, list)
  for _, c in ipairs(list) do
    if s:find(c, 1, true) then return true end
  end
  return false
end

-- Drop the 2-space margin and a response marker sitting in front of
-- the top border ("⏺ ┌───").
local function stripTableMargin(line)
  local s = line:gsub("^%s+", "")
  for _, marker in ipairs({ "⏺", "●", "•" }) do
    if s:sub(1, #marker) == marker then
      s = s:sub(#marker + 1):gsub("^%s+", "")
      break
    end
  end
  return (s:gsub("%s+$", ""))
end

-- A border needs a corner or junction: a bare ──── line is Claude's
-- record separator (or chrome), not part of a table.
local function isTableBorder(s)
  if s == "" or not containsAny(s, tableJunctions) then return false end
  local rest = s
  for _, c in ipairs(tableJunctions) do rest = rest:gsub(c, "") end
  for _, c in ipairs(tableRuleChars) do rest = rest:gsub(c, "") end
  return rest == ""
end

local function countBars(s)
  local _, n = s:gsub(BAR, "")
  return n
end

local function startsWithBar(s) return s:sub(1, #BAR) == BAR end
local function endsWithBar(s) return #s >= #BAR and s:sub(-#BAR) == BAR end

-- One gutter bar ("│ text") is quote/tool chrome, not a table row.
local function isTableRow(s)
  return countBars(s) >= 2 and (startsWithBar(s) or endsWithBar(s))
end

-- What is left of a row when the selection starts or ends inside it:
-- "c1 │" or "│ a2". Only accepted at the edge of a confirmed table.
local function isRowFragment(s)
  return countBars(s) == 1 and (startsWithBar(s) or endsWithBar(s)) and not isTableBorder(s)
end

-- Walk a stripped line, calling fn(char, displayColumn) per character.
local function eachColumn(s, fn)
  local col, i = 0, 1
  while i <= #s do
    local cp, len = decodeCodepoint(s, i)
    fn(s:sub(i, i + len - 1), col)
    col = col + (isWideCp(cp) and 2 or 1)
    i = i + len
  end
end

-- Display columns of the junctions on the block's first border: those
-- are the only places a row's │ is a cell separator.
local function borderColumns(block)
  for _, s in ipairs(block) do
    if isTableBorder(s) then
      local cols, n = {}, 0
      eachColumn(s, function(ch, col)
        if junctionSet[ch] then
          cols[col] = true
          n = n + 1
        end
      end)
      if n >= 2 then return cols, n - 1 end
    end
  end
  return nil, 0
end

local function barsOnColumns(s, cols)
  local hits = 0
  eachColumn(s, function(ch, col)
    if ch == BAR and cols[col] then hits = hits + 1 end
  end)
  return hits
end

-- A row belongs to the bordered table when it starts with │ and either
-- its bars sit on the junction columns, or (width drift: displayWidth
-- counts emoji as 1 column, the terminal as 2) it is closed on both
-- sides with exactly one bar per junction. `tree` output is neither.
local function isAlignedRow(s, cols, junctionCount)
  if not startsWithBar(s) then return false end
  if barsOnColumns(s, cols) >= 2 then return true end
  return endsWithBar(s) and countBars(s) == junctionCount
end

local function isValidTableBlock(block)
  local cols, width = borderColumns(block)
  for _, s in ipairs(block) do
    if isTableRow(s) then
      if cols then
        if isAlignedRow(s, cols, width + 1) then return true end
      elseif startsWithBar(s) and endsWithBar(s) then
        return true
      end
    end
  end
  return false
end

-- Split a row into cells. A full row whose bars all sit on the border's
-- junction columns is split only there, so a literal │ inside a cell
-- survives. Otherwise (cut short on the left, or columns drifted by a
-- wide character) it is split at every bar.
local function splitRowCells(s, cols, junctionCount)
  local leading, trailing = startsWithBar(s), endsWithBar(s)
  local useCols = cols and leading and barsOnColumns(s, cols) == junctionCount
  local cells, buf = {}, {}
  eachColumn(s, function(ch, col)
    if ch == BAR and (not useCols or cols[col]) then
      cells[#cells + 1] = table.concat(buf)
      buf = {}
    else
      buf[#buf + 1] = ch
    end
  end)
  cells[#cells + 1] = table.concat(buf)
  if leading then table.remove(cells, 1) end
  if trailing then table.remove(cells) end
  for k, c in ipairs(cells) do
    cells[k] = c:gsub("^%s+", ""):gsub("%s+$", "")
  end
  return cells, leading, trailing
end

-- A selection starting (or ending) mid-row loses the first (or last)
-- columns: pad on that side so the remaining cells line up. Builds a
-- new array in one pass (no repeated head inserts).
local function padCells(cells, leading, trailing, width)
  local missing = width - #cells
  if missing <= 0 or (leading and trailing) then return cells end
  local out = {}
  if not leading then
    for _ = 1, missing do out[#out + 1] = "" end
    for _, c in ipairs(cells) do out[#out + 1] = c end
  else
    for _, c in ipairs(cells) do out[#out + 1] = c end
    for _ = 1, missing do out[#out + 1] = "" end
  end
  return out
end

-- A selection starting inside a cell whose rest is blank keeps only
-- spaces before the next │; once they are trimmed ("│ 9.9 │ 48/95 │")
-- the line looks like a whole row a few columns short. Its bars still
-- sit on the border's junctions when counted from the right: returns
-- how many cells were cut off on the left, 0 for any other line.
local function leftCutCells(s, cols)
  if not cols or not (startsWithBar(s) and endsWithBar(s)) then return 0 end
  local bars = {}
  eachColumn(s, function(ch, col)
    if ch == BAR then bars[#bars + 1] = col end
  end)
  local right = 0
  for col in pairs(cols) do right = math.max(right, col) end
  local shift = right - bars[#bars]
  if shift <= 0 then return 0 end
  for _, col in ipairs(bars) do
    if not cols[col + shift] then return 0 end
  end
  local lost = 0
  for col in pairs(cols) do
    if col < shift then lost = lost + 1 end
  end
  return lost
end

-- A cell wrapped over several lines: ASCII words get a space back,
-- CJK text is joined directly.
local function joinCellFragments(a, b)
  if a == "" then return b end
  if b == "" then return a end
  local l, f = lastCp(a), firstCp(b)
  if l and f and l < 0x80 and f < 0x80 then return a .. " " .. b end
  return a .. b
end

local function csvField(s)
  if s:find('[,"\n\r]') or s:match("^%s") or s:match("%s$") then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

local function tableBlockToCsv(block)
  local cols, borderWidth = borderColumns(block)

  -- With row separators (├───┼───┤) every row line between two
  -- separators belongs to one logical row; without them each line is
  -- its own row.
  local grouped = false
  for _, s in ipairs(block) do
    if isTableBorder(s) and containsAny(s, innerJunctions) then grouped = true end
  end

  local lines = {}
  for _, s in ipairs(block) do
    if isTableBorder(s) then
      lines[#lines + 1] = { border = true }
    else
      local cells, leading, trailing = splitRowCells(s, cols, borderWidth + 1)
      local lost = leftCutCells(s, cols)
      if lost > 0 then
        local padded = {}
        for _ = 1, lost do padded[#padded + 1] = "" end
        for _, c in ipairs(cells) do padded[#padded + 1] = c end
        cells = padded
      end
      lines[#lines + 1] = { cells = cells, leading = leading, trailing = trailing }
    end
  end

  local width = borderWidth
  if width == 0 then
    for _, l in ipairs(lines) do
      if l.cells and l.leading and l.trailing then width = math.max(width, #l.cells) end
    end
  end
  if width == 0 then
    for _, l in ipairs(lines) do
      if l.cells then width = math.max(width, #l.cells) end
    end
  end

  -- Pad every physical line before merging wrapped lines, so a cut-off
  -- first line cannot shift its text into the wrong column.
  local rows, current = {}, nil
  local function flush()
    if current then rows[#rows + 1] = current end
    current = nil
  end
  for _, l in ipairs(lines) do
    if l.border then
      flush()
    else
      local cells = padCells(l.cells, l.leading, l.trailing, width)
      if current and grouped then
        for k, c in ipairs(cells) do
          current[k] = joinCellFragments(current[k] or "", c)
        end
      else
        flush()
        current = cells
      end
      if not grouped then flush() end
    end
  end
  flush()

  local out = {}
  for _, cells in ipairs(rows) do
    local fields = {}
    for k, c in ipairs(cells) do fields[k] = csvField(c) end
    out[#out + 1] = table.concat(fields, ",")
  end
  return table.concat(out, "\n")
end

-- Text the scorer calls plain may still be a Claude Code table: its own
-- copy (fullscreen TUI, copy-on-select) drops the margins. Without the
-- scorer, convert only what Claude Code itself draws, whole or a
-- selected part of it: light lines (┌─┬─┐ ├─┼─┤ └─┴─┘) with at least
-- one border or separator in the selection, every border on the same
-- junction columns, ┌ only first and └ only last, at least two
-- columns, every row closed on both sides except a first line cut on
-- the left and a last line cut on the right. The separators must also
-- leave no doubt which lines form a row: Claude puts one between every
-- row, while sqlite / psql / duckdb draw one under the header only,
-- where a two-line section could be two records or one wrapped row.
-- A neighbouring line drawn with other box characters (rich's ┏━┳━┓
-- header) means the block is only part of a table not drawn by Claude.
-- Diagrams, a lone row and other tools' tables stay as they are.
local lightBorderChars = { "─", "┌", "┬", "┐", "├", "┼", "┤", "└", "┴", "┘" }

local function isLightBorder(s)
  local rest = s
  for _, c in ipairs(lightBorderChars) do rest = rest:gsub(c, "") end
  return rest == ""
end

-- Junction columns of a border line, and its display width.
local function borderJunctions(s)
  local cols, width = {}, 0
  eachColumn(s, function(ch, col)
    if junctionSet[ch] then cols[#cols + 1] = col end
    width = col + 1
  end)
  return cols, width
end

-- Every border must sit on the junction columns of the widest one. The
-- selection may cut the block's first line short on the left, or its
-- last line on the right ("└───┴"): those only have to agree as far as
-- they go. Returns false, or true and the column count.
local function bordersAgree(block)
  local ref, refWidth
  for _, s in ipairs(block) do
    if isTableBorder(s) then
      local cols, width = borderJunctions(s)
      if not refWidth or width > refWidth then ref, refWidth = cols, width end
    end
  end
  if not ref then return true, 0 end
  local onRef = {}
  for _, c in ipairs(ref) do onRef[c] = true end
  for k, s in ipairs(block) do
    if isTableBorder(s) then
      local cols, width = borderJunctions(s)
      local shift = 0
      if width == refWidth then
        if #cols ~= #ref then return false end
      elseif k == 1 then
        shift = refWidth - width
      elseif k ~= #block then
        return false
      end
      for _, c in ipairs(cols) do
        if not onRef[c + shift] then return false end
      end
    end
  end
  return true, #ref - 1
end

-- Even with the scorer's say-so, a block is only a table when its
-- borders are: unbroken light lines on the same junction columns, at
-- least two columns. Box diagrams in a code block (┌──┐  ┌──┐, a single
-- box, └─┬─┴─┬─┘ branching off) go to the text cleaner instead. A few
-- copied rows without any border are taken as they are.
local function hasTableBorders(block)
  local any = false
  for _, s in ipairs(block) do
    if isTableBorder(s) then
      if not isLightBorder(s) then return false end
      any = true
    end
  end
  if not any then return true end
  local agree, width = bordersAgree(block)
  return agree and width >= 2
end

-- Box-drawing characters (U+2500–U+257F) other than the plain │.
local function hasOtherBoxChars(s)
  return s ~= nil and s:gsub(BAR, ""):find("\226[\148\149]") ~= nil
end

local function isClaudeTable(block, before, after)
  if hasOtherBoxChars(before) or hasOtherBoxChars(after) then return false end
  local cols, width = borderColumns(block)
  if not cols or width < 2 or not bordersAgree(block) then return false end
  local separators, sectionLines, multiLine = 0, 0, false
  for k, s in ipairs(block) do
    if isTableBorder(s) then
      if not isLightBorder(s) then return false end
      if (s:sub(1, #"┌") == "┌" and k > 1) or (s:sub(1, #"└") == "└" and k < #block) then
        return false
      end
      if k > 1 and k < #block then separators = separators + 1 end
      if sectionLines > 1 then multiLine = true end
      sectionLines = 0
    else
      local whole = startsWithBar(s) and endsWithBar(s)
        and (barsOnColumns(s, cols) == width + 1 or countBars(s) == width + 1)
      local cutLeft = k == 1 and endsWithBar(s)
        and (not startsWithBar(s) or leftCutCells(s, cols) > 0)
      local cutRight = k == #block and startsWithBar(s) and not endsWithBar(s)
        and barsOnColumns(s, cols) == countBars(s)
      if not (whole or cutLeft or cutRight) then return false end
      sectionLines = sectionLines + 1
    end
  end
  if sectionLines > 1 then multiLine = true end
  return separators >= 2 or not multiLine
end

-- Split text into prose and table segments, in order. A table segment
-- keeps its raw lines and line range alongside the stripped block.
local function splitTableSegments(text)
  local lines = splitLines(text)
  local stripped = {}
  for k, l in ipairs(lines) do stripped[k] = stripTableMargin(l) end

  local segments, i = {}, 1
  local function pushText(k)
    local last = segments[#segments]
    if last and last.kind == "text" then
      last.lines[#last.lines + 1] = lines[k]
    else
      segments[#segments + 1] = { kind = "text", lines = { lines[k] } }
    end
  end

  while i <= #lines do
    local s = stripped[i]
    if isTableBorder(s) or isTableRow(s) then
      -- A closed bottom border followed by a new top border is where
      -- one table ends and the next begins.
      local j = i
      while j < #lines and (isTableBorder(stripped[j + 1]) or isTableRow(stripped[j + 1]))
          and not (stripped[j]:sub(1, #"└") == "└" and stripped[j + 1]:sub(1, #"┌") == "┌") do
        j = j + 1
      end
      local block = {}
      for k = i, j do block[#block + 1] = stripped[k] end
      if isValidTableBlock(block) then
        local first, last = i, j
        -- Pull in a one-bar fragment right before or after the table,
        -- unless the table's own outer border is in between.
        local prev = segments[#segments]
        local closedTop = block[1]:sub(1, #"┌") == "┌" or block[1]:sub(1, #"╭") == "╭"
        local closedBottom = block[#block]:sub(1, #"└") == "└" or block[#block]:sub(1, #"╰") == "╰"
        if first > 1 and not closedTop and isRowFragment(stripped[first - 1]) and endsWithBar(stripped[first - 1])
            and prev and prev.kind == "text" and prev.lines[#prev.lines] == lines[first - 1] then
          table.remove(prev.lines)
          if #prev.lines == 0 then table.remove(segments) end
          first = first - 1
          table.insert(block, 1, stripped[first])
        end
        if last < #lines and not closedBottom and isRowFragment(stripped[last + 1]) and startsWithBar(stripped[last + 1]) then
          last = last + 1
          block[#block + 1] = stripped[last]
        end
        local raw = {}
        for k = first, last do raw[#raw + 1] = lines[k] end
        segments[#segments + 1] = {
          kind = "table", block = block, raw = raw,
          before = stripped[first - 1], after = stripped[last + 1],
        }
        i = last + 1
      else
        for k = i, j do pushText(k) end
        i = j + 1
      end
    else
      pushText(i)
      i = i + 1
    end
  end
  return segments
end

local function convertTables(segments)
  local out = {}
  for _, seg in ipairs(segments) do
    out[#out + 1] = seg.kind == "table" and tableBlockToCsv(seg.block)
      or table.concat(seg.lines or seg.raw, "\n")
  end
  return table.concat(out, "\n")
end

local PLACEHOLDER = "---ai-clean-copy-table-%d---"
-- The same marker as a Lua pattern that captures the table number.
local PLACEHOLDER_PATTERN = (PLACEHOLDER:gsub("%-", "%%-"):gsub("%%d", "(%%d+)"))

-- The table's margin, or its ⏺ marker when the table opens the
-- response. Markers are compared as strings: a Lua character class
-- like [⏺●•] matches single bytes and would cut a UTF-8 sequence.
local function placeholderPrefix(raw)
  local indent = raw:match("^%s*")
  local rest = raw:sub(#indent + 1)
  for _, marker in ipairs({ "⏺", "●", "•" }) do
    if rest:sub(1, #marker) == marker then return indent .. marker .. " " end
  end
  return indent
end

-- A box diagram goes back exactly as drawn, minus the margin: the
-- leading whitespace the lines after the first share. A ⏺ marker in
-- front of the first line stands in for the margin; a selection that
-- starts inside the margin leaves the first line only part of it.
local function dedentBlock(raw)
  local lines = {}
  for k, l in ipairs(raw) do lines[k] = (l:gsub("%s+$", "")) end
  local indent, rest = lines[1]:match("^(%s*)(.*)$")
  for _, marker in ipairs({ "⏺", "●", "•" }) do
    if rest:sub(1, #marker) == marker then
      lines[1] = indent .. "  " .. (rest:sub(#marker + 1):gsub("^ ", "", 1))
      break
    end
  end
  local margin
  for k = 2, #lines do
    if lines[k] ~= "" then
      local lead = lines[k]:match("^[ \t]*")
      local n = 0
      if margin then
        while n < #margin and margin:sub(n + 1, n + 1) == lead:sub(n + 1, n + 1) do n = n + 1 end
      end
      margin = margin and margin:sub(1, n) or lead
    end
  end
  margin = margin or lines[1]:match("^[ \t]*")
  for k, l in ipairs(lines) do
    if l:sub(1, #margin) == margin then
      lines[k] = l:sub(#margin + 1)
    elseif k == 1 then
      lines[k] = (l:gsub("^[ \t]*", ""))
    end
  end
  return table.concat(lines, "\n")
end

-- Claude Code's own copy (fullscreen TUI, copy-on-select) already drops
-- the margins and rejoins soft wraps, so the scorer sees plain text and
-- says "none" — but the ▎ blockquote bars come along. Strip only those;
-- every other byte stays as it was.
local function stripQuoteBars(text)
  local lines, changed = {}, false
  for raw in (text .. "\n"):gmatch("(.-)\n") do
    local indent, rest = raw:match("^([ \t]*)(.*)$")
    local bars = 0
    while rest:sub(1, #QUOTE_BAR) == QUOTE_BAR do
      rest = rest:sub(#QUOTE_BAR + 1):gsub("^ ", "", 1)
      bars = bars + 1
    end
    if bars > 0 then changed = true end
    lines[#lines + 1] = bars > 0 and indent .. rest or raw
  end
  return changed and table.concat(lines, "\n") or text
end

-- The pipeline claude-copy.lua runs on every terminal copy. Returns the
-- text unchanged when there is nothing to clean.
-- opts.appCopy: Claude Code copied the text itself (fullscreen TUI).
-- It has already rejoined its soft wraps, so every line break left in
-- the text was typed: strip margins, never reflow.
local function processClipboard(text, opts)
  local normalized = recoverFlattenedNumberedBlock(text)
  local decision = classifyClaudeClipboard(normalized)
  if type(opts) == "table" and opts.appCopy and decision.mode == "full" then
    decision.mode = "strip"
  end
  -- Same gate as before: text the scorer would not touch (code, plain
  -- text) stays byte-for-byte — apart from leading ▎ quote bars, which
  -- are never content, and whole Claude Code tables (see isClaudeTable).
  if decision.mode == "none" then
    local segments = splitTableSegments(text)
    local out, converted = {}, false
    for _, seg in ipairs(segments) do
      if seg.kind == "table" and isClaudeTable(seg.block, seg.before, seg.after) then
        out[#out + 1] = tableBlockToCsv(seg.block)
        converted = true
      else
        out[#out + 1] = stripQuoteBars(table.concat(seg.raw or seg.lines, "\n"))
      end
    end
    if not converted then return stripQuoteBars(text) end
    -- splitLines normalized the line breaks and dropped the final one.
    local eol = text:find("\r\n", 1, true) and "\r\n" or "\n"
    local result = table.concat(out, "\n"):gsub("\n", eol)
    if text:sub(-1) == "\n" then result = result .. eol end
    return result
  end

  local segments = splitTableSegments(text)
  local hasBlock = false
  for _, seg in ipairs(segments) do
    if seg.kind == "table" and not hasTableBorders(seg.block) then seg.kind = "diagram" end
    if seg.kind ~= "text" then hasBlock = true end
  end
  if not hasBlock then
    if decision.mode == "full" then return cleanClaudeTUI(normalized) end
    return cleanClaudeTUIStripOnly(normalized)
  end

  -- Clean the whole text in one pass with each table (or box diagram,
  -- which the cleaner would tear apart) replaced by a placeholder line,
  -- so blank lines and relative indentation around them come out
  -- exactly as without them. The placeholder keeps the block's margin
  -- (or ⏺ marker) and is a structural "---" line, which the cleaner
  -- never reflows.
  local lines, csv = {}, {}
  for _, seg in ipairs(segments) do
    if seg.kind ~= "text" then
      csv[#csv + 1] = seg.kind == "table" and tableBlockToCsv(seg.block) or dedentBlock(seg.raw)
      lines[#lines + 1] = placeholderPrefix(seg.raw[1]) .. PLACEHOLDER:format(#csv)
    else
      for _, l in ipairs(seg.lines) do lines[#lines + 1] = l end
    end
  end
  local withPlaceholders = recoverFlattenedNumberedBlock(table.concat(lines, "\n"))
  local cleaned = decision.mode == "full" and cleanClaudeTUI(withPlaceholders)
    or cleanClaudeTUIStripOnly(withPlaceholders)

  local out, found = {}, 0
  for _, l in ipairs(splitLines(cleaned)) do
    local k = l:match(PLACEHOLDER_PATTERN)
    if k and csv[tonumber(k)] then
      out[#out + 1] = csv[tonumber(k)]
      found = found + 1
    else
      out[#out + 1] = l
    end
  end
  -- Should never happen; if the cleaner ever mangles a placeholder,
  -- still deliver the tables rather than losing them.
  if found ~= #csv then return convertTables(segments) end
  return table.concat(out, "\n")
end

-- ═══════════════════════════════════════════════════════════════
-- Public API
-- ═══════════════════════════════════════════════════════════════

M.classify = classifyClaudeClipboard
M.clean = cleanClaudeTUI
M.stripOnly = cleanClaudeTUIStripOnly
M.recoverNumberedBlock = recoverFlattenedNumberedBlock
-- Table conversion alone, without the scorer gate or prose cleaning.
M.tablesToCsv = function(text) return convertTables(splitTableSegments(text)) end
M.process = processClipboard

return M
