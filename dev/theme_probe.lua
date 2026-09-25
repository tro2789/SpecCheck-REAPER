-- @noindex
-- Dev helper: print the active theme's colors for the keys Spec Check
-- maps, and check that ReaImGui can build the fonts it uses.
local keys = { "col_main_bg2", "col_main_text2", "col_main_bg", "col_main_text", "col_main_editbk",
  "col_main_3dhl", "col_main_3dsh", "col_buttonbg", "genlist_bg", "genlist_fg", "genlist_grid",
  "genlist_selbg", "genlist_selfg", "genlist_hilite", "col_tl_bgsel", "col_cursor",
  "col_toolbar_text_on", "toolbararmed_color", "col_arrangebg", "col_tr1_bg", "col_seltrack" }
local out = { "theme=" .. reaper.GetLastColorThemeFile() }
for _, k in ipairs(keys) do
  local c = reaper.GetThemeColor(k, 0)
  if c == -1 then out[#out + 1] = k .. " = (none)"
  else
    local r, g, b = reaper.ColorFromNative(c)
    out[#out + 1] = string.format("%-22s #%02X%02X%02X", k, r, g, b)
  end
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua"
local ImGui = require "imgui" "0.9.3"
local ok, err = pcall(function()
  local ctx = ImGui.CreateContext("probe")
  local f1 = ImGui.CreateFont("sans-serif", 14)
  local f2 = ImGui.CreateFont("monospace", 13)
  ImGui.Attach(ctx, f1); ImGui.Attach(ctx, f2)
end)
out[#out + 1] = "fonts: " .. (ok and "ok" or tostring(err))
reaper.SetExtState("reaper_mcp_script_result", "last_result", table.concat(out, "\n"), false)
