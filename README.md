# Firehose 2.0

Real-time streaming for Rails with WebSocket and SSE transports, database-backed persistence, and automatic replay on reconnect.

Built on a dedicated PostgreSQL LISTEN/NOTIFY connection — no ActionCable, no polling, no connection pool pressure.

## Why not ActionCable?

ActionCable is fire-and-forget. Messages are published into Redis pub/sub with no persistence — if a client is disconnected when a message arrives, that message is gone. There's no way to know what was missed, and no way to catch up.

This matters more than it sounds. Mobile users tunnel through subways. Laptops go to sleep. WiFi drops for a few seconds during a video call. Browser tabs get suspended by the OS to save memory. In every case, the WebSocket closes, messages fly by, and when the client reconnects it has no idea it missed anything. The UI is silently stale.

ActionCable also has no concept of message ordering. If you broadcast three updates to a stream, there's no sequence number, no monotonic ID, nothing for the client to compare against. You can't detect a gap because there's nothing to detect a gap *in*.

Firehose fixes this:

- **Every message is persisted** in PostgreSQL with a monotonic sequence per stream and a global auto-incrementing ID. Messages are real database rows, not ephemeral pub/sub pings.

- **Clients track their position** via `last_event_id`. The JavaScript client tracks the highest event ID it has seen. On reconnect, it sends this ID back to the server.

- **Replay on reconnect.** The server queries all messages with `id > last_event_id` across the client's subscribed streams and replays them in order before resuming live delivery. The client sees every message, in order, with no gaps.

- **Sequence numbers detect channel resets.** Each stream has its own monotonic sequence counter. If a client sees sequence 5 followed by sequence 1, it knows the channel was reset (e.g., data was cleared, the stream was recreated). The client can react accordingly — full refresh, re-fetch state, whatever makes sense for the application.

- **The browser does most of the work.** The `<firehose-stream-source>` custom element handles subscribe, unsubscribe, reconnection with exponential backoff, and `last_event_id` tracking automatically. Drop the element in your HTML and forget about it.

- **No Redis.** Everything runs on PostgreSQL, which you already have. LISTEN/NOTIFY for real-time fan-out, regular tables for persistence. One fewer piece of infrastructure.

## Prior Art

### ActionCable + Redis

The default Rails real-time stack. Redis pub/sub distributes messages across processes — fast, simple, and well-documented. But Redis pub/sub is ephemeral: messages exist only in the moment they're published. No persistence, no replay, no sequence numbers. The JavaScript client reconnects automatically but starts from zero every time. Works fine when "best effort" delivery is acceptable and you don't mind the occasional stale UI after a reconnect.

### SolidCable

37signals' database-backed ActionCable adapter, shipping with Rails 8. Replaces Redis with a `solid_cable_messages` table — each process polls for new messages by ID. Eliminates Redis as a dependency, which is great. The messages *are* in the database with auto-incrementing IDs, so the raw material for replay is right there. But SolidCable doesn't expose it: the ActionCable client has no `last_event_id` concept, so reconnection still means missed messages. Polling also introduces a small latency floor (default 100ms) compared to LISTEN/NOTIFY which is near-instant.

### AnyCable

Moves WebSocket connection handling to a Go or Rust server, calling back to Rails via gRPC for channel logic. Dramatically better connection scalability — tens of thousands of connections instead of hundreds. The commercial Pro version adds reliable streams with epoch+offset tracking and replay on reconnect, which solves the persistence gap. The open-source version is fire-and-forget like ActionCable. Requires deploying and operating a separate server process, plus Redis or NATS for pub/sub between the Go server and Rails.

### Turbo Streams / Broadcasts

A presentation layer on top of ActionCable, not a transport. Broadcasts `<turbo-stream>` HTML fragments that surgically update the DOM. Turbo 8's page refresh (morphing) simplifies this — broadcast `"refresh"` and the client re-fetches the full page, sidestepping DOM-ID coupling. Page refresh partially mitigates missed messages since each refresh fetches complete state, but the refresh *signal* itself can still be lost during a disconnection window. Inherits all of ActionCable's delivery guarantees (none).

### Mercure

A standalone SSE hub (written in Go) with built-in persistence and `Last-Event-ID` replay. Closest in philosophy to Firehose — messages are persisted, clients resume from where they left off, and SSE's native reconnection handles the transport. Not Rails-specific and requires deploying a separate server. SSE is unidirectional (server-to-client), so client-to-server communication needs separate HTTP requests.

### How Firehose Compares

| | ActionCable | SolidCable | AnyCable Pro | Mercure | **Firehose** |
|---|---|---|---|---|---|
| **Replay on reconnect** | No | No | Yes | Yes | **Yes** |
| **Message persistence** | No | Yes (no replay API) | Yes | Yes | **Yes** |
| **Sequence numbers** | No | No | Epoch+offset | Event IDs | **Per-stream monotonic** |
| **Infrastructure** | Redis | Database | Go/Rust + Redis/NATS | Go hub | **PostgreSQL** |
| **Transport** | WebSocket | WebSocket | WebSocket | SSE | **WebSocket + SSE** |
| **Latency** | ~instant | ~100ms (polling) | ~instant | ~instant | **~instant (NOTIFY)** |
| **Extra processes** | No | No | Yes | Yes | **No** |

## Quick Start

Add to your Gemfile:

```ruby
gem "firehose"
```

Install:

```bash
bundle install
bin/rails generate firehose:install
```

This creates a `FirehoseController`, adds routes, wires up the JavaScript client, and runs migrations.

Publish from anywhere in your app:

```ruby
Firehose.channel("dashboard").publish("refresh")
```

Subscribe in your views:

```html
<firehose-stream-source streams="dashboard"></firehose-stream-source>
```

The page will automatically refresh via Turbo when an event arrives.

## Features

- **Dual transports**: WebSocket and Server-Sent Events (SSE)
- **Database persistence**: Messages stored in PostgreSQL for replay on reconnect
- **Automatic replay**: Missed events delivered via `last_event_id` (WebSocket) or `Last-Event-ID` (SSE)
- **Dedicated PG connection**: LISTEN/NOTIFY outside the ActiveRecord pool, PgBouncer-safe with direct connection
- **Inline delivery**: Small payloads sent inline via NOTIFY (no DB round-trip), large payloads fall back to DB fetch
- **Auto-cleanup**: Configurable threshold keeps the last N messages per stream
- **Falcon-compatible**: Built for async Ruby with async-websocket

## Channels

Channels are the primary API for publishing and subscribing:

```ruby
# Get a channel
channel = Firehose.channel("dashboard")

# Publish a message (persists to DB + NOTIFY)
channel.publish("refresh")
channel.publish({ action: "update", id: 42 }.to_json)

# Subscribe to live events (returns a closeable subscription)
sub = channel.subscribe { |payload| puts payload }
sub.close

# From a model
class Comment < ApplicationRecord
  after_commit :notify_post

  def notify_post
    Firehose.channel(post.to_gid_param).publish("refresh")
  end
end
```

## Queues

Queues provide ephemeral push/pop signaling over PG LISTEN/NOTIFY — no database persistence, no replay. Use them for transient coordination like auth nonces, job completion signals, or request/response patterns between processes.

```ruby
queue = Firehose.server.queue("my-queue")

# Producer
queue.push("hello")

# Consumer (blocks until a message arrives)
message = queue.pop
message = queue.pop(timeout: 5) # raises Firehose::Queue::TimeoutError

queue.close
```

## Controller

The install generator creates `app/controllers/firehose_controller.rb`:

```ruby
class FirehoseController < ApplicationController
  include Firehose::Stream  # Includes both WebSocket and SSE

  # Or include just one:
  # include Firehose::WebSocket
  # include Firehose::SSE
end
```

Add authentication and stream authorization:

```ruby
class FirehoseController < ApplicationController
  include Firehose::Stream

  before_action :authenticate_user!

  def authorize_streams(streams)
    streams.select { |s| current_user.can_access?(s) }
  end

  def build_event(event)
    # Transform events before sending, or return nil to skip
    event
  end
end
```

## Routes

The install generator adds these routes:

```ruby
match "firehose", to: "firehose#websocket", via: [:get, :connect]
get "firehose/sse", to: "firehose#sse"
```

## JavaScript Client

The install generator adds `import "firehose"` to your `application.js`. The importmap pin is set up automatically by the engine.

### Declarative (Custom Element)

```html
<firehose-stream-source path="/firehose" streams="dashboard,user:42"></firehose-stream-source>
```

When the element connects, it opens a WebSocket and subscribes to the listed streams. When it disconnects (page navigation, element removal), it unsubscribes. Reconnection with exponential backoff is automatic.

Multiple elements with the same `path` share a single WebSocket connection.

### Programmatic

```javascript
Firehose.subscribe("/firehose", ["dashboard", "user:42"])
Firehose.unsubscribe("/firehose", ["dashboard"])

// Listen for events
document.addEventListener("firehose:message", (e) => {
  console.log(e.detail) // { id: 123, stream: "dashboard", data: "refresh" }
})
```

### Turbo Integration

When an event has `data: "refresh"`, the client automatically triggers a Turbo page refresh. No additional setup needed — just publish `"refresh"` as your data payload.

## Phlex Helper

```ruby
class Components::Base < Phlex::HTML
  include Firehose::Helper
end
```

```ruby
firehose_stream_from @report
firehose_stream_from "dashboard", "user:#{current_user.id}"
firehose_stream_from @model, path: "/admin/firehose"
```

## Configuration

Create `config/firehose.rb` for Ruby configuration, or `config/firehose.yml` for YAML. Ruby config takes precedence.

### Ruby

```ruby
# config/firehose.rb
Firehose.server.configure do |config|
  config.database_url       = ENV["FIREHOSE_DATABASE_URL"] # Direct PG connection (bypasses PgBouncer)
  config.cleanup_threshold  = 100                          # Keep last N messages per stream (default: 100)
  config.reconnect_attempts = 5                            # Max reconnect attempts (default: 5)
  config.reconnect_delay    = 1                            # Base delay in seconds, doubles each attempt (default: 1)
  config.notify_max_bytes   = 7999                         # PG NOTIFY payload limit (default: 7999)
end
```

### YAML

```yaml
# config/firehose.yml
development:
  cleanup_threshold: 100

production:
  database_url: postgres://direct-db:5432/myapp
  cleanup_threshold: 100
  reconnect_attempts: 10
```

### Logger

```ruby
Firehose.logger = Rails.logger            # default in Rails
Firehose.logger = Logger.new($stdout)     # outside Rails
Firehose.logger.level = Logger::DEBUG     # verbose: LISTEN/UNLISTEN/NOTIFY
```

## Protocol

### WebSocket

```
Client → Server: { "command": "subscribe", "streams": ["a", "b"], "last_event_id": 123 }
Client → Server: { "command": "unsubscribe", "streams": ["a"] }
Server → Client: { "id": 456, "stream": "a", "data": "refresh", "sequence": 7, "channel_id": 3 }
```

### SSE

```
GET /firehose/sse?streams=a,b
Last-Event-ID: 123

id: 456
event: a
data: {"data":"refresh","channel_id":3,"sequence":7}
```

## Architecture

```
Firehose.channel("stream").publish("refresh")
    │
    ├── INSERT into firehose_messages (persistence for replay)
    │
    └── PG NOTIFY with inline event JSON (or message ID if > 8KB)
            │
            ▼
    Server background thread (IO.select on PG socket)
            │
            ├── WebSocket handler → browser → Turbo page refresh
            ├── SSE handler → browser → Turbo page refresh
            └── Firehose::Queue → Ruby consumer
```

**Live path**: NOTIFY carries the full event inline — no database round-trip.

**Replay path**: On reconnect, missed messages fetched from database by ID.

**Connection model**: One dedicated PG connection per process. LISTEN stays on this connection (PG requirement). NOTIFY commands are non-blocking (queued to background thread).

## License

MIT
