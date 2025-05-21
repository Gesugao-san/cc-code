local monitor = peripheral.wrap("top")
local stressSensor = peripheral.wrap("right")
local outputButtonSide = "back"
local outputAlertSide = "left"

local redstoneState = false

monitor.setTextScale(1)
monitor.setBackgroundColor(colors.black)
monitor.setTxtColor(colors.white)
monitor.clear()

local function getBarColor(percent)
  if percent >= 90 then return colors.red
  elseif percent >=80 then return colors.orange
  else return colors.lime end
end

local function drawBar(y, percent, width)
  local filled = math.floor((percent / 100) * width)
  local color = getBarColor(percent)

  monitor.setCursorPos(1, y)
  monitor.setBackgroundColor(colors.gray)
  monitor.write(string.rep(" ", width))

  monitor.setCursorPos(1, y)
  monitor.setBackgroundColor(color)
  monitor.write(string.rep(" ", filled))
  
  monitor.setBackgroundColor(colors.black)
end

local function drawButton(active)
  monitor.setCursorPos(1, 7)
  if active then
    monitor.setBackgroundColor(colors.red)
    monitor.setTxtColor(colors.white)
    monitor.write(" [OFF] ")
  else
    monitor.setBackgroundColor(colors.lime)
    monitor.setTxtColor(colors.black)
    monitor.write(" [ON]  ")
  end
  monitor.setBackgroundColor(colors.black)
  monitor.setTxtColor(colors.white)
end

local function drawStress()
  local stress = stressSensor.getStress() or 0
  local capacity = stressSensor.getStressCapacity() or 1
  local percent = (stress / capacity) * 100

  monitor.setCursorPos(1, 1)
  monitor.clearLine()
  monitor.write("Stress: " .. math.floor(stress))
  monitor.setCursorPos(1, 2)
  monitor.write("Capacity: " .. math.floor(capacity))
  monitor.setCursorPos(1, 3)
  monitor.write("Usage: " .. percent .. "%")

  drawBar(4, percent, 20)

  if percent >= 80 then
    redstone.setOutput(outputAlertSide, true)
    monitor.setCursorPos(1, 5)
    monitor.setTxtColor(colors.red)
    monitor.write("!! OVERLOAD WARNING !!")
    monitor.setTxtColor(colors.white)
  else
    redstone.setOutput(outputAlertSide, false)
    monitor.setCursorPos(1, 5)
    monitor.clearLine()
  end
end

local function stressLoop()
  while true do
    drawStress()
    sleep(.5)
  end
end

local function buttonLoop()
  while true do
    local event, side, x, y = os.pullEvent("monitor_touch")
    if y == 7 and x >= 1 and x <= 8 then
      redstoneState = not redstoneState
      redstone.setOutput(outputAlertSide, redstoneState)
      drawButton(redstoneState)
    end
  end
end

drawButton(redstoneState)
drawStress()

parallel.waitForAny(stressLoop, buttonLoop)
