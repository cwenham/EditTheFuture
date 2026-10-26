// The script API for Lua (docs/DESIGN.md, 6.4). It runs before each script and returns the
// table of functions the app calls: finish, describe, start, step, emitted and output.
let luaPrelude = #"""
local rt = {}
local params, vars, inputs, emitList, handlers = {}, {}, {}, {}, {}
local declared, emitSet = {}, {}
local everyText, timeunitText
local loading, running = true, false
local emitted, printed = {}, {}
local names, inputNames = {}, {}
local userStep, userStart

local type, tostring, tonumber, error, pairs, ipairs, select, next, rawget, rawset, setmetatable, getmetatable =
      type, tostring, tonumber, error, pairs, ipairs, select, next, rawget, rawset, setmetatable, getmetatable
local format, concat, huge = string.format, table.concat, math.huge
local random, randomseed, log, cos, sqrt, pi = math.random, math.randomseed, math.log, math.cos, math.sqrt, math.pi
local newTable = table.create or function() return {} end

rt.vals, rt.ins, rt.tim, rt.evs = {}, {}, {}, {}

-- JSON for the app. Lists built here are marked, so empty ones still come out as [].
local LIST = {}
local function list(t) return setmetatable(t or {}, LIST) end
local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function encode(value)
  local kind = type(value)
  if kind == "nil" then return "null"
  elseif kind == "boolean" then return value and "true" or "false"
  elseif kind == "number" then
    if value ~= value or value == huge or value == -huge then return "null" end
    return format("%.17g", value)
  elseif kind == "string" then
    return '"' .. (value:gsub('[%c"\\]', function(c) return escapes[c] or format("\\u%04x", c:byte()) end)) .. '"'
  elseif getmetatable(value) == LIST then
    local parts = {}
    for i, item in ipairs(value) do parts[i] = encode(item) end
    return "[" .. concat(parts, ",") .. "]"
  else
    local parts = {}
    for key, item in pairs(value) do parts[#parts + 1] = encode(tostring(key)) .. ":" .. encode(item) end
    return "{" .. concat(parts, ",") .. "}"
  end
end

-- "4.5%" is 0.045, shown as a percent.
local function number(value)
  if type(value) == "number" then return value, false end
  if type(value) == "string" then
    local text = value:match("^%s*(.-)%s*$")
    if text:sub(-1) == "%" then
      local n = tonumber(text:sub(1, -2))
      if n then return n / 100, true end
    else
      local n = tonumber(text)
      if n then return n, false end
    end
  end
  return nil
end

local function distance(a, b)
  local previous = {}
  for j = 0, #b do previous[j] = j end
  for i = 1, #a do
    local current = { [0] = i }
    for j = 1, #b do
      local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
      current[j] = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
    end
    previous = current
  end
  return previous[#b]
end

local function suggestion(name)
  local best, bestDistance = nil, 3
  for candidate in pairs(declared) do
    local d = distance(name:lower(), candidate:lower())
    if d < bestDistance then best, bestDistance = candidate, d end
  end
  return best and (" Did you mean s." .. best .. "?") or ""
end

local function checkLoading(what)
  if not loading then error(what .. " can only be used at the top of the script, not while it runs", 3) end
end

local function checkName(name, what)
  if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
    error(what .. " needs a name made of letters, digits and underscores, like \"balance\"", 3)
  end
  if declared[name] then error("\"" .. name .. "\" is already declared", 3) end
end

local quantities = { number = true, percent = true, currency = true, temperature = true }

-- Returns the options, or nil and what's wrong with them.
local function readOptions(options, isPercent, allowStart)
  if options == nil then options = {} end
  if type(options) ~= "table" then return nil, "options should be a table, like { label = \"Balance\" }" end
  local result = {}
  for key, value in pairs(options) do
    if key == "range" then
      local low, lowPercent, high, highPercent
      if type(value) == "table" then
        low, lowPercent = number(value[1])
        high, highPercent = number(value[2])
      end
      if not low or not high or value[3] ~= nil then return nil, "range should be two numbers, like {0, 100} or {\"0%\", \"15%\"}" end
      result.min, result.max = low, high
      isPercent = isPercent or lowPercent or highPercent
    elseif key == "by" then
      local step = number(value)
      if not step then return nil, "by should be a number" end
      result.by = step
    elseif key == "label" then
      if type(value) ~= "string" then return nil, "label should be text" end
      result.label = value
    elseif key == "as" then
      if not quantities[value] then return nil, "as should be \"number\", \"percent\", \"currency\" or \"temperature\"" end
      result.as = value
    elseif key == "start" and allowStart then
      local start = number(value)
      if not start then return nil, "start should be a number" end
      result.start = start
    else
      return nil, "there's no option called \"" .. tostring(key) .. "\". The options are range, by, label, as"
        .. (allowStart and " and start" or "") .. "."
    end
  end
  if not result.as and isPercent then result.as = "percent" end
  return result
end

local function declareValue(kind, name, value, options, isInit)
  local v, isPercent = number(value)
  if v == nil then error(kind .. " \"" .. name .. "\" needs a value: a number, or text like \"4.5%\"", 3) end
  local read, problem = readOptions(options, isPercent, false)
  if not read then error(kind .. " \"" .. name .. "\": " .. problem, 3) end
  declared[name] = kind
  local entry = { name = name, value = v, label = read.label, min = read.min, max = read.max, by = read.by, as = read.as, isInit = isInit }
  return entry
end

-- Declarations

function every(text)
  checkLoading("every")
  if type(text) ~= "string" then error("every needs text, like every \"1 month\"", 2) end
  everyText = text
end

function timeunit(text)
  checkLoading("timeunit")
  if type(text) ~= "string" then error("timeunit needs text, like timeunit \"year\"", 2) end
  timeunitText = text
end

function param(name, value, options)
  checkLoading("param")
  checkName(name, "param")
  params[#params + 1] = declareValue("param", name, value, options, nil)
end

function init(name, value, options)
  checkLoading("init")
  checkName(name, "init")
  vars[#vars + 1] = declareValue("init", name, value, options, true)
end

function output(name, options)
  checkLoading("output")
  checkName(name, "output")
  local read, problem = readOptions(options, false, true)
  if not read then error("output \"" .. name .. "\": " .. problem, 2) end
  declared[name] = "output"
  vars[#vars + 1] = { name = name, value = read.start or 0, label = read.label, min = read.min, max = read.max,
                      by = read.by, as = read.as, isInit = false }
end

function input(name, reference)
  checkLoading("input")
  checkName(name, "input")
  if type(reference) ~= "string" then
    error("input \"" .. name .. "\" needs another slot's value to read, like input(\"temp\", \"Climate.temp\")", 2)
  end
  declared[name] = "input"
  inputs[#inputs + 1] = { name = name, ref = reference }
end

function emits(...)
  checkLoading("emits")
  for i = 1, select("#", ...) do
    local kind = select(i, ...)
    if type(kind) ~= "string" or not kind:match("^[%a_][%w_]*$") then
      error("emits needs event kinds made of letters, digits and underscores, like emits \"Millionaire\"", 2)
    end
    if not emitSet[kind] then
      emitSet[kind] = true
      emitList[#emitList + 1] = kind
    end
  end
end

function on(kind, handler)
  checkLoading("on")
  if type(kind) ~= "string" then error("on needs an event kind, like on(\"deposit\", function(s, e, t) ... end)", 2) end
  if type(handler) ~= "function" then error("on(\"" .. kind .. "\", ...) needs a function, like function(s, e, t) ... end", 2) end
  local slot, eventKind = kind:match("^%s*([%a_][%w_]*)%.([%a_][%w_]*)%[t%-1%]%s*$")
  if not slot then slot, eventKind = kind:match("^%s*([%a_][%w_]*)%.([%a_][%w_]*)%s*$") end
  if not slot then eventKind = kind:match("^%s*([%a_][%w_]*)%s*$") end
  if not eventKind then error("on \"" .. kind .. "\": write an event kind like \"deposit\", or another slot's like \"FireRisk.OverCapacity\"", 2) end
  handlers[#handlers + 1] = { text = kind, kind = eventKind, slot = slot, fn = handler }
end

function emit(kind, fields)
  if not running then error("emit can only be used while the script runs: in step or an on handler", 2) end
  if not emitSet[kind] then
    error("declare \"" .. tostring(kind) .. "\" at the top with emits \"" .. tostring(kind) .. "\" before sending it", 2)
  end
  local values = {}
  if fields ~= nil then
    if type(fields) ~= "table" then error("emit's fields should be a table, like { amount = 500 }", 2) end
    for key, value in pairs(fields) do
      if type(key) ~= "string" or type(value) ~= "number" then
        error("emit's fields should be names with numbers, like { amount = 500 }", 2)
      end
      values[key] = value
    end
  end
  emitted[#emitted + 1] = { kind = kind, values = values }
end

function print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  printed[#printed + 1] = concat(parts, "\t")
  if #printed > 200 then table.remove(printed, 1) end
end

local rawLoad = load
function load(chunk, name, mode, env) return rawLoad(chunk, name, "t", env) end

local function normal(mean, sd)
  local u1 = math.max(random(), 1e-300)
  return (mean or 0) + (sd or 1) * sqrt(-2 * log(u1)) * cos(2 * pi * random())
end

-- Running

local stateMeta = {
  __index = function(_, key)
    error("s." .. tostring(key) .. " isn't declared." .. suggestion(tostring(key)), 2)
  end,
  __newindex = function(_, key)
    error("s." .. tostring(key) .. " isn't declared. Declare it with init or output, or use a local variable."
      .. suggestion(tostring(key)), 2)
  end,
}

local timeKeys = { "index", "year", "month", "day", "dayOfYear", "days", "dt" }

local function prepare(date, seed, index)
  local vals, ins, tim = rt.vals, rt.ins, rt.tim
  local s = newTable(0, #names + #inputNames)
  for i = 1, #names do s[names[i]] = vals[i] end
  for i = 1, #inputNames do s[inputNames[i]] = ins[i] end
  setmetatable(s, stateMeta)
  local t = newTable(0, 12)
  for i = 1, #timeKeys do t[timeKeys[i]] = tim[i] end
  t.date, t.events, t.random, t.normal, t.emit = date, rt.evs, random, normal, emit
  randomseed(seed, index)
  emitted = {}
  return s, t
end

local function collect(s)
  local vals, ins = rt.vals, rt.ins
  for i = 1, #names do
    local value = rawget(s, names[i])
    if type(value) ~= "number" then
      if value == true then value = 1
      elseif value == false then value = 0
      else error("s." .. names[i] .. " should be a number, but it's " .. (value == nil and "nil" or ("a " .. type(value))), 0) end
    end
    vals[i] = value
  end
  for i = 1, #inputNames do
    local value, original = rawget(s, inputNames[i]), ins[i]
    if value ~= original and not (value ~= value and original ~= original) then
      error("s." .. inputNames[i] .. " is an input from another slot, so the script can't change it", 0)
    end
  end
end

function rt.finish()
  loading = false
  userStep, userStart = rawget(_G, "step"), rawget(_G, "start")
  if userStep ~= nil and type(userStep) ~= "function" then error("step should be a function: function step(s, t) ... end", 0) end
  if userStart ~= nil and type(userStart) ~= "function" then error("start should be a function: function start(s, t) ... end", 0) end
  for _, entry in ipairs(params) do names[#names + 1] = entry.name end
  for _, entry in ipairs(vars) do names[#names + 1] = entry.name end
  for _, entry in ipairs(inputs) do inputNames[#inputNames + 1] = entry.name end
  -- Values that change belong in s, where the app can rewind them. The globals move to a table
  -- of their own, so every assignment to _G, new or not, reaches __newindex.
  local globals, frozen = _G, {}
  for key, value in next, globals do frozen[key] = value end
  for key in next, frozen do rawset(globals, key, nil) end
  setmetatable(globals, {
    __index = frozen,
    __newindex = function(_, key)
      error("globals can't change while the script runs, so the app can rewind it. Use local " .. tostring(key)
        .. ", or declare it with init or output.", 2)
    end,
  })
end

function rt.describe()
  local handlerTexts = list()
  for i, handler in ipairs(handlers) do handlerTexts[i] = handler.text end
  return encode({
    every = everyText, timeunit = timeunitText,
    params = list(params), vars = list(vars), inputs = list(inputs), emits = list(emitList),
    handlers = handlerTexts, hasStep = userStep ~= nil, hasStart = userStart ~= nil,
  })
end

function rt.start(date, seed, index)
  local s, t = prepare(date, seed, index)
  running = false
  userStart(s, t)
  collect(s)
end

function rt.step(date, seed, index)
  local s, t = prepare(date, seed, index)
  running = true
  if userStep then userStep(s, t) end
  local events = rt.evs
  for i = 1, #events do
    local event = events[i]
    for j = 1, #handlers do
      local handler = handlers[j]
      if handler.kind == event.kind and handler.slot == event.slot then handler.fn(s, event, t) end
    end
  end
  running = false
  collect(s)
  return #emitted
end

function rt.emitted()
  return encode(list(emitted))
end

function rt.output()
  return concat(printed, "\n")
end

return rt
"""#
