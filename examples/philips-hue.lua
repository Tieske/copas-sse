-- Example showing event handling decoupled.
-- It reads events from a Philips Hue bridge

local BRIDGE_IP = assert(os.getenv("HUE_IP"), "please set env var 'HUE_IP'")
local API_KEY = assert(os.getenv("HUE_KEY"), "please set env var 'HUE_KEY'")


local SSE_Client = require "copas-sse/client"
local Queue = require "copas.queue"
local Timer = require "copas.timer"
local copas = require "copas"


-- create a que to decouple the event-stream from the event-handlers
local event_queue = Queue:new { name = "SSE event handler" }


-- add a worker to handle the incoming events
event_queue:add_worker(function(msg)
  if msg.id then    print("id   :" .. msg.id) end
  if msg.event then print("event:" .. msg.event) end
  if msg.data then  print("data :" .. msg.data) end
  print("")
end)


-- create the client in its own thread
local client
copas.addthread(function()
  copas.setthreadname("SSE stream reader")

  client = SSE_Client.new {
    url = "https://" .. BRIDGE_IP .. "/eventstream/clip/v2",
    headers = { ["Hue-Application-Key"] = API_KEY },
    cb_message = function(self, msg) event_queue:push(msg) end,
  }

  client:start()  -- this will not return until the client gets closed
  print "Event client was closed, destroying the queue and handler(s)..."
  event_queue:finish(10)
  print "Done!"
end)


-- add an exit timer that will close the stream after 60 seconds
Timer.new {
  delay = 60,
  callback = function() client:close() end
}


-- start the application
copas.loop()
