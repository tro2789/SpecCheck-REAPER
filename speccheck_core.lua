-- @noindex
-- Spec Check for REAPER: render / measure / score engine. No UI here, so
-- the dev runner can drive it headless.
--
-- Model (same as the Premiere panel): every analysis computes the FULL
-- metric set; a preset is only a checklist of {m, min?, max?} over those
-- metrics, so switching presets re-scores instantly with no re-analysis.
--
-- Measurement path: render the master mix to a temp 32-bit float WAV
-- (user's render settings saved and restored around it), then
--   * REAPER's CalculateNormalization for LUFS-I, true peak, LUFS-S/M max
--     (native BS.1770 code, independent of the render-stats preferences),
--   * one Lua pass over the samples for everything else (LRA, sample
--     peak, clips, RMS, correlation, DC, noise floor, head/tail silence).

local M = {}
M.VERSION = "0.2.0"

local sunpack, srep, floor, sqrt, log = string.unpack, string.rep, math.floor, math.sqrt, math.log
local NEG_INF = -math.huge

local function db20(x) return x > 0 and 20 * log(x, 10) or NEG_INF end
local function db10(x) return x > 0 and 10 * log(x, 10) or NEG_INF end
local function lufs(ms) return ms > 0 and -0.691 + 10 * log(ms, 10) or NEG_INF end

---------------------------------------------------------------- metrics

M.METRICS = {
  { key = "lufsI",        label = "Integrated loudness",  unit = "LUFS", fmt = "%.1f" },
  { key = "lufsSMax",     label = "Short-term max",       unit = "LUFS", fmt = "%.1f" },
  { key = "lufsMMax",     label = "Momentary max",        unit = "LUFS", fmt = "%.1f" },
  { key = "lra",          label = "Loudness range",       unit = "LU",   fmt = "%.1f" },
  { key = "truePeak",     label = "True peak",            unit = "dBTP", fmt = "%.2f" },
  { key = "samplePeakDb", label = "Sample peak",          unit = "dBFS", fmt = "%.2f" },
  { key = "clipCount",    label = "Clipped samples",      unit = "",     fmt = "%d" },
  { key = "plr",          label = "Peak to loudness",     unit = "dB",   fmt = "%.1f" },
  { key = "rmsDb",        label = "Overall RMS",          unit = "dB",   fmt = "%.1f" },
  { key = "correlation",  label = "Stereo correlation",   unit = "",     fmt = "%.2f" },
  { key = "corrMin",      label = "Min correlation (1 s)", unit = "",    fmt = "%.2f" },
  { key = "dcOffsetDb",   label = "DC offset",            unit = "dB",   fmt = "%.0f" },
  { key = "noiseFloor",   label = "Noise floor",          unit = "dB",   fmt = "%.1f" },
  { key = "headSilence",  label = "Head silence",         unit = "s",    fmt = "%.2f" },
  { key = "tailSilence",  label = "Tail silence",         unit = "s",    fmt = "%.2f" },
  { key = "sampleRateHz", label = "Sample rate",          unit = "Hz",   fmt = "%d" },
  { key = "channels",     label = "Channels",             unit = "",     fmt = "%d" },
  { key = "duration",     label = "Duration",             unit = "",     time = true },
}
M.METRIC_BY_KEY = {}
for _, d in ipairs(M.METRICS) do M.METRIC_BY_KEY[d.key] = d end

function M.fmt_time(s)
  if not s then return "-" end
  local m = floor(s / 60)
  return string.format("%d:%04.1f", m, s - m * 60)
end

function M.fmt_value(key, v)
  if v == nil then return "-" end
  local d = M.METRIC_BY_KEY[key]
  if d and d.time then return M.fmt_time(v) end
  if v == NEG_INF then return "-inf" end
  if v == math.huge then return "+inf" end
  local f = d and d.fmt or "%.2f"
  if f == "%d" then v = floor(v + 0.5) end
  local s = string.format(f, v)
  if s:match("^%-0%.?0*$") then s = s:sub(2) end -- no "-0.0"
  return s
end

-- Round to the metric's display precision so a verdict never contradicts
-- the number shown (e.g. -0.996 dBTP displays -1.00 and passes <= -1).
local function rounded(key, v)
  local d = M.METRIC_BY_KEY[key]
  if not d or d.time or v == NEG_INF or v == math.huge then return v end
  local dec = tonumber((d.fmt or ""):match("%.(%d)f")) or 0
  local p = 10 ^ dec
  return floor(v * p + 0.5) / p
end

---------------------------------------------------------------- presets

-- Music presets check what platforms actually reject or penalize (peaks,
-- clipping). Integrated loudness is informational there: the platform
-- table shows how much each service turns the master down or up.
-- Spoken-word presets are carried over from the Premiere Spec Check.
M.BUILTIN_PRESETS = {
  { name = "Streaming master (general)", group = "Music", checks = {
    { m = "truePeak", max = -1 }, { m = "clipCount", max = 0 } } },
  -- Spotify: keep true peak under -1 dBTP, and under -2 dBTP when the
  -- master is louder than -14 LUFS.
  { name = "Spotify", group = "Music", checks = {
    { m = "truePeak", max = -1 },
    { m = "truePeak", max = -2, when = { m = "lufsI", min = -14 } },
    { m = "clipCount", max = 0 } } },
  { name = "Apple Music", group = "Music", checks = {
    { m = "truePeak", max = -1 }, { m = "clipCount", max = 0 } } },
  { name = "Amazon Music", group = "Music", checks = {
    { m = "truePeak", max = -2 }, { m = "clipCount", max = 0 } } },
  { name = "YouTube", group = "Music", checks = {
    { m = "truePeak", max = -1 }, { m = "clipCount", max = 0 } } },

  { name = "ACX / Audible", group = "Spoken word", checks = {
    { m = "rmsDb", min = -23, max = -18 }, { m = "samplePeakDb", max = -3 },
    { m = "noiseFloor", max = -60 } } },
  -- LRA <= 7 LU is a recommendation in the Audible Originals spec, not an
  -- acceptance criterion, so it is shown but not checked.
  { name = "Audible Originals", group = "Spoken word", checks = {
    { m = "lufsI", min = -18, max = -16 }, { m = "truePeak", max = -1 },
    { m = "noiseFloor", max = -60 }, { m = "headSilence", max = 3 },
    { m = "tailSilence", max = 3 }, { m = "sampleRateHz", min = 44100, max = 44100 },
    { m = "channels", min = 1, max = 2 }, { m = "duration", max = 7140 } } },
  { name = "Apple Podcasts", group = "Spoken word", checks = {
    { m = "lufsI", min = -17, max = -15 }, { m = "truePeak", max = -1 } } },
  { name = "Spotify (podcast)", group = "Spoken word", checks = {
    { m = "lufsI", min = -15, max = -13 }, { m = "truePeak", max = -1 } } },
  { name = "EBU R128 broadcast", group = "Spoken word", checks = {
    { m = "lufsI", min = -23.5, max = -22.5 }, { m = "truePeak", max = -1 } } },
  { name = "YouTube (spoken)", group = "Spoken word", checks = {
    { m = "lufsI", min = -15, max = -13 }, { m = "truePeak", max = -1 } } },
}

-- up: false = only turns loud masters down; true = also turns quiet ones
-- up; "peak" = turns up only as far as true-peak headroom to -1 dBTP allows.
M.PLATFORMS = {
  { name = "Spotify",      target = -14, up = "peak" },
  { name = "Apple Music",  target = -16, up = true },
  { name = "YouTube",      target = -14, up = false },
  { name = "Tidal",        target = -14, up = false },
  { name = "Amazon Music", target = -14, up = false },
}

local EXT = "SpecCheck"

-- Custom presets persist in reaper-extstate.ini as lines of
--   name|metric:min:max;metric:min:max   (empty min/max = unbounded)
function M.load_custom()
  local out = {}
  local s = reaper.GetExtState(EXT, "custom_presets")
  for line in s:gmatch("[^\n]+") do
    local name, body = line:match("^(.-)|(.*)$")
    if name and name ~= "" then
      local p = { name = name, group = "Custom", checks = {} }
      for m, lo, hi in body:gmatch("([%w]+):([^:;]*):([^;]*)") do
        p.checks[#p.checks + 1] = { m = m, min = tonumber(lo), max = tonumber(hi) }
      end
      out[#out + 1] = p
    end
  end
  return out
end

function M.save_custom(list)
  local lines = {}
  for _, p in ipairs(list) do
    local parts = {}
    for _, c in ipairs(p.checks) do
      parts[#parts + 1] = c.m .. ":" .. (c.min and tostring(c.min) or "") .. ":" .. (c.max and tostring(c.max) or "")
    end
    lines[#lines + 1] = p.name:gsub("[|\n]", " ") .. "|" .. table.concat(parts, ";")
  end
  reaper.SetExtState(EXT, "custom_presets", table.concat(lines, "\n"), true)
end

---------------------------------------------------------------- scoring

function M.target_text(c)
  local d = M.METRIC_BY_KEY[c.m]
  local f = function(v) return M.fmt_value(c.m, v) end
  local t
  if c.min and c.max then
    t = (c.min == c.max) and f(c.min) or (f(c.min) .. " to " .. f(c.max))
  elseif c.max then t = "<= " .. f(c.max)
  elseif c.min then t = ">= " .. f(c.min)
  else t = "any" end
  if c.when then
    local w = c.when
    local cond = w.min and (">= " .. M.fmt_value(w.m, w.min)) or ("<= " .. M.fmt_value(w.m, w.max))
    t = t .. "  (if " .. (M.METRIC_BY_KEY[w.m] and M.METRIC_BY_KEY[w.m].label:lower() or w.m) .. " " .. cond .. ")"
  end
  return t
end

local function in_range(key, v, lo, hi)
  v = rounded(key, v)
  return (lo == nil or v >= lo) and (hi == nil or v <= hi)
end

-- Returns rows {m, check, value, status = "pass"|"fail"|"na"|"skip"} and
-- a summary {pass, fail, total}.
function M.score(metrics, preset)
  local rows, sum = {}, { pass = 0, fail = 0, total = 0 }
  for _, c in ipairs(preset and preset.checks or {}) do
    local v, status = metrics[c.m], nil
    if c.when then
      local w = metrics[c.when.m]
      if w == nil or not in_range(c.when.m, w, c.when.min, c.when.max) then status = "skip" end
    end
    if not status then
      if v == nil then status = "na"
      else status = in_range(c.m, v, c.min, c.max) and "pass" or "fail" end
    end
    if status == "pass" or status == "fail" then
      sum.total = sum.total + 1
      sum[status] = sum[status] + 1
    end
    rows[#rows + 1] = { m = c.m, check = c, value = v, status = status }
  end
  return rows, sum
end

function M.platform_rows(m)
  local out = {}
  if not m.lufsI or m.lufsI == NEG_INF then return out end
  for _, p in ipairs(M.PLATFORMS) do
    local delta = p.target - m.lufsI
    local change
    if delta < 0 then change = delta
    elseif p.up == "peak" then change = math.max(0, math.min(delta, -1 - (m.truePeak or 0)))
    elseif p.up then change = delta
    else change = 0 end
    local text
    if change <= -0.05 then text = string.format("%.1f dB quieter", -change)
    elseif change >= 0.05 then text = string.format("%.1f dB louder", change)
    else text = "plays as is" end
    out[#out + 1] = { name = p.name, target = p.target, change = change, text = text }
  end
  return out
end

---------------------------------------------------------------- ranges

-- A range is {kind="project"|"timesel"|"region", start, stop, label}.
function M.list_ranges()
  local r = { { kind = "project", label = "Entire project" } }
  local ts, te = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if te > ts then
    r[#r + 1] = { kind = "timesel", start = ts, stop = te,
      label = string.format("Time selection (%s - %s)", M.fmt_time(ts), M.fmt_time(te)) }
  end
  local i = 0
  while true do
    local ok, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers(i)
    if ok == 0 then break end
    if isrgn and not name:lower():match("^%s*roomtone%s*$") then
      r[#r + 1] = { kind = "region", start = pos, stop = rgnend, regionIndex = idx,
        label = string.format("Region %d: %s", idx, name ~= "" and name or "(unnamed)") }
    end
    i = i + 1
  end
  return r
end

-- Region named "roomtone" (any case): pins the noise-floor measurement.
local function find_roomtone()
  local i = 0
  while true do
    local ok, isrgn, pos, rgnend, name = reaper.EnumProjectMarkers(i)
    if ok == 0 then return nil end
    if isrgn and name:lower():match("^%s*roomtone%s*$") then return pos, rgnend end
    i = i + 1
  end
end

---------------------------------------------------------------- render

local NUM_KEYS = { "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_STARTPOS", "RENDER_ENDPOS",
  "RENDER_SRATE", "RENDER_CHANNELS", "RENDER_TAILFLAG", "RENDER_TAILMS", "RENDER_ADDTOPROJ",
  "RENDER_NORMALIZE", "RENDER_DITHER" }
local STR_KEYS = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT", "RENDER_FORMAT2" }

-- WAV sink config: "evaw" + bit depth byte (32 = float) + 2 option bytes.
local WAV32F = "ZXZhdyAAAA=="
local RENDER_MOST_RECENT_AUTOCLOSE = 42230

function M.temp_dir()
  local base = os.getenv("TEMP") or os.getenv("TMPDIR") or (reaper.GetResourcePath() .. "/tmp")
  local dir = base .. "/SpecCheck"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir
end

local function save_render_settings()
  local s = { num = {}, str = {} }
  for _, k in ipairs(NUM_KEYS) do s.num[k] = reaper.GetSetProjectInfo(0, k, 0, false) end
  for _, k in ipairs(STR_KEYS) do
    local _, v = reaper.GetSetProjectInfo_String(0, k, "", false)
    s.str[k] = v
  end
  s.dirty = reaper.GetSetProjectInfo(0, "DIRTY", 0, false)
  return s
end

local function restore_render_settings(s)
  for _, k in ipairs(NUM_KEYS) do reaper.GetSetProjectInfo(0, k, s.num[k], true) end
  for _, k in ipairs(STR_KEYS) do reaper.GetSetProjectInfo_String(0, k, s.str[k], true) end
  -- Net change is zero, so put the project's modified flag back too.
  reaper.GetSetProjectInfo(0, "DIRTY", s.dirty, true)
end

-- Renders the master mix over `range` to a temp WAV. Blocks while REAPER's
-- render window runs. Returns path or nil, err.
function M.render_mix(range)
  if range.kind == "timesel" then
    local ts, te = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    if te <= ts then return nil, "No time selection" end
  end
  local saved = save_render_settings()
  local ok, res, err = pcall(function()
    local dir = M.temp_dir()
    local set = function(k, v) reaper.GetSetProjectInfo(0, k, v, true) end
    local sets = function(k, v) reaper.GetSetProjectInfo_String(0, k, v, true) end
    set("RENDER_SETTINGS", 0)          -- master mix
    if range.kind == "project" then set("RENDER_BOUNDSFLAG", 1)
    elseif range.kind == "timesel" then set("RENDER_BOUNDSFLAG", 2)
    else
      set("RENDER_BOUNDSFLAG", 0)
      set("RENDER_STARTPOS", range.start)
      set("RENDER_ENDPOS", range.stop)
    end
    set("RENDER_SRATE", 0)             -- project rate
    set("RENDER_CHANNELS", 2)
    set("RENDER_TAILFLAG", 0)
    set("RENDER_ADDTOPROJ", 0)
    set("RENDER_NORMALIZE", 0)         -- measure the mix, not render post-processing
    set("RENDER_DITHER", 0)
    sets("RENDER_FILE", dir)
    sets("RENDER_PATTERN", "speccheck_mix")
    sets("RENDER_FORMAT", WAV32F)
    sets("RENDER_FORMAT2", "")
    local _, targets = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
    local path = targets:match("^[^;]+")
    if not path then return nil, "REAPER returned no render target" end
    os.remove(path) -- avoid the overwrite prompt
    reaper.Main_OnCommand(RENDER_MOST_RECENT_AUTOCLOSE, 0)
    if not reaper.file_exists(path) then return nil, "Render did not produce a file (cancelled?)" end
    return path
  end)
  restore_render_settings(saved)
  if not ok then return nil, "Render failed: " .. tostring(res) end
  return res, err
end

---------------------------------------------------------------- WAV reader

local function open_wav(path)
  local f = io.open(path, "rb")
  if not f then return nil, "Cannot open " .. path end
  local hdr = f:read(12)
  if not hdr or #hdr < 12 then f:close(); return nil, "Not a WAV file" end
  local riff, _, wave = sunpack("<c4I4c4", hdr)
  if riff ~= "RIFF" or wave ~= "WAVE" then f:close(); return nil, "Unsupported container " .. riff end
  local fmt, dataPos, dataLen
  while true do
    local ch = f:read(8)
    if not ch or #ch < 8 then break end
    local id, len = sunpack("<c4I4", ch)
    if id == "fmt " then
      local b = f:read(len)
      local tag, nch, sr, _, align, bits = sunpack("<I2I2I4I4I2I2", b)
      if tag == 0xFFFE and len >= 26 then tag = sunpack("<I2", b, 25) end
      fmt = { tag = tag, nch = nch, sr = sr, align = align, bits = bits }
      if len % 2 == 1 then f:read(1) end
    elseif id == "data" then
      dataPos, dataLen = f:seek(), len
      break
    else
      f:seek("cur", len + (len % 2))
    end
  end
  if not fmt or not dataPos then f:close(); return nil, "WAV has no fmt/data chunk" end
  local code, scale
  if fmt.tag == 3 and fmt.bits == 32 then code, scale = "f", 1
  elseif fmt.tag == 3 and fmt.bits == 64 then code, scale = "d", 1
  elseif fmt.tag == 1 and fmt.bits == 16 then code, scale = "i2", 1 / 32768
  elseif fmt.tag == 1 and fmt.bits == 24 then code, scale = "i3", 1 / 8388608
  elseif fmt.tag == 1 and fmt.bits == 32 then code, scale = "i4", 1 / 2147483648
  else f:close(); return nil, ("Unsupported WAV format tag %d / %d bit"):format(fmt.tag, fmt.bits) end
  if fmt.nch < 1 or fmt.nch > 2 then f:close(); return nil, "Only mono or stereo is supported" end
  fmt.code, fmt.scale = code, scale
  fmt.frames = floor(dataLen / fmt.align)
  return { f = f, fmt = fmt }
end

---------------------------------------------------------------- analysis

-- BS.1770 K-weighting biquads for any sample rate (libebur128 derivation).
local function kweight_coefs(fs)
  local f0, G, Q = 1681.974450955533, 3.999843853973347, 0.7071752369554196
  local K = math.tan(math.pi * f0 / fs)
  local Vh = 10 ^ (G / 20)
  local Vb = Vh ^ 0.4996667741545416
  local a0 = 1 + K / Q + K * K
  local s1 = { b0 = (Vh + Vb * K / Q + K * K) / a0, b1 = 2 * (K * K - Vh) / a0,
    b2 = (Vh - Vb * K / Q + K * K) / a0, a1 = 2 * (K * K - 1) / a0, a2 = (1 - K / Q + K * K) / a0 }
  f0, Q = 38.13547087602444, 0.5003270373238773
  K = math.tan(math.pi * f0 / fs)
  local d = 1 + K / Q + K * K
  local s2 = { a1 = 2 * (K * K - 1) / d, a2 = (1 - K / Q + K * K) / d }
  return s1, s2
end

-- Gated mean per BS.1770 over a list of block energies.
local function gated_loudness(E)
  local sum, n = 0, 0
  for i = 1, #E do if lufs(E[i]) > -70 then sum, n = sum + E[i], n + 1 end end
  if n == 0 then return NEG_INF end
  local rel = lufs(sum / n) - 10
  local s2, n2 = 0, 0
  for i = 1, #E do if lufs(E[i]) > rel then s2, n2 = s2 + E[i], n2 + 1 end end
  return n2 > 0 and lufs(s2 / n2) or NEG_INF
end

-- EBU Tech 3342 loudness range from short-term energies.
local function loudness_range(ST)
  local sum, n = 0, 0
  for i = 1, #ST do if lufs(ST[i]) > -70 then sum, n = sum + ST[i], n + 1 end end
  if n == 0 then return 0 end
  local rel = lufs(sum / n) - 20
  local L = {}
  for i = 1, #ST do
    local l = lufs(ST[i])
    if l > -70 and l > rel then L[#L + 1] = l end
  end
  if #L < 2 then return 0 end
  table.sort(L)
  local function pct(p) return L[math.max(1, math.min(#L, floor((#L - 1) * p + 0.5) + 1))] end
  return pct(0.95) - pct(0.10)
end

local function sliding_means(E, width)
  local out, acc = {}, 0
  for i = 1, #E do
    acc = acc + E[i]
    if i > width then acc = acc - E[i - width] end
    if i >= width then out[#out + 1] = acc / width end
  end
  return out
end

-- The Lua sample pass as a coroutine body; yields progress 0..1.
local function sample_pass(w, res, opts)
  local fmt, f = w.fmt, w.f
  local fs, nch, total = fmt.sr, fmt.nch, fmt.frames
  local mono = nch == 1
  local k1, k2 = kweight_coefs(fs)
  local b0, b1, b2, a1, a2 = k1.b0, k1.b1, k1.b2, k1.a1, k1.a2
  local c1, c2 = k2.a1, k2.a2
  local blockLen = floor(fs * 0.1 + 0.5) -- 100 ms
  local silenceThr, clipThr = 0.001, 1.0 -- -60 dBFS; 0 dBFS
  local clipGap = floor(fs * 0.05)

  -- running state
  local zL1, zL2, wL1, wL2, zR1, zR2, wR1, wR2 = 0, 0, 0, 0, 0, 0, 0, 0
  local pkL, pkR, sL, sR, ssL, ssR, sLR = 0, 0, 0, 0, 0, 0, 0
  local clips, events, lastClip = 0, {}, -1e18
  local first, last = -1, -1
  local bK, bF, bLR, bLL, bRR, bn = 0, 0, 0, 0, 0, 0
  local KE, FE, CLR, CLL, CRR = {}, {}, {}, {}, {}

  local perCall = 1024 -- values per string.unpack call
  local fmtFull = "<" .. srep(fmt.code, perCall)
  local chunkFrames = 16384
  local frame = 0
  local tick = reaper.time_precise()
  local budget = opts.budget or 0.03

  while frame < total do
    local nFrames = math.min(chunkFrames, total - frame)
    local data = f:read(nFrames * fmt.align)
    if not data then break end
    nFrames = floor(#data / fmt.align)
    local nVals = nFrames * nch
    local pos, got = 1, 0
    while got < nVals do
      local cnt = math.min(perCall, nVals - got)
      local v = { sunpack(cnt == perCall and fmtFull or ("<" .. srep(fmt.code, cnt)), data, pos) }
      pos = v[cnt + 1]
      local sc = fmt.scale
      local step = mono and 1 or 2
      for i = 1, cnt, step do
        local l = v[i] * sc
        local r = mono and l or v[i + 1] * sc
        local al = l < 0 and -l or l
        local ar = r < 0 and -r or r
        if al > pkL then pkL = al end
        if ar > pkR then pkR = ar end
        if al >= clipThr or ar >= clipThr then
          local n = (al >= clipThr and 1 or 0) + ((not mono and ar >= clipThr) and 1 or 0)
          clips = clips + n
          if frame - lastClip > clipGap then
            events[#events + 1] = { t = frame / fs, n = 0, peak = 0 }
          end
          local e = events[#events]
          e.n = e.n + n
          local a = al > ar and al or ar
          if a > e.peak then e.peak = a end
          lastClip = frame
        end
        if al > silenceThr or ar > silenceThr then
          if first < 0 then first = frame end
          last = frame
        end
        sL, sR = sL + l, sR + r
        ssL, ssR, sLR = ssL + l * l, ssR + r * r, sLR + l * r
        bLL, bRR, bLR = bLL + l * l, bRR + r * r, bLR + l * r
        -- K-weighting, transposed direct form II, two stages per channel
        local y = b0 * l + zL1
        zL1 = b1 * l - a1 * y + zL2
        zL2 = b2 * l - a2 * y
        local k = y + wL1
        wL1 = -2 * y - c1 * k + wL2
        wL2 = y - c2 * k
        local kk = k * k
        if not mono then
          y = b0 * r + zR1
          zR1 = b1 * r - a1 * y + zR2
          zR2 = b2 * r - a2 * y
          k = y + wR1
          wR1 = -2 * y - c1 * k + wR2
          wR2 = y - c2 * k
          kk = kk + k * k
        end
        bK = bK + kk
        bn = bn + 1
        if bn == blockLen then
          KE[#KE + 1] = bK / blockLen
          FE[#FE + 1] = (bLL + bRR) / (2 * blockLen)
          CLR[#CLR + 1], CLL[#CLL + 1], CRR[#CRR + 1] = bLR, bLL, bRR
          bK, bLL, bRR, bLR, bn = 0, 0, 0, 0, 0
        end
        frame = frame + 1
      end
      got = got + cnt
    end
    if reaper.time_precise() - tick > budget then
      coroutine.yield(frame / total)
      tick = reaper.time_precise()
    end
  end
  w.f:close()

  local n = math.max(frame, 1)
  res.duration = frame / fs
  res.sampleRateHz = fs
  res.channels = nch
  res.samplePeakDb = db20(math.max(pkL, pkR))
  res.clipCount = clips
  res.clipEvents = events
  res.rmsDb = db10((ssL + ssR) / (2 * n))
  res.dcOffsetDb = db20(math.max(math.abs(sL / n), math.abs(sR / n)))
  if first < 0 then
    res.headSilence, res.tailSilence = res.duration, res.duration
  else
    res.headSilence = first / fs
    res.tailSilence = (frame - 1 - last) / fs
  end

  -- Loudness cross-checks and LRA from 100 ms K-weighted blocks.
  res.lufsI_lua = gated_loudness(sliding_means(KE, 4))
  local ST = sliding_means(KE, 30)
  res.lra = loudness_range(ST)
  local stMax = 0
  for i = 1, #ST do if ST[i] > stMax then stMax = ST[i] end end
  res.lufsSMax_lua = lufs(stMax)

  -- Noise floor: quietest 0.5 s window above digital silence, or exact
  -- RMS over a "roomtone" region inside the checked range.
  local best
  for i = 1, #FE - 4, 5 do
    local e = (FE[i] + FE[i + 1] + FE[i + 2] + FE[i + 3] + FE[i + 4]) / 5
    local d = db10(e)
    if d > -100 and (best == nil or d < best) then best = d end
  end
  res.noiseFloor, res.noiseFloorExact = best, false
  if opts.roomtone then
    local a = math.max(1, floor(opts.roomtone[1] * 10) + 1)
    local b = math.min(#FE, floor(opts.roomtone[2] * 10))
    if b >= a then
      local e = 0
      for i = a, b do e = e + FE[i] end
      res.noiseFloor, res.noiseFloorExact = db10(e / (b - a + 1)), true
    end
  end

  -- Stereo correlation: overall, and the worst 1 s window with signal.
  if not mono then
    res.correlation = (ssL > 0 and ssR > 0) and sLR / sqrt(ssL * ssR) or nil
    local worst, worstT
    for i = 1, #CLR - 9 do
      local lr, ll, rr = 0, 0, 0
      for j = i, i + 9 do lr, ll, rr = lr + CLR[j], ll + CLL[j], rr + CRR[j] end
      if db10((ll + rr) / (2 * blockLen * 10)) > -40 and ll > 0 and rr > 0 then
        local c = lr / sqrt(ll * rr)
        if worst == nil or c < worst then worst, worstT = c, (i - 1) * 0.1 end
      end
    end
    res.corrMin, res.corrMinAt = worst, worstT
  end
end

-- REAPER-native measurements. normalizeTarget 0 means the returned linear
-- gain g gives measured = -20*log10(g).
local NORM = {
  { key = "lufsI", mode = 0, label = "integrated loudness" },
  { key = "truePeak", mode = 3, label = "true peak" },
  { key = "lufsSMax", mode = 5, label = "short-term loudness" },
  { key = "lufsMMax", mode = 4, label = "momentary loudness" },
}

-- Build an analysis job over a WAV file. job:step() advances it within a
-- time budget; returns done, progress (0..1), status text.
function M.new_analysis(path, opts)
  opts = opts or {}
  local res = { path = path }
  local job = { res = res, status = "Starting", progress = 0 }
  local co = coroutine.create(function()
    local w, err = open_wav(path)
    if not w then error(err, 0) end
    job.status = "Reading samples"
    sample_pass(w, res, opts)
    local src = reaper.PCM_Source_CreateFromFile(path)
    if not src then error("REAPER could not open the render", 0) end
    for i, n in ipairs(NORM) do
      job.status = "Measuring " .. n.label
      coroutine.yield(0.8 + 0.05 * (i - 1)) -- let the UI show the label first
      local g = reaper.CalculateNormalization(src, n.mode, 0, 0, 0)
      res[n.key] = (g and g > 0) and -db20(g) or nil
    end
    reaper.PCM_Source_Destroy(src)
    if res.lufsI and res.truePeak and res.lufsI > NEG_INF then
      res.plr = res.truePeak - res.lufsI
    end
  end)
  function job:step()
    if self.done then return true, 1, self.status end
    local ok, p = coroutine.resume(co)
    if not ok then
      self.done, self.error, self.status = true, tostring(p), "Error"
    elseif coroutine.status(co) == "dead" then
      self.done, self.progress, self.status = true, 1, "Done"
    elseif self.status == "Reading samples" then
      self.progress = 0.8 * (p or 0) -- sample pass fills the first 80% of the bar
    else
      self.progress = p or self.progress
    end
    return self.done, self.progress, self.status
  end
  return job
end

-- Full check of one range: render, then return an analysis job. Roomtone
-- times are converted to be relative to the rendered file.
function M.check_range(range, opts)
  opts = opts or {}
  local path, err = M.render_mix(range)
  if not path then return nil, err end
  local rs, re = find_roomtone()
  if rs then
    local start = range.start or 0
    local stop = range.stop or math.huge
    if range.kind == "project" then start, stop = 0, math.huge end
    local a, b = math.max(rs, start), math.min(re, stop)
    if b > a then opts.roomtone = { a - start, b - start } end
  end
  local job = M.new_analysis(path, opts)
  job.range = range
  job.res.label = range.label
  job.res.rangeStart = (range.kind == "project") and 0 or range.start
  job.res.when = os.date("%Y-%m-%d %H:%M")
  return job
end

---------------------------------------------------------------- report

function M.report_text(res, preset)
  local L = {}
  local add = function(s) L[#L + 1] = s end
  local rows, sum = M.score(res, preset)
  local _, projname = reaper.GetSetProjectInfo_String(0, "PROJECT_NAME", "", false)
  add("Spec Check for REAPER " .. M.VERSION)
  add("Project: " .. (projname ~= "" and projname or "(unsaved)"))
  add("Range:   " .. (res.label or "?"))
  add("Checked: " .. (res.when or os.date("%Y-%m-%d %H:%M")))
  add("Preset:  " .. (preset and preset.name or "(none)"))
  add("")
  add(string.format("Verdict: %s (%d of %d checks pass)",
    sum.fail == 0 and "PASS" or "FAIL", sum.pass, sum.total))
  add("")
  add("Checks")
  for _, r in ipairs(rows) do
    local d = M.METRIC_BY_KEY[r.m]
    add(string.format("  %-4s  %-24s %10s %-5s target %s",
      r.status:upper(), d and d.label or r.m, M.fmt_value(r.m, r.value),
      d and d.unit or "", M.target_text(r.check)))
  end
  add("")
  add("Measurements")
  for _, d in ipairs(M.METRICS) do
    local extra = ""
    if d.key == "noiseFloor" and res.noiseFloor then
      extra = res.noiseFloorExact and "  (roomtone region)" or "  (quietest 0.5 s)"
    elseif d.key == "corrMin" and res.corrMinAt then
      extra = "  at " .. M.fmt_time((res.rangeStart or 0) + res.corrMinAt)
    end
    add(string.format("  %-24s %10s %s%s", d.label, M.fmt_value(d.key, res[d.key]), d.unit, extra))
  end
  local pr = M.platform_rows(res)
  if #pr > 0 then
    add("")
    add("Streaming playback (loudness normalization)")
    for _, p in ipairs(pr) do
      add(string.format("  %-14s target %4d LUFS   %s", p.name, p.target, p.text))
    end
  end
  if res.clipEvents and #res.clipEvents > 0 then
    add("")
    add("Clipping (samples at or above 0 dBFS)")
    for i, e in ipairs(res.clipEvents) do
      if i > 100 then add(string.format("  ... %d more", #res.clipEvents - 100)); break end
      add(string.format("  %s  %d sample%s  peak %+.2f dBFS",
        M.fmt_time((res.rangeStart or 0) + e.t), e.n, e.n == 1 and "" or "s", db20(e.peak)))
    end
  end
  return table.concat(L, "\n") .. "\n"
end

return M
