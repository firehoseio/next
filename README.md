# Firehose 2.0

Real-time streaming for Rails with WebSocket and SSE transports, database-backed persistence, and automatic replay on reconnect.

Built on a dedicated PostgreSQL LISTEN/NOTIFY connection — no ActionCable, no polling, no connection pool pressure.

## Features

- **Dual transports**: WebSocket and Server-Sent Events (SSE)
- **Database persistence**: Messages stored in PostgreSQL for replay on reconnect
- **Automatic replay**: Missed events delivered via `Last-Event-ID` (SSE) or `last_event_id` (WebSocket)
- **Dedicated PG connection**: LISTEN/NOTIFY outside the ActiveRecord pool, PgBouncer-safe with direct connection
- **Inline delivery**: Small payloads sent inline via NOTIFY (no DB round-trip), large payloads fall back to DB fetch
- **Ruby queue**: `Firehose::Queue` for server-side push/pop over PG LISTEN/NOTIFY
- **Auto-cleanup**: Configurable threshold keeps the last N messages per stream
- **Falcon-compatible**: Built for async Ruby with async-websocket

## Installation

Add to your Gemfile:

```ruby
gem "firehose", path: "gems/firehose"
```

Run the migration:

```bash
bin/rails db:migrate
```

The engine auto-discovers its migrations — no generator needed.

## Usage

### Broadcasting

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

### Controller Setup

```ruby
class FirehoseController < ApplicationController
  include Firehose::Stream  # Includes both WebSocket and SSE

  # Or include just one:
  # include Firehose::WebSocket
  # include Firehose::SSE
end
```

With authentication and stream authorization:

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

### Routes

```ruby
# config/routes.rb
match "firehose", to: "firehose#websocket", via: [:get, :connect]
get "firehose/sse", to: "firehose#sse"
```

### JavaScript Client

```javascript
import "firehose"

// Declarative via custom element
<firehose-stream-source path="/firehose" streams="dashboard,user:42"></firehose-stream-source>

// Programmatic
Firehose.subscribe("/firehose", ["dashboard", "user:42"])
Firehose.unsubscribe("/firehose", ["dashboard"])

// Listen for events
document.addEventListener("firehose:message", (e) => {
  console.log(e.detail) // { id: 123, stream: "dashboard", data: "refresh" }
})
```

### Phlex Helper

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

### Ruby Queue

For server-side push/pop — ephemeral signaling over PG LISTEN/NOTIFY without database persistence:

```ruby
queue = Firehose.server.queue("my-channel")

# Producer
queue.push("hello")

# Consumer (blocks until a message arrives)
message = queue.pop
message = queue.pop(timeout: 5) # raises Firehose::Queue::TimeoutError

queue.close
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
