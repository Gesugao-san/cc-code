--- aepattern: encode Applied Energistics 2 patterns from CC:Tweaked.
--
-- FAILED EXPERIMENT, kept for reference. Tested in game on 2026-10-18:
-- the server runs official Advanced Peripherals, whose ME Bridge only has
-- getPatterns, so this program cannot encode anything there. The AE2
-- terminal itself exposes only its blank-pattern slot (see aeprobe).
--
-- The program drives an Advanced Peripherals ME Bridge (peripheral type
-- "me_bridge", Minecraft 1.21.1). Pattern encoding is NOT part of official
-- Advanced Peripherals releases (checked 2026-10-18): it only exists in the
-- draft pull request #791 (branch SchachSebastian:feat/mePatternCreation).
-- If that PR gets merged, method names and behaviour may change.
-- On a stock Advanced Peripherals build the ME Bridge only has getPatterns,
-- and this program stops with an explanation right away.
--
-- Requirements on the ME network:
--
--  * a Pattern Encoding Terminal attached somewhere on the network;
--  * blank patterns (ae2:blank_pattern) in ME storage, one per encoded pattern;
--  * enableMEBridgePatternCreator = true in the Advanced Peripherals config.
--
-- Encoded patterns are inserted into ME storage, not into a pattern provider.
-- Patterns that do not fit are dropped as items above the ME Bridge block.
--
-- Recipe commands (craft, smelt, ...) select recipes by their OUTPUT item.
-- Every matching recipe (and, for cooking/smithing, every ingredient variant)
-- becomes a separate pattern and consumes its own blank pattern.
--
-- @script aepattern
-- @usage aepattern craft minecraft:stick
-- @usage aepattern smelt iron_ingot          -- namespace defaults to minecraft
-- @usage aepattern process raw_iron*2 -> iron_ingot*3
-- @usage aepattern batch patterns.txt
-- @usage aepattern check

local PERIPHERAL_TYPE = "me_bridge"
local BLANK_PATTERN = "ae2:blank_pattern"
local DEFAULT_NAMESPACE = "minecraft"
local ARROW = "->"
local COMMENT_PREFIX = "#"
local REGEX_OPTION = "--regex"

--- Output filter that matches no recipe: lets "check" probe the encoder
-- without consuming blank patterns (the bridge returns NOT_FOUND before
-- it extracts any).
local PROBE_FILTER = "aepattern:probe-matches-nothing"

--- Status prefix the bridge returns when patterns were created.
local STATUS_CREATED = "PATTERN_CREATED"

--- Status prefix the bridge returns when no recipe matched the filter.
local STATUS_NOT_FOUND = "NOT_FOUND"

--- Statuses after which a batch cannot make further progress.
local FATAL_STATUSES = {
  "MISSING_BLANK_PATTERN",
  "PATTERN_ENCODING_DISABLED",
  "NOT_CONNECTED",
}

--- Error codes of bridge.getItem that mean "no such item in the registry".
local UNKNOWN_ITEM_ERRORS = {
  ITEM_NOT_FOUND = true,
  NO_VALID_ITEM = true,
}

--- Recipe-based commands: bridge method and the boolean options it accepts,
-- in the order the bridge expects them. Each option, when given, passes
-- false for the matching "allow substitutes" argument (bridge default: true).
local RECIPE_COMMANDS = {
  craft = {
    method = "createCraftingPattern",
    options = { "nosub", "nofluidsub" },
  },
  smelt = { method = "createSmeltingPattern", options = {} },
  blast = { method = "createBlastingPattern", options = {} },
  smoke = { method = "createSmokingPattern", options = {} },
  smith = { method = "createSmithingPattern", options = { "nosub" } },
  stonecut = { method = "createStonecuttingPattern", options = { "nosub" } },
}

--- Commands that are not allowed inside a batch file.
local BATCH_FORBIDDEN = {
  batch = true,
}

local USAGE = [[
Usage:
  aepattern craft <item> [nosub] [nofluidsub] [--regex]
  aepattern smelt|blast|smoke <item> [--regex]
  aepattern smith|stonecut <item> [nosub] [--regex]
  aepattern process <in>[*n] ... -> <out>[*n] ...
  aepattern batch <file>
  aepattern check
<item> is the recipe OUTPUT; "stick" = "minecraft:stick".
--regex treats <item> as a Java regex (may make many patterns).
Batch file: one command per line, "#" starts a comment.]]

-- Text helpers --------------------------------------------------------------

--- Raise an error without position info, so the user sees only the message.
-- @tparam string message Error text.
local function fail(message)
  error(message, 0)
end

--- Check whether a string starts with a prefix.
-- @tparam string text String to test.
-- @tparam string prefix Expected beginning.
-- @treturn boolean True if text begins with prefix.
local function startsWith(text, prefix)
  return text:sub(1, #prefix) == prefix
end

--- Check whether a status text begins with any of the given status names.
-- @tparam string text Status text returned by the bridge.
-- @tparam {string,...} statuses Status names to look for.
-- @treturn boolean True if one of the statuses matches.
local function hasAnyStatus(text, statuses)
  for _, status in ipairs(statuses) do
    if startsWith(text, status) then
      return true
    end
  end
  return false
end

--- Split a line into whitespace-separated words.
-- @tparam string line Source line.
-- @treturn {string,...} Words in order.
local function splitWords(line)
  local words = {}
  for word in line:gmatch("%S+") do
    words[#words + 1] = word
  end
  return words
end

--- Return all elements of a list starting at a given index.
-- @tparam table list Source list.
-- @tparam number first Index of the first element to keep.
-- @treturn table New list with the tail.
local function tail(list, first)
  return { table.unpack(list, first) }
end

--- Print a line in a colour when the terminal supports it.
-- @tparam number colour A value from the colours API.
-- @tparam string text Line to print.
local function printColoured(colour, text)
  local previous = term.getTextColour()
  if term.isColour() then
    term.setTextColour(colour)
  end
  print(text)
  term.setTextColour(previous)
end

--- Show the result of a command: green on success, red on failure.
-- @tparam boolean ok Whether the command succeeded.
-- @tparam[opt] string message Text to show; nothing is printed when nil.
local function report(ok, message)
  if not message then
    return
  end
  if not ok then
    printError(message)
    return
  end
  printColoured(colours.green, message)
end

-- Item ids ------------------------------------------------------------------

--- Normalise an item id: lower case, default namespace, format check.
-- @tparam string raw Id as typed by the user, e.g. "stick" or
-- "create:zinc_ingot".
-- @treturn string Full id such as "minecraft:stick".
local function normalizeItemId(raw)
  local id = raw:lower()
  if not id:find(":", 1, true) then
    id = DEFAULT_NAMESPACE .. ":" .. id
  end
  if not id:match("^[%w_.%-]+:[%w_./%-]+$") then
    fail("Invalid item id: " .. raw)
  end
  return id
end

--- Escape an item id so the bridge's Java regex matches it literally.
-- Only "." needs escaping: ids may contain [a-z0-9_.-/:] and "-" is
-- literal outside character classes.
-- @tparam string id Normalised item id.
-- @treturn string Regex matching exactly this id.
local function toLiteralRegex(id)
  return (id:gsub("%.", "\\."))
end

-- Bridge access -------------------------------------------------------------

local cachedBridge

--- Find the ME Bridge and make sure it can encode patterns.
-- @treturn table Wrapped ME Bridge peripheral.
-- @raise When no bridge is attached, the build lacks pattern encoding
-- or the ME network is not booted.
local function getBridge()
  if cachedBridge then
    return cachedBridge
  end
  local bridge = peripheral.find(PERIPHERAL_TYPE)
  if not bridge then
    fail("No ME Bridge (" .. PERIPHERAL_TYPE .. ") attached")
  end
  if not bridge.createProcessingPattern then
    fail("This ME Bridge cannot encode patterns"
      .. " (needs an Advanced Peripherals build with PR #791)")
  end
  if not bridge.isConnected() then
    fail("ME Bridge is not connected to a booted ME network")
  end
  cachedBridge = bridge
  return bridge
end

--- Make sure an item id exists in the game registry.
-- Relies on getItem returning ITEM_NOT_FOUND only for unregistered ids
-- (an item that is merely absent from storage returns nil without error).
-- @tparam table bridge ME Bridge peripheral.
-- @tparam string id Normalised item id.
-- @raise When the id is not registered.
local function assertItemRegistered(bridge, id)
  local _, err = bridge.getItem({ name = id })
  if UNKNOWN_ITEM_ERRORS[err] then
    fail("Unknown item: " .. id)
  end
end

--- Call a pattern-creation method and interpret its status text.
-- @tparam table bridge ME Bridge peripheral.
-- @tparam string method Name of the bridge method.
-- @param ... Arguments for the method.
-- @treturn boolean True if patterns were created.
-- @treturn string Status text from the bridge.
local function callPattern(bridge, method, ...)
  local result, err = bridge[method](...)
  local text = tostring(result or err or "UNKNOWN_ERROR")
  return startsWith(text, STATUS_CREATED), text
end

-- Recipe commands -----------------------------------------------------------

--- Parse trailing options and reject unknown ones.
-- @tparam {string,...} tokens Words after the item argument.
-- @tparam {string,...} allowed Option names accepted by the command.
-- @treturn table Set of options that were given.
-- @raise On an unknown option.
local function parseOptions(tokens, allowed)
  local allowedSet = { [REGEX_OPTION] = true }
  for _, name in ipairs(allowed) do
    allowedSet[name] = true
  end
  local given = {}
  for _, token in ipairs(tokens) do
    if not allowedSet[token] then
      fail("Unknown option: " .. token)
    end
    given[token] = true
  end
  return given
end

--- Build the output filter the bridge matches recipe results against.
-- @tparam table bridge ME Bridge peripheral.
-- @tparam string target Item id or, in regex mode, a Java regex.
-- @tparam boolean isRegex Whether target is a raw regex.
-- @treturn string Regex for the bridge.
local function buildOutputFilter(bridge, target, isRegex)
  if isRegex then
    printColoured(colours.orange,
      "Regex mode: every matching recipe uses a blank pattern")
    return target
  end
  local id = normalizeItemId(target)
  assertItemRegistered(bridge, id)
  return toLiteralRegex(id)
end

--- Create a command handler for a recipe-based pattern type.
-- @tparam table spec Entry of RECIPE_COMMANDS.
-- @treturn function Handler taking the argument list.
local function makeRecipeCommand(spec)
  return function(args)
    local target = args[1]
    if not target then
      fail("Missing output item")
    end
    local given = parseOptions(tail(args, 2), spec.options)
    local bridge = getBridge()
    local filter = buildOutputFilter(bridge, target, given[REGEX_OPTION])
    local allowFlags = {}
    for i, name in ipairs(spec.options) do
      allowFlags[i] = not given[name]
    end
    return callPattern(bridge, spec.method, filter,
      table.unpack(allowFlags, 1, #spec.options))
  end
end

-- Processing command --------------------------------------------------------

--- Parse "id" or "id*count" into the {id, count} pair the bridge expects.
-- @tparam string token Word such as "raw_iron*2".
-- @treturn table Pair { id, count }.
-- @raise On a bad id or a count below 1.
local function parseStack(token)
  local name, count = token:match("^(.-)%*(%d+)$")
  if not name then
    name, count = token, "1"
  end
  local amount = tonumber(count)
  if amount < 1 then
    fail("Count must be at least 1: " .. token)
  end
  return { normalizeItemId(name), amount }
end

--- Split processing arguments into inputs and outputs around "->".
-- @tparam {string,...} tokens Words after the command name.
-- @treturn table List of input pairs.
-- @treturn table List of output pairs.
-- @raise On a missing or repeated arrow, or an empty side.
local function parseProcessingArgs(tokens)
  local sides = { {}, {} }
  local side = 1
  for _, token in ipairs(tokens) do
    if token == ARROW then
      side = side + 1
    elseif side <= 2 then
      table.insert(sides[side], parseStack(token))
    end
  end
  if side ~= 2 then
    fail("Use exactly one '" .. ARROW .. "' between inputs and outputs")
  end
  if #sides[1] == 0 then
    fail("No inputs given")
  end
  if #sides[2] == 0 then
    fail("No outputs given")
  end
  return sides[1], sides[2]
end

--- Encode a processing pattern from explicit inputs and outputs.
-- Items only: the bridge looks ids up in the item registry, fluids fail.
-- The first output is meant to be the primary one, but the bridge reads the
-- Lua list as a Java map, so the order is not guaranteed; check the pattern.
-- @tparam {string,...} args Words after the command name.
-- @treturn boolean True if the pattern was created.
-- @treturn string Status text from the bridge.
local function runProcess(args)
  local inputs, outputs = parseProcessingArgs(args)
  local bridge = getBridge()
  for _, list in ipairs({ inputs, outputs }) do
    for _, stack in ipairs(list) do
      assertItemRegistered(bridge, stack[1])
    end
  end
  return callPattern(bridge, "createProcessingPattern", inputs, outputs)
end

-- Check and help ------------------------------------------------------------

--- Describe a probe status in plain words.
local PROBE_VERDICTS = {
  {
    prefix = STATUS_NOT_FOUND,
    ok = true,
    text = "pattern encoding is available",
  },
  {
    prefix = "PATTERN_ENCODING_DISABLED",
    ok = false,
    text = "disabled in Advanced Peripherals config",
  },
  {
    prefix = "NOT_CONNECTED",
    ok = false,
    text = "no Pattern Encoding Terminal on the network",
  },
}

--- Verify the setup without consuming blank patterns.
-- @treturn boolean True if pattern encoding should work.
-- @treturn string Summary for the user.
local function runCheck()
  local bridge = getBridge()
  local blank = bridge.getItem({ name = BLANK_PATTERN })
  local blankCount = blank and blank.count or 0
  local _, status = callPattern(
    bridge, "createStonecuttingPattern", PROBE_FILTER)
  for _, verdict in ipairs(PROBE_VERDICTS) do
    if startsWith(status, verdict.prefix) then
      local summary = ("Encoder: %s. Blank patterns: %d")
        :format(verdict.text, blankCount)
      return verdict.ok, summary
    end
  end
  return false, "Unexpected bridge status: " .. status
end

--- Print usage.
-- @treturn boolean Always true.
local function runHelp()
  print(USAGE)
  return true
end

-- Dispatch ------------------------------------------------------------------

local COMMANDS = {
  process = runProcess,
  check = runCheck,
  help = runHelp,
}
for name, spec in pairs(RECIPE_COMMANDS) do
  COMMANDS[name] = makeRecipeCommand(spec)
end

--- Run one command given as a word list.
-- @tparam {string,...} words Command name followed by its arguments.
-- @treturn boolean Success flag.
-- @treturn[opt] string Message for the user.
local function runCommand(words)
  local handler = COMMANDS[words[1]]
  if not handler then
    fail("Unknown command: " .. tostring(words[1]) .. " (try: aepattern help)")
  end
  return handler(tail(words, 2))
end

--- Run a command and turn raised errors into a failed result.
-- @tparam {string,...} words Command name followed by its arguments.
-- @treturn boolean Success flag.
-- @treturn[opt] string Message for the user.
local function safeRun(words)
  local results = table.pack(pcall(runCommand, words))
  if not results[1] then
    return false, tostring(results[2])
  end
  return results[2], results[3]
end

--- Check whether a batch line carries no command.
-- @tparam {string,...} words Words of the line.
-- @treturn boolean True for empty and comment lines.
local function isSkippable(words)
  return #words == 0 or startsWith(words[1], COMMENT_PREFIX)
end

--- Run one batch line, refusing commands not allowed in a batch.
-- @tparam {string,...} words Words of the line.
-- @treturn boolean Success flag.
-- @treturn string Message for the user.
local function runBatchLine(words)
  if BATCH_FORBIDDEN[words[1]] then
    return false, "'" .. words[1] .. "' is not allowed inside a batch"
  end
  return safeRun(words)
end

--- Run and report one batch line.
-- @tparam number lineNo Line number for the report.
-- @tparam {string,...} words Words of the line.
-- @treturn boolean Success flag.
-- @treturn boolean True if the batch should stop after this line.
local function executeBatchLine(lineNo, words)
  local ok, message = runBatchLine(words)
  report(ok, ("line %d: %s"):format(lineNo, tostring(message)))
  return ok, not ok and hasAnyStatus(tostring(message), FATAL_STATUSES)
end

--- Run every command from a file, stopping on statuses no later line can fix.
-- @tparam {string,...} args Words after the command name; args[1] is the path.
-- @treturn boolean True if all lines succeeded.
-- @treturn string Summary for the user.
local function runBatch(args)
  local path = args[1]
  if not path then
    fail("Missing batch file path")
  end
  local resolved = shell.resolve(path)
  if not fs.exists(resolved) or fs.isDir(resolved) then
    fail("File not found: " .. path)
  end
  getBridge()
  local handle = io.open(resolved, "r")
  local counts = { [true] = 0, [false] = 0 }
  local lineNo = 0
  for line in handle:lines() do
    lineNo = lineNo + 1
    local words = splitWords(line)
    if not isSkippable(words) then
      local ok, stop = executeBatchLine(lineNo, words)
      counts[ok] = counts[ok] + 1
      if stop then
        printError("Stopping: later lines would fail the same way")
        break
      end
    end
  end
  handle:close()
  local summary = ("Batch finished: %d ok, %d failed")
    :format(counts[true], counts[false])
  return counts[false] == 0, summary
end

COMMANDS.batch = runBatch

--- Entry point.
-- @tparam {string,...} argv Program arguments.
local function main(argv)
  if #argv == 0 then
    runHelp()
    return
  end
  report(safeRun(argv))
end

main({ ... })
