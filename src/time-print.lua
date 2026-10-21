--- Shows the in-game time on a Create Display Link, updated every second.
-- @script time-print

local link = peripheral.find("Create_DisplayLink")
  or error("No Create Display Link attached", 0)

while true do
  link.clear()
  link.setCursorPos(1, 1)
  link.write(textutils.formatTime(os.time(), true))
  link.update()
  sleep(1)
end

