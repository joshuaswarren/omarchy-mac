#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const audio = requireFromRoot('shell/plugins/panels/audio/Model.js')

assert(audio.isPlaybackStream({ isStream: true, isSink: true }), 'audio detects sink-backed playback streams')
assert(audio.isPlaybackStream({ isStream: true, type: 'Stream/Output/Audio' }), 'audio detects typed playback streams')
assert(!audio.isPlaybackStream({ isStream: false, isSink: true }), 'audio rejects non-stream playback nodes')
assert(audio.isAudioSource({ audio: {} }), 'audio detects nodes with audio as sources')
assert(audio.isAudioSource({ type: 'Audio/Source' }), 'audio detects typed source nodes')

assertEqual(audio.outputVolumeName(0, false), 'Silenced', 'audio labels silent output')
assertEqual(audio.outputVolumeName(0.9, false), 'Party mode', 'audio labels loud output')
assertEqual(audio.outputVolumeName(0.5, true), 'Muted', 'audio labels muted output')

assertDeepEqual(audio.parseSinkAvailability('alsa_output\t1\nhdmi_output\t0\n'), { alsa_output: true, hdmi_output: false }, 'audio parses sink availability')
assertEqual(audio.friendlyDeviceLabel('Built-in Audio Speakers Output'), 'Speakers', 'audio cleans device labels')
assertEqual(
  audio.nodeLabel({ ready: true, properties: { 'node.nick': 'Built-in Audio Microphones Input' }, name: 'alsa_input' }),
  'Microphone',
  'audio chooses friendly node labels'
)

const headphones = { ready: true, name: 'bluez_output.airpods', properties: { 'device.product.name': 'AirPods Headphones' } }
assert(audio.isHeadphones(headphones), 'audio detects headphone devices')
assertEqual(audio.sinkGlyph(headphones), '󰋋', 'audio uses headphone sink glyph')
assert(audio.sourceGlyph({ ready: true, properties: { 'device.icon-name': 'camera-webcam' } }).length > 0, 'audio maps webcam source glyph')

assertEqual(audio.friendlyStreamLabel('spotify'), 'Spotify', 'audio normalizes known stream labels')
assert(audio.streamRepresentsMprisPlayer('Chromium', 'Chromium Browser'), 'audio matches related stream and MPRIS labels')

const players = [
  { identity: 'Spotify', canPlay: true, isPlaying: true, dbusName: 'org.mpris.MediaPlayer2.spotify' },
  { identity: 'Chromium', canPlay: true, isPlaying: false, dbusName: 'org.mpris.MediaPlayer2.chromium' }
]
const streams = [
  { ready: true, properties: { 'application.name': 'Chromium' } },
  { ready: true, properties: { 'application.name': 'audio-src' } }
]

assertEqual(audio.matchingMprisStreamLabel('Chromium', players), 'Chromium', 'audio finds matching MPRIS labels')
assertEqual(audio.unmatchedMprisStreamLabel('audio-src', players, streams), 'Spotify', 'audio uses unmatched MPRIS player for generic streams')
assertEqual(audio.streamLabel(streams[1], players, streams), 'Spotify', 'audio labels generic streams from MPRIS')
assert(audio.streamRepresentsPlayer(streams[1], players[0], players, streams), 'audio links generic streams to active player')

// Apple Silicon: asahi-audio's DSP graph streams leave the per-app list; the
// speaker sink and anything outside asahi-audio's names stay. The panel asks
// only on an Apple Silicon host.
for (const board of ['j314', 'j416', 'j613']) {
  assert(audio.isAsahiInternalStream('effect_output.' + board + '-convolver'), 'audio hides the speaker DSP output on ' + board)
  assert(audio.isAsahiInternalStream('audio_effect.' + board + '-mic'), 'audio hides the microphone DSP capture on ' + board)
  assert(!audio.isAsahiInternalStream('audio_effect.' + board + '-convolver'), 'audio keeps the speaker sink on ' + board)
}
for (const name of ['effect_output.eq6', 'omarchy_speaker_tuning', 'Firefox', 'effect_output.j416-convolver-eq', '', undefined])
  assert(!audio.isAsahiInternalStream(name), 'audio keeps stream ' + name)

// The mono DSP microphone is hidden only while the mapper's stereo copy exists;
// the raw devices asahi-audio marks "do not use" are always hidden.
assert(audio.asahiSourceHidden('effect_output.j314-mic', true), 'audio hides the DSP microphone behind its mapping')
assert(!audio.asahiSourceHidden('effect_output.j314-mic', false), 'audio keeps the DSP microphone without a mapping')
assert(audio.asahiSourceHidden('alsa_input.platform-sound.RawMics', false), 'audio hides the raw microphone array')
assert(audio.isAsahiRawDevice('alsa_output.platform-sound.RawSpeakers'), 'audio hides the raw speakers')
for (const name of ['omarchy_asahi_mic', 'alsa_input.platform-sound.HiFi__Headset__source', 'alsa_input.pci-0000_00_1f.3.analog-stereo'])
  assert(!audio.asahiSourceHidden(name, true), 'audio keeps input ' + name)
assert(audio.isAsahiMicMapping('omarchy_asahi_mic') && !audio.isAsahiMicMapping('omarchy_asahi_mic.monitor'), 'audio names the mapping exactly')

// The mapping has no PwNode.audio, so its level is read from wpctl.
assertDeepEqual(audio.parseWpctlVolume('Volume: 0.50\n'), { volume: 0.5, muted: false }, 'audio reads a wpctl volume')
assertDeepEqual(audio.parseWpctlVolume('Volume: 1.00 [MUTED]'), { volume: 1, muted: true }, 'audio reads a muted wpctl volume')
for (const text of ['', 'Translate ID error: 404', 'Volume: loud', 'Volume: 0.50 [muted]'])
  assertEqual(audio.parseWpctlVolume(text), null, 'audio rejects wpctl output ' + JSON.stringify(text))
JS
