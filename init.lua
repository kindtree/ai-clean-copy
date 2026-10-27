-- ai-clean-copy: Auto-clean Claude Code / Codex CLI clipboard artifacts
-- https://github.com/kindtree/ai-clean-copy
-- Fork of: https://github.com/andersmyrmel/claude-copy
--
-- Intercepts Cmd+C in terminal apps, performs the real copy,
-- then conditionally cleans Claude TUI artifacts in the copied text.

local VERSION = "2026-10-27"

local scriptDir = debug.getinfo(1, "S").source:match("@(.*/)")
local clean = dofile(scriptDir .. "clean.lua")

-- ═══════════════════════════════════════════════════════════════
-- Configuration
-- ═══════════════════════════════════════════════════════════════

local terminalApps = {
  ["Ghostty"] = true,
  ["iTerm2"] = true,
  ["Terminal"] = true,
  ["Alacritty"] = true,
  ["kitty"] = true,
  ["WezTerm"] = true,
  ["Hyper"] = true,
  ["Warp"] = true,
  ["Rio"] = true,
  ["Tabby"] = true,
  ["Wave"] = true,
  -- Claude Code hosts beyond plain terminal emulators:
  -- cmux (multi-session agent manager) and the Claude desktop app
  -- both embed the same TUI with the same clipboard artifacts.
  ["cmux"] = true,
  ["Claude"] = true,
}

local config = {
  copyTimeoutMs = 350,
  copyPollIntervalMs = 10,
}

-- ═══════════════════════════════════════════════════════════════
-- Clipboard Interception
-- ═══════════════════════════════════════════════════════════════

local function isTerminalFocused()
  local app = hs.application.frontmostApplication()
  if not app then return false end
  return terminalApps[app:name()] == true
end

local copyInterceptor
local copyInProgress = false

local function triggerRawCopy()
  if copyInterceptor then copyInterceptor:stop() end
  local ok, err = pcall(function()
    hs.eventtap.keyStroke({ "cmd" }, "c", 0)
  end)
  if copyInterceptor then copyInterceptor:start() end

  if not ok then
    hs.printf("claude-copy: failed to send Cmd+C: %s", tostring(err))
    return false
  end
  return true
end

local function readClipboardAfterCopy()
  local startCount = hs.pasteboard.changeCount()
  if not triggerRawCopy() then return nil end

  local waited = 0
  while waited < config.copyTimeoutMs do
    if hs.pasteboard.changeCount() ~= startCount then
      return hs.pasteboard.getContents()
    end
    hs.timer.usleep(config.copyPollIntervalMs * 1000)
    waited = waited + config.copyPollIntervalMs
  end
  return nil
end

local function isPlainCmdC(event)
  if event:getKeyCode() ~= hs.keycodes.map.c then return false end
  local flags = event:getFlags()
  return flags.cmd
    and not flags.shift
    and not flags.alt
    and not flags.ctrl
    and not flags.fn
end

local function cleanClipboard(content)
  if type(content) ~= "string" then return end
  -- Claude TUI copies are conversation-sized; anything huge is a file
  -- dump. Skip cleaning rather than stall Hammerspoon's main thread.
  if #content > 512 * 1024 then return end
  local countAfterCopy = hs.pasteboard.changeCount()
  -- Box-drawn tables become CSV; everything else goes through the
  -- classify → clean / stripOnly path exactly as before.
  local cleaned = clean.process(content)

  -- Never wipe the clipboard with an empty result (e.g. content that
  -- turned out to be pure TUI chrome).
  if cleaned == content or not cleaned:match("%S") then return end

  -- If something else wrote the clipboard while we were cleaning
  -- (clipboard managers, a second copy), don't clobber it.
  if hs.pasteboard.changeCount() ~= countAfterCopy then return end

  hs.pasteboard.setContents(cleaned)
end

local function handleTerminalCopy()
  cleanClipboard(readClipboardAfterCopy())
end

copyInterceptor = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
  if copyInProgress then return false end
  if not isPlainCmdC(event) then return false end
  if not isTerminalFocused() then return false end

  copyInProgress = true
  hs.timer.doAfter(0, function()
    local ok, err = pcall(handleTerminalCopy)
    if not ok then
      hs.printf("claude-copy: copy handler failed: %s", tostring(err))
    end
    copyInProgress = false
  end)

  return true
end)

copyInterceptor:start()

-- ═══════════════════════════════════════════════════════════════
-- Copy-on-select
-- ═══════════════════════════════════════════════════════════════
-- Claude Code's fullscreen TUI handles mouse selection itself and,
-- with copyOnSelect (on by default), writes the clipboard the moment
-- the mouse is released. No ⌘C is involved — and a ⌘C pressed after
-- that changes nothing, so the interceptor above comes back empty.
-- Clean any clipboard write that lands while a terminal is in front.
-- Our own setContents comes back through here as well; process() is
-- a no-op on text it already cleaned, so nothing is written twice.
-- A global, not a local: an unreferenced watcher gets garbage
-- collected and silently stops.
ClaudeCopyPasteboardWatcher = hs.pasteboard.watcher.new(function(content)
  if copyInProgress or not isTerminalFocused() then return end
  local ok, err = pcall(cleanClipboard, content)
  if not ok then
    hs.printf("claude-copy: copy-on-select cleaner failed: %s", tostring(err))
  end
end)

hs.printf("claude-copy: terminal Cmd+C + copy-on-select cleaner loaded (%s)", VERSION)
