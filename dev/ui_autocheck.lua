-- @noindex
-- Dev helper: open the Spec Check window and press Check once, so the UI
-- job path can be exercised through the REAPER MCP without a click.
-- REAPER takes media offline while inactive, so bring it online first.
reaper.Main_OnCommand(40101, 0)
SPECCHECK_DEV_AUTOCHECK = true
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
dofile(here .. "../Spec Check.lua")
