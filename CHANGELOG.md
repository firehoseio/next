# Changelog

## [2.0.0] - 2024

Complete rewrite with new architecture.

### Added

- WebSocket transport via `Firehose::WebSocket`
- SSE transport via `Firehose::SSE`
- Combined transport via `Firehose::Stream`
- Database-backed event persistence with `Firehose::Event`
- Automatic replay on reconnect via `last_event_id`
- PostgreSQL LISTEN/NOTIFY for instant delivery
- Configurable cleanup threshold per stream
- Controller callbacks: `authorize_streams`, `build_event`
- Phlex helper for declarative stream elements
- JavaScript client with connection pooling
- Falcon/async-websocket compatibility

### Changed

- Complete rewrite, not compatible with Firehose 1.x
- Events stored in PostgreSQL instead of Redis
- Uses ActionCable pubsub for NOTIFY
- No channel abstractions, just streams and data
