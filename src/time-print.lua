link = peripheral.find("Create_DisplayLink") or error("no create:display_link")
while true do
  link.clear()
  link.setCursorPos(1,1)
  link.write(tostring(os.time()))
  link.update()
  sleep(1)
end
