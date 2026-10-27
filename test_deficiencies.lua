#!/usr/bin/env lua
-- Deficiency tests for claude-copy/clean.lua
-- Fixtures are taken from a REAL Claude Code v2.1.207 TUI capture
-- (tmux capture-pane, 100 cols) — see tui-capture-raw.txt.
-- Run: lua test_deficiencies.lua

local clean = dofile("clean.lua")

local passed, failed = 0, 0
local failures = {}

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    failures[#failures + 1] = name
    io.write("FAIL: " .. name .. "\n  " .. tostring(err) .. "\n")
  end
end

local function eq(got, expected, msg)
  if got ~= expected then
    error((msg or "") .. "\n  expected: " .. tostring(expected) .. "\n       got: " .. tostring(got))
  end
end

-- ═══════════════════════════════════════════════════════════════
-- 1. Pure-CJK wrapped paragraph (real fixture, lines 15-18)
--    Regression: must classify full and rejoin with NO spaces
--    inserted between CJK chars.
-- ═══════════════════════════════════════════════════════════════

local pureCJK = table.concat({
  "  剪贴板清理工具通过监听操作系统的剪贴板事件来工作。当用户复制内容时，工具会拦截并分析该数据，判断是",
  "  否符合删除规则。根据预设的过滤策略（如大小限制、内容类型、敏感信息检测等），工具会自动清理过期或无",
  "  用的剪贴板条目。通过定时任务和内存管理机制，它能有效控制系统剪贴板占用的资源，防止堆积导致的性能下",
  "  降。整个过程透明化运行，用户无需手动干预，极大提升了使用效率和系统稳定性。",
}, "\n")

test("CJK: pure Chinese paragraph classifies as full", function()
  local r = clean.classify(pureCJK)
  eq(r.mode, "full", "mode")
end)

test("CJK: pure Chinese paragraph rejoins seamlessly", function()
  local result = clean.clean(pureCJK)
  eq(result:find("\n"), nil, "should be one line")
  assert(result:find("判断是否符合"), "boundary 是/否 must join without space")
  assert(result:find("过期或无用的"), "boundary 无/用 must join without space")
  assert(result:find("性能下降"), "boundary 下/降 must join without space")
end)

-- ═══════════════════════════════════════════════════════════════
-- 2. CJK mid-word hard break in a line that ALSO contains ASCII
--    spaces (mixed 中英文). Current code joins with " " because the
--    previous line contains a space → "修 改" corruption.
-- ═══════════════════════════════════════════════════════════════

test("CJK: mixed line hard break must not insert space mid-word", function()
  local input = table.concat({
    "  这个方案的关键在于我们可以直接复用 Hammerspoon 提供的 eventtap 机制来拦截快捷键，不需要修",
    "  改任何系统设置就能生效。",
  }, "\n")
  local result = clean.clean(input)
  assert(result:find("不需要修改任何"), "修/改 must join without space, got: " .. result)
  assert(not result:find("修 改"), "spurious space inside 修改")
end)

-- ═══════════════════════════════════════════════════════════════
-- 3. Mixed CJK/ASCII paragraph: byte-length vs display-width.
--    A CJK line is ~1.5x bytes per column; ASCII continuation lines
--    fail the byte-based width check and are left unjoined.
-- ═══════════════════════════════════════════════════════════════

test("CJK: mixed-width paragraph rejoins ASCII continuation", function()
  local input = table.concat({
    "  这个工具的核心逻辑其实非常简单：先监听系统剪贴板的变化事件，然后按照预先定义好的规则逐条进行分析和",
    "  过滤。The whole pipeline is written in Lua and runs inside Hammerspoon as a background",
    "  daemon, which makes it easy to customize.",
  }, "\n")
  local result = clean.clean(input)
  eq(result:find("\n"), nil, "should be one joined line, got:\n" .. result)
  assert(result:find("background daemon"), "ASCII wrap must join with space")
end)

-- Real fixture (lines 22-25): mixed paragraph must fully rejoin.
test("CJK: real mixed fixture rejoins into one paragraph", function()
  local input = table.concat({
    "  在 macOS 环境中，Hammerspoon 这个强大的自动化框架能够拦截 Cmd+C 快捷键事件，实现对 clipboard",
    "  的实时监控。通过编写 Lua 脚本，开发者可以在每次复制操作时自动触发清理逻辑，检查 clipboard",
    "  中的文本是否包含敏感信息。如果检测到需要处理的内容，工具会调用系统 API 自动清空 clipboard",
    "  或替换其内容。这种方法比传统的后台守护进程更加灵活高效，特别适合需要精细化内容管理的场景。",
  }, "\n")
  local result = clean.clean(input)
  eq(result:find("\n"), nil, "should be one joined line, got:\n" .. result)
  assert(not result:find("clipboard 的 实时"), "no double-spacing artifacts")
end)

-- ═══════════════════════════════════════════════════════════════
-- 4. ⏺ response marker (real fixture, line 13 / lines 33-34 of
--    second capture). Must be stripped from cleaned output.
-- ═══════════════════════════════════════════════════════════════

test("TUI: ⏺ first-line marker is stripped, content joined", function()
  local input = table.concat({
    "⏺ 你的 Hammerspoon 配置目录包含 init.lua 主入口、claude-copy.lua 复制工具脚本、clean.lua",
    "  清理工具脚本，以及存放第三方插件的 Spoons 文件夹。",
  }, "\n")
  local r = clean.classify(input)
  assert(r.mode == "full" or r.mode == "strip", "should clean, got " .. r.mode)
  local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
  assert(not result:find("⏺"), "⏺ marker must be stripped, got: " .. result)
  assert(result:find("^你的 Hammerspoon"), "content must start at column 0")
end)

test("TUI: ⏺ heading + margined body cleans without markers", function()
  local input = table.concat({
    "⏺ 1. 纯中文段落",
    "",
    "  剪贴板清理工具通过监听操作系统的剪贴板事件来工作。当用户复制内容时，工具会拦截并分析该数据，判断是",
    "  否符合删除规则。根据预设的过滤策略（如大小限制、内容类型、敏感信息检测等），工具会自动清理过期或无",
    "  用的剪贴板条目。",
  }, "\n")
  local r = clean.classify(input)
  assert(r.mode == "full" or r.mode == "strip", "should clean, got " .. r.mode)
  local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
  assert(not result:find("⏺"), "⏺ must be stripped")
end)

-- ═══════════════════════════════════════════════════════════════
-- 5. ❯ prompt-echo marker and ✻ spinner/status lines (real fixture
--    lines 38, 41 and "Listed 1 directory (ctrl+o to expand)").
-- ═══════════════════════════════════════════════════════════════

test("TUI: sweep copy drops spinner + expand-hint chrome lines", function()
  local input = table.concat({
    "❯ 运行 ls -la ~/.hammerspoon 看看有哪些文件，然后用一句话总结",
    "",
    "  Listed 1 directory (ctrl+o to expand)",
    "",
    "⏺ 你的 Hammerspoon 配置目录包含 init.lua 主入口、claude-copy.lua 复制工具脚本、clean.lua",
    "  清理工具脚本，以及存放第三方插件的 Spoons 文件夹。",
    "",
    "✻ Worked for 11s",
  }, "\n")
  local r = clean.classify(input)
  assert(r.mode == "full" or r.mode == "strip", "should clean, got " .. r.mode)
  local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
  assert(not result:find("✻"), "spinner line must be dropped, got:\n" .. result)
  assert(not result:find("ctrl%+o to expand"), "expand-hint chrome must be dropped")
  assert(not result:find("❯"), "prompt marker must be stripped")
  assert(result:find("运行 ls %-la"), "prompt text itself must be kept")
  assert(result:find("Spoons 文件夹"), "answer text must survive")
end)

test("TUI: ⎿ tool-result marker is stripped", function()
  local input = table.concat({
    "⏺ Bash(ls -la ~/.hammerspoon)",
    "  ⎿  total 64",
    "     drwxr-xr-x   6 alex  staff   192 Mar 31 10:30 .",
    "     -rw-r--r--   1 alex  staff  3853 Mar 30 22:05 claude-copy.lua",
  }, "\n")
  local r = clean.classify(input)
  if r.mode ~= "none" then
    local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
    assert(not result:find("⎿"), "⎿ marker must be stripped, got:\n" .. result)
  end
end)

-- ═══════════════════════════════════════════════════════════════
-- 6. Code-line misclassification → prose join corruption.
-- ═══════════════════════════════════════════════════════════════

test("code: call with trailing lua comment is not joined into prose", function()
  local input = table.concat({
    "  这一行是普通的介绍文字它非常长非常长非常长非常长非常长非常长非常长非常长非常长非常长非常长非常",
    "  hs.pasteboard.clearContents()  -- 清空剪贴板内容",
  }, "\n")
  local result = clean.clean(input)
  assert(result:find("\n"), "code line must stay on its own line, got:\n" .. result)
end)

test("code: bare closing bracket line is not joined into prose", function()
  local input = table.concat({
    "  这一行是普通的介绍文字它非常长非常长非常长非常长非常长非常长非常长非常长非常长非常长非常长非常",
    "  end)",
  }, "\n")
  local result = clean.clean(input)
  assert(result:find("\n"), "'end)' must stay on its own line, got:\n" .. result)
end)

test("code: lua comment line is code-like, not prose", function()
  local input = table.concat({
    "  这一行是普通的介绍文字它非常长非常长非常长非常长非常长非常长非常长非常长非常长非常长非常长非常",
    "  -- Hammerspoon 剪贴板监控脚本",
  }, "\n")
  local result = clean.clean(input)
  assert(result:find("\n"), "lua comment must stay on its own line, got:\n" .. result)
end)

-- Real fixture code block (lines 29-36): must survive full clean intact.
test("code: real lua block keeps all lines separate", function()
  local input = table.concat({
    "  -- Hammerspoon 剪贴板监控脚本",
    "  hs.hotkey.bind({'cmd'}, 'c', function()",
    "    -- 捕获 Cmd+C 事件",
    "    local pasteboard = hs.pasteboard.readString()",
    "    if pasteboard and string.len(pasteboard) > 1000 then",
    "      hs.pasteboard.clearContents()  -- 清空超过限制的剪贴板内容",
    "    end",
    "  end)",
  }, "\n")
  local r = clean.classify(input)
  if r.mode ~= "none" then
    local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
    local n = select(2, result:gsub("\n", "")) + 1
    eq(n, 8, "all 8 code lines must stay separate, got:\n" .. result)
  end
end)

-- ═══════════════════════════════════════════════════════════════
-- 7. CJK structural lines: fullwidth-colon key-value pairs.
-- ═══════════════════════════════════════════════════════════════

test("CJK: fullwidth-colon key-value lines stay separate", function()
  local input = table.concat({
    "  标题：一个关于剪贴板自动清理工具的完整介绍文档说明",
    "  描述：这份文档详细讲解了工具的安装步骤和配置方法以及注意事项",
  }, "\n")
  local result = clean.clean(input)
  assert(result:find("\n"), "Key：value lines must stay separate, got:\n" .. result)
end)

-- ═══════════════════════════════════════════════════════════════
-- 8. CJK sentence-end punctuation recognized in wrap detection:
--    short standalone lines each ending with 。must not count as
--    wrapped pairs (they are complete sentences / list-ish rows).
-- ═══════════════════════════════════════════════════════════════

test("CJK: short standalone sentences are not reflowed", function()
  local input = table.concat({
    "  第一步，安装依赖工具。",
    "  第二步，复制配置文件。",
    "  第三步，重新加载配置。",
  }, "\n")
  local r = clean.classify(input)
  if r.mode == "full" then
    local result = clean.clean(input)
    local n = select(2, result:gsub("\n", "")) + 1
    eq(n, 3, "three complete sentences must stay as 3 lines, got:\n" .. result)
  end
end)

-- ═══════════════════════════════════════════════════════════════
-- 9. Full pipeline on the complete real capture sweep.
-- ═══════════════════════════════════════════════════════════════

test("e2e: full sweep of real capture cleans markers and keeps content", function()
  local f = io.open("tui-fixture-sweep.txt", "r")
  assert(f, "fixture file missing")
  local input = f:read("*a")
  f:close()
  local normalized = clean.recoverNumberedBlock(input)
  local r = clean.classify(normalized)
  assert(r.mode == "full" or r.mode == "strip", "sweep should clean, got " .. r.mode)
  local result = (r.mode == "full") and clean.clean(normalized) or clean.stripOnly(normalized)
  assert(not result:find("⏺"), "no ⏺ in output")
  assert(not result:find("✻"), "no spinner lines in output")
  assert(result:find("剪贴板清理工具通过监听"), "paragraph 1 content kept")
  assert(result:find("hs%.hotkey%.bind"), "code content kept")
end)

-- ═══════════════════════════════════════════════════════════════
-- 10. Wrapped list items (real fixture: Claude TUI renders bullet
--     continuations at margin level; greedy word-wrap can leave a
--     very short head like "3. API" before a long CJK run).
-- ═══════════════════════════════════════════════════════════════

test("list: wrapped bullet/numbered items classify full and rejoin", function()
  local f = io.open("tui-fixture-lists.txt", "r")
  assert(f, "fixture file missing")
  local input = f:read("*a"); f:close()
  local r = clean.classify(input)
  eq(r.mode, "full", "wrapped list items need full mode")
  local result = clean.clean(input)
  for l in (result .. "\n"):gmatch("(.-)\n") do
    assert(not l:match("^%s+%S"), "no leading spaces on: [" .. l .. "]")
  end
  local items = 0
  for l in (result .. "\n"):gmatch("(.-)\n") do
    if l:match("^[%-%d]") then items = items + 1 end
  end
  eq(items, 7, "4 bullets + 3 numbered items, got:\n" .. result)
  assert(result:find("Python脚本实现") or result:find("Python 脚本实现"), "bullet 1 rejoined")
  assert(result:find("ELK Stack方案实现") or result:find("ELK Stack 方案实现"), "numbered 1 rejoined")
  assert(result:find("API文档自动生成") or result:find("API 文档自动生成"), "short-head '3. API' rejoined")
end)

test("list: complete short bullets stay separate", function()
  local input = table.concat({
    "  - 第一项说明。",
    "  - 第二项说明。",
    "  - 第三项说明。",
  }, "\n")
  local r = clean.classify(input)
  if r.mode ~= "none" then
    local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
    local n = select(2, result:gsub("\n", "")) + 1
    eq(n, 3, "3 bullets stay 3 lines, got:\n" .. result)
  end
end)

-- ═══════════════════════════════════════════════════════════════
-- 11. Column/table-like output must never be reflowed.
-- ═══════════════════════════════════════════════════════════════

test("table: ls-style column output is not joined", function()
  local input = table.concat({
    "  total 64",
    "  drwxr-xr-x   6 alex  staff   192 Mar 31 10:30 spoons",
    "  -rw-r--r--   1 alex  staff  3853 Mar 30 22:05 claude-copy.lua",
    "  -rw-r--r--   1 alex  staff  1140 Mar 31 10:30 clean.lua",
  }, "\n")
  local r = clean.classify(input)
  if r.mode ~= "none" then
    local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
    local n = select(2, result:gsub("\n", "")) + 1
    eq(n, 4, "4 rows stay 4 lines, got:\n" .. result)
  end
end)

-- ═══════════════════════════════════════════════════════════════
-- 12. Whole-line copies: common leading indent is removed, but
--     relative (nested) indentation is preserved.
-- ═══════════════════════════════════════════════════════════════

test("dedent: deep-selected block loses common leading spaces", function()
  local input = table.concat({
    "     drwxr-xr-x   6 alex  staff   192 spoons",
    "     -rw-r--r--   1 alex  staff  3853 claude-copy.lua",
    "     -rw-r--r--   1 alex  staff  1140 clean.lua",
  }, "\n")
  local r = clean.classify(input)
  assert(r.mode ~= "none", "margined block should clean, got none")
  local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
  for l in (result .. "\n"):gmatch("(.-)\n") do
    if l:match("%S") then
      assert(not l:match("^%s"), "leading spaces remain on: [" .. l .. "]")
    end
  end
end)

test("dedent: relative indentation is preserved", function()
  local input = table.concat({
    "  下面是代码示例的说明文字这一行要足够长足够长足够长足够长足够长足够长",
    "      local x = 1",
    "          local y = 2",
  }, "\n")
  local r = clean.classify(input)
  if r.mode ~= "none" then
    local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
    assert(result:find("\nlocal x = 1\n") or result:find("\nlocal x = 1$"),
      "outer code line at col 0, got:\n" .. result)
    assert(result:find("\n    local y = 2"),
      "nested code keeps deeper indent, got:\n" .. result)
  end
end)

-- ═══════════════════════════════════════════════════════════════
-- 13. User field report: whole-line copy of margined bullets in a
--     wide window (each item one line). Must paste with no leading
--     spaces. Variant: selection started at column 1, leaving a
--     partial 1-space margin on the first line.
-- ═══════════════════════════════════════════════════════════════

local fieldBullets = table.concat({
  "  - 列表项折行识别：- item / 1. item 现在作为折行源参与检测，续行正确拼回成完整一行；",
  "  - 贪婪折行救援拼接：短头行（如 3. API）+ 下一行首个词放不进上一行，判定为折行点，照样拼接；",
  "  - 列对齐守卫：行内出现 3 连空格（ls、ps、表格列）永不重排；",
  "  - 统一去公共缩进：输出前把所有行共有的最小缩进剥掉，嵌套的相对缩进保留。",
}, "\n")

test("field: margined bullet block pastes flush-left", function()
  local r = clean.classify(fieldBullets)
  assert(r.mode ~= "none", "must clean, got none")
  local result = (r.mode == "full") and clean.clean(fieldBullets) or clean.stripOnly(fieldBullets)
  for l in (result .. "\n"):gmatch("(.-)\n") do
    if l:match("%S") then
      assert(l:match("^%- "), "bullet must start at column 0: [" .. l .. "]")
    end
  end
end)

test("field: partial 1-space margin on first line is normalized", function()
  local input = fieldBullets:gsub("^  ", " ", 1)  -- selection started at col 1
  local r = clean.classify(input)
  assert(r.mode ~= "none", "must clean, got none")
  local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
  for l in (result .. "\n"):gmatch("(.-)\n") do
    if l:match("%S") then
      assert(l:match("^%- "), "bullet must start at column 0: [" .. l .. "]")
    end
  end
end)

-- ═══════════════════════════════════════════════════════════════
-- 14. Codex CLI support (real fixture: tui-fixture-codex.txt).
--     Codex renders "• " response markers, "› " prompt echoes, and
--     hanging-indent (4-space) list continuations.
-- ═══════════════════════════════════════════════════════════════

test("codex: response block cleans markers and rejoins paragraph", function()
  local f = io.open("tui-fixture-codex.txt", "r")
  assert(f, "codex fixture missing")
  local input = f:read("*a"); f:close()
  local r = clean.classify(input)
  eq(r.mode, "full", "codex response should be full mode")
  local result = clean.clean(input)
  assert(not result:find("•"), "• marker must be stripped, got:\n" .. result)
  assert(result:find("^剪贴板工具能自动保存"), "content flush-left")
  assert(result:find("与输入，提高资料整理"), "paragraph wrap rejoined across margin lines")
end)

test("codex: hanging-indent list continuation rejoins", function()
  local f = io.open("tui-fixture-codex.txt", "r")
  local input = f:read("*a"); f:close()
  local result = clean.clean(input)
  assert(result:find("链接或代码片段。"), "4-space hanging continuation must rejoin, got:\n" .. result)
  assert(result:find("云端同步功能。"), "second hanging continuation must rejoin")
  local items = 0
  for l in (result .. "\n"):gmatch("(.-)\n") do
    if l:match("^%- ") then items = items + 1 end
  end
  eq(items, 3, "3 bullet items each on one line, got:\n" .. result)
end)

test("codex: › prompt echo marker is stripped", function()
  local input = table.concat({
    "› 请帮我分析这个文件的结构，并给出一份详细的重构建议清单，谢谢",
    "",
    "• 好的，我先看一下这个文件的整体结构，然后按模块给出对应的重构建议，稍等。",
  }, "\n")
  local r = clean.classify(input)
  assert(r.mode ~= "none", "should clean, got none")
  local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
  assert(not result:find("›"), "› must be stripped, got:\n" .. result)
  assert(not result:find("•"), "• must be stripped")
  assert(result:find("请帮我分析"), "prompt text kept")
end)

test("codex: bullet + indented real code is NOT merged", function()
  local input = table.concat({
    "  - 下面这一段配置直接粘贴到你的初始化文件末尾就可以立即生效了",
    "    local ok = pcall(require, \"module\")",
  }, "\n")
  local r = clean.classify(input)
  if r.mode ~= "none" then
    local result = (r.mode == "full") and clean.clean(input) or clean.stripOnly(input)
    assert(result:find("\n"), "code line must stay separate, got:\n" .. result)
  end
end)

-- ═══════════════════════════════════════════════════════════════
-- 15. Box-drawn tables paste as CSV (real fixture: Claude Code
--     v2.1.309, cmux read-screen, 2026-10-23). Any fragment of a
--     table (whole, a few rows, starting mid-row) becomes CSV; prose
--     around it is still cleaned; gutter bars and tree output are not
--     tables.
-- ═══════════════════════════════════════════════════════════════

local boxTable = {
  "⏺ ┌────────────────────────────────────────────────────────────────────────────────┬───────┐",
  "  │                                      建议                                      │ 数量  │",
  "  ├────────────────────────────────────────────────────────────────────────────────┼───────┤",
  "  │ 删 Bright Data 相关 skill（其中 bright-data-mcp 还和你的 web-access 规则冲突） │ 12    │",
  "  ├────────────────────────────────────────────────────────────────────────────────┼───────┤",
  "  │ 删 copywriting、design-mirror                                                  │ 2     │",
  "  ├────────────────────────────────────────────────────────────────────────────────┼───────┤",
  "  │ 清理 sandbox 下的临时截图与缓存文件（放 /tmp 之外的历史产物）                  │ 1,200 │",
  "  ├────────────────────────────────────────────────────────────────────────────────┼───────┤",
  "  │ 保留 web-access、codebase-memory 等在用的 skill，不动                          │ 5     │",
  "  └────────────────────────────────────────────────────────────────────────────────┴───────┘",
}

test("table: whole table becomes CSV, comma cell quoted", function()
  eq(clean.process(table.concat(boxTable, "\n")), table.concat({
    "建议,数量",
    "删 Bright Data 相关 skill（其中 bright-data-mcp 还和你的 web-access 规则冲突）,12",
    "删 copywriting、design-mirror,2",
    "清理 sandbox 下的临时截图与缓存文件（放 /tmp 之外的历史产物）,\"1,200\"",
    "保留 web-access、codebase-memory 等在用的 skill，不动,5",
  }, "\n"))
end)

test("table: two rows with the separator between them", function()
  eq(clean.process(table.concat({ boxTable[4], boxTable[5], boxTable[6] }, "\n")), table.concat({
    "删 Bright Data 相关 skill（其中 bright-data-mcp 还和你的 web-access 规则冲突）,12",
    "删 copywriting、design-mirror,2",
  }, "\n"))
end)

test("table: single row", function()
  eq(clean.process(boxTable[6]), "删 copywriting、design-mirror,2")
end)

test("table: selection starting mid-row keeps the partial cell", function()
  local partial = boxTable[4]:gsub("^.-相关 ", "")
  eq(clean.process(table.concat({ partial, boxTable[5], boxTable[6] }, "\n")), table.concat({
    "skill（其中 bright-data-mcp 还和你的 web-access 规则冲突）,12",
    "删 copywriting、design-mirror,2",
  }, "\n"))
end)

test("table: partial first row is padded so columns line up", function()
  local input = table.concat({
    "b1 │ c1 │",
    "├────┼────┼────┤",
    "│ a2 │ b2 │ c2 │",
  }, "\n")
  eq(clean.tablesToCsv(input), ",b1,c1\na2,b2,c2")
end)

test("table: cell wrapped over two lines is joined per column", function()
  local input = table.concat({
    "┌──────────────┬──────┐",
    "│ install the  │ 安装 │",
    "│ package      │ 依赖 │",
    "├──────────────┼──────┤",
    "│ run tests    │ 测试 │",
    "└──────────────┴──────┘",
  }, "\n")
  eq(clean.tablesToCsv(input), "install the package,安装依赖\nrun tests,测试")
end)

test("table: quotes and commas are escaped", function()
  eq(clean.tablesToCsv('│ say "hi", ok │ 1 │'), '"say ""hi"", ok",1')
end)

test("table: prose around the table is still cleaned", function()
  local input = table.concat({
    "⏺ 下面是清单：",
    boxTable[1], boxTable[2], boxTable[3], boxTable[6], boxTable[11],
    "  以上。",
  }, "\n")
  eq(clean.process(input), "下面是清单：\n建议,数量\n删 copywriting、design-mirror,2\n以上。")
end)

test("table: one gutter bar is not a table", function()
  local input = "  │ Hello world\n  │ Second line"
  assert(not clean.process(input):find(",", 1, true), "gutter text must not become CSV")
end)

test("table: tree output is not a table", function()
  local input = table.concat({ "src", "│   │   └── clean.lua", "│   └── init.lua", "└── test.lua" }, "\n")
  eq(clean.tablesToCsv(input), input)
end)

test("table: record separator alone is not a table border", function()
  local input = "方案: A\n────────────────────────────────────────\n方案: B"
  eq(clean.tablesToCsv(input), input)
end)

-- Regression cases from an independent review (Codex, 2026-10-23).

test("table: a row inside code the scorer leaves alone is not converted", function()
  local input = "const banner = `\n│ left │ right │\n`;"
  eq(clean.process(input), input)
end)

test("table: cut-off first line of a wrapped row keeps its columns", function()
  local input = table.concat({
    "b1 │ c1 │",
    "│ a2 │ b2 │ c2 │",
    "├────┼────┼────┤",
    "│ a3 │ b3 │ c3 │",
  }, "\n")
  eq(clean.tablesToCsv(input), "a2,b1 b2,c1 c2\na3,b3,c3")
end)

test("table: a literal │ inside a cell is not a separator", function()
  local input = table.concat({
    "┌─────┬───┐",
    "│ txt │ n │",
    "├─────┼───┤",
    "│ a│b │ 1 │",
    "└─────┴───┘",
  }, "\n")
  eq(clean.tablesToCsv(input), "txt,n\na│b,1")
end)

test("table: a lone tree connector is not a table", function()
  local input = "src\n│   │   └── clean.lua\n│   └── init.lua\n└──"
  eq(clean.tablesToCsv(input), input)
end)

test("table: blank lines and relative indent around a table survive", function()
  local input = "⏺ Intro.\n\n  ┌───┬───┐\n  │ a │ b │\n  └───┴───┘\n\n    nested text"
  eq(clean.process(input), "Intro.\n\na,b\n\n  nested text")
end)

test("table: one-bar fragments at the table edges are padded", function()
  eq(clean.tablesToCsv("│ a1 │ b1 │ c1 │\n├────┼────┼────┤\n│ a2"), "a1,b1,c1\na2,,")
  eq(clean.tablesToCsv("c1 │\n├────┼────┼────┤\n│ a2 │ b2 │ c2 │"), ",,c1\na2,b2,c2")
end)

test("table: padding a very wide cut-off row stays fast", function()
  local n = 50000
  local input = "│" .. string.rep(" x │", n) .. "\ny │ z │"
  local started = os.clock()
  local out = clean.tablesToCsv(input)
  local elapsed = os.clock() - started
  eq(out, string.rep("x,", n - 1) .. "x\n" .. string.rep(",", n - 2) .. "y,z")
  assert(elapsed < 1, string.format("took %.2fs", elapsed))
end)

test("table: emoji cells (terminal width 2, counted as 1) still split", function()
  local input = table.concat({
    "  ┌──────┬────────┐",
    "  │ 状态 │ 说明   │",
    "  ├──────┼────────┤",
    "  │ ✅   │ 已完成 │",
    "  ├──────┼────────┤",
    "  │ 🚀   │ 已上线 │",
    "  └──────┴────────┘",
  }, "\n")
  eq(clean.process(input), "状态,说明\n✅,已完成\n🚀,已上线")
  eq(clean.tablesToCsv("│ ✅   │ 已完成 │\n├──────┼────────┤\n│ 🚀   │ 已上线 │"), "✅,已完成\n🚀,已上线")
end)

-- ═══════════════════════════════════════════════════════════════
-- Blockquotes: Claude Code renders "> text" as "▎ text" (U+258E,
-- one bar per nesting level) on every visual row. Real capture from
-- `cmux read-screen`, 2026-10-27 (Claude Code 2.1.311).
-- ═══════════════════════════════════════════════════════════════

local quoteCapture = {
  "  ▎ 查清楚了，是我们的 bug，不是你操作的问题。你出完两套写真后切到 AI 换装，那时生成次数刚好用完，弹出了充值框；从里面点「返回解锁」再解锁时，系统错把上一套写真当成要解锁的图，你那 1 ",
  "  ▎ 次就扣在写真上了，所以出来的是之前那张拿花的。已经修好。",
  "  ▎ 补偿已到账：取件码 SGKJJYJNY6 加了 5 次解锁，另外附带 10 次生成，刷新页面就能看到。",
  "  ▎ AI 换装我用你传的白 T 恤照片试了「休闲时尚」，效果如图，别的款式你可以自己再试。",
  "  ▎ 之前那套写真 4 张已经解锁了，在「我的作品」里能下载全部 4 张，不会再扣次数。",
}

test("quote: ▎ bars are stripped and wrapped quote rows rejoin", function()
  -- "1次": the terminal wrapped at the space after "1" and the copy
  -- trims trailing spaces, so the CJK join has nothing to restore.
  eq(clean.process(table.concat(quoteCapture, "\n")), table.concat({
    "查清楚了，是我们的 bug，不是你操作的问题。你出完两套写真后切到 AI 换装，那时生成次数刚好用完，弹出了充值框；从里面点「返回解锁」再解锁时，系统错把上一套写真当成要解锁的图，你那 1次就扣在写真上了，所以出来的是之前那张拿花的。已经修好。",
    "补偿已到账：取件码 SGKJJYJNY6 加了 5 次解锁，另外附带 10 次生成，刷新页面就能看到。",
    "AI 换装我用你传的白 T 恤照片试了「休闲时尚」，效果如图，别的款式你可以自己再试。",
    "之前那套写真 4 张已经解锁了，在「我的作品」里能下载全部 4 张，不会再扣次数。",
  }, "\n"))
end)

test("quote: mixed copy keeps the heading and list around the quote", function()
  local input = table.concat(quoteCapture, "\n") .. "\n\n  残留风险（这次没改）\n\n"
    .. "  - 付款查单有一个并发报错：两次查单同时进来时会报「数据库已关闭」，只让那一次查单失败，不影响到账。修法是两行代码。"
  local out = clean.process(input)
  assert(not out:find("▎", 1, true), "bar left in output:\n" .. out)
  assert(out:find("\n\n残留风险（这次没改）\n\n%- 付款查单"), "structure lost:\n" .. out)
end)

test("quote: nested ▎ ▎ bars are all stripped", function()
  eq(clean.process("  ▎ 外层引用的一句话。\n  ▎ ▎ 内层引用的一句话。"),
    "外层引用的一句话。\n内层引用的一句话。")
end)

-- What Claude Code's own copy-on-select puts on the clipboard for the
-- same rows (fullscreen TUI): margins already gone, the soft wrap
-- already rejoined ("1 次" keeps its space), the bars still there.
-- It scores as plain text, so only the bars may change.
test("quote: Claude's copy-on-select text loses only its ▎ bars", function()
  local copied = table.concat({
    "▎ 查清楚了，是我们的 bug，不是你操作的问题。你那 1 次就扣在写真上了，所以出来的是之前那张拿花的。已经修好。",
    "▎ 补偿已到账：取件码 SGKJJYJNY6 加了 5 次解锁，另外附带 10 次生成，刷新页面就能看到。",
    "",
    "残留风险（这次没改）",
    "▎ ▎ 嵌套的一句。",
  }, "\n")
  eq(clean.process(copied), table.concat({
    "查清楚了，是我们的 bug，不是你操作的问题。你那 1 次就扣在写真上了，所以出来的是之前那张拿花的。已经修好。",
    "补偿已到账：取件码 SGKJJYJNY6 加了 5 次解锁，另外附带 10 次生成，刷新页面就能看到。",
    "",
    "残留风险（这次没改）",
    "嵌套的一句。",
  }, "\n"))
end)

test("quote: plain text without leading bars stays byte-for-byte", function()
  for _, s in ipairs({ "进度 ▎▎▎ 30%\n下一行\n", "local x = 1\nreturn x", "a\r\nb" }) do
    eq(clean.process(s), s)
  end
end)

test("quote: a quote row never swallows the plain row after it", function()
  local wide = string.rep("引", 60)
  eq(clean.process("  ▎ " .. wide .. "\n  " .. string.rep("正", 30)),
    wide .. "\n" .. string.rep("正", 30))
end)

-- ═══════════════════════════════════════════════════════════════
-- Results
-- ═══════════════════════════════════════════════════════════════

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed > 0 and 1 or 0)
