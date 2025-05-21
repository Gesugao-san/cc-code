fw = peripheral.find("modem")
rednet.open("left")
master_id = 100

while true do
  id, message = rednet.receive()
  if id != master_id then goto continue end
  if message == "hello" then
    print("Hello world!")
  end
  ::continue::
end
