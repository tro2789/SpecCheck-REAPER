-- @noindex
-- Dev helper: compile-check the shipped scripts without running them.
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
local out = {}
for _, f in ipairs({ "../speccheck_core.lua", "../Spec Check.lua" }) do
  local fn, err = loadfile(here .. f)
  out[#out + 1] = f .. ": " .. (fn and "ok" or err)
end
reaper.SetExtState("reaper_mcp_script_result", "last_result", table.concat(out, "\n"), false)
