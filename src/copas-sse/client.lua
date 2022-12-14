--- Server-Sent-Events client for Copas.
--
-- According to [this specification](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream).
--
-- For usage see the [`philips-hue.lua`](examples/philips-hue.lua.html) example.
--
-- @copyright Copyright (c) 2022-2022 Thijs Schreijer
-- @author Thijs Schreijer
-- @license MIT, see `LICENSE`.

local SSE_Client = {}
SSE_Client.__index = SSE_Client
SSE_Client._VERSION = "0.1.0"
SSE_Client._COPYRIGHT = "Copyright (c) 2022-2022 Thijs Schreijer"
SSE_Client._DESCRIPTION = "Lua Server-Sent-Events client for use with the Copas scheduler"

local copas = require "copas"
local http = require("copas.http")
local http_request = http.request
local Queue = require("copas.queue")
local Timer = require("copas.timer")
local socket = require("socket")


local LF = string.char(tonumber("0A",16))
local CR = string.char(tonumber("0D",16))
local CRLF = CR..LF
local NULL = string.char(tonumber("00",16))
local UTF8_BOM = string.char(tonumber("EF",16)) ..
                 string.char(tonumber("BB",16)) ..
                 string.char(tonumber("BF",16))


--- The LuaLogging compatible logger in use. If [LuaLogging](https://lunarmodules.github.io/lualogging/)
-- was loaded then it will use the `defaultLogger()`, otherwise a stub.
-- The logger can be replaced, to customize the logging.
-- @field SSE_Client.url
SSE_Client.log = require("copas-sse.log")


--- Current connection state (read-only). See `SSE_Client.states`.
-- @field SSE_Client.state


--- The url providing the stream (read-only).
-- @field SSE_Client.url


--- Constants to match `SSE_Client.state` (read-only). Eg. `if client.state ==
-- SSE_Client.states.CONNECTING then ...`.
-- Values are; `CONNECTING`, `OPEN`, `CLOSED`.
-- @field SSE_Client.states
SSE_Client.states = setmetatable({
  CONNECTING = "connecting",
  OPEN = "open",
  CLOSED = "closed",
}, {
  __index = function(self, key)
    error("'"..tostring(key).."' is not a valid state, use 'CONNECTING', 'OPEN', or 'CLOSED'", 2)
  end,
})


local function set_state(self, new_state)
  if self.state == new_state then return end
  self.state = new_state
  self.queue:push {
    client = self,
    type = "connect",
    data = self.state,
  }
end


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
        self.log:info("[SSE-client] received reconnect-delay: %s ms", value)
      end

    elseif field == "" then
      local comment = line:gsub("^:%s?", "")
      self.queue:push {
        client = self,
        type = "comment",
        data = comment,
      }
      self.log:debug("[SSE-client] received comment: %s", comment)

    else
      self.log:warn("[SSE-client] received bad line: '%s'", line)
    end
  end

  if next(event) then
    event.client = self
    event.type = "event"
    event.event = event.event or "message"  -- set default event type
    if (not self.data_as_table) and event.data then
      event.data = table.concat(event.data, "\n")
    end
    self.queue:push(event)
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

  self.last_event_time = socket.gettime()

  if self.state == self.states.CONNECTING then
    set_state(self, SSE_Client.states.OPEN)
    self.log:debug("[SSE-client] connection state: open")
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
    if #self.sbuffer < #UTF8_BOM then
      self.socket:settimeouts(nil, nil, self.timeout)
      return 1
    end
    if self.sbuffer:sub(1,#UTF8_BOM) == UTF8_BOM then
      -- drop the BOM characters
      self.buffer = self.buffer:sub(#UTF8_BOM+1, -1)
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
    -- TODO: on first chunk, check "Content-Type" header to be "text/event-stream", and status 200 if not
    -- close and exit with an error (no retries). Copas http client doesn't support
    -- passing headers here...
    parse_chunk(self, chunk)
    return 1
  end
  return sink
end


--- Closes the connection.
-- Call this function to exit the event stream. This will destroy the message-queue.
-- If a timeout is provided then the timeout will be passed to `queue:finish(timeout)`,
-- if omitted the queue will be destroyed by calling `queue:stop()`. See Copas
-- documentation for the difference.
-- @tparam[opt] number timeout Timeout in seconds.
-- @return results from `queue:stop` or `queue:finish`.
function SSE_Client:close(timeout)
  self.log:debug("[SSE-client] closing connection")
  set_state(self, SSE_Client.states.CLOSED)
  if self.socket then
    self.socket:close()
  end

  -- yield one cycle, to allow the request to return after closing the socket. This
  -- to prevent just returned events from erroring when adding to a 'destroyed' queue.
  copas.pause(0)

  if timeout then
    return self.queue:finish(timeout)
  end
  return self.queue:stop()
end


--- Creates a new SSE client.
--
-- The message objects will be pushed to the returned `Queue` instance. The message contains the following fields:
--
--  - `"type"`: one of `"event"` (incoming data), `"comment"` (incoming comment),
--    `"connect"` (connection state changed), or `"error"` (connection error happened).
--
--  - `"id"`: the event id (only for "event" types).
--
--  - `"event"`: event name (only for "event" types).
--
--  - `"data"` for "event" type: a string, or an array of strings (if option `data_as_table` was set).
--
--  - `"data"` for "comment" type: the comment (string).
--
--  - `"data"` for "connect" type: the new connection state (string) `"connecting"`, `"open"`, or `"close"`.
--
--  - `"data"` for "error" type: the error message (string).
--
-- @tparam table opts Options table.
-- @tparam string opts.url the url to connect to for the event stream.
-- @tparam[opt] table opts.headers table of headers to include in the request.
-- @tparam[opt] string opts.last_event_id The last event ID to pass to the server when initiating the stream..
-- @tparam[opt=30] number opts.timeout the timeout (seconds) to use for connecting to the stream.
-- @tparam[opt=300] number opts.next_event_timeout the timeout (seconds) between 2 succesive events.
-- @tparam[opt=3] number opts.reconnect_delay delay (seconds) before reconnecting after a lost connection.
-- This is the initial setting, it can be overridden by the server if it sends a new value.
-- @tparam[opt] number|nil opts.event_timeout timeout (seconds) since last event, after which the socket
-- is closed and reconnection is started. Default is "nil"; no timeout.
-- @tparam[opt=false] bool opts.data_as_table return data as an array of lines.
-- @return new client object
function SSE_Client.new(opts)
  local self = setmetatable({}, SSE_Client)
  self.lbuffer = {}   -- line buffer
  self.sbuffer = ""   -- string buffer
  self.ignore_next_LF = false
  self.state = self.states.CLOSED -- set directly, to not send event (bypass set_state)

  if opts.last_event_id ~= nil and type(opts.last_event_id) ~= string then
    error("expected 'last_event_id' to be a string value", 2)
  end
  if opts.event_timeout then
    assert(type(opts.event_timeout) == "number" and opts.event_timeout > 1,
          "expected 'event_timeout' to be a number > 1 (or nil)")
  end
  self.last_event_id = opts.last_event_id or ""
  self.timeout = opts.timeout or 30
  self.next_event_timeout = opts.next_event_timeout or (5 * 60)
  self.headers = opts.headers or {}
  self.reconnect_delay = opts.reconnect_delay or 3 -- in seconds
  self.url = assert(opts.url, "expected a 'url' option")
  self.data_as_table = not not opts.data_as_table
  self.event_timeout = opts.event_timeout
  return self
end


local function start(self)
  set_state(self, SSE_Client.states.CONNECTING)
  self.log:debug("[SSE-client] starting connection, connection state: connecting")

  self.lbuffer = {}   -- line buffer
  self.sbuffer = ""   -- string buffer
  self.ignore_next_LF = false
  self.expect_utf8_bom = false
  self.last_event_time = socket.gettime()
  if self.event_timeout then
    self.last_event_timer = Timer.new {
      delay = self.event_timeout,
      name = "Hue event-timeout",
      callback = function()
        if self.state ~= SSE_Client.states.OPEN then
          -- not open, so delay for another round
          self.last_event_timer:arm(self.event_timeout)
          return
        end
        local t = socket.gettime()
        local to = self.last_event_time + self.event_timeout
        if to < t then
          -- we've got a timeout
          self.log:warn("[SSE-client] event-timeout, closing connection for reconnect")
          self.socket:close()
          self.last_event_timer:arm(self.event_timeout)
          return
        end
        -- no timeout, reschedule timer based on last event
        self.last_event_timer:arm(self.last_event_time + self.event_timeout - t)
      end
    }
  end

  local headers = {}
  for k,v in pairs(self.headers) do headers[k] = v end

  repeat
    headers["Accept"] = "text/event-stream"
    headers["Cache-Control"] = "no-cache"
    headers["Last-Event-ID`"] = self.last_event_id

    -- TODO: do a callback here to allow for updating headers in case of expired tokens, etc.

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

    self.log:debug("[SSE-client] initiating request: %s", self.url)
    local ok, resp_status = http_request(self.request)

    if self.state ~= self.states.CLOSED then
      -- error happened, and we need to reconnect
      set_state(self, SSE_Client.states.CONNECTING)

      local msg
      if ok then
        msg = "request terminated, returned status: " .. tostring(resp_status)
        self.log:warn("[SSE-client] %s", msg)

      elseif resp_status == "timeout" and #self.lbuffer == 0 and self.sbuffer == "" then
        msg = "timeout while connecting, or waiting for next event"
        self.log:warn("[SSE-client] %s", msg)

      elseif resp_status == "timeout" then
        msg = "timeout while receiving event data"
        self.log:error("[SSE-client] %s", msg)

      else
        msg = "request failed with: " .. tostring(resp_status)
        self.log:error("[SSE-client] %s", msg)
      end
      self.queue:push {
        client = self,
        type = "error",
        data = msg,
      }

      self.log:debug("[SSE-client] reconnecting in %d seconds", self.reconnect_delay)
      copas.pause(self.reconnect_delay)
    end

  until self.state == self.states.CLOSED

  if self.last_event_timer then
    self.last_event_timer:cancel()
    self.last_event_timer = nil
  end

  self.log:debug("[SSE-client] connection finished")
end


--- Starts the connection.
-- Will start the http-request (in the background) and keep looping/retrying to read
-- events. In case of network failures it will automatically reconnect and use the
-- `last_event_id` to resume events.
--
-- The returned queue (a `copas.queue` instance), will receive incoming events.
-- @return event-queue or `nil + "already started"`
function SSE_Client:start()
  if self.state ~= self.states.CLOSED then
    return nil, "already started"
  end

  self.queue = Queue.new {
    name = "SSE queue " .. self.url
  }

  copas.addthread(start, self)

  return self.queue
end


return SSE_Client
