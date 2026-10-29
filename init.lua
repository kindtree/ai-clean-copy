-- ai-clean-copy: Auto-clean Claude Code / Codex CLI clipboard artifacts
-- https://github.com/kindtree/ai-clean-copy
-- Fork of: https://github.com/andersmyrmel/claude-copy
--
-- Intercepts Cmd+C in terminal apps, performs the real copy,
-- then conditionally cleans Claude TUI artifacts in the copied text.

local VERSION = "2026-10-29"

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
  -- Claude Code's fullscreen TUI answers ⌘C by copying its selection
  -- again, ~0.5s later: after copyTimeoutMs, and often after the user
  -- has switched to the app they paste into. Clipboard writes landing
  -- this soon after a terminal ⌘C still count as terminal copies.
  lateCopyWindowMs = 1500,
  -- A ⌘C repeating the copy Claude Code made on select within this
  -- long is the same copy again.
  appCopyRepeatMs = 30000,
}

-- Terminals whose own copy-on-select can write the system clipboard
-- (iTerm2 does by default). A clipboard write in front of them with no
-- ⌘C may be the terminal's native copy, soft wraps included as hard
-- line breaks, so it still gets the full clean.
local nativeCopyOnSelectApps = {
  ["iTerm2"] = true,
  ["WezTerm"] = true,
  ["Warp"] = true,
}

-- ═══════════════════════════════════════════════════════════════
-- Clipboard Interception
-- ═══════════════════════════════════════════════════════════════

local function isTerminalFocused()
  local app = hs.application.frontmostApplication()
  if not app then return false end
  return terminalApps[app:name()] == true
end

-- hs.timer.absoluteTime() (ns) after which a write no longer counts
-- as the late answer to a terminal ⌘C.
local lateCopyDeadline = 0

local function isTerminalCopy()
  return isTerminalFocused() or hs.timer.absoluteTime() < lateCopyDeadline
end

-- Claude Code's own copies (fullscreen TUI) come with their soft wraps
-- already rejoined, so clean.process must not reflow them. Copy-on-select
-- writes are theirs unless the terminal may copy on select itself; the
-- raw text is kept so the ⌘C repeating it is recognised too.
local lastAppCopy = { text = nil, at = 0 }
local ownWrite = nil

local function isNativeCopyOnSelectFront()
  local app = hs.application.frontmostApplication()
  return app ~= nil and nativeCopyOnSelectApps[app:name()] == true
end

local function repeatsAppCopy(content)
  return content ~= nil and content == lastAppCopy.text
    and hs.timer.absoluteTime() - lastAppCopy.at < config.appCopyRepeatMs * 1000000
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

local function cleanClipboard(content, appCopy)
  if type(content) ~= "string" then return end
  -- Claude TUI copies are conversation-sized; anything huge is a file
  -- dump. Skip cleaning rather than stall Hammerspoon's main thread.
  if #content > 512 * 1024 then return end
  local countAfterCopy = hs.pasteboard.changeCount()
  -- Box-drawn tables become CSV; everything else goes through the
  -- classify → clean / stripOnly path exactly as before.
  local cleaned = clean.process(content, { appCopy = appCopy })

  -- Never wipe the clipboard with an empty result (e.g. content that
  -- turned out to be pure TUI chrome).
  if cleaned == content or not cleaned:match("%S") then return end

  -- If something else wrote the clipboard while we were cleaning
  -- (clipboard managers, a second copy), don't clobber it.
  if hs.pasteboard.changeCount() ~= countAfterCopy then return end

  ownWrite = cleaned
  hs.pasteboard.setContents(cleaned)
end

local function handleTerminalCopy()
  local content = readClipboardAfterCopy()
  cleanClipboard(content, repeatsAppCopy(content))
end

copyInterceptor = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
  if copyInProgress then return false end
  if not isPlainCmdC(event) then return false end
  if not isTerminalFocused() then return false end

  copyInProgress = true
  lateCopyDeadline = hs.timer.absoluteTime() + config.lateCopyWindowMs * 1000000
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
-- the mouse is released. No ⌘C is involved. A ⌘C pressed after that
-- makes it copy the selection again (twice: natively and via OSC 52),
-- ~0.5s later, so the interceptor above comes back empty and the raw
-- text lands over the cleaned one — see config.lateCopyWindowMs.
-- Clean any clipboard write that lands while a terminal is in front
-- or in that window, as Claude Code's own copy (no reflow) unless the
-- terminal in front may copy on select itself. Our own setContents
-- comes back through here as well and is skipped, so it is never taken
-- for Claude Code's copy. A global, not a local: an unreferenced
-- watcher gets garbage collected and silently stops.
ClaudeCopyPasteboardWatcher = hs.pasteboard.watcher.new(function(content)
  if copyInProgress or not isTerminalCopy() then return end
  if content == ownWrite then return end
  local appCopy = not isNativeCopyOnSelectFront()
  if appCopy then lastAppCopy = { text = content, at = hs.timer.absoluteTime() } end
  local ok, err = pcall(cleanClipboard, content, appCopy)
  if not ok then
    hs.printf("claude-copy: copy-on-select cleaner failed: %s", tostring(err))
  end
end)

hs.printf("claude-copy: terminal Cmd+C + copy-on-select cleaner loaded (%s)", VERSION)
