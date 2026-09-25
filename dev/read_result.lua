-- @noindex
-- Dev helper: return the last dev-runner result through the MCP result slot.
reaper.SetExtState("reaper_mcp_script_result", "last_result",
  reaper.GetExtState("SpecCheckDev", "result"), false)
