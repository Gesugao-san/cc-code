-- Download and install:
-- rm rednet-d.lua
-- wget https://github.com/Gesugao-san/cc-code/raw/refs/heads/master/src/rednet-d.lua rednet-d.lua
-- rednet-d.lua
master_id = 100

local modem = peripheral.find("modem") or error("No modem attached", 0)
if not rednet.isOpen() then
  -- This will open the modem on two channels:
  -- one which has the same ID as the computer, and
  -- another on the broadcast channel.
  rednet.open(modem)
end

print("Rednet channel opened.")
while true do
  print("Listeting from "..master_id.."...")
  id, message = rednet.receive()
  if id ~= master_id then goto continue end
  if message == "hello" then
    print("Hello world!")
  end
  ::continue::
end
