local tank = peripheral.find("inventory")
local disenchanter = peripheral.find("create_enchantment_industry:disenchanter")
print(tank)
print(disenchanter)
tank.pullItems("Liquid Experience", 0)
tank.pullItems("create_enchantment_industry:disenchanter", 0)
tank.pullItems("disenchanter", 0)
disenchanter.pushItems("inventory", 0)
disenchanter.pushItems("tank", 0)
disenchanter.pushItems("create:fluid_tank", 0)
disenchanter.pushItems("fluid_tank", 0)
