-- IC2 energy monitor (tier-split + totals + hysteresis + generator panel)
-- Tekkit 2 / Classic

local REFRESH_INTERVAL = 2
local DISCOVERY_INTERVAL = 10
local TITLE = "EU Power-grid"

-- generator control thresholds (network totals)
local LOW_THRESHOLD = 0.20   -- 20%: turn generators ON
local HIGH_THRESHOLD = 0.55  -- 55%: turn generators OFF
local genActive = false      -- latched state

-- helpers
local function findMonitor()
  local mons = { peripheral.find("monitor") }
  if #mons > 0 then return mons[1] end
  if peripheral.isPresent("right") and peripheral.getType("right") == "monitor" then
    return peripheral.wrap("right")
  end
  return nil
end

local function centerText(mon, y, text, color)
  local w,_ = mon.getSize()
  local x = math.floor((w - #text) / 2) + 1
  mon.setCursorPos(x, y)
  if color then mon.setTextColor(color) end
  mon.write(text)
end

local function getIC2Devices()
  local devices = {}
  for _, name in ipairs(peripheral.getNames()) do
    local ok, p = pcall(peripheral.wrap, name)
    if ok and p and p.getEUStored and p.getEUCapacity then
      local tier = p.getSourceTier and tonumber(p.getSourceTier()) or 0
      table.insert(devices, { name = name, p = p, tier = tier })
    end
  end
  return devices
end

local function getGenerators()
  local gens = {}
  for _, name in ipairs(peripheral.getNames()) do
    local ok, p = pcall(peripheral.wrap, name)
    if ok and p and p.getOfferedEnergy then
      table.insert(gens, { name = name, p = p })
    end
  end
  return gens
end

local function getStats(p)
  local stored = tonumber(p.getEUStored() or 0)
  local cap    = tonumber(p.getEUCapacity() or 0)
  local output = p.getEUOutput and tonumber(p.getEUOutput()) or nil
  local tier   = p.getSourceTier and tonumber(p.getSourceTier()) or nil
  return stored, cap, output, tier
end

local function formatEU(n)
  if n >= 1000000000 then return string.format("%.2fG", n / 1000000000).." EU" end
  if n >= 1000000 then return string.format("%.2fM", n / 1000000).." EU" end
  if n >= 1000 then return string.format("%.1fk", n / 1000).." EU" end
  return tostring(n).." EU"
end

local function formatRateEUt(euPerTick)
  if euPerTick >= 1000 then
    return string.format("%.1fk EU/t", euPerTick/1000)
  else
    return string.format("%.1f EU/t", euPerTick)
  end
end

local function formatDeltaRate(deltaEU, dt)
  local rate = deltaEU / dt
  local sign = rate >= 0 and "+" or "-"
  local euPerTick = math.abs(rate) / 20
  return sign .. formatRateEUt(euPerTick)
end

local function drawBar(mon, x, y, width, pct)
  local filled = math.floor(width * math.max(0, math.min(1, pct)))
  local color = colors.red
  if pct >= 0.8 then color = colors.green
  elseif pct >= 0.4 then color = colors.yellow end
  mon.setBackgroundColor(color)
  mon.setCursorPos(x, y)
  mon.write(string.rep(" ", filled))
  mon.setBackgroundColor(colors.black)
  mon.setCursorPos(x+filled, y)
  mon.write(string.rep(" ", width-filled))
  mon.setTextColor(colors.white)
end
-- main
local mon = findMonitor()
if not mon then
  print("No Monitor found.")
  return
end
mon.setTextScale(0.5)
mon.setBackgroundColor(colors.black)
mon.clear()
centerText(mon, 1, TITLE, colors.cyan)

local lastSample = {}
local lastDiscovery = 0
local devices, generators = {}, {}

-- generator panel
local function drawGenerators(mon, gens, startY, panelWidth, screenW, screenH)
  local row = startY
  local totalGenOut = 0

  -- header
  mon.setCursorPos(screenW - panelWidth + 1, row)
  mon.setTextColor(colors.cyan)
  mon.write(string.rep(" ", panelWidth))
  mon.setCursorPos(screenW - panelWidth + 1, row)
  mon.write("Generators ("..#gens..")")

  -- gen lines
  row = row + 1
  for i, g in ipairs(gens) do
    local offered = tonumber(g.p.getOfferedEnergy() or 0) or 0
    totalGenOut = totalGenOut + offered

    mon.setCursorPos(screenW - panelWidth + 1, row)
    mon.write(string.rep(" ", panelWidth))
    mon.setCursorPos(screenW - panelWidth + 1, row)
    mon.setTextColor(colors.white)
    mon.write(string.format("Gen %d > ", i))
    if offered > 0 then
      mon.setTextColor(colors.green)
      mon.write("Active")
    else
      mon.setTextColor(colors.red)
      mon.write("Inactive")
    end

    row = row + 1
    if row >= screenH-2 then break end
  end

  -- total gen line output
  local totalLineY = (row + 1 <= screenH-2) and (row + 1) or (screenH - 2)
  mon.setCursorPos(screenW - panelWidth + 1, totalLineY)
  mon.write(string.rep(" ", panelWidth))
  mon.setCursorPos(screenW - panelWidth + 1, totalLineY)
  mon.setTextColor(colors.cyan)
  local line = "Total Gen: "..formatRateEUt(totalGenOut)
  mon.write(line .. string.rep(" ", panelWidth - #line))
end

while true do
  local now = os.epoch("utc")
  if (now - lastDiscovery)/1000 >= DISCOVERY_INTERVAL or lastDiscovery == 0 then
    devices = getIC2Devices()
    generators = getGenerators()
    lastDiscovery = now
  end

  local w,h = mon.getSize()
  local usableHeight = h - 5 -- reserve bottom for totals + generator panel

  -- split devices for grouping
  local groups = { bat={}, mfe={}, mfsu={} }
  for _,d in ipairs(devices) do
    if d.tier == 1 then table.insert(groups.bat,d)
    elseif d.tier == 2 then table.insert(groups.mfe,d)
    else table.insert(groups.mfsu,d) end
  end

  local colWidth = math.floor(w/3)
  local function clearLineRange(x, y, width, lines)
    for i=0,lines-1 do
      mon.setCursorPos(x, y+i)
      mon.write(string.rep(" ", width))
    end
  end

  local function drawGroup(devs, colX, label)
    mon.setCursorPos(colX, 3)
    mon.setTextColor(colors.cyan)
    mon.write(string.rep(" ", colWidth-1))
    mon.setCursorPos(colX, 3)
    mon.write(label.." ("..#devs..")")

    local row = 5
    local barWidth = colWidth - 2
    for _,d in ipairs(devs) do
      local stored, cap, output, tier = getStats(d.p)
      local pct = (cap>0) and (stored/cap) or 0
      local prev = lastSample[d.name]
      local deltaEU, dt = 0, REFRESH_INTERVAL
      if prev then
        dt = math.max(0.5,(now-prev.time)/1000)
        deltaEU = stored - prev.stored
      end
      lastSample[d.name] = { stored=stored, time=now }

      clearLineRange(colX, row, colWidth-1, 3)

      drawBar(mon, colX, row, barWidth, pct)

      mon.setCursorPos(colX, row+1)
      mon.setTextColor(colors.white)
      mon.write(string.format("%4.1f%% %s/%s", pct*100, formatEU(stored), formatEU(cap)))

      mon.setCursorPos(colX, row+2)
      mon.setTextColor(deltaEU>=0 and colors.green or colors.red)
      mon.write(formatDeltaRate(deltaEU,dt))
      if output then
        mon.setTextColor(colors.gray)
        mon.write(" Out:"..output.." EU/t T"..(tier or "?"))
      end

      row = row+4
      if row+3 > usableHeight then break end
    end
  end

  drawGroup(groups.bat, 1, "BatBoxes")
  drawGroup(groups.mfe, colWidth+1, "MFEs")
  drawGroup(groups.mfsu, colWidth*2+1, "MFSUs")

  -- footer
  local totalStored, totalCap = 0,0
  for _,d in ipairs(devices) do
    local stored, cap = getStats(d.p)
    totalStored = totalStored + stored
    totalCap = totalCap + cap
  end
  local totalPct = (totalCap>0) and (totalStored/totalCap) or 0

  -- hysteresis ctrl on total
  if totalPct < LOW_THRESHOLD then
    genActive = true
  elseif totalPct > HIGH_THRESHOLD then
    genActive = false
  end
  redstone.setOutput("back", genActive)

  -- total bar
  mon.setCursorPos(1,h-1); mon.write(string.rep(" ", w))
  mon.setCursorPos(1,h);   mon.write(string.rep(" ", w))

  drawBar(mon, 1, h-1, w, totalPct)
  mon.setCursorPos(1,h)
  mon.setTextColor(colors.white)
  mon.write(string.format("Total: %s / %s (%.1f%%)  Control: %s",
    formatEU(totalStored), formatEU(totalCap), totalPct*100, genActive and "ON" or "OFF"))

  -- gen pan
  local panelWidth = math.min(w, 30)
  local genHeaderY = h - (#generators + 3)
  if genHeaderY < 3 then genHeaderY = 3 end

  drawGenerators(mon, generators, genHeaderY, panelWidth, w, h)

  -- status icon
  mon.setCursorPos(w-1, h-1)
  mon.setBackgroundColor(genActive and colors.green or colors.red)
  mon.write("  ")
  mon.setBackgroundColor(colors.black)

  sleep(REFRESH_INTERVAL)
end
