--- Create stress monitor with an on/off button (v2).
-- Shows stress usage of a Stressometer on a monitor as text and a bar,
-- raises a redstone alert on overload, and toggles a redstone output
-- when the on-screen button is touched.
--
-- Layout: monitor on top, Stressometer on the right,
-- button output at the back, alert output on the left.
-- @script unknown-scada-2

local monitor = peripheral.wrap("top") or error("No monitor on top", 0)
local stressSensor = peripheral.wrap("right")
  or error("No stress sensor on the right", 0)

local BUTTON_OUTPUT_SIDE = "back"
local ALERT_OUTPUT_SIDE = "left"
local ALERT_PERCENT = 80
local BAR_WIDTH = 20
local BUTTON_ROW = 7
local BUTTON_WIDTH = 7
local REFRESH_SECONDS = 0.5

--- Bar colors by usage threshold, checked from the highest.
local BAR_COLORS = {
  { percent = 90, color = colors.red },
  { percent = 80, color = colors.orange },
  { percent = 0, color = colors.lime },
}

local buttonState = false

--- Picks a bar color for a usage percentage.
-- @tparam number percent Usage, 0..100
-- @treturn number Color from the colors API
local function getBarColor(percent)
  for _, entry in ipairs(BAR_COLORS) do
    if percent >= entry.percent then
      return entry.color
    end
  end
  return colors.lime
end

--- Draws a horizontal usage bar.
-- @tparam number y Row to draw on
-- @tparam number percent Usage, 0..100 (clamped)
-- @tparam number width Bar width in characters
local function drawBar(y, percent, width)
  local clamped = math.max(0, math.min(percent, 100))
  local filled = math.floor(clamped / 100 * width)

  monitor.setCursorPos(1, y)
  monitor.setBackgroundColor(colors.gray)
  monitor.write(string.rep(" ", width))

  monitor.setCursorPos(1, y)
  monitor.setBackgroundColor(getBarColor(percent))
  monitor.write(string.rep(" ", filled))

  monitor.setBackgroundColor(colors.black)
end

--- Draws the toggle button.
-- @tparam boolean active Current output state
local function drawButton(active)
  monitor.setCursorPos(1, BUTTON_ROW)
  if active then
    monitor.setBackgroundColor(colors.red)
    monitor.setTextColor(colors.white)
    monitor.write(" [OFF] ")
  else
    monitor.setBackgroundColor(colors.lime)
    monitor.setTextColor(colors.black)
    monitor.write(" [ON]  ")
  end
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.white)
end

--- Writes a line of text, clearing the old one first.
-- @tparam number y Row to write on
-- @tparam string text Text to write
local function writeLine(y, text)
  monitor.setCursorPos(1, y)
  monitor.clearLine()
  monitor.write(text)
end

--- Shows or hides the overload warning and sets the alert output.
-- @tparam boolean overloaded True if usage is above the alert level
local function updateAlert(overloaded)
  redstone.setOutput(ALERT_OUTPUT_SIDE, overloaded)
  monitor.setCursorPos(1, 5)
  monitor.clearLine()
  if not overloaded then
    return
  end

  monitor.setTextColor(colors.red)
  monitor.write("!! OVERLOAD WARNING !!")
  monitor.setTextColor(colors.white)
end

--- Reads the sensor and redraws stress info.
local function drawStress()
  local stress = stressSensor.getStress() or 0
  local capacity = stressSensor.getStressCapacity() or 0
  local percent = capacity > 0 and stress / capacity * 100 or 0

  writeLine(1, "Stress: " .. math.floor(stress))
  writeLine(2, "Capacity: " .. math.floor(capacity))
  writeLine(3, string.format("Usage: %.1f%%", percent))
  drawBar(4, percent, BAR_WIDTH)
  updateAlert(percent >= ALERT_PERCENT)
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

monitor.setTextScale(1)
monitor.setBackgroundColor(colors.black)
monitor.setTextColor(colors.white)
monitor.clear()

redstone.setOutput(BUTTON_OUTPUT_SIDE, buttonState)
drawButton(buttonState)
drawStress()

parallel.waitForAny(stressLoop, buttonLoop)

