-- SPDX-FileCopyrightText: 2017 Daniel Ratcliffe
--
-- SPDX-License-Identifier: LicenseRef-CCPL
--
-- Forked from:
-- https://github.com/cc-tweaked/CC-Tweaked/blob/mc-1.20.x/projects/core/src/main/resources/data/computercraft/lua/rom/programs/gps.lua
-- To:
-- https://github.com/Gesugao-san/cc-code/edit/master/src/gps-fork.lua

local function printUsage()
    local programName = arg[0] or fs.getName(shell.getRunningProgram())
    print("Usages:")
    print(programName .. " host")
    print(programName .. " host <x> <y> <z>")
    print(programName .. " locate")
end

local tArgs = { ... }
if #tArgs < 1 then
    printUsage()
    return
end

 local sCommand = tArgs[1]
if sCommand == "locate" then
    -- "gps locate"
    -- Just locate this computer (this will print the results)
    gps.locate(2, true)

elseif sCommand == "host" then
    -- "gps host"
    -- Act as a GPS host
    if pocket then
        print("GPS Hosts must be stationary")
        return
    end

    print("Emulate? y/[n]")
    local input = read("*")
    if input ~= "y" then
        local emulate = false
        print("Standart behavior selected.")
    else
        local emulate = true
    end

    -- Find a modem
    local sModemSide = nil
    for _, sSide in ipairs(rs.getSides()) do
        if peripheral.getType(sSide) == "modem" and peripheral.call(sSide, "isWireless") then
            sModemSide = sSide
            print("Wireless modem found locally.")
            break
        end
    end

    if sModemSide == nil then
        print("No wireless modems found locally.")
        print("Looking up at LAN...")
    end

    local modem = nil
    local bWirelessModemFound = false
    local tModemNames = peripheral.getNames()
    for _, sModemName in ipairs(tModemNames) do
        if peripheral.call(sModemName, "isWireless") then
        --if modem.isWireless() then
            sModemSide = "remote"
            modem = peripheral.wrap(sModemName)
            print("Wireless modem found at LAN.")
            break
        end
    end

    -- Determine position
    local x, y, z
    if #tArgs >= 4 then
        -- Position is manually specified
        x = tonumber(tArgs[2])
        y = tonumber(tArgs[3])
        z = tonumber(tArgs[4])
        if x == nil or y == nil or z == nil then
            printUsage()
            return
        end
        print("Position is " .. x .. "," .. y .. "," .. z)
    else
        -- Position is to be determined using locate
        x, y, z = gps.locate(2, true)
        if x == nil then
            print("Run \"gps host <x> <y> <z>\" to set position manually")
            return
        end
    end

    -- Open a channel
    if sModemSide ~= "remote" then
      modem = peripheral.wrap(sModemSide)
    end
    print("Opening channel on modem " .. sModemSide)
    modem.open(gps.CHANNEL_GPS)

    -- Serve requests indefinitely
    local nServed = 0
    while true do
        local e, p1, p2, p3, p4, p5 = os.pullEvent("modem_message")
        -- We received a message from a modem
        if e ~= "modem_message" then goto continue end
        -- Guard Clause Technique
        -- See https://youtu.be/Zmx0Ou5TNJs
        local sSide, sChannel, sReplyChannel, sMessage, nDistance = p1, p2, p3, p4, p5
        if sSide ~= sModemSide and sModemSide ~= "remote" then goto continue end
        if sChannel ~= gps.CHANNEL_GPS then goto continue end
        if sMessage ~= "PING" then goto continue end
        if not nDistance then goto continue end
        -- We received a ping message on the GPS channel, send a response
        modem.transmit(sReplyChannel, gps.CHANNEL_GPS, { x, y, z })
        if emulate then
            modem.transmit(sReplyChannel, gps.CHANNEL_GPS, { x+5, y, z })
            modem.transmit(sReplyChannel, gps.CHANNEL_GPS, { x-5, y, z })
            modem.transmit(sReplyChannel, gps.CHANNEL_GPS, { x, y+5, z })
            modem.transmit(sReplyChannel, gps.CHANNEL_GPS, { x, y-5, z })
            modem.transmit(sReplyChannel, gps.CHANNEL_GPS, { x, y, z+5 })
            modem.transmit(sReplyChannel, gps.CHANNEL_GPS, { x, y, z-5 })
        end

        -- Print the number of requests handled
        nServed = nServed + 1
        if nServed > 1 then
            local _, y = term.getCursorPos()
            term.setCursorPos(1, y - 1)
        end
        print(nServed .. " GPS requests served")
        ::continue::
    end
else
    -- "gps somethingelse"
    -- Error
    printUsage()
end
