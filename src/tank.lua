--- Moves Liquid Experience from a Create Enchantment Industry disenchanter
-- into a fluid tank.
--
-- Both blocks must be on the same wired modem network: pullFluid takes
-- the source by its peripheral name.
-- @script tank

local DISENCHANTER_TYPE = "create_enchantment_industry:disenchanter"

local disenchanter = peripheral.find(DISENCHANTER_TYPE)
  or error("No disenchanter found", 0)
local disenchanterName = peripheral.getName(disenchanter)

--- Accepts any fluid storage except the disenchanter itself.
-- @tparam string name Peripheral name
-- @treturn boolean True if this peripheral can be the target tank
local function isTargetTank(name)
  return name ~= disenchanterName
end

local tank = peripheral.find("fluid_storage", isTargetTank)
  or error("No fluid tank found", 0)

local moved = tank.pullFluid(disenchanterName)
print("Moved " .. moved .. " mB from " .. disenchanterName
  .. " to " .. peripheral.getName(tank))

