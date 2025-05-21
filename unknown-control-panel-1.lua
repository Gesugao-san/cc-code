local stressSensor = peripheral.wrap("right")
local monitor = peripheral.wrap("top")
local rs = true

monitor.clear()
monitor.setCursorPos(1,1)

local function drawButton(active)
  monitor.setCursorPos(1,10)
  if active then
    monitor.setBackgroundColor(colors.red)
    monitor.write(" |Off| ")
  else
    monitor.setBackgroundColor(colors.lime)
    monitor.write(" |On|  ")
  end
end

local function drawStress()
  local currentStress = stressSensor.getStress()
  local capacity = stressSensor.getStressCapacity()
  local usagePercent = (currentStress/capacity)*100

  monitor.setCursorPos(1,1)
  monitor.write("Stress-level: " .. math.floor(usagePercent) .. "%")
  monitor.setCursorPos(1,3)
  monitor.write("Currently used: " .. math.floor(currentStress))
  monitor.setCursorPos(1,6)
  monitor.write("Stress-level: " .. math.floor(capacity))

  if usagePercent >= 80 then
    monitor.setCursorPos(1,9)
    monitor.write("!! WARNING: LIMIT ALMOST REACHED !!")
    redstone.setOutput("left", true)
  else
    redstone.setOutput("left", false)
  end
end

drawStress()
drawButton(rs)

while true do
  drawStress()
  sleep(1)

  local event, side, x, y = os.
  if y == 10 and x >= 1 and x <=8 then
    rs = not rs
    redstone.setOutput("back", rs)
    drawButton(rs)
  end
end
