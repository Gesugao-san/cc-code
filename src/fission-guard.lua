--- Fission reactor guard with a sodium-aware burn rate controller.
--
-- What it does:
--   * Watches the Mekanism fission reactor through its logic adapter
--     (temperature, damage, coolant, heated coolant, waste, fuel, burn).
--   * SCRAMs the reactor on any hazard, lowers the burn rate and then
--     waits for a manual start (START button, S key or the reactor GUI).
--   * Watches sodium stock in the ME system through an ME Bridge and
--     fits a model "stock change = supply - perBurn * burnRate".
--     The burn rate is kept below the point where the reactor would
--     consume sodium faster than the infinite source refills it.
--   * While sodium storage is full, extra supply is lost and the stock
--     change says nothing about the supply. Such windows are not learned
--     from and never lower the burn rate.
--   * Shows status on the computer and on a touch monitor (on top of the
--     computer by default) with SCRAM, START, AUTO/MANUAL and burn buttons.
--
-- Needs: Fission Reactor Logic Adapter, ME Bridge (Advanced Peripherals)
-- with Applied Mekanistics, both on this computer's wired network.
-- Optional: an Advanced Monitor for the touch screen.
--
-- Files: fission-guard.state keeps measurements between restarts
-- (delete it to recalibrate), fission-guard.log keeps events.
-- @script fission-guard

-- Configuration ----------------------------------------------------------

local CONFIG = {
  SODIUM = "mekanism:sodium",  -- chemical id in the ME system
  LOOP_SECONDS = 0.5,          -- safety check and stock sample period
  WINDOW_SECONDS = 10,         -- length of one measurement window
  MIN_WINDOW_POINTS = 4,       -- fewer stock samples in a window = no data
  SETTLE_WINDOWS = 1,          -- windows ignored after a burn change

  -- SCRAM limits; fractions are tank fill levels
  MAX_TEMPERATURE = 725,       -- deg C; damage starts at 1200 K (927 C)
  MIN_COOLANT = 0.99,          -- SCRAM when coolant is at or below this
  MAX_HEATED_COOLANT = 0.01,   -- SCRAM when heated coolant is at or above
  MAX_WASTE = 0.01,            -- SCRAM when waste is at or above this
  TRIP_BURN_FACTOR = 0.5,      -- burn rate multiplier after a SCRAM

  KNOWN_SUPPLY = 10 * 192000,  -- mB/t from the infinite sources (10 barrels);
                               -- nil = estimate it from the stock change
  MIN_STOCK = 10000,           -- mB of sodium kept in ME as a reserve
  MIN_BURN = 0.1,              -- mB/t
  BURN_LIMIT = nil,            -- manual upper limit, mB/t; nil = reactor max
  SAFETY_MARGIN = 0.99,        -- run at this share of the balance point
  DEADBAND = 0.05,             -- mB/t of stock change treated as noise
  DECREASE_FACTOR = 0.95,      -- burn step down while sodium drains
  INCREASE_FACTOR = 1.02,      -- burn step up while sodium accumulates
  MAX_STEP_UP = 1.05,          -- largest increase per window

  FULL_FREE_MB = 10000000,     -- free tank space (mB) still counted as full;
                               -- must exceed one tick of consumption
  FLAT_FRACTION = 0.02,        -- if free space is unknown: a stock change
                               -- below this share of consumption = full

  MAX_MODEL_SAMPLES = 20,      -- older measurements are forgotten
  MIN_MODEL_SAMPLES = 10,
  MIN_BURN_SPREAD = 0.1,       -- mB/t between lowest and highest sample
  MIN_FIT_R2 = 0.8,            -- how well samples must fit a straight line
  MIN_PER_BURN = 1,            -- mB of sodium per burn unit, sanity floor

  MONITOR_SIDE = "top",        -- preferred monitor; any monitor otherwise
  BURN_STEP_TINY = 0.01,       -- mB/t per press of -.01 / +.01
  BURN_STEP_SMALL = 0.1,       -- mB/t per press of -.1 / +.1
  BURN_STEP_BIG = 1,           -- mB/t per press of -1 / +1

  STATE_FILE = "fission-guard.state",
  LOG_FILE = "fission-guard.log",
}

local STATE_VERSION = 3 -- bump to discard calibration saved by old versions
local TICKS_PER_SECOND = 20
local KELVIN_OFFSET = 273.15
local DEGREE = "\176" -- degree sign in the CC font

-- Peripherals ------------------------------------------------------------

local reactor = peripheral.find("fissionReactorLogicAdapter")
  or error("No fission reactor logic adapter found", 0)
local bridge = peripheral.find("me_bridge") or peripheral.find("meBridge")
  or error("No ME Bridge found", 0)

-- Logging and persistence ------------------------------------------------

--- Appends a timestamped line to the log file.
-- @tparam string message Text to log
local function log(message)
  local file = fs.open(CONFIG.LOG_FILE, "a")
  if not file then
    return
  end

  file.writeLine(os.date("%Y-%m-%d %H:%M:%S") .. " " .. message)
  file.close()
end

--- Loads saved calibration; data from other versions is ignored.
-- @treturn table { samples = table, model = table|nil }
local function loadCalibration()
  local empty = { samples = {} }
  if not fs.exists(CONFIG.STATE_FILE) then
    return empty
  end

  local file = fs.open(CONFIG.STATE_FILE, "r")
  if not file then
    return empty
  end

  local data = textutils.unserialize(file.readAll())
  file.close()
  if type(data) ~= "table" or data.version ~= STATE_VERSION then
    return empty
  end
  if type(data.samples) ~= "table" then
    return empty
  end
  return data
end

--- Saves calibration so it survives restarts.
-- @tparam table samples Array of { burn = number, slope = number }
-- @tparam table|nil model Current model
local function saveCalibration(samples, model)
  local file = fs.open(CONFIG.STATE_FILE, "w")
  if not file then
    return
  end

  file.write(textutils.serialize({
    version = STATE_VERSION,
    samples = samples,
    model = model,
  }))
  file.close()
end

-- Sodium storage ---------------------------------------------------------

--- Ways to read a chemical amount, newest Advanced Peripherals first.
-- Each entry is used only if the bridge has its method.
local STOCK_READERS = {
  {
    method = "getChemical", -- AP 0.8+ (Minecraft 1.21.1)
    read = function()
      local chemical = bridge.getChemical({ name = CONFIG.SODIUM })
      if not chemical then
        return 0
      end
      return chemical.count or chemical.amount or 0
    end,
  },
  {
    method = "listGas", -- AP 0.7 and older
    read = function()
      for _, gas in ipairs(bridge.listGas() or {}) do
        if gas.name == CONFIG.SODIUM then
          return gas.amount or gas.count or 0
        end
      end
      return 0
    end,
  },
}

--- ME Bridge methods for free and used chemical space behind storage
-- buses (tanks such as a Dynamic Tank), in mB. Newer names first.
local SPACE_METHODS = {
  { free = "getAvailableExternalChemicalStorage",
    used = "getUsedExternalChemicalStorage" },
  { free = "getAvailableExternChemicalStorage",
    used = "getUsedExternChemicalStorage" },
}

--- Picks the stock reader supported by this ME Bridge.
-- @treturn function Function returning sodium stock in mB
local function pickStockReader()
  for _, reader in ipairs(STOCK_READERS) do
    if bridge[reader.method] then
      return reader.read
    end
  end
  error("ME Bridge has no chemical methods (Applied Mekanistics?)", 0)
end

--- Reader used when the bridge cannot report free space.
-- @treturn nil Always unknown
local function unknownSpace()
  return nil
end

--- Picks a reader of free chemical space, if the bridge supports one.
-- @treturn function Function returning free and capacity in mB, or nil
local function pickSpaceReader()
  for _, pair in ipairs(SPACE_METHODS) do
    if bridge[pair.free] and bridge[pair.used] then
      return function()
        local free, used = bridge[pair.free](), bridge[pair.used]()
        if type(free) ~= "number" or type(used) ~= "number" then
          return nil
        end
        local capacity = free + used
        if capacity <= 0 then
          return nil -- no tanks behind storage buses
        end
        return free, capacity
      end
    end
  end
  return unknownSpace
end

local readStock = pickStockReader()
local readSpace = pickSpaceReader()

--- Reads sodium stock and whether the sodium tank is full.
-- @treturn table|nil { stock = number, full = boolean|nil }, nil on error;
--   full is nil when free space is unknown
local function readStorage()
  local okStock, stock = pcall(readStock)
  if not okStock then
    return nil
  end

  local okSpace, free = pcall(readSpace)
  if not (okSpace and free) then
    return { stock = stock, full = nil }
  end
  return { stock = stock, full = free <= CONFIG.FULL_FREE_MB }
end

-- Reactor state ----------------------------------------------------------

--- Converts a stack and a capacity to a fill fraction.
-- Computed here because the adapter's percentage scale is not documented.
-- @tparam table|nil stack Chemical or fluid stack with an amount field
-- @tparam number capacity Tank capacity
-- @treturn number Fill fraction, 0..1
local function fraction(stack, capacity)
  if capacity <= 0 or type(stack) ~= "table" then
    return 0
  end
  return (stack.amount or 0) / capacity
end

--- Reads everything the guard needs from the reactor.
-- @treturn table Snapshot; only `formed` is set if the reactor is not formed
local function readReactor()
  if not reactor.isFormed() then
    return { formed = false }
  end

  return {
    formed = true,
    active = reactor.getStatus(),
    temperature = reactor.getTemperature() - KELVIN_OFFSET, -- deg C
    damage = reactor.getDamagePercent(),
    coolant = fraction(reactor.getCoolant(), reactor.getCoolantCapacity()),
    heated = fraction(reactor.getHeatedCoolant(),
      reactor.getHeatedCoolantCapacity()),
    waste = fraction(reactor.getWaste(), reactor.getWasteCapacity()),
    fuel = fraction(reactor.getFuel(), reactor.getFuelCapacity()),
    burnRate = reactor.getBurnRate(),
    actualBurn = reactor.getActualBurnRate(),
    maxBurn = reactor.getMaxBurnRate(),
  }
end

--- Reads the reactor without letting errors escape.
-- @treturn table|nil Snapshot of a formed reactor, or nil
local function safeReadReactor()
  local ok, snapshot = pcall(readReactor)
  if not ok or not snapshot.formed then
    return nil
  end
  return snapshot
end

-- Safety -----------------------------------------------------------------

--- Hazards that trigger a SCRAM, checked in order.
local SAFETY_RULES = {
  {
    isUnsafe = function(s) return s.temperature >= CONFIG.MAX_TEMPERATURE end,
    describe = function(s)
      return string.format("temperature %.0f %sC", s.temperature, DEGREE)
    end,
  },
  {
    isUnsafe = function(s) return s.damage > 0 end,
    describe = function(s) return string.format("damage %.1f", s.damage) end,
  },
  {
    isUnsafe = function(s) return s.coolant <= CONFIG.MIN_COOLANT end,
    describe = function(s)
      return string.format("coolant %.1f%%", s.coolant * 100)
    end,
  },
  {
    isUnsafe = function(s) return s.heated >= CONFIG.MAX_HEATED_COOLANT end,
    describe = function(s)
      return string.format("heated coolant %.1f%%", s.heated * 100)
    end,
  },
  {
    isUnsafe = function(s) return s.waste >= CONFIG.MAX_WASTE end,
    describe = function(s)
      return string.format("waste %.1f%%", s.waste * 100)
    end,
  },
}

--- Finds the first hazard in a snapshot.
-- @tparam table snapshot Reactor snapshot
-- @treturn string|nil Hazard description, or nil if safe
local function findHazard(snapshot)
  for _, rule in ipairs(SAFETY_RULES) do
    if rule.isUnsafe(snapshot) then
      return rule.describe(snapshot)
    end
  end
  return nil
end

-- Math -------------------------------------------------------------------

--- Least-squares line through points.
-- @tparam table points Array of { x = number, y = number }
-- @treturn number|nil Slope, or nil if x has no spread
-- @treturn number Mean x
-- @treturn number Mean y
-- @treturn number Coefficient of determination R^2, 0..1
local function linearFit(points)
  local n = #points
  if n < 2 then
    return nil
  end

  local sumX, sumY = 0, 0
  for _, p in ipairs(points) do
    sumX, sumY = sumX + p.x, sumY + p.y
  end
  local meanX, meanY = sumX / n, sumY / n

  local sxx, sxy, syy = 0, 0, 0
  for _, p in ipairs(points) do
    local dx, dy = p.x - meanX, p.y - meanY
    sxx, sxy, syy = sxx + dx * dx, sxy + dx * dy, syy + dy * dy
  end

  if sxx == 0 then
    return nil
  end
  local r2 = syy > 0 and (sxy * sxy) / (sxx * syy) or 0
  return sxy / sxx, meanX, meanY, r2
end

--- Builds a model from supply and consumption, if they make sense.
-- @tparam number supply Sodium supply, mB/t
-- @tparam number perBurn Sodium consumed per 1 mB/t of burn
-- @treturn table|nil { supply, perBurn, balance }
local function makeModel(supply, perBurn)
  if supply <= 0 or perBurn < CONFIG.MIN_PER_BURN then
    return nil
  end
  return { supply = supply, perBurn = perBurn, balance = supply / perBurn }
end

--- Median of an array of numbers.
-- @tparam table values Numbers, not empty
-- @treturn number Median
local function median(values)
  local sorted = { table.unpack(values) }
  table.sort(sorted)
  local n = #sorted
  if n % 2 == 1 then
    return sorted[(n + 1) / 2]
  end
  return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

--- Estimates consumption per burn unit when the supply is known:
-- perBurn = (supply - slope) / burn for every sample, median of them.
-- @tparam table samples Array of { burn = number, slope = number }
-- @treturn table|nil Model
local function fitKnownSupply(samples)
  local supply = CONFIG.KNOWN_SUPPLY
  local estimates = {}
  for _, sample in ipairs(samples) do
    if sample.burn >= CONFIG.MIN_BURN then
      table.insert(estimates, (supply - sample.slope) / sample.burn)
    end
  end
  if #estimates < CONFIG.MIN_MODEL_SAMPLES then
    return nil
  end
  return makeModel(supply, median(estimates))
end

--- Fits "slope = supply - perBurn * burn" to measurements.
-- With KNOWN_SUPPLY only perBurn is estimated.
-- @tparam table samples Array of { burn = number, slope = number }
-- @treturn table|nil Model, or nil if data is missing or inconsistent
local function fitModel(samples)
  if #samples < CONFIG.MIN_MODEL_SAMPLES then
    return nil
  end
  if CONFIG.KNOWN_SUPPLY then
    return fitKnownSupply(samples)
  end

  local points, minBurn, maxBurn = {}, math.huge, -math.huge
  for _, sample in ipairs(samples) do
    table.insert(points, { x = sample.burn, y = sample.slope })
    minBurn = math.min(minBurn, sample.burn)
    maxBurn = math.max(maxBurn, sample.burn)
  end

  if maxBurn - minBurn < CONFIG.MIN_BURN_SPREAD then
    return nil
  end

  local m, meanBurn, meanSlope, r2 = linearFit(points)
  if not m or m >= 0 or r2 < CONFIG.MIN_FIT_R2 then
    return nil -- more burn must clearly consume more sodium
  end

  local perBurn = -m
  return makeModel(meanSlope + perBurn * meanBurn, perBurn)
end

--- Re-estimates supply with a known consumption per burn unit.
-- Used when recent samples cannot be fitted on their own: consumption per
-- burn is physics and stays, supply may drift.
-- @tparam table model Previous model
-- @tparam table samples Array of { burn = number, slope = number }
-- @treturn table|nil Updated model, or nil if the estimate makes no sense
local function refitSupply(model, samples)
  local recent = math.min(#samples, CONFIG.MIN_MODEL_SAMPLES)
  if recent == 0 then
    return nil
  end

  local sum = 0
  for i = #samples - recent + 1, #samples do
    sum = sum + samples[i].slope + model.perBurn * samples[i].burn
  end
  return makeModel(sum / recent, model.perBurn)
end

--- Checks that a saved model is usable.
-- @param model Anything loaded from the state file
-- @treturn table|nil The model if valid
local function validModel(model)
  if type(model) ~= "table" then
    return nil
  end
  if type(model.supply) ~= "number" or type(model.perBurn) ~= "number" then
    return nil
  end
  return makeModel(model.supply, model.perBurn)
end

--- Rounds a burn rate to 0.01 mB/t.
-- @tparam number value Burn rate
-- @treturn number Rounded burn rate
local function roundBurn(value)
  return math.floor(value * 100 + 0.5) / 100
end

--- Limits a burn rate to what the reactor and config allow.
-- @tparam number rate Wanted burn rate, mB/t
-- @tparam table snapshot Reactor snapshot
-- @treturn number Allowed burn rate
local function clampBurn(rate, snapshot)
  local limit = math.min(snapshot.maxBurn,
    CONFIG.BURN_LIMIT or snapshot.maxBurn)
  return roundBurn(math.max(CONFIG.MIN_BURN, math.min(rate, limit)))
end

-- Controller -------------------------------------------------------------

local calibration = loadCalibration()

local state = {
  samples = calibration.samples,
  model = nil,
  auto = true,         -- automatic burn calibration
  trip = nil,          -- SCRAM reason while waiting for a manual start
  settle = 0,          -- windows left to ignore
  window = nil,
  snapshot = nil,      -- last reactor snapshot
  stock = nil,
  full = nil,          -- storage full right now; nil if unknown
  overflow = false,    -- last window had sodium overflowing
  slope = nil,         -- last measured stock change, mB/t
  lastAction = "starting",
}
state.model = fitModel(state.samples) or validModel(calibration.model)

--- Starts a new measurement window.
local function resetWindow()
  state.window = {
    startTime = nil,   -- os.clock() of the first sample
    points = {},
    burnSum = 0,
    active = nil,
    burnRate = nil,
    clean = true,
    openPoints = {},   -- samples taken while the tank was not full
    sawFull = false,   -- tank was full at least once
    knowsFull = true,  -- every sample knew whether the tank was full
  }
end

--- Sets the burn rate and starts settling.
-- @tparam number rate New burn rate, mB/t
-- @tparam string reason Why the rate changed
local function applyBurn(rate, reason)
  local ok, err = pcall(reactor.setBurnRate, rate)
  if not ok then
    state.lastAction = "setBurnRate failed: " .. tostring(err)
    log(state.lastAction)
    return
  end

  state.settle = CONFIG.SETTLE_WINDOWS
  state.lastAction = string.format("burn %.2f (%s)", rate, reason)
  log(state.lastAction)
end

--- SCRAMs the reactor and lowers the burn rate for the next start.
-- @tparam table snapshot Reactor snapshot
-- @tparam string reason Hazard description
local function trip(snapshot, reason)
  pcall(reactor.scram)
  state.trip = reason
  log("SCRAM: " .. reason)
  applyBurn(clampBurn(snapshot.burnRate * CONFIG.TRIP_BURN_FACTOR, snapshot),
    "after SCRAM")
end

--- Chooses a burn rate while the sodium tank is full.
-- The source overflows, so the real supply is hidden: never go down.
-- If the total stock still drains, ME takes sodium from other storage
-- (cells) first, so hold until that is used up.
-- @tparam number current Current burn rate, mB/t
-- @tparam number slope Total stock change, mB/t
-- @treturn number Wanted burn rate
-- @treturn string Reason
local function overflowBurn(current, slope)
  if slope < -CONFIG.DEADBAND then
    return current, "tank full, ME draining other storage"
  end

  local model = state.model
  if not model then
    return math.max(current * CONFIG.INCREASE_FACTOR,
      current + CONFIG.MIN_BURN), "storage full, probing"
  end

  local target = math.max(model.balance * CONFIG.SAFETY_MARGIN, current)
  return math.min(target, current * CONFIG.MAX_STEP_UP), "storage full"
end

--- Chooses a burn rate when no model is known yet.
-- @tparam number current Current burn rate, mB/t
-- @tparam number slope Stock change, mB/t
-- @treturn number Wanted burn rate
-- @treturn string Reason
local function noModelBurn(current, slope)
  if slope < -CONFIG.DEADBAND then
    return current * CONFIG.DECREASE_FACTOR, "sodium draining"
  end
  if slope > CONFIG.DEADBAND then
    return math.max(current * CONFIG.INCREASE_FACTOR,
      current + CONFIG.MIN_BURN), "sodium surplus"
  end
  return current, "balanced"
end

--- Chooses a burn rate from the latest measurement.
-- @tparam number current Current burn rate, mB/t
-- @tparam number slope Stock change, mB/t
-- @tparam boolean overflow Storage was full during the window
-- @treturn number Wanted burn rate
-- @treturn string Reason
local function chooseBurn(current, slope, overflow)
  if (state.stock or 0) < CONFIG.MIN_STOCK then
    return current * 0.5, "sodium reserve low"
  end
  if overflow then
    return overflowBurn(current, slope)
  end

  local model = state.model
  if not model then
    return noModelBurn(current, slope)
  end

  local target = model.balance * CONFIG.SAFETY_MARGIN
  if slope < -CONFIG.DEADBAND then
    target = math.min(target, current * CONFIG.DECREASE_FACTOR)
  elseif slope > CONFIG.DEADBAND then
    target = math.max(target, current)
  end
  return math.min(target, current * CONFIG.MAX_STEP_UP), "model"
end

--- Applies a new burn rate if it differs enough.
-- @tparam table snapshot Reactor snapshot
-- @tparam number slope Stock change, mB/t
-- @tparam boolean overflow Storage was full during the window
local function calibrate(snapshot, slope, overflow)
  local wanted, reason = chooseBurn(snapshot.burnRate, slope, overflow)
  local rate = clampBurn(wanted, snapshot)
  if math.abs(rate - snapshot.burnRate) < 0.01 then
    state.lastAction = "holding (" .. reason .. ")"
    return
  end

  applyBurn(rate, reason)
end

--- Stores a measurement and refits the model.
-- @tparam number burn Average actual burn rate during the window
-- @tparam number slope Stock change, mB/t
local function recordSample(burn, slope)
  table.insert(state.samples, { burn = burn, slope = slope })
  while #state.samples > CONFIG.MAX_MODEL_SAMPLES do
    table.remove(state.samples, 1)
  end

  local fitted = fitModel(state.samples)
  if fitted then
    state.model = fitted
  elseif state.model and not CONFIG.KNOWN_SUPPLY then
    state.model = refitSupply(state.model, state.samples) or state.model
  end
  saveCalibration(state.samples, state.model)
end

--- Stock change that cannot be told apart from "storage is full".
-- Used only when the bridge cannot report free space.
-- @tparam number burn Average actual burn rate during the window
-- @treturn number Threshold, mB/t
local function flatThreshold(burn)
  local model = state.model
  if not model then
    return CONFIG.DEADBAND
  end
  return math.max(CONFIG.DEADBAND, CONFIG.FLAT_FRACTION * model.perBurn * burn)
end

--- Tells whether sodium overflowed during a window.
-- @tparam table window Finished window
-- @tparam number slope Stock change, mB/t
-- @tparam number burn Average actual burn rate during the window
-- @treturn boolean True if the window must not be learned from
local function isOverflow(window, slope, burn)
  if window.knowsFull then
    return window.sawFull
  end
  return math.abs(slope) <= flatThreshold(burn)
end

--- Learns from the part of a window where the tank was not full,
-- if that part is long enough.
-- @tparam table window Finished window
-- @tparam number burn Average actual burn rate during the window
local function recordOpenPart(window, burn)
  if not window.knowsFull then
    return
  end
  local needed = math.max(CONFIG.MIN_WINDOW_POINTS, #window.points / 2)
  if #window.openPoints < needed then
    return
  end

  local perSecond = linearFit(window.openPoints)
  if perSecond then
    recordSample(burn, perSecond / TICKS_PER_SECOND)
  end
end

--- Closes the current window: measures, learns and calibrates.
-- @tparam table snapshot Reactor snapshot
local function finishWindow(snapshot)
  local window = state.window
  resetWindow()

  if state.settle > 0 then
    state.settle = state.settle - 1
    return
  end
  if not window.clean then
    return
  end

  if #window.points < CONFIG.MIN_WINDOW_POINTS then
    return
  end
  local perSecond = linearFit(window.points)
  if not perSecond then
    return
  end

  local slope = perSecond / TICKS_PER_SECOND
  local burn = window.burnSum / #window.points
  local overflow = isOverflow(window, slope, burn)
  state.slope, state.overflow = slope, overflow
  if not overflow then
    recordSample(burn, slope)
  else
    recordOpenPart(window, burn)
  end

  if snapshot.active and state.auto and not state.trip then
    calibrate(snapshot, slope, overflow)
  end
end

--- Adds one storage sample to the current window.
-- @tparam table snapshot Reactor snapshot
-- @tparam table|nil storage Result of readStorage
local function addSample(snapshot, storage)
  local window = state.window
  if not storage then
    window.clean = false
    return
  end

  if window.active == nil then
    window.active, window.burnRate = snapshot.active, snapshot.burnRate
  end
  if window.active ~= snapshot.active
    or window.burnRate ~= snapshot.burnRate then
    window.clean = false -- someone changed the reactor mid-window
  end

  local point = { x = os.clock(), y = storage.stock }
  window.startTime = window.startTime or point.x
  window.sawFull = window.sawFull or storage.full == true
  window.knowsFull = window.knowsFull and storage.full ~= nil
  table.insert(window.points, point)
  if storage.full == false then
    table.insert(window.openPoints, point)
  end
  window.burnSum = window.burnSum + (snapshot.active and snapshot.actualBurn
    or 0)
end

-- Manual controls --------------------------------------------------------

--- Starts the reactor if it is stopped and safe.
local function startReactor()
  local snapshot = safeReadReactor()
  if not snapshot then
    state.lastAction = "start refused: reactor unavailable"
    return
  end
  if snapshot.active then
    state.lastAction = "already running"
    return
  end

  local hazard = findHazard(snapshot)
  if hazard then
    state.lastAction = "start refused: " .. hazard
    return
  end
  if not pcall(reactor.activate) then
    state.lastAction = "start failed"
    return
  end

  state.trip = nil
  state.lastAction = "started manually"
  log("Started manually from the guard")
end

--- SCRAMs the reactor by hand; it then waits for a manual start.
local function manualScram()
  local snapshot = safeReadReactor()
  if not (snapshot and snapshot.active) then
    state.lastAction = "already stopped"
    return
  end

  pcall(reactor.scram)
  state.trip = "manual SCRAM"
  state.lastAction = "manual SCRAM"
  log("SCRAM: manual")
end

--- Switches between automatic and manual burn control.
local function toggleMode()
  state.auto = not state.auto
  state.lastAction = state.auto and "auto calibration on"
    or "manual burn control"
  log(state.lastAction)
end

--- Makes a button action that changes the burn rate by a step.
-- Changing the burn by hand switches to manual control.
-- @tparam number delta Step, mB/t
-- @treturn function Action
local function burnStep(delta)
  return function()
    local snapshot = safeReadReactor()
    if not snapshot then
      return
    end
    state.auto = false
    applyBurn(clampBurn(snapshot.burnRate + delta, snapshot), "manual")
  end
end

--- Picks a color pair by whether a button can be used now.
-- @tparam boolean enabled Button is usable
-- @tparam number background Background color when usable
-- @tparam number text Text color when usable
-- @treturn number Background color
-- @treturn number Text color
local function enabledColors(enabled, background, text)
  if enabled then
    return background, text
  end
  return colors.gray, colors.lightGray
end

--- On-screen buttons, left to right.
-- style(snapshot) returns label, background and text colors.
local BUTTONS = {
  {
    id = "scram",
    press = manualScram,
    style = function(s)
      return " SCRAM ", enabledColors(s.active, colors.red, colors.white)
    end,
  },
  {
    id = "start",
    press = startReactor,
    style = function(s)
      return " START ", enabledColors(not s.active, colors.lime, colors.black)
    end,
  },
  {
    id = "mode",
    press = toggleMode,
    style = function()
      if state.auto then
        return "  AUTO  ", colors.cyan, colors.black
      end
      return " MANUAL ", colors.orange, colors.black
    end,
  },
}

--- Makes a gray burn step button.
-- @tparam string id Button id
-- @tparam string text Label
-- @tparam number delta Step, mB/t
-- @treturn table Button definition
local function stepButton(id, text, delta)
  return {
    id = id,
    press = burnStep(delta),
    style = function() return text, colors.gray, colors.white end,
  }
end

--- Second button row: burn steps, down on the left, up on the right.
local STEP_BUTTONS = {
  stepButton("downBig", " -1 ", -CONFIG.BURN_STEP_BIG),
  stepButton("downSmall", " -.1 ", -CONFIG.BURN_STEP_SMALL),
  stepButton("downTiny", " -.01 ", -CONFIG.BURN_STEP_TINY),
  stepButton("upTiny", " +.01 ", CONFIG.BURN_STEP_TINY),
  stepButton("upSmall", " +.1 ", CONFIG.BURN_STEP_SMALL),
  stepButton("upBig", " +1 ", CONFIG.BURN_STEP_BIG),
}

--- Button rows, top to bottom.
local BUTTON_ROWS = { BUTTONS, STEP_BUTTONS }

local BUTTONS_BY_ID = {}
for _, buttonRow in ipairs(BUTTON_ROWS) do
  for _, button in ipairs(buttonRow) do
    BUTTONS_BY_ID[button.id] = button
  end
end

-- Formatting -------------------------------------------------------------

--- Suffixes for large amounts, biggest first.
local AMOUNT_UNITS = {
  { size = 1e9, suffix = "G" },
  { size = 1e6, suffix = "M" },
  { size = 1e3, suffix = "k" },
}

--- Formats a number compactly, e.g. 1537531.4 -> "1.54M".
-- @tparam number value Number to format
-- @treturn string Text
local function formatAmount(value)
  local magnitude = math.abs(value)
  for _, unit in ipairs(AMOUNT_UNITS) do
    if magnitude >= unit.size then
      return string.format("%.2f%s", value / unit.size, unit.suffix)
    end
  end
  return string.format("%.2f", value)
end

--- Formats a number compactly with an explicit sign.
-- @tparam number value Number to format
-- @treturn string Text such as "+811.47k"
local function formatSigned(value)
  local sign = value >= 0 and "+" or ""
  return sign .. formatAmount(value)
end

--- Risk colors by how close a value is to its trip limit, worst first.
local RISK_TIERS = {
  { from = 0.9, color = colors.red },
  { from = 0.6, color = colors.yellow },
}

--- Fuel share treated as "almost empty" on screen (no SCRAM for it).
local FUEL_DISPLAY_LIMIT = 0.05

--- Picks a color for a risk ratio (0 = safe, 1 = at the limit).
-- @tparam number ratio Closeness to the limit
-- @treturn number Color
local function riskColor(ratio)
  for _, tier in ipairs(RISK_TIERS) do
    if ratio >= tier.from then
      return tier.color
    end
  end
  return colors.lime
end

--- Color for a value where higher is worse (temperature, waste).
-- @tparam number value Current value
-- @tparam number limit Trip limit
-- @treturn number Color
local function highRisk(value, limit)
  return riskColor(value / limit)
end

--- Color for a tank that should stay full (coolant): 1.0 is safe,
-- the trip level is the limit.
-- @tparam number value Current fill, 0..1
-- @tparam number limit Trip fill level
-- @treturn number Color
local function depletionRisk(value, limit)
  return riskColor((1 - value) / math.max(1 - limit, 1e-9))
end

--- Color for a value where lower is worse (fuel).
-- @tparam number value Current value
-- @tparam number limit Lowest acceptable value
-- @treturn number Color
local function lowRisk(value, limit)
  return riskColor(limit / math.max(value, 1e-9))
end

-- Screen content ---------------------------------------------------------

--- Describes the reactor state for the header.
-- @tparam table snapshot Reactor snapshot
-- @treturn string Text
-- @treturn number Color
local function headerText(snapshot)
  if state.trip then
    return "TRIPPED: " .. state.trip, colors.red
  end
  if snapshot.active then
    return "RUNNING", colors.lime
  end
  return "OFF", colors.yellow
end

--- Number with a fixed count of digits; leading zeros are dimmed.
-- @tparam number value Non-negative number, rounded to an integer
-- @tparam number width Digits to show
-- @tparam number color Color of the significant digits
-- @treturn table Segments
local function padded(value, width, color)
  local digits = string.format("%0" .. width .. ".0f", math.max(0, value))
  local zeros = digits:match("^0*")
  if #zeros == #digits then
    zeros = zeros:sub(2) -- a plain zero keeps its last digit bright
  end
  return { { zeros, colors.gray }, { digits:sub(#zeros + 1), color } }
end

--- Zero-padded percentage segments, e.g. dim "0" + "87%".
-- @tparam number value Fraction, 0..1
-- @tparam number color Color of the value
-- @treturn table Segments
local function paddedPercent(value, color)
  local segments = padded(value * 100, 3, color)
  table.insert(segments, { "%", color })
  return segments
end

--- A value followed by a dim unit, e.g. "9.23" + " set".
-- @tparam string value Value text
-- @tparam number color Value color
-- @tparam string unit Unit text
-- @treturn table Segments
local function withUnit(value, color, unit)
  return { { value, color }, { unit, colors.gray } }
end

--- Total length of the text in segments.
-- @tparam table segments Array of { text, color }
-- @treturn number Characters
local function segmentsLength(segments)
  local length = 0
  for _, segment in ipairs(segments) do
    length = length + #segment[1]
  end
  return length
end

--- Cuts segments to a width.
-- @tparam table segments Array of { text, color }
-- @tparam number width Characters allowed
-- @treturn table Segments that fit
local function clipSegments(segments, width)
  local result, used = {}, 0
  for _, segment in ipairs(segments) do
    local text = segment[1]:sub(1, width - used)
    table.insert(result, { text, segment[2] })
    used = used + #text
  end
  return result
end

--- Appends segments to a row.
-- @tparam table target Row being built
-- @tparam table segments Segments to add
local function appendSegments(target, segments)
  for _, segment in ipairs(segments) do
    table.insert(target, segment)
  end
end

--- One table row: cells padded to column widths between gray pipes.
-- Leading columns are left-aligned (names, text), the rest right-aligned.
-- @tparam table widths Inner widths of the columns
-- @tparam table cells Segment arrays, one per column
-- @tparam[opt=1] number leftColumns How many columns are left-aligned
-- @treturn table Segments
local function tableRow(widths, cells, leftColumns)
  leftColumns = leftColumns or 1
  local result = { { "| ", colors.gray } }
  for i, width in ipairs(widths) do
    local cell = clipSegments(cells[i] or {}, width)
    local gap = { string.rep(" ", width - segmentsLength(cell)) }
    local left = i <= leftColumns
    if not left then
      table.insert(result, gap)
    end
    appendSegments(result, cell)
    if left then
      table.insert(result, gap)
    end
    table.insert(result, { i < #widths and " | " or " |", colors.gray })
  end
  return result
end

--- Table ruler such as "|-------|---------|".
-- @tparam table widths Inner widths of the columns
-- @treturn table Segments
local function tableRuler(widths)
  local parts = {}
  for _, width in ipairs(widths) do
    table.insert(parts, string.rep("-", width + 2))
  end
  return { { "|" .. table.concat(parts, "|") .. "|", colors.gray } }
end

--- Plain text cell.
-- @tparam string text Text
-- @tparam[opt] number color Color, light gray by default
-- @treturn table Segments
local function textCell(text, color)
  return { { text, color or colors.lightGray } }
end

--- Column widths of the parameter table: PARAM, VALUE, TRIP.
local PARAM_WIDTHS = { 5, 7, 7 }

--- Parameter table rows: name, value cell and SCRAM limit.
local PARAM_ROWS = {
  {
    name = "COOL",
    value = function(s)
      return paddedPercent(s.coolant,
        depletionRisk(s.coolant, CONFIG.MIN_COOLANT))
    end,
    trip = function()
      return string.format("<=%.0f%%", CONFIG.MIN_COOLANT * 100)
    end,
  },
  {
    name = "HEAT",
    value = function(s)
      return paddedPercent(s.heated,
        highRisk(s.heated, CONFIG.MAX_HEATED_COOLANT))
    end,
    trip = function()
      return string.format(">=%.0f%%", CONFIG.MAX_HEATED_COOLANT * 100)
    end,
  },
  {
    name = "WASTE",
    value = function(s)
      return paddedPercent(s.waste, highRisk(s.waste, CONFIG.MAX_WASTE))
    end,
    trip = function()
      return string.format(">=%.0f%%", CONFIG.MAX_WASTE * 100)
    end,
  },
  {
    name = "TMP",
    value = function(s)
      local color = highRisk(s.temperature, CONFIG.MAX_TEMPERATURE)
      local segments = padded(s.temperature, 4, color)
      table.insert(segments, { " " .. DEGREE .. "C", color })
      return segments
    end,
    trip = function()
      return string.format(">=%.0f%sC", CONFIG.MAX_TEMPERATURE, DEGREE)
    end,
  },
  {
    name = "DMG",
    value = function(s)
      return textCell(string.format("%.1f", s.damage),
        s.damage > 0 and colors.red or colors.lime)
    end,
    trip = function() return ">0" end,
  },
  {
    name = "FUEL",
    value = function(s)
      return paddedPercent(s.fuel, lowRisk(s.fuel, FUEL_DISPLAY_LIMIT))
    end,
    trip = function() return "-" end,
  },
}

--- Column widths of the control table: name and three values.
local CONTROL_WIDTHS = { 5, 11, 11, 11 }

--- Cells of the sodium row.
-- @treturn table Cells
local function sodiumCells()
  local slope = state.slope
  local slopeColor = (slope or 0) >= 0 and colors.lime or colors.red
  return {
    textCell("NA"),
    withUnit(state.stock and formatAmount(state.stock) or "?", colors.white,
      " mB"),
    withUnit(slope and formatSigned(slope) or "?", slopeColor, "/t"),
    state.full and textCell("FULL", colors.cyan) or {},
  }
end

--- Cells of the calibration model row.
-- @treturn table Cells
local function modelCells()
  local model = state.model
  if not model then
    return {
      textCell("MODEL"),
      textCell("collecting", colors.gray),
      textCell(string.format("%d/%d", #state.samples,
        CONFIG.MIN_MODEL_SAMPLES), colors.gray),
      {},
    }
  end
  return {
    textCell("MODEL"),
    withUnit(formatSigned(model.supply), colors.lime, "/t"),
    withUnit("-" .. formatAmount(model.perBurn), colors.orange, "/b"),
    withUnit(string.format("%.2f", model.balance), colors.cyan, " bal"),
  }
end

--- Builds all status rows for a snapshot.
-- @tparam table s Reactor snapshot
-- @treturn table Array of rows; each row is an array of { text, color }
local function contentRows(s)
  local header, headerColor = headerText(s)
  local line = { { string.rep("-", 200), colors.gray } }
  local rows = {
    { { "FISSION GUARD", colors.lightBlue }, { " / ", colors.gray },
      { header, headerColor } },
    line,
    tableRow(PARAM_WIDTHS, { textCell("PARAM"), textCell("VALUE"),
      textCell("TRIP") }),
    tableRuler(PARAM_WIDTHS),
  }

  for _, param in ipairs(PARAM_ROWS) do
    table.insert(rows, tableRow(PARAM_WIDTHS, { textCell(param.name),
      param.value(s), textCell(param.trip(), colors.gray) }))
  end

  local lastWidth = CONTROL_WIDTHS[2] + CONTROL_WIDTHS[3]
    + CONTROL_WIDTHS[4] + 6
  appendSegments(rows, {
    line,
    tableRow(CONTROL_WIDTHS, {
      textCell("BURN"),
      withUnit(string.format("%.2f", s.burnRate), colors.orange, " set"),
      withUnit(string.format("%.2f", s.actualBurn), colors.white, " act"),
      withUnit(string.format("%.0f", s.maxBurn), colors.white, " max"),
    }),
    tableRow(CONTROL_WIDTHS, sodiumCells()),
    tableRow(CONTROL_WIDTHS, modelCells()),
    tableRow({ CONTROL_WIDTHS[1], lastWidth }, { textCell("LAST"),
      textCell(state.lastAction, colors.lightGray) }, 2),
  })
  return rows
end

-- Screens ----------------------------------------------------------------

local LAYOUT_WIDTH = 51       -- widest content row
local CONTENT_ROWS = 15       -- rows returned by contentRows
local TOUCH_BUTTON_HEIGHT = 3 -- button height on a big enough monitor

--- Rows a screen needs for content and button rows, each after a gap.
-- @tparam number buttonHeight Button height in rows
-- @treturn number Rows
local function neededRows(buttonHeight)
  return CONTENT_ROWS + #BUTTON_ROWS * (1 + buttonHeight)
end

--- Sets a color if the device can show colors.
-- @tparam table device Terminal or monitor
-- @tparam string kind "setTextColor" or "setBackgroundColor"
-- @tparam number color Color from the colors API
local function paint(device, kind, color)
  if device.isColor() then
    device[kind](color)
  end
end

--- Writes one row of colored segments, cut to the device width.
-- @tparam table device Terminal or monitor
-- @tparam number y Row
-- @tparam table segments Array of { text, color }
local function row(device, y, segments)
  local width = device.getSize()
  device.setCursorPos(1, y)
  paint(device, "setBackgroundColor", colors.black)
  device.clearLine()

  local used = 0
  for _, segment in ipairs(segments) do
    local text = segment[1]:sub(1, width - used)
    paint(device, "setTextColor", segment[2] or colors.white)
    device.write(text)
    used = used + #text
  end
  paint(device, "setTextColor", colors.white)
end

--- Draws one button and returns its touch area.
-- @tparam table screen Screen
-- @tparam table button Button definition
-- @tparam table snapshot Reactor snapshot
-- @tparam number left First column
-- @tparam number top First row
-- @treturn table|nil Touch area, or nil if the button does not fit
local function drawButton(screen, button, snapshot, left, top)
  local device = screen.device
  local text, background, foreground = button.style(snapshot)
  local right = left + #text - 1
  if right > device.getSize() then
    return nil
  end

  local height = screen.buttonHeight
  local middle = math.floor((height - 1) / 2)
  paint(device, "setBackgroundColor", background)
  paint(device, "setTextColor", foreground)
  for dy = 0, height - 1 do
    device.setCursorPos(left, top + dy)
    device.write(dy == middle and text or string.rep(" ", #text))
  end

  return { id = button.id, left = left, right = right, top = top,
    bottom = top + height - 1 }
end

--- Draws one row of buttons and adds their touch areas to the screen.
-- @tparam table screen Screen
-- @tparam table buttons Button definitions, left to right
-- @tparam table snapshot Reactor snapshot
-- @tparam number top First row of the button row
local function drawButtonRow(screen, buttons, snapshot, top)
  local device = screen.device
  for dy = 0, screen.buttonHeight - 1 do
    row(device, top + dy, {})
  end

  local left = 1
  for _, button in ipairs(buttons) do
    local box = drawButton(screen, button, snapshot, left, top)
    if not box then
      break
    end
    table.insert(screen.boxes, box)
    left = box.right + 2
  end
  paint(device, "setBackgroundColor", colors.black)
  paint(device, "setTextColor", colors.white)
end

--- Draws all button rows, each after a blank row.
-- @tparam table screen Screen
-- @tparam table snapshot Reactor snapshot
-- @tparam number top Row right after the content
local function drawButtons(screen, snapshot, top)
  screen.boxes = {}
  for _, buttons in ipairs(BUTTON_ROWS) do
    row(screen.device, top, {})
    drawButtonRow(screen, buttons, snapshot, top + 1)
    top = top + 1 + screen.buttonHeight
  end
end

--- Draws the full status screen with buttons.
-- @tparam table screen Screen
-- @tparam table snapshot Reactor snapshot
local function drawStatus(screen, snapshot)
  for y, segments in ipairs(contentRows(snapshot)) do
    row(screen.device, y, segments)
  end
  drawButtons(screen, snapshot, CONTENT_ROWS + 1)
end

--- Draws the "reactor unavailable" screen without buttons.
-- @tparam table screen Screen
local function drawUnavailable(screen)
  local device = screen.device
  paint(device, "setBackgroundColor", colors.black)
  device.clear()
  row(device, 1, { { "FISSION GUARD", colors.lightBlue },
    { " / ", colors.gray }, { "reactor unavailable", colors.red } })
  screen.boxes = {}
end

--- Picks the largest text scale that fits the layout with tall buttons.
-- @tparam table monitor Monitor peripheral
local function fitTextScale(monitor)
  for scale = 5, 0.5, -0.5 do
    monitor.setTextScale(scale)
    local width, height = monitor.getSize()
    if width >= LAYOUT_WIDTH and height >= neededRows(TOUCH_BUTTON_HEIGHT) then
      return
    end
  end
  monitor.setTextScale(0.5)
end

--- Sets the monitor scale, button height and clears it.
-- @tparam table screen Monitor screen
local function prepareMonitor(screen)
  local device = screen.device
  fitTextScale(device)
  local _, height = device.getSize()
  screen.buttonHeight = height >= neededRows(TOUCH_BUTTON_HEIGHT)
    and TOUCH_BUTTON_HEIGHT or 1
  paint(device, "setBackgroundColor", colors.black)
  device.clear()
end

--- Finds the touch monitor, preferring the configured side.
-- @treturn table|nil Monitor peripheral
-- @treturn string|nil Its peripheral name
local function findMonitor()
  local side = CONFIG.MONITOR_SIDE
  if side and peripheral.hasType(side, "monitor") then
    return peripheral.wrap(side), side
  end

  local monitor = peripheral.find("monitor")
  if not monitor then
    return nil
  end
  return monitor, peripheral.getName(monitor)
end

local termScreen = { device = term, name = "term", buttonHeight = 1,
  boxes = {} }
local screens = { termScreen }

local monitorDevice, monitorName = findMonitor()
if monitorDevice then
  local monitorScreen = { device = monitorDevice, name = monitorName,
    buttonHeight = 1, boxes = {} }
  prepareMonitor(monitorScreen)
  table.insert(screens, monitorScreen)
end

--- Finds a screen by its peripheral name.
-- @tparam string name Peripheral name
-- @treturn table|nil Screen
local function screenByName(name)
  for _, screen in ipairs(screens) do
    if screen.name == name then
      return screen
    end
  end
  return nil
end

--- Redraws every screen; a detached monitor is skipped.
local function drawAll()
  local snapshot = state.snapshot
  for _, screen in ipairs(screens) do
    if snapshot then
      pcall(drawStatus, screen, snapshot)
    else
      pcall(drawUnavailable, screen)
    end
  end
end

--- Finds the button under a screen position.
-- @tparam table screen Screen
-- @tparam number x Column
-- @tparam number y Row
-- @treturn string|nil Button id
local function buttonAt(screen, x, y)
  for _, box in ipairs(screen.boxes) do
    if x >= box.left and x <= box.right and y >= box.top
      and y <= box.bottom then
      return box.id
    end
  end
  return nil
end

--- Runs a button action and redraws with fresh data.
-- @tparam string|nil id Button id
local function press(id)
  local button = BUTTONS_BY_ID[id]
  if not button then
    return
  end

  button.press()
  state.snapshot = safeReadReactor() or state.snapshot
  drawAll()
end

-- Main loops -------------------------------------------------------------

--- One guard step: safety first, then measurement and calibration.
local function step()
  local snapshot = safeReadReactor()
  state.snapshot = snapshot
  if not snapshot then
    resetWindow()
    drawAll()
    return
  end

  if state.trip and snapshot.active then
    log("Manual start detected, guard resumed")
    state.trip = nil
  end

  local hazard = snapshot.active and findHazard(snapshot)
  if hazard then
    trip(snapshot, hazard)
    resetWindow()
  end

  local storage = readStorage()
  state.stock = storage and storage.stock
  state.full = storage and storage.full
  addSample(snapshot, storage)
  local started = state.window.startTime
  if started and os.clock() - started >= CONFIG.WINDOW_SECONDS then
    finishWindow(snapshot)
  end

  drawAll()
end

--- Runs guard steps forever.
local function guardLoop()
  while true do
    step()
    sleep(CONFIG.LOOP_SECONDS)
  end
end

--- Input handlers by event name.
local EVENT_HANDLERS = {
  monitor_touch = function(side, x, y)
    local screen = screenByName(side)
    if screen then
      press(buttonAt(screen, x, y))
    end
  end,
  mouse_click = function(_, x, y)
    press(buttonAt(termScreen, x, y))
  end,
  char = function(char)
    if char == "s" or char == "S" then
      press("start")
    end
  end,
  monitor_resize = function(side)
    local screen = screenByName(side)
    if screen then
      prepareMonitor(screen)
      drawAll()
    end
  end,
}

--- Handles touches, clicks and keys forever.
local function inputLoop()
  while true do
    local event = { os.pullEvent() }
    local handler = EVENT_HANDLERS[event[1]]
    if handler then
      handler(table.unpack(event, 2))
    end
  end
end

resetWindow()
term.setBackgroundColor(colors.black)
term.clear()
log("Guard started")
parallel.waitForAny(guardLoop, inputLoop)

