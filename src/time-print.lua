link = peripheral.find("create:display_link") or error("no create:display_link")
while true do
  link.clear()
  link.write(tostring(os.time()))
  link.update()
  sleep(1)
end
