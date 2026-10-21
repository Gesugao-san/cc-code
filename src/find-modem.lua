--- Lists all modems attached to this computer and shows which are wireless.
-- See https://tweaked.cc/module/peripheral.html#v:find
-- @script find-modem

-- To get wireless modems only, pass a filter:
--local modems = { peripheral.find("modem", function(name, modem)
--  return modem.isWireless()
--end) }

local modems = { peripheral.find("modem") }
if #modems == 0 then
  printError("No modems attached")
  return
end

for _, modem in ipairs(modems) do
  local kind = modem.isWireless() and "wireless" or "wired"
  print(peripheral.getName(modem) .. ": " .. kind)
end

