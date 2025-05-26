-- GPS Daemon for "cell tower", for our city - "The Capital". CraftOS 1.9.
-- SMP Server: https://redd.it/1kamzcj
-- See elso: https://tweaked.cc/guide/gps_setup.html
-- https://www.computercraft.info/wiki/Gps_(API)
-- https://www.computercraft.info/wiki/Gps_(program)

-- Note: Every GPSd-PC serves per dimension and works only on loaded chunks.

--shell.run("label", "set", "Capital-GPSd-1")
shell.run("gps", "host", x, y, z)
