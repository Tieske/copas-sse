# Server-Sent Events extension proposal

## The specification

[The SSE specification](https://html.spec.whatwg.org/multipage/server-sent-events.html) is part of the [WHATWG workgroup](https://whatwg.org/) set of standards.

The Server-Sent event (SSE) specification has some shortcomings that will not be resolved by the standard. The spec is [no longer expected to be updated as it has been superseded by newer tools in the browser world](https://github.com/whatwg/html/issues/8297#issuecomment-1293054529). It is not a spec on its own, but rather part of the [HTML spec](https://html.spec.whatwg.org/). And even within itself the spec is a mixture of 2 components;
1. The actual protocol, with data formats, sequences, etc.
2. The browser side interface (the `EventSource` API)

Since SSE is also used outside of the browser world, where it cannot be replaced by the newer browser based tools, this document picks up where WHATWG left it.

---

## The extension

This document specifies extensions (designed to be compatible) on top of the WHATWG spec, to overcome the shortcomings in the spec. Since this is an extension, it will also cover both the protocol itself, as well as the `EventSource` API.

---

### Keep-Alive

Connections can go stale, without notification on client side. Hence the problem is that a client will wait forever on a stale connection for the next event.

To resolve this the server can sent comment messages at regular intervals. The client needs to know what the interval is to be able to drop the existing connection and reconnect.

#### Server implementation

If the Server supports keep-alive, it should include a response header;
```
    Sse-Keep-Alive: <integer number in seconds>
```
The interval choosen by the server should be small enough that all events reasonably expected to happen within one interval can be queued by the Server. Such that reconnecting with the `Last-Event-ID` will not break the client-side stream by missing events.

Reasonable keep-alive time takes into account:
- queue capacity server-side
- reconnect time (client delay before reconnecting)
- assume the client will overrun the interval by 10-50% before reconnecting

Processing the keep-alive interval server-side:

1. On connection start, the server should immediately send some data. This data can be either an event or otherwise a comment.
1. A keep-alive timer is set to expire in the interval specified.
1. Optional: upon sending any message (event or comment) the keep-alive timer is reset for again the interval specified.
1. When the keep-alive timer expires, a comment is to be transmitted to the client.

The server can sent keep-alive comments sooner than the interval expires, but should never sent it later.

#### Client implementation

Upon receiving the initial response, the presence of the response header `Sse-Keep-Alive` informs the client on whether this keep-alive extension is supported or not.

Processing the keep-alive interval client-side:

1. On connection start, introspect the `Sse-Keep-Alive` response header to find the keep-alive interval. If unspecified, a user specified value can be used. The response-header value should take precedence over any user specified value.
1. A keep-alive timer is set to expire in the interval specified + an extra delay. The extra delay is suggested to be 10-50% of the interval, with a suggested minimum of 1 and maximum of 10 seconds.
1. Upon reception of any data (event or comment), the keep-alive timer is reset to its original value.
1. When the keep-alive timer expires, the client should assume the connection failed, and start the reconnect sequence, while respecting the reconnect delay.

---

### Event stream resuming

The `Last-Event-ID` parameter allows a client to resume the event-stream after it had a connection failure. This relies on the server to be able to queue the messages for each client. Obviously this queue capacity is limited, as at some point the server will run out of resources. Unfortunately the client, once the auto-reconnect succeeds, will not be informed it missed some events and its received stream is incomplete.

To overcome this the client can add an EventHandler;
```js
    attribute EventHandler onreset; // Event handler event type: error
```
And the server can add a response header;
```
    Sse-Stream-Status: [ initialized | continued | reset ]
```
Where;
- `"initialized"` means no `Last-Event-ID` was received in the request, and hence the stream is a fresh one. The presence of this response-header will indicate to the client that this extension is supported by the server.
- `"continued"` means the event-stream is being resumed, and no loss of events has occured.
- `"reset"` means that the specified `Last-Event-ID` was no longer available (or was invalid), and the stream is a fresh one. The client might have missed events that fired while it was disconnected.

#### Server implementation

Processing the stream-status info server-side:

1. On connection start, the server checks the client provided `Last-Event-ID` value.
1. If not provided the server adds `Sse-Stream-Status: initialized` to the response headers.
1. If provided and still available the server adds `Sse-Stream-Status: continued` to the response headers.
1. If provided and no longer available (or invalid) the server adds `Sse-Stream-Status: reset` to the response headers.


#### Client implementation

Upon receiving the initial response, the presence of the response header `Sse-Stream-Status` informs the client on whether this stream-status extension is supported or not.

Processing the stream-status client-side:

1. On connection start, introspect the `Sse-Stream-Status` response header
1. if the value is `"reset"` then fire the `onreset` event with event type `error`, before processing any new events.

