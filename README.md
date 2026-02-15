# Firehose 2.0

Real-time streaming for Rails with WebSocket and SSE transports, database-backed persistence, and automatic replay on reconnect.

## Features

- **Dual transports**: WebSocket and Server-Sent Events (SSE)
- **Database persistence**: Events stored in PostgreSQL for replay
- **Automatic replay**: Clients reconnect and receive missed events via `Last-Event-ID`
- **PostgreSQL LISTEN/NOTIFY**: Instant delivery via ActionCable pubsub
- **Auto-cleanup**: Configurable threshold keeps last N events per stream
- **Falcon-compatible**: Built for async Ruby with async-websocket

## Installation

Add to your Gemfile:

```ruby
gem "firehose", path: "gems/firehose", require: false
```

Create an initializer to load after Rails boots:

```ruby
# config/initializers/firehose.rb
require "firehose"
```

Run the migration:

```ruby
# db/migrate/TIMESTAMP_create_firehose_events.rb
class CreateFirehoseEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :firehose_events do |t|
      t.text :stream, null: false
      t.text :data, null: false
      t.datetime :created_at, null: false, default: -> { "now()" }
    end

    add_index :firehose_events, [:stream, :id]
  end
end
```

## Usage

### Broadcasting

```ruby
# Broadcast to a stream
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

Include the transport modules in your controller:

```ruby
class FirehoseController < ApplicationController
  include Firehose::Stream  # Includes both WebSocket and SSE

  # Or include just one:
  # include Firehose::WebSocket
  # include Firehose::SSE
end
```

With authentication:

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

Include the helper in your base component:

```ruby
class Components::Base < Phlex::HTML
  include Firehose::Helper
end
```

Then use in views:

```erb
firehose_stream_from @report
firehose_stream_from "dashboard", "user:#{current_user.id}"
firehose_stream_from @model, path: "/admin/firehose"
```

## Configuration

```ruby
# config/initializers/firehose.rb
require "firehose"

Firehose.cleanup_threshold = 100  # Keep last 100 events per stream (default)
```

## Protocol

### WebSocket

```
Client → Server: { "command": "subscribe", "streams": ["a", "b"], "last_event_id": 123 }
Client → Server: { "command": "unsubscribe", "streams": ["a"] }
Server → Client: { "id": 456, "stream": "a", "data": "refresh" }
```

### SSE

```
GET /firehose/sse?streams=a,b
Last-Event-ID: 123

Server → Client:
id: 456
event: a
data: refresh
```

## Architecture

```
Firehose.broadcast("stream", "data")
    ↓
1. INSERT into firehose_events (persistence for replay)
2. ActionCable.server.pubsub.broadcast (instant NOTIFY)
    ↓
FirehoseController (WebSocket or SSE endpoint)
    ↓
Browser → Turbo page refresh
```

## Why Firehose 2.0?

This is a complete rewrite focused on:

- **Simplicity**: No complex channel abstractions, just streams and data
- **Reliability**: Database persistence ensures no missed events
- **Flexibility**: Works with any auth system via controller callbacks
- **Performance**: PostgreSQL LISTEN/NOTIFY for instant delivery, no polling

## License

MIT
