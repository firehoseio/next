// Firehose: WebSocket client with automatic reconnection and replay
//
// Usage (declarative):
//   <firehose-stream-source path="/firehose" streams="dashboard,user:42"></firehose-stream-source>
//
// Usage (imperative):
//   Firehose.subscribe("/firehose", ["dashboard", "user:42"])
//   Firehose.unsubscribe("/firehose", ["dashboard"])
//
// Each unique path gets its own WebSocket connection.
// Streams are subscribed/unsubscribed within each connection.
//
const Firehose = (function() {
  // Connection pool: path -> Connection instance
  const connections = new Map()

  class Connection {
    constructor(path) {
      this.path = path
      this.socket = null
      this.streams = new Set()
      this.lastEventId = 0
      this.reconnectTimer = null
      this.reconnectDelay = 1000
      this.intentionalDisconnect = false
    }

    connect() {
      // Don't create new connection if socket exists in any state except CLOSED
      if (this.socket && this.socket.readyState !== WebSocket.CLOSED) {
        console.debug(`[Firehose:${this.path}] Socket exists, state:`, this.socket.readyState)
        return
      }

      this.socket = null

      const protocol = window.location.protocol === "https:" ? "wss:" : "ws:"
      const url = `${protocol}//${window.location.host}${this.path}`

      console.debug(`[Firehose:${this.path}] Creating connection to`, url)
      this.intentionalDisconnect = false
      this.socket = new WebSocket(url)

      this.socket.onopen = () => {
        console.debug(`[Firehose:${this.path}] Connected`)
        this.reconnectDelay = 1000

        if (this.streams.size > 0) {
          console.debug(`[Firehose:${this.path}] Subscribing to`, Array.from(this.streams), "from event", this.lastEventId)
          this.send({
            command: "subscribe",
            streams: Array.from(this.streams),
            last_event_id: this.lastEventId
          })
        }
      }

      this.socket.onmessage = (event) => {
        const data = JSON.parse(event.data)
        this.handleEvent(data)
      }

      this.socket.onclose = () => {
        console.debug(`[Firehose:${this.path}] Closed, intentional:`, this.intentionalDisconnect)
        this.socket = null

        if (!this.intentionalDisconnect && this.streams.size > 0) {
          this.scheduleReconnect()
        } else if (this.streams.size === 0) {
          // Remove from pool if no streams
          connections.delete(this.path)
        }
      }

      this.socket.onerror = (error) => {
        console.debug(`[Firehose:${this.path}] Error`, error)
      }
    }

    disconnect() {
      console.debug(`[Firehose:${this.path}] Disconnect called`)
      clearTimeout(this.reconnectTimer)
      this.intentionalDisconnect = true
      if (this.socket) {
        this.socket.close()
      }
    }

    scheduleReconnect() {
      clearTimeout(this.reconnectTimer)
      if (this.streams.size === 0) return
      console.debug(`[Firehose:${this.path}] Reconnecting in`, this.reconnectDelay, "ms")
      this.reconnectTimer = setTimeout(() => {
        this.connect()
        this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000)
      }, this.reconnectDelay)
    }

    send(message) {
      if (this.socket && this.socket.readyState === WebSocket.OPEN) {
        this.socket.send(JSON.stringify(message))
      }
    }

    subscribe(streamList) {
      const newStreams = streamList.filter(s => !this.streams.has(s))
      console.debug(`[Firehose:${this.path}] Subscribe:`, streamList, "new:", newStreams)

      if (newStreams.length === 0) return

      newStreams.forEach(s => this.streams.add(s))

      if (this.socket && this.socket.readyState === WebSocket.OPEN) {
        this.send({
          command: "subscribe",
          streams: newStreams,
          last_event_id: this.lastEventId
        })
      } else if (!this.socket || this.socket.readyState === WebSocket.CLOSED) {
        this.connect()
      } else if (this.socket.readyState === WebSocket.CLOSING) {
        // Socket is closing - ensure onclose will reconnect
        console.debug(`[Firehose:${this.path}] Socket closing, will reconnect`)
        this.intentionalDisconnect = false
      }
    }

    unsubscribe(streamList) {
      const toRemove = streamList.filter(s => this.streams.has(s))
      console.debug(`[Firehose:${this.path}] Unsubscribe:`, streamList, "removing:", toRemove)

      if (toRemove.length === 0) return

      toRemove.forEach(s => this.streams.delete(s))

      if (this.socket && this.socket.readyState === WebSocket.OPEN) {
        this.send({
          command: "unsubscribe",
          streams: toRemove
        })
      }

      if (this.streams.size === 0) {
        this.disconnect()
      }
    }

    handleEvent(event) {
      console.debug(`[Firehose:${this.path}] Event:`, event)

      if (event.id) {
        this.lastEventId = Math.max(this.lastEventId, event.id)
      }

      const customEvent = new CustomEvent("firehose:message", {
        bubbles: true,
        detail: { ...event, path: this.path }
      })
      document.dispatchEvent(customEvent)

      if (event.data === "refresh") {
        refresh()
      }
    }
  }

  function getConnection(path) {
    if (!connections.has(path)) {
      connections.set(path, new Connection(path))
    }
    return connections.get(path)
  }

  function subscribe(path, streamList) {
    getConnection(path).subscribe(streamList)
  }

  function unsubscribe(path, streamList) {
    const conn = connections.get(path)
    if (conn) {
      conn.unsubscribe(streamList)
    }
  }

  function refresh() {
    console.debug("[Firehose] Triggering page refresh")
    if (typeof Turbo !== "undefined") {
      if (Turbo.session && typeof Turbo.session.refresh === "function") {
        Turbo.session.refresh(document.baseURI)
      } else {
        Turbo.visit(window.location.href, { action: "replace" })
      }
    } else {
      window.location.reload()
    }
  }

  return {
    subscribe,
    unsubscribe,
    getConnection,
    get connections() { return connections }
  }
})()

// Custom element for declarative stream subscriptions
class FirehoseStreamSource extends HTMLElement {
  connectedCallback() {
    this._path = this.getAttribute("path") || "/firehose"
    const streams = this.getAttribute("streams")
    console.debug("[Firehose] Element connected, path:", this._path, "streams:", streams)

    if (streams) {
      this._streams = streams.split(",").map(s => s.trim()).filter(Boolean)
      Firehose.subscribe(this._path, this._streams)
    }
  }

  disconnectedCallback() {
    console.debug("[Firehose] Element disconnected, path:", this._path, "streams:", this._streams)
    if (this._streams && this._path) {
      Firehose.unsubscribe(this._path, this._streams)
    }
  }

  static get observedAttributes() {
    return ["streams", "path"]
  }

  attributeChangedCallback(name, oldValue, newValue) {
    // Only handle changes after initial connection
    if (oldValue === null) return

    if (name === "streams") {
      const oldStreams = oldValue.split(",").map(s => s.trim()).filter(Boolean)
      const newStreams = newValue.split(",").map(s => s.trim()).filter(Boolean)

      const toRemove = oldStreams.filter(s => !newStreams.includes(s))
      const toAdd = newStreams.filter(s => !oldStreams.includes(s))

      if (toRemove.length) Firehose.unsubscribe(this._path, toRemove)
      if (toAdd.length) Firehose.subscribe(this._path, toAdd)

      this._streams = newStreams
    }
  }
}

if (!customElements.get("firehose-stream-source")) {
  customElements.define("firehose-stream-source", FirehoseStreamSource)
}

// Export for module systems
if (typeof module !== "undefined" && module.exports) {
  module.exports = Firehose
} else if (typeof window !== "undefined") {
  window.Firehose = Firehose
}
