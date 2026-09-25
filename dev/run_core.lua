-- @noindex
-- Dev runner: headless check of the entire project through speccheck_core,
-- driven via the REAPER MCP (script_run). Stores a text result in
-- ExtState SpecCheckDev/result and the MCP result slot; poll with
-- dev/read_result.lua for long runs.
local here = debug.getinfo(1, "S").source:match("^@(.*[\\/])")
local core = dofile(here .. "../speccheck_core.lua")

local function publish(s)
  reaper.SetExtState("SpecCheckDev", "result", s, false)
  reaper.SetExtState("reaper_mcp_script_result", "last_result", s, false)
end
publish("RUNNING")

-- REAPER takes media offline while inactive (offlineinact=1); the MCP
-- drives it while another app has focus, so bring media back first.
reaper.Main_OnCommand(40101, 0)

local KEYS_N = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_STARTPOS", "RENDER_ENDPOS",
  "RENDER_SRATE", "RENDER_CHANNELS", "RENDER_TAILFLAG", "RENDER_TAILMS", "RENDER_ADDTOPROJ",
  "RENDER_NORMALIZE", "RENDER_DITHER", "DIRTY" }
local KEYS_S = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT", "RENDER_FORMAT2" }
local function snapshot()
  local t = {}
  for _, k in ipairs(KEYS_N) do t[#t + 1] = k .. "=" .. reaper.GetSetProjectInfo(0, k, 0, false) end
  for _, k in ipairs(KEYS_S) do
    local _, v = reaper.GetSetProjectInfo_String(0, k, "", false); t[#t + 1] = k .. "=" .. v
  end
  return table.concat(t, "\n")
end

local before = snapshot()
local t0 = reaper.time_precise()
local ranges = core.list_ranges()
local job, err = core.check_range(ranges[1], { budget = 0.2 })
local tRender = reaper.time_precise() - t0
local after = snapshot()
if not job then publish("ERROR " .. tostring(err)); return end

-- Peek at the rendered WAV header before the pass consumes it.
local hdrInfo = ""
do
  local f = io.open(job.res.path, "rb")
  if f then
    local d = f:read(64); f:close()
    local tag = string.unpack("<I2", d, 21)
    local bits = string.unpack("<I2", d, 35)
    hdrInfo = string.format("wav fmt tag=%d bits=%d", tag, bits)
  end
end

local t1 = reaper.time_precise()
local function loop()
  local done = job:step()
  if not done then reaper.defer(loop); return end
  local r = job.res
  local out = {
    job.error and ("JOB ERROR " .. job.error) or "OK",
    string.format("render %.2fs, analysis %.2fs, %s", tRender, reaper.time_precise() - t1, hdrInfo),
    "settings restored: " .. tostring(before == after),
  }
  if before ~= after then out[#out + 1] = "BEFORE\n" .. before .. "\nAFTER\n" .. after end
  out[#out + 1] = string.format("lua cross-check: LUFS-I %.2f  S-max %.2f",
    r.lufsI_lua or 0 / 0, r.lufsSMax_lua or 0 / 0)
  out[#out + 1] = ""
  local presets = core.BUILTIN_PRESETS
  out[#out + 1] = core.report_text(r, presets[2]) -- Spotify
  os.remove(r.path)
  publish(table.concat(out, "\n"))
end
reaper.defer(loop)
