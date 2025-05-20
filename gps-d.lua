-- GPS Daemon for "cell tower", for our city - "The Capital".
-- SMP Server: https://redd.it/1kamzcj
-- See elso: https://tweaked.cc/guide/gps_setup.html
-- https://www.computercraft.info/wiki/Gps_(API)
-- https://www.computercraft.info/wiki/Gps_(program)

-- Note: Every GPSd-PC serves per dimension and works only on loaded chunks.

term.setCursorPos(1, 1)
term.clear()
shell.run("label", "set", "Capital-GPSd-1")
shell.run("gps", "host", x, y, z)
print( "Serving GPS requests" )
exit

if not x then
  print("Failed to get my location!")
else
