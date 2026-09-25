-- @description Spec Check: measure a mix against a delivery spec
-- @author Trevor O'Hare Productions
-- @version 0.2.0
-- @changelog
--   Window colors follow the active REAPER theme (and theme switches)
--   Labels in a regular font, measured values in monospace
-- @provides [nomain] speccheck_core.lua
-- @about
--   Renders the master mix (entire project, time selection or a region) to
--   a temp file, measures loudness, true peak, clipping, stereo correlation,
--   noise floor and silence, and scores it against a delivery preset
--   (Spotify, Apple Music, Amazon, YouTube, ACX, podcast specs, custom).
--   Requires ReaImGui.

local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
-- Running from a git checkout (dev) rather than a ReaPack install.
local IS_DEV = reaper.file_exists(here .. ".git/HEAD")
local core = dofile(here .. "speccheck_core.lua")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("Spec Check needs ReaImGui. Install it from ReaPack (ReaTeam Extensions).", "Spec Check", 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua"
local ImGui = require "imgui" "0.9.3"

local EXT = "SpecCheck"

local ctx = ImGui.CreateContext("Spec Check")
-- Labels in a regular face, measured values in monospace.
local FONT_UI = ImGui.CreateFont("sans-serif", 14)
-- The generic "monospace" family resolves to a thin face on Windows.
local os_name = reaper.GetOS()
local MONO = "monospace"
if os_name:match("^Win") then MONO = "Consolas"
elseif os_name:match("^OSX") or os_name:match("^macOS") then MONO = "Menlo" end
local FONT_NUM = ImGui.CreateFont(MONO, 14)
ImGui.Attach(ctx, FONT_UI)
ImGui.Attach(ctx, FONT_NUM)

---------------------------------------------------------------- theme

-- Colors follow the active REAPER theme so the window looks built in and
-- tracks theme switches. A few theme colors seed everything else; text is
-- pushed until it meets a contrast floor so unusual themes stay readable.
local COL_PASS, COL_FAIL, COL_DIM, BTN_PASS, BTN_FAIL, COL_ON_BTN
local THEME_COLS = {}
local themeAt = -1
local WHITE, BLACK = { 255, 255, 255 }, { 0, 0, 0 }

local STYLE_VARS = {
  { ImGui.StyleVar_WindowRounding, 0 },
  { ImGui.StyleVar_ChildRounding, 2 },
  { ImGui.StyleVar_FrameRounding, 2 },
  { ImGui.StyleVar_PopupRounding, 2 },
  { ImGui.StyleVar_GrabRounding, 2 },
  { ImGui.StyleVar_ScrollbarRounding, 2 },
  { ImGui.StyleVar_WindowBorderSize, 1 },
  { ImGui.StyleVar_WindowPadding, 10, 10 },
  { ImGui.StyleVar_FramePadding, 6, 4 },
  { ImGui.StyleVar_ItemSpacing, 6, 6 },
  { ImGui.StyleVar_CellPadding, 6, 3 },
}

local function theme_rgb(key, fallback)
  local c = reaper.GetThemeColor(key, 0)
  if not c or c == -1 then return fallback end
  local r, g, b = reaper.ColorFromNative(c)
  return { r, g, b }
end

local function mix(c, t, f)
  return { c[1] + (t[1] - c[1]) * f, c[2] + (t[2] - c[2]) * f, c[3] + (t[3] - c[3]) * f }
end

local function rgba(c, a)
  local function b(v) return math.max(0, math.min(255, math.floor(v + 0.5))) end
  return (b(c[1]) << 24) | (b(c[2]) << 16) | (b(c[3]) << 8) | b((a or 1) * 255)
end

-- WCAG relative luminance and contrast ratio.
local function luminance(c)
  local function ch(v)
    v = v / 255
    return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * ch(c[1]) + 0.7152 * ch(c[2]) + 0.0722 * ch(c[3])
end
local function contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end
local function readable(c, bg, ratio, toward)
  for _ = 1, 20 do
    if contrast(c, bg) >= ratio then break end
    c = mix(c, toward, 0.1)
  end
  return c
end

local function refresh_theme(force)
  local now = reaper.time_precise()
  if not force and now - themeAt < 1 then return end
  themeAt = now
  local bg = theme_rgb("col_main_bg2", { 51, 51, 51 })
  local dark = luminance(bg) < 0.18
  local up, down = dark and WHITE or BLACK, dark and BLACK or WHITE
  local textSrc = theme_rgb("col_main_text2", dark and { 200, 200, 200 } or { 40, 40, 40 })
  local text = readable(textSrc, bg, 7, up)
  local dim = readable(textSrc, bg, 3.5, up)
  local accent = readable(theme_rgb("col_toolbar_text_on", theme_rgb("genlist_selbg", { 26, 188, 152 })), bg, 3, up)
  local line = mix(bg, up, 0.14)

  if dark then
    COL_PASS, COL_FAIL = 0x5FBF77FF, 0xE0605EFF
    BTN_PASS, BTN_FAIL = 0x2E6B3CFF, 0x8A2F2EFF
  else
    COL_PASS, COL_FAIL = 0x2E7D45FF, 0xB3312FFF
    BTN_PASS, BTN_FAIL = 0x3E8E54FF, 0xC0443FFF
  end
  COL_ON_BTN = 0xFFFFFFFF
  COL_DIM = rgba(dim)

  THEME_COLS = {
    { ImGui.Col_WindowBg, rgba(bg) },
    { ImGui.Col_ChildBg, rgba(mix(bg, down, 0.12)) },
    { ImGui.Col_PopupBg, rgba(mix(bg, up, 0.04)) },
    { ImGui.Col_Text, rgba(text) },
    { ImGui.Col_TextDisabled, rgba(dim) },
    { ImGui.Col_Border, rgba(line) },
    { ImGui.Col_Separator, rgba(line) },
    { ImGui.Col_SeparatorHovered, rgba(accent, 0.6) },
    { ImGui.Col_SeparatorActive, rgba(accent) },
    { ImGui.Col_FrameBg, rgba(mix(bg, down, 0.22)) },
    { ImGui.Col_FrameBgHovered, rgba(mix(bg, down, 0.30)) },
    { ImGui.Col_FrameBgActive, rgba(mix(bg, down, 0.36)) },
    { ImGui.Col_TitleBg, rgba(mix(bg, down, 0.25)) },
    { ImGui.Col_TitleBgActive, rgba(mix(bg, down, 0.15)) },
    { ImGui.Col_TitleBgCollapsed, rgba(mix(bg, down, 0.25)) },
    { ImGui.Col_Button, rgba(mix(bg, up, 0.10)) },
    { ImGui.Col_ButtonHovered, rgba(mix(bg, up, 0.17)) },
    { ImGui.Col_ButtonActive, rgba(mix(bg, accent, 0.45)) },
    { ImGui.Col_Header, rgba(accent, 0.30) },
    { ImGui.Col_HeaderHovered, rgba(accent, 0.45) },
    { ImGui.Col_HeaderActive, rgba(accent, 0.60) },
    { ImGui.Col_CheckMark, rgba(accent) },
    { ImGui.Col_PlotHistogram, rgba(accent) },
    { ImGui.Col_TableHeaderBg, rgba(mix(bg, up, 0.06)) },
    { ImGui.Col_TableRowBg, rgba(bg, 0) },
    { ImGui.Col_TableRowBgAlt, rgba(mix(bg, up, 0.03)) },
    { ImGui.Col_TableBorderLight, rgba(mix(bg, up, 0.08)) },
    { ImGui.Col_TableBorderStrong, rgba(line) },
    { ImGui.Col_ScrollbarBg, rgba(bg, 0) },
    { ImGui.Col_ScrollbarGrab, rgba(mix(bg, up, 0.20)) },
    { ImGui.Col_ScrollbarGrabHovered, rgba(mix(bg, up, 0.28)) },
    { ImGui.Col_ScrollbarGrabActive, rgba(accent) },
    { ImGui.Col_ResizeGrip, rgba(accent, 0.20) },
    { ImGui.Col_ResizeGripHovered, rgba(accent, 0.50) },
    { ImGui.Col_ResizeGripActive, rgba(accent, 0.80) },
    { ImGui.Col_TextSelectedBg, rgba(accent, 0.35) },
    { ImGui.Col_NavHighlight, rgba(accent) },
    { ImGui.Col_ModalWindowDimBg, rgba(BLACK, 0.35) },
    { ImGui.Col_DockingEmptyBg, rgba(bg) },
  }
end

local function push_theme()
  for _, c in ipairs(THEME_COLS) do ImGui.PushStyleColor(ctx, c[1], c[2]) end
  for _, v in ipairs(STYLE_VARS) do ImGui.PushStyleVar(ctx, v[1], v[2], v[3]) end
end

local function pop_theme()
  ImGui.PopStyleVar(ctx, #STYLE_VARS)
  ImGui.PopStyleColor(ctx, #THEME_COLS)
end

---------------------------------------------------------------- state

local S = {
  presets = {},
  presetIdx = 1,
  ranges = {},
  rangeIdx = 1,
  rangesAt = 0,
  results = {},     -- newest last
  resultIdx = 0,
  showAll = reaper.GetExtState(EXT, "show_all") ~= "0",
  queue = nil,      -- pending ranges for a batch
  job = nil,
  status = "",
  statusBad = false,
  editor = nil,     -- preset being edited
  dock = nil,       -- pending dock id
}

local function set_status(s, bad) S.status, S.statusBad = s, bad or false end

local function reload_presets(selectName)
  S.presets = {}
  for _, p in ipairs(core.BUILTIN_PRESETS) do S.presets[#S.presets + 1] = p end
  for _, p in ipairs(core.load_custom()) do S.presets[#S.presets + 1] = p end
  selectName = selectName or reaper.GetExtState(EXT, "preset")
  S.presetIdx = 1
  for i, p in ipairs(S.presets) do if p.name == selectName then S.presetIdx = i end end
end

local function refresh_ranges(force)
  local now = reaper.time_precise()
  if not force and now - S.rangesAt < 1 then return end
  S.rangesAt = now
  local prev = S.ranges[S.rangeIdx]
  S.ranges = core.list_ranges()
  local regions = 0
  for _, r in ipairs(S.ranges) do if r.kind == "region" then regions = regions + 1 end end
  if regions > 1 then S.ranges[#S.ranges + 1] = { kind = "allregions", label = "All regions, one by one" } end
  local want = prev and prev.label or reaper.GetExtState(EXT, "range")
  local wantKind = prev and prev.kind
  S.rangeIdx = 1
  for i, r in ipairs(S.ranges) do
    if r.label == want then S.rangeIdx = i; break end
    if wantKind and r.kind == wantKind and (r.kind == "timesel" or r.kind == "project") then S.rangeIdx = i end
  end
end

local function current_preset() return S.presets[S.presetIdx] end
local function current_result() return S.results[S.resultIdx] end

---------------------------------------------------------------- jobs

local function start_next()
  local range = table.remove(S.queue, 1)
  if not range then S.queue = nil; return end
  set_status("Rendering " .. range.label .. " ...")
  local job, err = core.check_range(range, {})
  if not job then
    set_status(err, true)
    S.queue = nil
    return
  end
  S.job = job
end

local function start_check()
  if S.job then return end
  refresh_ranges(true)
  local r = S.ranges[S.rangeIdx]
  if not r then return end
  S.queue = {}
  if r.kind == "allregions" then
    for _, x in ipairs(S.ranges) do if x.kind == "region" then S.queue[#S.queue + 1] = x end end
  else
    S.queue[1] = r
  end
  start_next()
end

local function pump_job()
  if not S.job then return end
  local done = S.job:step()
  if not done then return end
  local job = S.job
  S.job = nil
  os.remove(job.res.path)
  if job.error then
    set_status(job.error, true)
    S.queue = nil
    return
  end
  S.results[#S.results + 1] = job.res
  S.resultIdx = #S.results
  set_status(string.format("Checked %s in %s", job.res.label, core.fmt_time(job.res.duration)))
  if S.queue and #S.queue > 0 then start_next() else S.queue = nil end
end

---------------------------------------------------------------- actions

local function jump_to(t)
  reaper.SetEditCurPos(t, true, false)
end

-- One marker per clip spot; spots closer than 1 s fold into the first
-- marker's name instead of stacking markers on top of each other.
local function add_clip_markers(res)
  local ev = res.clipEvents or {}
  if #ev == 0 then return end
  reaper.Undo_BeginBlock()
  local groups = {}
  for _, e in ipairs(ev) do
    local g = groups[#groups]
    if g and e.t - g.last < 1 then
      g.n, g.last = g.n + e.n, e.t
      if e.peak > g.peak then g.peak = e.peak end
    else
      groups[#groups + 1] = { t = e.t, last = e.t, n = e.n, peak = e.peak }
    end
  end
  for _, g in ipairs(groups) do
    local name = string.format("Clip %+.2f dBFS (%d sample%s)", 20 * math.log(g.peak, 10), g.n, g.n == 1 and "" or "s")
    reaper.AddProjectMarker2(0, false, (res.rangeStart or 0) + g.t, 0, name, -1, 0)
  end
  reaper.Undo_EndBlock("Spec Check: add clip markers", -1)
  set_status(string.format("Added %d clip marker%s", #groups, #groups == 1 and "" or "s"))
end

local function save_report(res)
  local preset = current_preset()
  local projPath = reaper.GetProjectPath("")
  local _, projName = reaper.GetSetProjectInfo_String(0, "PROJECT_NAME", "", false)
  local base = (projName ~= "" and projName:gsub("%.[Rr][Pp][Pp]$", "") or "Mix")
  local fname = string.format("%s - %s.qc.txt", base, (res.label or "mix"):gsub("[\\/:*?\"<>|]", "-"))
  local path = projPath .. "/" .. fname
  if reaper.JS_Dialog_BrowseForSaveFile then
    local rv, p = reaper.JS_Dialog_BrowseForSaveFile("Save Spec Check report", projPath, fname, "Text files (*.txt)\0*.txt\0\0")
    if rv ~= 1 then return end
    path = p
  end
  local f = io.open(path, "w")
  if not f then set_status("Cannot write " .. path, true); return end
  f:write(core.report_text(res, preset))
  f:close()
  set_status("Saved " .. path)
end

---------------------------------------------------------------- preset editor

local function open_editor(p)
  local copy = { name = p.name, checks = {}, isNew = p.group ~= "Custom", orig = p.group == "Custom" and p.name or nil }
  if p.group ~= "Custom" then copy.name = p.name .. " (custom)" end
  for _, c in ipairs(p.checks) do
    if not c.when then -- conditional checks are built-in only
      copy.checks[#copy.checks + 1] = { m = c.m,
        min = c.min and tostring(c.min) or "", max = c.max and tostring(c.max) or "" }
    end
  end
  S.editor = copy
  ImGui.OpenPopup(ctx, "Edit preset")
end

local function draw_editor()
  if not S.editor then return end
  ImGui.SetNextWindowSize(ctx, 460, 0, ImGui.Cond_Appearing)
  if not ImGui.BeginPopupModal(ctx, "Edit preset", nil, ImGui.WindowFlags_AlwaysAutoResize) then return end
  local e = S.editor
  local rv
  ImGui.SetNextItemWidth(ctx, 300)
  rv, e.name = ImGui.InputText(ctx, "Name", e.name)
  ImGui.Spacing(ctx)
  ImGui.TextDisabled(ctx, "Leave min or max empty for no limit.")
  local remove
  if ImGui.BeginTable(ctx, "checks", 4, ImGui.TableFlags_SizingFixedFit) then
    ImGui.TableSetupColumn(ctx, "Metric")
    ImGui.TableSetupColumn(ctx, "Min")
    ImGui.TableSetupColumn(ctx, "Max")
    ImGui.TableSetupColumn(ctx, "")
    ImGui.TableHeadersRow(ctx)
    for i, c in ipairs(e.checks) do
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, 190)
      local d = core.METRIC_BY_KEY[c.m]
      if ImGui.BeginCombo(ctx, "##m", d and d.label or c.m) then
        for _, md in ipairs(core.METRICS) do
          if ImGui.Selectable(ctx, md.label, md.key == c.m) then c.m = md.key end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, 70)
      rv, c.min = ImGui.InputText(ctx, "##min", c.min)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, 70)
      rv, c.max = ImGui.InputText(ctx, "##max", c.max)
      ImGui.TableNextColumn(ctx)
      if ImGui.SmallButton(ctx, "x") then remove = i end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(e.checks, remove) end
  if ImGui.SmallButton(ctx, "+ Add check") then e.checks[#e.checks + 1] = { m = "lufsI", min = "", max = "" } end
  ImGui.Separator(ctx)

  local name = e.name:gsub("^%s+", ""):gsub("%s+$", "")
  local clash = false
  for _, p in ipairs(core.BUILTIN_PRESETS) do if p.name == name then clash = true end end
  if clash then ImGui.TextColored(ctx, COL_FAIL, "A built-in preset already has that name.") end
  ImGui.BeginDisabled(ctx, name == "" or clash)
  if ImGui.Button(ctx, "Save", 90, 0) then
    local list = core.load_custom()
    local p = { name = name, group = "Custom", checks = {} }
    for _, c in ipairs(e.checks) do
      p.checks[#p.checks + 1] = { m = c.m, min = tonumber(c.min), max = tonumber(c.max) }
    end
    local replaced = false
    for i, q in ipairs(list) do
      if q.name == (e.orig or name) or q.name == name then list[i] = p; replaced = true; break end
    end
    if not replaced then list[#list + 1] = p end
    core.save_custom(list)
    reload_presets(name)
    reaper.SetExtState(EXT, "preset", name, true)
    S.editor = nil
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.EndDisabled(ctx)
  ImGui.SameLine(ctx)
  if e.orig then
    if ImGui.Button(ctx, "Delete", 90, 0) then
      local list = core.load_custom()
      for i, q in ipairs(list) do if q.name == e.orig then table.remove(list, i); break end end
      core.save_custom(list)
      reload_presets()
      S.editor = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SameLine(ctx)
  end
  if ImGui.Button(ctx, "Cancel", 90, 0) then
    S.editor = nil
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.EndPopup(ctx)
end

---------------------------------------------------------------- drawing

local function draw_controls()
  local busy = S.job ~= nil or S.queue ~= nil
  local labelW = 52
  -- Preset
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Preset")
  ImGui.SameLine(ctx, labelW)
  local p = current_preset()
  ImGui.SetNextItemWidth(ctx, -70)
  if ImGui.BeginCombo(ctx, "##preset", p and p.name or "") then
    local group
    for i, q in ipairs(S.presets) do
      if q.group ~= group then
        group = q.group
        ImGui.SeparatorText(ctx, group)
      end
      if ImGui.Selectable(ctx, q.name, i == S.presetIdx) then
        S.presetIdx = i
        reaper.SetExtState(EXT, "preset", q.name, true)
      end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Edit...", -1, 0) and p then open_editor(p) end

  -- Range
  refresh_ranges(false)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, "Range")
  ImGui.SameLine(ctx, labelW)
  local r = S.ranges[S.rangeIdx]
  ImGui.SetNextItemWidth(ctx, -70)
  if ImGui.BeginCombo(ctx, "##range", r and r.label or "") then
    for i, x in ipairs(S.ranges) do
      if ImGui.Selectable(ctx, x.label, i == S.rangeIdx) then
        S.rangeIdx = i
        reaper.SetExtState(EXT, "range", x.label, true)
      end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SameLine(ctx)
  ImGui.BeginDisabled(ctx, busy)
  if ImGui.Button(ctx, "Check", -1, 0) then S.wantCheck = true end
  ImGui.EndDisabled(ctx)

  if S.job then
    local label = S.job.status .. (S.queue and #S.queue > 0 and string.format("  (%d more)", #S.queue) or "")
    ImGui.ProgressBar(ctx, S.job.progress or 0, -1, 0, label)
  end
end

local function draw_verdict(res, sum)
  local text, col
  if sum.total == 0 then
    text, col = "No checks in this preset", nil
  elseif sum.fail == 0 then
    text, col = string.format("PASS   %d of %d checks", sum.pass, sum.total), BTN_PASS
  else
    text, col = string.format("FAIL   %d of %d checks fail", sum.fail, sum.total), BTN_FAIL
  end
  if col then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, col)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, col)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, col)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, COL_ON_BTN)
  end
  ImGui.Button(ctx, text, -1, 30)
  if col then ImGui.PopStyleColor(ctx, 4) end
end

local function value_extra(res, key)
  if key == "noiseFloor" and res.noiseFloor then
    return res.noiseFloorExact and "roomtone region" or "quietest 0.5 s"
  end
end

local function draw_table(res, rows)
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_SizingStretchProp
  if not ImGui.BeginTable(ctx, "metrics", 4, flags) then return end
  ImGui.TableSetupColumn(ctx, "", ImGui.TableColumnFlags_WidthFixed, 22)
  ImGui.TableSetupColumn(ctx, "Measurement", ImGui.TableColumnFlags_WidthStretch, 1.6)
  ImGui.TableSetupColumn(ctx, "Value", ImGui.TableColumnFlags_WidthStretch, 1.0)
  ImGui.TableSetupColumn(ctx, "Target", ImGui.TableColumnFlags_WidthStretch, 1.4)
  ImGui.TableHeadersRow(ctx)
  local checked = {}
  for _, row in ipairs(rows) do
    checked[row.m] = true
    local d = core.METRIC_BY_KEY[row.m]
    ImGui.TableNextRow(ctx)
    local col = row.status == "pass" and COL_PASS or row.status == "fail" and COL_FAIL or COL_DIM
    ImGui.TableNextColumn(ctx)
    ImGui.TextColored(ctx, col, row.status == "pass" and "OK" or row.status == "fail" and "X" or "-")
    ImGui.TableNextColumn(ctx)
    ImGui.TextColored(ctx, col, d and d.label or row.m)
    ImGui.TableNextColumn(ctx)
    ImGui.PushFont(ctx, FONT_NUM)
    ImGui.TextColored(ctx, col, core.fmt_value(row.m, row.value) .. " " .. (d and d.unit or ""))
    ImGui.PopFont(ctx)
    ImGui.TableNextColumn(ctx)
    if row.status == "skip" then
      ImGui.TextDisabled(ctx, core.target_text(row.check) .. " (n/a)")
    else
      ImGui.Text(ctx, core.target_text(row.check))
    end
  end
  if S.showAll then
    for _, d in ipairs(core.METRICS) do
      if not checked[d.key] then
        ImGui.TableNextRow(ctx)
        ImGui.TableNextColumn(ctx)
        ImGui.TableNextColumn(ctx)
        ImGui.TextDisabled(ctx, d.label)
        ImGui.TableNextColumn(ctx)
        ImGui.PushFont(ctx, FONT_NUM)
        ImGui.Text(ctx, core.fmt_value(d.key, res[d.key]) .. " " .. d.unit)
        ImGui.PopFont(ctx)
        ImGui.TableNextColumn(ctx)
        local extra = value_extra(res, d.key)
        if d.key == "corrMin" and res.corrMinAt then
          if ImGui.SmallButton(ctx, "at " .. core.fmt_time((res.rangeStart or 0) + res.corrMinAt)) then
            jump_to((res.rangeStart or 0) + res.corrMinAt)
          end
        elseif extra then
          ImGui.TextDisabled(ctx, extra)
        end
      end
    end
  end
  ImGui.EndTable(ctx)
end

local function draw_platforms(res)
  local pr = core.platform_rows(res)
  if #pr == 0 then return end
  ImGui.SeparatorText(ctx, "Streaming playback")
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingStretchProp
  if not ImGui.BeginTable(ctx, "platforms", 3, flags) then return end
  for _, p in ipairs(pr) do
    ImGui.TableNextRow(ctx)
    ImGui.TableNextColumn(ctx); ImGui.Text(ctx, p.name)
    ImGui.PushFont(ctx, FONT_NUM)
    ImGui.TableNextColumn(ctx); ImGui.TextDisabled(ctx, string.format("%d LUFS", p.target))
    ImGui.TableNextColumn(ctx); ImGui.Text(ctx, p.text)
    ImGui.PopFont(ctx)
  end
  ImGui.EndTable(ctx)
end

local function draw_clips(res)
  local ev = res.clipEvents or {}
  if #ev == 0 then return end
  ImGui.SeparatorText(ctx, string.format("Clipping: %d sample%s in %d spot%s",
    res.clipCount, res.clipCount == 1 and "" or "s", #ev, #ev == 1 and "" or "s"))
  local h = math.min(#ev, 6) * ImGui.GetTextLineHeightWithSpacing(ctx) + 8
  if ImGui.BeginChild(ctx, "clips", -1, h, ImGui.ChildFlags_Border) then
    ImGui.PushFont(ctx, FONT_NUM)
    for i, e in ipairs(ev) do
      local t = (res.rangeStart or 0) + e.t
      local label = string.format("%-9s %+.2f dBFS   %d sample%s##c%d", core.fmt_time(t),
        20 * math.log(e.peak, 10), e.n, e.n == 1 and "" or "s", i)
      if ImGui.Selectable(ctx, label, false) then jump_to(t) end
    end
    ImGui.PopFont(ctx)
    ImGui.EndChild(ctx)
  end
  if ImGui.Button(ctx, "Add clip markers") then add_clip_markers(res) end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "One project marker per clip spot (spots under 1 s apart share a marker). Undoable.")
  end
end

local function draw_results()
  local res = current_result()
  if not res then
    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, COL_DIM)
    ImGui.TextWrapped(ctx, "Pick a range and press Check. The master mix is rendered to a temp file "
      .. "and measured; your render settings are restored afterwards.")
    ImGui.PopStyleColor(ctx)
    return
  end
  if #S.results > 1 then
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, "Result")
    ImGui.SameLine(ctx, 52)
    ImGui.SetNextItemWidth(ctx, -1)
    if ImGui.BeginCombo(ctx, "##result", string.format("%s  (%s)", res.label, res.when)) then
      for i = #S.results, 1, -1 do
        local r = S.results[i]
        if ImGui.Selectable(ctx, string.format("%s  (%s)##r%d", r.label, r.when, i), i == S.resultIdx) then
          S.resultIdx = i
        end
      end
      ImGui.EndCombo(ctx)
    end
  else
    ImGui.TextDisabled(ctx, string.format("%s  (%s)", res.label, res.when))
  end
  local rows, sum = core.score(res, current_preset())
  draw_verdict(res, sum)
  draw_table(res, rows)
  local rv
  rv, S.showAll = ImGui.Checkbox(ctx, "Show all measurements", S.showAll)
  if rv then reaper.SetExtState(EXT, "show_all", S.showAll and "1" or "0", true) end
  draw_platforms(res)
  draw_clips(res)
  ImGui.Separator(ctx)
  if ImGui.Button(ctx, "Save report...") then save_report(res) end
end

local function draw_context_menu()
  if ImGui.BeginPopupContextWindow(ctx) then
    local docked = ImGui.IsWindowDocked(ctx)
    if ImGui.MenuItem(ctx, docked and "Undock" or "Dock in REAPER docker") then
      S.dock = docked and 0 or -1
    end
    if ImGui.MenuItem(ctx, "Clear results", nil, false, #S.results > 0) then
      S.results, S.resultIdx = {}, 0
    end
    ImGui.EndPopup(ctx)
  end
end

local function loop()
  -- Renders block inside REAPER's modal render window, so start them
  -- outside the ImGui frame.
  if S.wantCheck then
    S.wantCheck = false
    start_check()
  end
  pump_job()
  if S.dock then
    ImGui.SetNextWindowDockID(ctx, S.dock)
    S.dock = nil
  end
  refresh_theme(false)
  ImGui.PushFont(ctx, FONT_UI)
  push_theme()
  ImGui.SetNextWindowSize(ctx, 460, 800, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, IS_DEV and "Spec Check (dev)" or "Spec Check", true,
    ImGui.WindowFlags_NoCollapse)
  if visible then
    draw_controls()
    ImGui.Spacing(ctx)
    draw_results()
    if S.status ~= "" then
      ImGui.Spacing(ctx)
      if S.statusBad then ImGui.TextColored(ctx, COL_FAIL, S.status) else ImGui.TextDisabled(ctx, S.status) end
    end
    draw_context_menu()
    draw_editor()
    ImGui.End(ctx)
  end
  pop_theme()
  ImGui.PopFont(ctx)
  if open then reaper.defer(loop) end
end

reload_presets()
refresh_ranges(true)
if SPECCHECK_DEV_AUTOCHECK then S.wantCheck = true end -- set by dev/ui_autocheck.lua
reaper.defer(loop)
