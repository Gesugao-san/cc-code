--- Rednet daemon: listens for commands from the master computer.
-- Messages from any other computer are ignored.
--
-- Download and install:
--   rm rednet-d.lua
--   wget https://github.com/Gesugao-san/cc-code/raw/refs/heads/main/src/rednet-d.lua rednet-d.lua
--   rednet-d
-- @script rednet-d

local MASTER_ID = 100

--- Known commands, keyed by message text.
-- Add new commands here instead of chaining if/elseif.
local COMMANDS = {
  hello = function() print("Hello world!") end,
}

--- Runs the command for a message, if it is known.
-- @tparam number senderId ID of the computer that sent the message
-- @param message Received message (any type)
local function handleMessage(senderId, message)
  if senderId ~= MASTER_ID then
    return
  end

  local command = COMMANDS[message]
  if not command then
    print("Unknown command: " .. tostring(message))
    return
  end

  command()
end

local modem = peripheral.find("modem") or error("No modem attached", 0)
local modemName = peripheral.getName(modem)
if not rednet.isOpen(modemName) then
  -- Opens the modem on two channels: one matching this computer's ID
  -- and the broadcast channel.
  rednet.open(modemName)
end

print("Rednet opened on " .. modemName .. ".")
print("Listening to #" .. MASTER_ID .. "...")
while true do
  local senderId, message = rednet.receive()
  handleMessage(senderId, message)
end

