# Firehose 2.0

Real-time streaming for Rails with WebSocket and SSE transports, database-backed persistence, and automatic replay on reconnect.

Built on a dedicated PostgreSQL LISTEN/NOTIFY connection — no ActionCable, no polling, no connection pool pressure.

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

Broadcast from anywhere in your app:

```ruby
Firehose.broadcast("dashboard", "refresh")
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

## Broadcasting

```ruby
Firehose.broadcast("dashboard", "refresh")
Firehose.broadcast("user:42", "notification")

# From a model
class Comment < ApplicationRecord
  after_commit :notify_post

  def notify_post
    Firehose.broadcast(post.to_gid_param, "refresh")
  end
end
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

When an event has `data: "refresh"`, the client automatically triggers a Turbo page refresh. No additional setup needed — just broadcast `"refresh"` as your data payload.

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
Firehose.broadcast("stream", "refresh")
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
