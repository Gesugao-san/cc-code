--- Environment guard for CC:Tweaked, OpenComputers and OpenComputers II.
-- Crashes immediately when started in plain Lua on a real machine,
-- otherwise prints the detected environment and continues.
-- @script guard

--- Find a library either as a global or as an already loaded module.
-- Bare OpenComputers (EEPROM only) exposes `component` and `computer` as
-- globals, while OpenOS removes them from `_G` and keeps them in
-- `package.loaded`, so both places are checked.
-- @tparam string name Library name.
-- @treturn table|nil The library table, or nil when it is absent.
local function findLibrary(name)
  local global = rawget(_G, name)
  if type(global) == "table" then
    return global
  end

  local loaded = type(package) == "table" and package.loaded
  if type(loaded) ~= "table" then
    return nil
  end

  local module = loaded[name]
  return type(module) == "table" and module or nil
end

--- Detect CC:Tweaked by its `_HOST` string and CC-only `os` API.
-- @treturn string|nil Description,
--   e.g. "ComputerCraft 1.93.0 (Minecraft 1.15.2)".
local function detectComputerCraft()
  local host = rawget(_G, "_HOST")
  local has_cc_os = type(os) == "table" and type(os.getComputerID) == "function"

  if type(host) ~= "string" or not has_cc_os then
    return nil
  end

  return host
end

--- Detect OpenComputers by its `component` and `computer` libraries.
-- @treturn string|nil Description,
--   e.g. "OpenComputers (OpenOS 1.7.5, Lua 5.3)".
local function detectOpenComputers()
  local component = findLibrary("component")
  local computer = findLibrary("computer")
  local is_oc = component ~= nil and computer ~= nil
    and type(component.list) == "function"
    and type(computer.address) == "function"

  if not is_oc then
    return nil
  end

  local os_version = rawget(_G, "_OSVERSION") or "no OS"
  return ("OpenComputers (%s, %s)"):format(
    tostring(os_version), tostring(_VERSION))
end

--- Check whether the CPU is 64-bit RISC-V, as in the OpenComputers II VM.
-- Reads Linux `/proc/cpuinfo`; any other system simply has no such file.
-- @treturn boolean True when the CPU reports an rv64 ISA.
local function isRiscV64()
  if type(io) ~= "table" or type(io.open) ~= "function" then
    return false
  end

  local file = io.open("/proc/cpuinfo", "r")
  if not file then
    return false
  end

  local cpuinfo = file:read("*a") or ""
  file:close()
  return cpuinfo:find("rv64") ~= nil
end

--- Detect OpenComputers II by its `devices` library on a RISC-V Linux VM.
-- OC2 runs real Linux, so this is a heuristic: the mod-specific Lua library
-- plus the emulated RISC-V CPU. Must run last, after the other detectors.
-- @treturn string|nil Description,
--   e.g. "OpenComputers II (Linux on RISC-V, Lua 5.4)".
local function detectOpenComputers2()
  if type(require) ~= "function" then
    return nil
  end

  local loaded, devices = pcall(require, "devices")
  local has_devices = loaded and type(devices) == "table"
    and type(devices.find) == "function"
  if not has_devices then
    return nil
  end

  if not isRiscV64() then
    return nil
  end

  return ("OpenComputers II (Linux on RISC-V, %s)"):format(tostring(_VERSION))
end

--- Environment detectors, tried in order. Add new mods here.
local DETECTORS = {
  detectComputerCraft,
  detectOpenComputers,
  detectOpenComputers2,
}

--- Run detectors in order and return the first match.
-- Uses only standard Lua, so it is safe to call before any mod API is touched.
-- @treturn string|nil Environment description, or nil for plain Lua.
local function detectEnvironment()
  for _, detect in ipairs(DETECTORS) do
    local description = detect()
    if description then
      return description
    end
  end

  return nil
end

local environment = detectEnvironment()

-- Plain Lua on a real machine: crash with a non-zero exit code.
if environment == nil then
  error("This program runs only in CC:Tweaked or OpenComputers (1/2), not in "
    .. tostring(_VERSION), 0)
end

-- Keep text ASCII: the CC terminal font does not render Cyrillic.
print("Environment detected: " .. environment)

-- Main program starts here: mod APIs are safe to use below this line.
