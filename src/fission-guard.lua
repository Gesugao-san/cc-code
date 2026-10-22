--- Fission reactor guard with a sodium-aware burn rate controller.
--
-- What it does:
--   * Watches the Mekanism fission reactor through its logic adapter
--     (temperature, damage, coolant, heated coolant, waste, fuel, burn).
--   * SCRAMs the reactor on any hazard, lowers the burn rate and then
--     waits for a manual start (reactor GUI, or the S key here).
--   * Watches sodium stock in the ME system through an ME Bridge and
--     fits a model "stock change = supply - perBurn * burnRate".
--     The burn rate is kept below the point where the reactor would
--     consume sodium faster than the infinite source refills it.
--
-- Needs: Fission Reactor Logic Adapter, ME Bridge (Advanced Peripherals)
-- with Applied Mekanistics, both on this computer's wired network.
--
-- Files: fission-guard.state keeps measurements between restarts
-- (delete it to recalibrate), fission-guard.log keeps events.
-- @script fission-guard

-- Configuration ----------------------------------------------------------

local CONFIG = {
  SODIUM = "mekanism:sodium",  -- chemical id in the ME system
  LOOP_SECONDS = 0.5,          -- safety check and stock sample period
  WINDOW_SAMPLES = 60,         -- samples per measurement window (30 s)
  SETTLE_WINDOWS = 1,          -- windows ignored after a burn change

  MAX_TEMPERATURE = 1000,      -- K; Mekanism starts damage at 1200 K
  MIN_COOLANT = 0.10,          -- reactor coolant tank, fraction
  MAX_HEATED_COOLANT = 0.95,   -- heated coolant tank, fraction
  MAX_WASTE = 0.90,            -- waste tank, fraction
  TRIP_BURN_FACTOR = 0.5,      -- burn rate multiplier after a SCRAM

  MIN_STOCK = 10000,           -- mB of sodium kept in ME as a reserve
  MIN_BURN = 0.1,              -- mB/t
  BURN_LIMIT = nil,            -- manual upper limit, mB/t; nil = reactor max
  SAFETY_MARGIN = 0.9,         -- run at this share of the balance point
  DEADBAND = 0.05,             -- mB/t of stock change treated as noise
  DECREASE_FACTOR = 0.8,       -- burn step down while sodium drains
  INCREASE_FACTOR = 1.1,       -- burn step up while sodium accumulates
  MAX_STEP_UP = 1.25,          -- largest increase per window

  MAX_MODEL_SAMPLES = 12,      -- older measurements are forgotten
  MIN_MODEL_SAMPLES = 3,
  MIN_BURN_SPREAD = 0.2,       -- mB/t between lowest and highest sample

  STATE_FILE = "fission-guard.state",
  LOG_FILE = "fission-guard.log",
}

local TICKS_PER_SECOND = 20

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

--- Loads saved calibration.
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
  if type(data) ~= "table" or type(data.samples) ~= "table" then
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

  file.write(textutils.serialize({ samples = samples, model = model }))
  file.close()
end

-- Sodium stock -----------------------------------------------------------

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

local readStock = pickStockReader()

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
    temperature = reactor.getTemperature(),
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

-- Safety -----------------------------------------------------------------

--- Hazards that trigger a SCRAM, checked in order.
local SAFETY_RULES = {
  {
    isUnsafe = function(s) return s.temperature >= CONFIG.MAX_TEMPERATURE end,
    describe = function(s)
      return string.format("temperature %.0f K", s.temperature)
    end,
  },
  {
    isUnsafe = function(s) return s.damage > 0 end,
    describe = function(s) return string.format("damage %.1f", s.damage) end,
  },
  {
    isUnsafe = function(s) return s.coolant < CONFIG.MIN_COOLANT end,
    describe = function(s)
      return string.format("coolant %.0f%%", s.coolant * 100)
    end,
  },
  {
    isUnsafe = function(s) return s.heated > CONFIG.MAX_HEATED_COOLANT end,
    describe = function(s)
      return string.format("heated coolant %.0f%%", s.heated * 100)
    end,
  },
  {
    isUnsafe = function(s) return s.waste > CONFIG.MAX_WASTE end,
    describe = function(s)
      return string.format("waste %.0f%%", s.waste * 100)
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

--- Least-squares slope of y over x.
-- @tparam table points Array of { x = number, y = number }
-- @treturn number|nil Slope, or nil if x has no spread
local function regressionSlope(points)
  local n = #points
  if n < 2 then
    return nil
  end

  local sumX, sumY = 0, 0
  for _, p in ipairs(points) do
    sumX, sumY = sumX + p.x, sumY + p.y
  end
  local meanX, meanY = sumX / n, sumY / n

  local sxx, sxy = 0, 0
  for _, p in ipairs(points) do
    sxx = sxx + (p.x - meanX) ^ 2
    sxy = sxy + (p.x - meanX) * (p.y - meanY)
  end

  if sxx == 0 then
    return nil
  end
  return sxy / sxx, meanX, meanY
end

--- Fits "slope = supply - perBurn * burn" to measurements.
-- @tparam table samples Array of { burn = number, slope = number }
-- @treturn table|nil { supply, perBurn, balance } or nil if not enough data
local function fitModel(samples)
  if #samples < CONFIG.MIN_MODEL_SAMPLES then
    return nil
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

  local m, meanBurn, meanSlope = regressionSlope(points)
  if not m or m >= 0 then
    return nil -- more burn must consume more sodium, otherwise data is noise
  end

  local perBurn = -m
  local supply = meanSlope + perBurn * meanBurn
  return {
    supply = supply,
    perBurn = perBurn,
    balance = math.max(0, supply / perBurn),
  }
end

--- Re-estimates supply with a known consumption per burn unit.
-- Used when recent samples share one burn rate and no line can be fitted:
-- consumption per burn is physics and stays, supply may drift.
-- @tparam table model Previous model
-- @tparam table samples Array of { burn = number, slope = number }
-- @treturn table Updated model
local function refitSupply(model, samples)
  local recent = math.min(#samples, CONFIG.MIN_MODEL_SAMPLES)
  local sum = 0
  for i = #samples - recent + 1, #samples do
    sum = sum + samples[i].slope + model.perBurn * samples[i].burn
  end

  local supply = sum / recent
  return {
    supply = supply,
    perBurn = model.perBurn,
    balance = math.max(0, supply / model.perBurn),
  }
end

--- Rounds a burn rate to 0.01 mB/t.
-- @tparam number value Burn rate
-- @treturn number Rounded burn rate
local function roundBurn(value)
  return math.floor(value * 100 + 0.5) / 100
end

-- Controller -------------------------------------------------------------

local calibration = loadCalibration()

local state = {
  samples = calibration.samples,
  model = calibration.model,
  trip = nil,          -- SCRAM reason while waiting for a manual start
  settle = 0,          -- windows left to ignore
  window = nil,
  stock = nil,
  slope = nil,         -- last measured stock change, mB/t
  lastAction = "starting",
}
state.model = fitModel(state.samples) or state.model

--- Starts a new measurement window.
local function resetWindow()
  state.window = { points = {}, burnSum = 0, active = nil, burnRate = nil,
    clean = true }
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

  local lowered = roundBurn(math.max(CONFIG.MIN_BURN,
    snapshot.burnRate * CONFIG.TRIP_BURN_FACTOR))
  applyBurn(lowered, "after SCRAM")
end

--- Chooses a burn rate from the latest measurement.
-- @tparam number current Current burn rate, mB/t
-- @tparam number slope Stock change, mB/t
-- @treturn number Wanted burn rate
-- @treturn string Reason
local function chooseBurn(current, slope)
  if state.stock < CONFIG.MIN_STOCK then
    return current * 0.5, "sodium reserve low"
  end

  local model = state.model
  if not model then
    if slope < -CONFIG.DEADBAND then
      return current * CONFIG.DECREASE_FACTOR, "sodium draining"
    end
    if slope > CONFIG.DEADBAND then
      return math.max(current * CONFIG.INCREASE_FACTOR,
        current + CONFIG.MIN_BURN), "sodium surplus"
    end
    return current, "balanced"
  end

  local target = model.balance * CONFIG.SAFETY_MARGIN
  if slope < -CONFIG.DEADBAND then
    target = math.min(target, current * CONFIG.DECREASE_FACTOR)
  elseif slope > CONFIG.DEADBAND then
    target = math.max(target, current)
  end
  return math.min(target, current * CONFIG.MAX_STEP_UP), "model"
end

--- Clamps and applies a new burn rate if it differs enough.
-- @tparam table snapshot Reactor snapshot
-- @tparam number slope Stock change, mB/t
local function calibrate(snapshot, slope)
  local wanted, reason = chooseBurn(snapshot.burnRate, slope)
  local limit = math.min(snapshot.maxBurn,
    CONFIG.BURN_LIMIT or snapshot.maxBurn)
  local rate = roundBurn(math.max(CONFIG.MIN_BURN, math.min(wanted, limit)))
  if math.abs(rate - snapshot.burnRate) < 0.01 then
    state.lastAction = "holding (" .. reason .. ")"
    return
  end

  applyBurn(rate, reason)
end

--- Stores a finished window as a measurement and refits the model.
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
  elseif state.model then
    state.model = refitSupply(state.model, state.samples)
  end
  saveCalibration(state.samples, state.model)
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

  local perSecond = regressionSlope(window.points)
  if not perSecond then
    return
  end

  local slope = perSecond / TICKS_PER_SECOND
  state.slope = slope
  recordSample(window.burnSum / #window.points, slope)

  if snapshot.active and not state.trip then
    calibrate(snapshot, slope)
  end
end

--- Adds one stock sample to the current window.
-- @tparam table snapshot Reactor snapshot
-- @tparam number|nil stock Sodium stock in mB, or nil if unreadable
local function addSample(snapshot, stock)
  local window = state.window
  if not stock then
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

  table.insert(window.points, { x = os.clock(), y = stock })
  window.burnSum = window.burnSum + (snapshot.active and snapshot.actualBurn
    or 0)
end

-- Display ----------------------------------------------------------------

--- Writes a line at the current cursor row, optionally colored.
-- @tparam string text Text to write
-- @tparam[opt] number color Text color
local function line(text, color)
  if color and term.isColor() then
    term.setTextColor(color)
  end
  term.clearLine()
  print(text)
  term.setTextColor(colors.white)
end

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

--- Describes the calibration model.
-- @treturn string Text
local function modelText()
  local model = state.model
  if not model then
    return string.format("Model    collecting data (%d/%d samples)",
      #state.samples, CONFIG.MIN_MODEL_SAMPLES)
  end
  return string.format("Model    +%.2f mB/t, -%.2f per burn -> %.2f",
    model.supply, model.perBurn, model.balance)
end

--- Redraws the status screen.
-- @tparam table snapshot Reactor snapshot
local function draw(snapshot)
  term.setCursorPos(1, 1)
  local header, color = headerText(snapshot)
  line("Fission guard  " .. header, color)
  line(string.format("Temp     %.0f K (max %d)", snapshot.temperature,
    CONFIG.MAX_TEMPERATURE))
  line(string.format("Damage   %.1f", snapshot.damage))
  line(string.format("Coolant  %3.0f%%  Heated %3.0f%%", snapshot.coolant
    * 100, snapshot.heated * 100))
  line(string.format("Waste    %3.0f%%  Fuel   %3.0f%%", snapshot.waste * 100,
    snapshot.fuel * 100))
  line(string.format("Burn     %.2f set, %.2f actual, %.0f max",
    snapshot.burnRate, snapshot.actualBurn, snapshot.maxBurn))
  line(string.format("Sodium   %s mB, %s mB/t", tostring(state.stock or "?"),
    state.slope and string.format("%+.2f", state.slope) or "?"))
  line(modelText())
  line("Last     " .. state.lastAction)
  line(state.trip and "[S] start reactor manually" or "")
end

-- Main loops -------------------------------------------------------------

--- Reads sodium stock without letting bridge errors stop the guard.
-- @treturn number|nil Stock in mB, or nil on error
local function safeReadStock()
  local ok, stock = pcall(readStock)
  return ok and stock or nil
end

--- One guard step: safety first, then measurement and calibration.
local function step()
  local ok, snapshot = pcall(readReactor)
  if not ok or not snapshot.formed then
    term.setCursorPos(1, 1)
    line("Fission guard  reactor unavailable", colors.red)
    resetWindow()
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

  state.stock = safeReadStock()
  addSample(snapshot, state.stock)
  if #state.window.points >= CONFIG.WINDOW_SAMPLES then
    finishWindow(snapshot)
  end

  draw(snapshot)
end

--- Runs guard steps forever.
local function guardLoop()
  while true do
    step()
    sleep(CONFIG.LOOP_SECONDS)
  end
end

--- Starts the reactor on the S key if it was tripped and is safe now.
local function keyLoop()
  while true do
    local _, char = os.pullEvent("char")
    if (char == "s" or char == "S") and state.trip then
      local ok, snapshot = pcall(readReactor)
      local hazard = ok and snapshot.formed and findHazard(snapshot)
      if hazard then
        state.lastAction = "start refused: " .. hazard
      elseif ok and snapshot.formed and pcall(reactor.activate) then
        log("Started manually from the guard")
        state.trip = nil
      end
    end
  end
end

resetWindow()
term.clear()
log("Guard started")
parallel.waitForAny(guardLoop, keyLoop)

