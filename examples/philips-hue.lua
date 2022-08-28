-- Example for Server-Sent events client.
-- It reads events from a Philips Hue bridge

local BRIDGE_IP = assert(os.getenv("HUE_IP"), "please set env var 'HUE_IP'")
local API_KEY = assert(os.getenv("HUE_KEY"), "please set env var 'HUE_KEY'")

require "logging" -- pre-load lualogging to enable logs

local SSE_Client = require "copas-sse/client"
local Timer = require "copas.timer"
local copas = require "copas"


-- create the client
local client = SSE_Client.new {
  url = "https://" .. BRIDGE_IP .. "/eventstream/clip/v2",
  headers = { ["Hue-Application-Key"] = API_KEY },
}


-- start the client and collect the destination queue
local event_queue = client:start()


-- add a worker to handle the incoming messages
event_queue:add_worker(function(msg)
  if msg.type then  print("type :" .. msg.type) end
  if msg.id then    print("id   :" .. msg.id) end
  if msg.event then print("event:" .. msg.event) end
  if msg.data then  print("data :" .. msg.data) end
  print("")
end)


-- add an exit timer that will close the stream after 60 seconds
Timer.new {
  delay = 60,
  callback = function() client:close() end
}


-- start the application
copas.loop()
