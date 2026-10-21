--- Create stress monitor with an on/off button (v1, simpler layout).
-- Shows stress usage of a Stressometer on a monitor, raises a redstone
-- alert near the limit, and toggles a redstone output when the
-- on-screen button is touched.
--
-- Layout: monitor on top, Stressometer on the right,
-- button output at the back, alert output on the left.
-- @script unknown-scada-1

local monitor = peripheral.wrap("top") or error("No monitor on top", 0)
local stressSensor = peripheral.wrap("right")
  or error("No stress sensor on the right", 0)

local BUTTON_OUTPUT_SIDE = "back"
local ALERT_OUTPUT_SIDE = "left"
local ALERT_PERCENT = 80
local BUTTON_ROW = 10
local BUTTON_WIDTH = 7
local REFRESH_SECONDS = 1

local buttonState = true

--- Writes a line of text, clearing the old one first.
-- @tparam number y Row to write on
-- @tparam string text Text to write
local function writeLine(y, text)
  monitor.setCursorPos(1, y)
  monitor.clearLine()
  monitor.write(text)
end

--- Draws the toggle button.
-- @tparam boolean active Current output state
local function drawButton(active)
  monitor.setCursorPos(1, BUTTON_ROW)
  if active then
    monitor.setBackgroundColor(colors.red)
    monitor.write(" |Off| ")
  else
    monitor.setBackgroundColor(colors.lime)
    monitor.write(" |On|  ")
  end
  monitor.setBackgroundColor(colors.black)
end

--- Reads the sensor, redraws stress info and sets the alert output.
local function drawStress()
  local currentStress = stressSensor.getStress() or 0
  local capacity = stressSensor.getStressCapacity() or 0
  local usagePercent = capacity > 0 and currentStress / capacity * 100 or 0
  local overloaded = usagePercent >= ALERT_PERCENT

  writeLine(1, "Stress-level: " .. math.floor(usagePercent) .. "%")
  writeLine(3, "Currently used: " .. math.floor(currentStress))
  writeLine(6, "Capacity: " .. math.floor(capacity))
  writeLine(9, overloaded and "!! WARNING: LIMIT ALMOST REACHED !!" or "")
  redstone.setOutput(ALERT_OUTPUT_SIDE, overloaded)
end

--- Refreshes stress info forever.
local function stressLoop()
  while true do
    drawStress()
    sleep(REFRESH_SECONDS)
  end
end

--- Handles button touches forever.
local function buttonLoop()
  while true do
    local _, _, x, y = os.pullEvent("monitor_touch")
    if y == BUTTON_ROW and x <= BUTTON_WIDTH then
      buttonState = not buttonState
      redstone.setOutput(BUTTON_OUTPUT_SIDE, buttonState)
      drawButton(buttonState)
    end
  end
end

monitor.setBackgroundColor(colors.black)
monitor.clear()

redstone.setOutput(BUTTON_OUTPUT_SIDE, buttonState)
drawButton(buttonState)
drawStress()

parallel.waitForAny(stressLoop, buttonLoop)

