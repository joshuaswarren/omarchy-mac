import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Volume and mute of one PipeWire node through wpctl, for a node Quickshell
// gives no PwNode.audio: Quickshell types only exact media classes, so a
// virtual source (the Apple microphone mapping is an Audio/Source/Virtual) has
// no volume or mute there. Reads and writes name the node by id, a reply for a
// node no longer tracked is dropped, and writes run one at a time with only the
// latest volume kept, so a slider drag cannot land on another input later.
Item {
  id: root
  visible: false

  property int nodeId: -1
  property bool active: false
  readonly property bool tracking: active && nodeId >= 0

  property bool known: false
  property real volume: 0
  property bool muted: false

  property int generation: 0
  property int readGeneration: -1
  property bool readAgain: false
  property var pendingVolume: null
  property var pendingMute: null

  onTrackingChanged: reset()
  onNodeIdChanged: reset()
  Component.onCompleted: reset()

  function reset() {
    generation++
    known = false
    pendingVolume = null
    pendingMute = null
    events.running = tracking
    refresh()
  }

  function refresh() {
    if (!tracking) return
    if (reader.running || writer.running) {
      readAgain = true
      return
    }
    readGeneration = generation
    reader.command = ["wpctl", "get-volume", String(nodeId)]
    reader.running = true
  }

  function setVolume(value) {
    if (!tracking) return
    volume = Math.max(0, Math.min(1, value))
    pendingVolume = [String(nodeId), volume.toFixed(2)]
    flush()
  }

  function setMuted(value) {
    if (!tracking || !known) return
    muted = value
    pendingMute = [String(nodeId), value ? "1" : "0"]
    flush()
  }

  function flush() {
    if (reader.running || writer.running) return true
    var args = null
    if (pendingMute !== null) {
      args = ["wpctl", "set-mute"].concat(pendingMute)
      pendingMute = null
    } else if (pendingVolume !== null) {
      args = ["wpctl", "set-volume"].concat(pendingVolume)
      pendingVolume = null
    }
    if (!args) return false
    writer.command = args
    writer.running = true
    return true
  }

  function settle() {
    if (flush()) return
    if (readAgain) {
      readAgain = false
      refresh()
    }
  }

  Process {
    id: reader
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var level = Model.parseWpctlVolume(text)
        if (!level || !root.tracking || root.readGeneration !== root.generation) return
        if (root.pendingVolume !== null || root.pendingMute !== null || writer.running) return
        root.volume = level.volume
        root.muted = level.muted
        root.known = true
      }
    }
    onExited: root.settle()
  }

  Process {
    id: writer
    onExited: {
      root.readAgain = true
      root.settle()
    }
  }

  // The volume keys, the mute key and other apps change the node too. pactl
  // translates its events, so they are read in the C locale.
  Process {
    id: events
    command: ["pactl", "subscribe"]
    environment: ({ LC_ALL: "C" })
    onExited: if (root.tracking) resubscribe.start()
    stdout: SplitParser {
      onRead: function(line) {
        if (String(line).indexOf(" on source #") !== -1) root.refresh()
      }
    }
  }

  Timer {
    id: resubscribe
    interval: 2000
    onTriggered: if (root.tracking && !events.running) {
      events.running = true
      root.refresh()
    }
  }
}
