--- aeprobe: find out which inventory slots a peripheral exposes to CC.
--
-- Written for the AE2 Pattern Encoding Terminal, but works with any
-- inventory peripheral. Everything printed is also written to aeprobe.log,
-- so the result can be copied out of the game.
--
-- Note from the AE2 1.21.1 source (InitCapabilityProviders): the terminal
-- part registers an item handler for its blank-pattern slot only (1 slot,
-- accepts ae2:blank_pattern). The crafting/processing grid and the encoded
-- pattern slot are not registered there. This program checks what your
-- modpack actually exposes instead of trusting that reading.
-- Checked in game on Minecraft 1.21.1: CC sees the terminal as a peripheral
-- of type "ae2:cable_bus" with size() = 1 (the blank-pattern slot only).
--
-- @script aeprobe
-- @usage aeprobe                     -- list peripherals and their types
-- @usage aeprobe info [name]         -- methods, size, per-slot limit and item
-- @usage aeprobe watch [name]        -- live slot changes; Q stops
-- @usage aeprobe push <buffer> [name] -- try 1 item from buffer into each slot

--- AE2 parts (terminals, buses) show up as the cable bus block they sit on.
-- With several cable buses attached, pass the peripheral name explicitly.
local TARGET_TYPE = "ae2:cable_bus"
local LOG_PATH = "aeprobe.log"
local WATCH_INTERVAL = 0.5
local STOP_KEY = keys.q

local USAGE = [[
Usage:
  aeprobe                      list peripherals
  aeprobe info [name]          dump methods and slots
  aeprobe watch [name]         show slot changes (Q stops)
  aeprobe push <buffer> [name] insert 1 item per slot, then return it
Default name: first peripheral of type ]] .. TARGET_TYPE

-- Output ----------------------------------------------------------------------

local logHandle = fs.open(shell.resolve(LOG_PATH), "w")

--- Append a line to the log file, if it could be opened.
-- @tparam string text Line to store.
local function writeLog(text)
  if not logHandle then
    return
  end
  logHandle.writeLine(text)
  logHandle.flush()
end

--- Print a line and append it to the log file.
-- @tparam string text Line to output.
local function out(text)
  print(text)
  writeLog(text)
end

--- Raise an error without position info, so the user sees only the message.
-- @tparam string message Error text.
local function fail(message)
  error(message, 0)
end

--- Describe a slot entry from list() or getItemDetail().
-- @tparam[opt] table item Item table or nil for an empty slot.
-- @treturn string Text such as "3x ae2:blank_pattern" or "empty".
local function describeItem(item)
  if not item then
    return "empty"
  end
  return ("%dx %s"):format(item.count, item.name)
end

-- Peripheral lookup -----------------------------------------------------------

--- Get all types of a peripheral as a comma-separated string.
-- @tparam string name Peripheral name.
-- @treturn string Types, e.g. "minecraft:chest, inventory".
local function typesOf(name)
  return table.concat({ peripheral.getType(name) }, ", ")
end

--- Resolve the probed peripheral by explicit name or by TARGET_TYPE.
-- @tparam[opt] string name Peripheral name given by the user.
-- @treturn string Peripheral name.
-- @treturn table Wrapped peripheral.
-- @raise When nothing suitable is attached.
local function resolveTarget(name)
  if name then
    local wrapped = peripheral.wrap(name)
    if not wrapped then
      fail("No peripheral named " .. name)
    end
    return name, wrapped
  end
  local found = peripheral.find(TARGET_TYPE)
  if not found then
    fail("No " .. TARGET_TYPE .. " found; run 'aeprobe' to list names")
  end
  return peripheral.getName(found), found
end

--- Make sure a peripheral behaves like an inventory.
-- @tparam string name Peripheral name for the message.
-- @tparam table target Wrapped peripheral.
-- @raise When the peripheral has no size()/list().
local function assertInventory(name, target)
  if not (target.size and target.list) then
    fail(name .. " is not an inventory (types: " .. typesOf(name) .. ")")
  end
end

-- Commands --------------------------------------------------------------------

--- List every attached peripheral with all of its types.
local function runList()
  local names = peripheral.getNames()
  if #names == 0 then
    out("No peripherals attached")
    return
  end
  table.sort(names)
  for _, name in ipairs(names) do
    out(("%s: %s"):format(name, typesOf(name)))
  end
end

--- Dump methods, size and every slot of the target.
-- @tparam {string,...} args args[1] is an optional peripheral name.
local function runInfo(args)
  local name, target = resolveTarget(args[1])
  out("Name:    " .. name)
  out("Types:   " .. typesOf(name))
  local methods = peripheral.getMethods(name)
  table.sort(methods)
  out("Methods: " .. table.concat(methods, ", "))
  assertInventory(name, target)
  local size = target.size()
  out("Size:    " .. size)
  for slot = 1, size do
    local limit = target.getItemLimit(slot)
    local detail = target.getItemDetail(slot)
    out(("slot %2d  limit %-3d %s"):format(slot, limit, describeItem(detail)))
  end
end

--- Compare two list() snapshots and report changed slots.
-- @tparam table before Previous snapshot.
-- @tparam table after Current snapshot.
-- @tparam number size Number of slots to compare.
local function reportDiff(before, after, size)
  for slot = 1, size do
    local old, new = describeItem(before[slot]), describeItem(after[slot])
    if old ~= new then
      local clock = textutils.formatTime(os.time(), true)
      out(("[%s] slot %d: %s -> %s"):format(clock, slot, old, new))
    end
  end
end

--- Poll the target and print every slot change until Q is pressed.
-- Put or take items in the GUI: the printed slot number is the CC index.
-- No output for a GUI slot means CC does not see that slot at all.
-- @tparam {string,...} args args[1] is an optional peripheral name.
local function runWatch(args)
  local name, target = resolveTarget(args[1])
  assertInventory(name, target)
  local size = target.size()
  out(("Watching %s (%d slots). Change slots in the GUI, Q to stop.")
    :format(name, size))
  local snapshot = target.list()
  reportDiff({}, snapshot, size)
  local timer = os.startTimer(WATCH_INTERVAL)
  local running = true
  local handlers = {
    timer = function(id)
      if id ~= timer then
        return
      end
      local current = target.list()
      reportDiff(snapshot, current, size)
      snapshot = current
      timer = os.startTimer(WATCH_INTERVAL)
    end,
    key = function(code)
      running = code ~= STOP_KEY
    end,
    peripheral_detach = function(side)
      if side == name then
        out("Peripheral detached")
        running = false
      end
    end,
  }
  while running do
    local event = { os.pullEvent() }
    local handler = handlers[event[1]]
    if handler then
      handler(table.unpack(event, 2))
    end
  end
  out("Stopped")
end

--- Find the first non-empty slot of an inventory.
-- @tparam table inventory Wrapped inventory.
-- @treturn[opt] number Slot index, nil when the inventory is empty.
local function firstFilledSlot(inventory)
  local slots = {}
  for slot in pairs(inventory.list()) do
    slots[#slots + 1] = slot
  end
  table.sort(slots)
  return slots[1]
end

--- Try to move one item into a target slot and take it back.
-- @tparam table buffer Wrapped buffer inventory.
-- @tparam string bufferName Buffer peripheral name.
-- @tparam number fromSlot Buffer slot holding the test item.
-- @tparam table target Wrapped target inventory.
-- @tparam string targetName Target peripheral name.
-- @tparam number slot Target slot to test.
-- @treturn string Result line for this slot.
local function probeSlot(buffer, bufferName, fromSlot, target, targetName, slot)
  local okIn, moved = pcall(buffer.pushItems, targetName, fromSlot, 1, slot)
  if not okIn then
    return "error: " .. tostring(moved)
  end
  if moved == 0 then
    return "rejected"
  end
  local okBack, returned = pcall(target.pushItems, bufferName, slot, moved)
  if not okBack or returned < moved then
    return "ACCEPTED, but could not take it back - check the slot!"
  end
  return "accepted (returned)"
end

--- Insert one item from a buffer inventory into every target slot.
-- Use a blank pattern for the blank slot, any other item for the rest.
-- Both peripherals must be reachable from this computer (same wired network).
-- @tparam {string,...} args args[1] buffer name, args[2] optional target name.
local function runPush(args)
  local bufferName = args[1]
  if not bufferName then
    fail("Missing buffer inventory name")
  end
  local name, target = resolveTarget(args[2])
  assertInventory(name, target)
  local buffer = peripheral.wrap(bufferName)
  if not buffer then
    fail("No peripheral named " .. bufferName)
  end
  assertInventory(bufferName, buffer)
  local fromSlot = firstFilledSlot(buffer)
  if not fromSlot then
    fail("Buffer " .. bufferName .. " is empty")
  end
  local testItem = describeItem(buffer.list()[fromSlot])
  out(("Test item: %s (buffer slot %d)"):format(testItem, fromSlot))
  for slot = 1, target.size() do
    local result = probeSlot(buffer, bufferName, fromSlot, target, name, slot)
    out(("slot %2d: %s"):format(slot, result))
  end
end

--- Print usage.
local function runHelp()
  out(USAGE)
end

-- Dispatch --------------------------------------------------------------------

local COMMANDS = {
  info = runInfo,
  watch = runWatch,
  push = runPush,
  help = runHelp,
}

--- Entry point.
-- @tparam {string,...} argv Program arguments.
local function main(argv)
  if #argv == 0 then
    runList()
    return
  end
  local handler = COMMANDS[argv[1]]
  if not handler then
    fail("Unknown command: " .. argv[1] .. " (try: aeprobe help)")
  end
  handler({ table.unpack(argv, 2) })
end

local ok, err = pcall(main, { ... })
if not ok then
  printError(err)
  writeLog("ERROR: " .. tostring(err))
end
if logHandle then
  logHandle.close()
end
