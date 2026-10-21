--- GPS daemon for a "cell tower" of our city, "The Capital". CraftOS 1.9.
-- Every GPS host serves its own dimension and works only in loaded chunks.
--
-- Usage:
--   gps-host-d <x> <y> <z>  -- host with a manually set position
--   gps-host-d              -- host and locate itself via other GPS hosts
--
-- SMP server: https://redd.it/1kamzcj
-- See also:
--   https://tweaked.cc/guide/gps_setup.html
--   https://www.computercraft.info/wiki/Gps_(API)
--   https://www.computercraft.info/wiki/Gps_(program)
-- @script gps-host-d

local args = { ... }

--shell.run("label", "set", "Capital-GPSd-1")

if #args == 0 then
  -- No position given: "gps host" will try to locate itself.
  shell.run("gps", "host")
  return
end

local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
if not (x and y and z) then
  printError("Usage: gps-host-d [<x> <y> <z>]")
  return
end

shell.run("gps", "host", x, y, z)

