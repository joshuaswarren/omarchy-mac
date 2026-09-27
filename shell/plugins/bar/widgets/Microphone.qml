import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import qs.Ui
import "../../panels/audio" as Audio
import "../../panels/audio/Model.js" as AudioModel

BarWidget {
  id: root
  moduleName: "omarchy.microphone"


  readonly property var source: Pipewire.defaultAudioSource
  // On Apple Silicon the microphone mapping is a virtual source without
  // PwNode.audio; its volume and mute go through wpctl.
  readonly property bool appleHost: !!bar && bar.appleSiliconHost === true
  readonly property bool viaWpctl: appleHost && !!source && !source.audio && AudioModel.isAsahiMicMapping(source.name)
  readonly property bool muted: viaWpctl ? (!level.known || level.muted) : (source && source.audio ? source.audio.muted : true)
  readonly property real volume: viaWpctl ? level.volume : (source && source.audio ? source.audio.volume : 0)
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  readonly property var activeStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (!node || !node.isStream || node.isSink !== false || node.audio?.muted) continue
      // The DSP's own capture always runs, and the panel's level meter is ours.
      if (appleHost && (AudioModel.isAsahiInternalStream(node.name) || node.name === "quickshell")) continue
      list.push(node)
    }
    return list
  }

  readonly property bool inUse: activeStreams.length > 0 && !muted

  visible: source !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function toggleMute() {
    if (viaWpctl) {
      if (level.known) level.setMuted(!level.muted)
    }
    else if (source && source.audio) source.audio.muted = !source.audio.muted
  }

  PwObjectTracker { objects: root.source ? [root.source] : [] }

  Audio.WpctlNodeLevel {
    id: level
    nodeId: root.viaWpctl ? root.source.id : -1
    active: root.viaWpctl
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.muted ? "󰍭" : "󰍬"
    active: root.inUse
    tooltipText: root.muted ? "Microphone muted" : (root.inUse ? "Microphone in use" : "Microphone live")
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.bar.run("omarchy-shell shell toggle omarchy.audio")
      else root.toggleMute()
    }
    onWheelMoved: function(delta) {
      var step = 0.05
      if (root.viaWpctl) {
        if (level.known) level.setVolume(root.volume + (delta > 0 ? step : -step))
        return
      }
      if (!root.source || !root.source.audio) return
      root.source.audio.volume = Math.max(0, Math.min(1, root.volume + (delta > 0 ? step : -step)))
    }
  }
}
