--- Builds a line overhead: 15 pipes, then a small cogwheel,
-- repeated until the turtle hits an obstacle in front of it.
--
-- Slots: 1 - small cogwheels, 2..12 - pipes (restocked into slot 2).
-- At start the turtle refuels from the currently selected slot.
-- @script turtle

local COGWHEEL_SLOT = 1
local PIPE_SLOT = 2
local LAST_PIPE_SLOT = 12
local PIPES_PER_SEGMENT = 15

--- Moves pipes from the spare slots into the main pipe slot.
local function restockPipes()
  for slot = LAST_PIPE_SLOT, PIPE_SLOT + 1, -1 do
    turtle.select(slot)
    turtle.transferTo(PIPE_SLOT)
  end
end

--- Moves forward and places the item from a slot above the turtle.
-- @tparam number slot Inventory slot to place from
-- @treturn boolean True if the turtle moved
local function stepAndPlaceUp(slot)
  if not turtle.forward() then
    return false
  end

  turtle.select(slot)
  turtle.placeUp()
  return true
end

--- Builds one segment: a run of pipes followed by a cogwheel.
-- @treturn boolean True if the whole segment was built
local function buildSegment()
  restockPipes()
  for _ = 1, PIPES_PER_SEGMENT do
    if not stepAndPlaceUp(PIPE_SLOT) then
      return false
    end
  end

  return stepAndPlaceUp(COGWHEEL_SLOT)
end

turtle.refuel()
if turtle.getFuelLevel() == 0 then
  printError("No fuel")
  return
end

while not turtle.detect() do
  if not buildSegment() then
    print("Blocked, stopping.")
    break
  end
end

print("Done. Fuel left: " .. turtle.getFuelLevel())

