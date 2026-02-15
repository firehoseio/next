# Changelog

## [2.0.0] - 2026

Complete rewrite with new architecture.

### Added

- WebSocket transport via `Firehose::WebSocket`
- SSE transport via `Firehose::SSE`
- Combined transport via `Firehose::Stream`
- Database-backed message persistence with `Firehose::Channel` and `Firehose::Message`
- Automatic replay on reconnect via `last_event_id`
- Dedicated PG connection for LISTEN/NOTIFY (no ActionCable, no AR pool pressure)
- Inline NOTIFY delivery for small payloads, DB fallback for oversized (>8KB)
- Automatic PG reconnection with configurable exponential backoff
- `Firehose::Queue` for server-side push/pop over LISTEN/NOTIFY
- Per-channel monotonic sequences with counter cache
- Configurable cleanup threshold per stream
- Controller callbacks: `authorize_streams`, `build_event`
- Server-instance configuration via `configure`, `configure_from_yaml`, `configure_from_hash`
- Phlex helper for declarative stream elements
- Falcon/async-websocket compatibility

### Changed

- Complete rewrite, not compatible with Firehose 1.x
- Messages stored in PostgreSQL instead of Redis
- Dedicated PG connection instead of ActionCable pubsub
- No channel abstractions, just streams and data
