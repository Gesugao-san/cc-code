--- Lists methods of every attached peripheral and saves them to a file.
-- Includes peripherals on wired modem networks.
-- Usage: dumpmethods [output_file]

local DEFAULT_OUTPUT = "methods.txt"

--- Builds a text section for one peripheral.
-- @tparam string name Side or network name of the peripheral
-- @treturn string|nil Section text, or nil if the peripheral is gone
-- @treturn number Number of methods
local function describe(name)
  local methods = peripheral.getMethods(name)
  if not methods then
    return nil, 0
  end

  table.sort(methods)
  local header = "== " .. name .. " (" .. peripheral.getType(name) .. ") =="
  return header .. "\n" .. table.concat(methods, "\n"), #methods
end

--- Writes text to a file.
-- @tparam string path File path
-- @tparam string text Content to write
-- @treturn boolean True on success
local function save(path, text)
  local file = fs.open(path, "w")
  if not file then
    return false
  end

  file.write(text)
  file.close()
  return true
end

local args = { ... }
local output = args[1] or DEFAULT_OUTPUT

local names = peripheral.getNames()
if #names == 0 then
  printError("No peripherals attached")
  return
end
table.sort(names)

local sections = {}
for _, name in ipairs(names) do
  local text, count = describe(name)
  if text then
    table.insert(sections, text)
    print(name .. ": " .. count)
  end
end

if not save(output, table.concat(sections, "\n\n")) then
  printError("Cannot write " .. output)
  return
end

print("Saved " .. #sections .. " peripherals to " .. output)

