-- Download and install:
-- shell.run("rm", "rednet-d.lua")
-- shell.run("wget", "https://github.com/Gesugao-san/cc-code/raw/refs/heads/master/src/rednet-d.lua", "rednet-d.lua")
-- shell.run("rednet-d.lua")
master_id = 100

local modem = peripheral.find("modem") or error("No modem attached", 0)
if not m.isOpen() then
  rednet.open("left")
end

while true do
  id, message = rednet.receive()
  if id ~= master_id then goto continue end
  if message == "hello" then
    print("Hello world!")
  end
  ::continue::
end
