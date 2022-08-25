--- Server Side Events client for Copas.
--
-- According to [this specification](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream).
--
-- For usage see the [`philips-hue.lua`](examples/philips-hue.lua.html) example. It shows how to decouple the receiving thread
-- (executing the callbacks) and the actual handling thread. If it would not be decoupled, and the event handler would
-- take a long time (network timeout for example), then during that time, no new events would be received.
--
-- @copyright Copyright (c) 2022-2022 Thijs Schreijer
-- @author Thijs Schreijer
-- @license MIT, see `LICENSE`.

local SSE_Client = {}
SSE_Client.__index = SSE_Client
SSE_Client._VERSION = "0.0.1"
SSE_Client._COPYRIGHT = "Copyright (c) 2022-2022 Thijs Schreijer"
SSE_Client._DESCRIPTION = "Lua Server-Side-Event client for use with the Copas scheduler"


local copas = require "copas"
local http = require("copas.http")
local http_request = http.request


local LF = string.char(tonumber("0A",16))
local CR = string.char(tonumber("0D",16))
local CRLF = CR..LF
local NULL = string.char(tonumber("00",16))
local UTF8_BOM = string.char(tonumber("FE",16))..string.char(tonumber("FF",16))


--- Current connection state. See `SSE_Client.states`.
-- @field SSE_Client.readyState

--- Constants to match `SSE_Client.readyState`. Eg. `if client.readyState == SSE_Client.states.CONNECTING then ...`.
-- Values are; `CONNECTING`, `OPEN`, `CLOSED`.
-- @field SSE_Client.states
SSE_Client.states = setmetatable({
  CONNECTING = 0,
  OPEN = 1,
  CLOSED = 2,
}, {
  __index = function(self, key)
    error("'"..tostring(key).."' is not a valid state, use 'CONNECTING', 'OPEN', or 'CLOSED'", 2)
  end,
})


-- handles an array of lines as a single event/message
local function handle_message(self, lines)
  local event = {}
  for i, line in ipairs(lines) do
    local field, value
    local colon, cend = line:find(":%s?")

    if not colon then
      field = line
      value = ""
    else
      field = line:sub(1, colon - 1)
      value = line:sub(cend + 1, -1)
    end

    if field == "event" then
      event.event = value

    elseif field == "data" then
      local d = event.data
      if not d then
        d = {}
        event.data = d
      end
      d[#d + 1] = value

    elseif field == "id" and value ~= NULL then
      event.id = value
      self.last_event_id = value

    elseif field == "retry" then
      if value:match("^%d+$") then
        self.reconnect_delay = tonumber(value) / 1000 -- convert to seconds
      end

    elseif field == "" then
      -- comment
      self:cb_comment(line:gsub("^:%s?", ""))

    -- else
      -- ignore, log something?
    end
  end

  if next(event) then
    event.event = event.event or "message"  -- set default event type
    if event.data and not self.data_as_table then
      event.data = table.concat(event.data, LF) .. LF
    end

    self:cb_message(event)
  end
end


-- Parsed the clients string buffer into lines. If lines result in complete
-- messages, they will be handled.
local function parse_buffer(self)
  -- parse string buffer to lines
  --print("buffer:",self.sbuffer)
  local pos = 1
  for line, remainder in self.sbuffer:gmatch("([^"..LF.."]*)"..LF) do
    self.lbuffer[#self.lbuffer + 1] = line
    pos = pos + #line + 1
  end
  self.sbuffer = self.sbuffer:sub(pos,-1)

  -- check lines for complete messages
  local msg = {}
  for i, line in ipairs(self.lbuffer) do
    -- not a comment
    if line == "" then
      -- end of message
      if #msg > 0 then
        handle_message(self, msg)
        msg = {}
      end
    else
      msg[#msg+1] = line
    end
  end
  self.lbuffer = msg
end


local function parse_chunk(self, chunk)
  if not chunk then
    return true
  end

  if self.readyState == self.states.CONNECTING then
    self.readyState = self.states.OPEN
  end

  if self.ignore_next_LF and chunk:sub(1,1) == LF then
    -- CRLF was split across chunks, ignore initial LF for new chunk
    chunk = chunk:sub(2,-1)
    self.ignore_next_LF = false
  end

  if #chunk == 0 then
    return true
  end

  if chunk:sub(-1,-1) == CR then
    -- last byte is a CR, so IF the next chunk starts with an LF, we should ignore it
    self.ignore_next_LF = true
  end

  -- normalize to LF line endings, and store
  chunk = chunk:gsub(CRLF, LF):gsub(CR, LF)
  self.sbuffer = self.sbuffer .. chunk

  if self.expect_utf8_bom then
    if #self.sbuffer < 2 then
      -- this is safe, since every message is terminated by 2 LF's, so if the first
      -- bytes we handle are less than 2, we can safely wait for more to appear.
      -- Set short timeout while waiting for remainder
      self.socket:settimeouts(nil, nil, self.timeout)
      return 1
    end
    if self.sbuffer:sub(1,2) == UTF8_BOM then
      -- drop the BOM characters
      self.buffer = self.buffer:sub(3, -1)
    end
    self.expect_utf8_bom = false
  end

  parse_buffer(self)

  if self.socket then
    if self.sbuffer == "" then
      -- empty buffer, so wait for next event (long)
      self.socket:settimeouts(nil, nil, self.next_event_timeout)
    else
      -- last message incomplete, use short timeout while waiting for remainder
      self.socket:settimeouts(nil, nil, self.timeout)
    end
  end

  return true
end


local function sse_sink(self)
  local function sink(chunk)
    parse_chunk(self, chunk)
    return 1
  end
  return sink
end


--- Closes the connection.
-- Call this function to exit the event stream and have the `SSE_Client:start`
-- call return.
-- @return true
function SSE_Client:close()
  self.readyState = self.states.CLOSED
  if self.socket then
    self.socket:close()
  end
  return true
end

--- Creates a new SSE client.
--
-- The callback functions both have signature `function(SSE_Client, msg)`. Where `msg` will
-- be a `string` in case of the comment callback, or a message object otherwise.
--
-- The message object
-- can have up to 3 fields;  `"id"`, `"event"`, and `"data"`. The `data` field will have
-- multiple `data` lines concatenated with `LF`(x0A) (including the trailing one), in
-- conformance with the spec (unless `opts.data_as_table` has been set).
-- @tparam table opts Options table.
-- @tparam string opts.url the url to connect to for the event stream.
-- @tparam[opt] table opts.headers table of headers to include in the request.
-- @tparam[opt] function opts.cb_message the callback function to deliver incoming events to.
-- @tparam[opt] function opts.cb_comment the callback function to deliver incoming comments to.
-- @tparam[opt] string opts.last_event_id The last event ID to pass to the server when initiating the stream..
-- @tparam[opt=30] number opts.timeout the timeout (seconds) to use for connecting to the stream.
-- @tparam[opt=300] number opts.next_event_timeout the timeout (seconds) between 2 succesive events.
-- @tparam[opt=3] number opts.reconnect_delay delay (seconds) before reconnecting after a lost connection.
-- This is the initial setting, it can be overridden by the server if it sends a new value.
-- @tparam[opt] bool opts.data_as_table if truthy, the `data` field in the messages will an array of strings,
-- without the LF line terminators. Otherwise it will be a `LF` separated/terminated string.
-- @return new client object
function SSE_Client.new(opts)
  local self = setmetatable({}, SSE_Client)
  self.lbuffer = {}   -- line buffer
  self.sbuffer = ""   -- string buffer
  self.ignore_next_LF = false
  self.readyState = self.states.CLOSED

  if opts.last_event_id ~= nil and type(opts.last_event_id) ~= string then
    error("expected 'last_event_id' to be a string value", 2)
  end
  self.last_event_id = opts.last_event_id
  self.timeout = opts.timeout or 30
  self.next_event_timeout = opts.next_event_timeout or (5 * 60)
  self.headers = opts.headers or {}
  self.reconnect_delay = opts.reconnect_delay or 3 -- in seconds
  self.url = assert(opts.url, "expected a 'url' option")
  self.cb_message = opts.cb_message or function() end  -- function(sse_client, msg)
  self.cb_comment = opts.cb_comment or function() end  -- function(sse_client, comment)
  self.data_as_table = not not opts.data_as_table
  return self
end


--- Starts the connection.
-- Will start the request and keep looping/retrying to handle events. In case of
-- network failures it will automatically reconnect and use the `last_event_id`
-- to resume events.
--
-- **NOTE**: This function will NOT return until the connection is closed by calling
-- `SSE_Client:close`.
-- @return true
function SSE_Client:start()
  if self.readyState ~= self.states.CLOSED then
    return nil, "already started"
  end
  self.readyState = self.states.CONNECTING

  self.lbuffer = {}   -- line buffer
  self.sbuffer = ""   -- string buffer
  self.ignore_next_LF = false
  self.expect_utf8_bom = false

  local headers = {}
  for k,v in pairs(self.headers) do headers[k] = v end

  repeat
    headers["Accept"] = "text/event-stream"
    headers["Last-Event-ID`"] = self.last_event_id

    local creator

    self.request = {
      url = self.url,
      sink = sse_sink(self),
      method = "GET",
      headers = headers,
      timeout = self.timeout,
      create = function(reqt)
        -- use a create function that wraps around the regular one, but stores
        -- the created socket in our request table, for later use;
        -- changing timeouts, and closing
        creator = creator or http.getcreatefunc(self.request)
        local sock, err = creator(reqt)
        self.socket = sock
        copas.setsocketname("SSE stream " .. self.url, sock)
        return sock, err
      end
    }

    local ok, resp_status = http_request(self.request)

    if self.readyState == self.states.CLOSED then
      print("exiting, client was closed by user")
    elseif ok then
      print("request returned status: ", resp_status)
    elseif resp_status == "timeout" and #self.lbuffer == 0 and self.sbuffer == "" then
      print("timeout while connecting, or waiting for next event")
    elseif resp_status == "timeout" then
      print("timeout while receiving event data")
    else
      print("request failed with: ", resp_status)
    end

    if self.readyState ~= self.states.CLOSED then
      self.readyState = self.states.CONNECTING
      copas.sleep(self.reconnect_delay)
    end

  until self.readyState == self.states.CLOSED

  return true
end


return SSE_Client
