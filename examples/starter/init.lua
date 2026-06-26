-- Starter plugin for Vesta — a tour of the core API in one working file.
--
-- Try it: copy this `starter/` folder into ~/.config/vesta/plugins/ and reload
-- (vesta reload), or declare it from your init.lua: vesta.plugin("you/vesta-starter").
-- Everything below is real and runnable; delete what you don't want.

-- ── Commands + keybinds ─────────────────────────────────────────────────────
-- A command palette built with vesta.menu: each item carries its own action.
local function palette()
  vesta.menu({
    { text = "split pane", desc = "vertical split",      action = function() vesta.split() end },
    { text = "new tab",    desc = "new session",          action = function() vesta.tab("new") end },
    { text = "clear",      desc = "clear the screen",     action = function() vesta.send("clear\n") end },
    { text = "git status", desc = "run in this pane",      action = function() vesta.send("git status\n") end },
  })
end
vesta.command("palette", palette)          -- runnable as a Vesta command
vesta.bind("cmd+shift+p", palette)         -- and on a keybind

-- A prompt → run whatever you type; a confirm before something destructive.
vesta.command("run", function()
  vesta.prompt("command to run", "", function(text)
    if text ~= "" then vesta.send(text .. "\n") end
  end)
end)
vesta.command("reset", function()
  vesta.confirm("Reset this pane?", function(yes)
    if yes then vesta.send("clear && reset\n") end
  end)
end)

-- ── Events ──────────────────────────────────────────────────────────────────
-- React when the working directory changes (OSC 7): show it in the chrome.
vesta.on("dir-changed", function(paneID)
  local a = vesta.active()
  if a then vesta.status("» " .. a.cwd) end
end)

-- React to a shell exiting on its own.
vesta.on("session-exited", function(paneID)
  vesta.notify("a shell exited")
end)

-- React to raw terminal OUTPUT, from EVERY live pane (chunk is raw bytes).
-- Here: flag the word "error" as it scrolls by. Comment this out if it's noisy.
vesta.on("pane-output", function(paneID, chunk)
  if chunk:find("error", 1, true) then
    vesta.notify("saw 'error' in a pane")
  end
end)

-- ── A live panel ─────────────────────────────────────────────────────────────
-- A small bottom-right panel with a clock + cwd, refreshed on a timer. Passing
-- the previous id updates it in place instead of stacking new panels.
local panelId
vesta.timer(2, function()
  local a = vesta.active()
  panelId = vesta.panel({
    { text = os.date("%H:%M:%S"), color = "#7dcfff" },
    { text = a and a.cwd or "—",  color = "#9ece6a" },
    -- An editable field: type + Enter runs it in the active pane.
    { input = true, placeholder = "run…", action = function(t) vesta.send(t .. "\n") end },
  }, { title = "starter", corner = "bottomright", width = 240, id = panelId })
end)
