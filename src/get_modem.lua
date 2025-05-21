-- Find all wireless modems connected to this computer.
-- https://tweaked.cc/module/peripheral.html#v:find

--local modems = { peripheral.find("modem", function(name, modem)
--  return modem.isWireless() -- Check this modem is wireless.
--end) }

local modems = { peripheral.find("modem") }
for _, modem in pairs(modems) do
  print(modem.isWireless())
end
