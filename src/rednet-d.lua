master_id = 100

local modem = peripheral.find("modem") or error("No modem attached", 0)
if not m.isOpen() then
  rednet.open("left")
end

while true do
  id, message = rednet.receive()
  if id != master_id then goto continue end
  if message == "hello" then
    print("Hello world!")
  end
  ::continue::
end
