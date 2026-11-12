# Carrier-route validation after legacy removal

The retired `android/phone-audio-bridge` implementation is available in Git history at commit `90c06928b41530ef24e9255e645868af06dfeadf`. It is no longer a source, build, launch or recovery path in this tree.

The current adapter is `TelephonyAudioDevice` beside the native WebRTC peer in the privileged Shizuku process. It captures `VOICE_DOWNLINK`, injects into the telephony uplink and exchanges bounded in-process 8 kHz mono samples with WebRTC. No samples cross Binder, a pipe or a separate network-PCM service.

## Cloud outgoing setup

Once the outgoing call is bound to a dialing/connecting Telecom call, the authenticated iPhone owner can negotiate WebRTC during ringback. The agent sends `media_prepared` without invoking `Telecom.answer()` or claiming the remote party has answered. ICE, DTLS and the native peer run while the carrier device stays closed. When Telecom becomes active, `activate_audio` attaches the carrier device to the same peer and the agent sends `active`; the call timer and recording availability begin then. Incoming calls still require successful answer confirmation. CallKit must activate the iPhone audio session before its peer starts.

The existing Relay forwards these agent status messages; this path needs matching iOS and Android builds, without a Relay protocol deployment. An unanswered/canceled call closes its prepared peer without opening carrier audio. Reconnects repeat the owner handshake and discard the old negotiation.

## Evidence still needed

- On both Q25 and Pixel 8 Pro, verify signed APK native loading and bidirectional speech during a real carrier call. A build, tone, SDP answer, RTP count or service heartbeat does not prove this.
- Observe the actual telephony output route. A Samsung `VOICE_TX` tag alone is insufficient. A hidden OEM route needs explicit device evidence before changing the current fail-closed adapter.
- Test repeated calls, mute and route changes, phone lock/background, service death, Shizuku restart and APK upgrade. Confirm native/audio workers terminate and local output is restored before another owner starts.
- Start carrier audio before WebRTC playout exists: answer an outgoing call before the owner's `answer` arrives, and force a media rebuild during an active call. The privileged process must log `standalone_carrier_silence_started` and then `standalone_carrier_silence_stopped gap_ms=…` covering the wait for the offer, with no `carrier_route_inactive` or `carrier_route_changed_type_N` failure. Whether Android reports no device or another device for a starved carrier AudioTrack on each phone is not known from source; these two reason codes are how a device log tells them apart. See [Carrier attach and setup recovery](cloud-audio-startup.md#carrier-attach-and-setup-recovery).
- Test local host ICE and cloud/forced TURN separately. Inspect sockets and processes for the absence of the retired raw-audio listeners.
- Measure latency, underruns and backlog on sustained speech; a NetEq packet cap is not a latency result.
- For outgoing Cloud calls, verify the WebRTC connection completes during a long ringback, before the carrier `active` event; the timer stays at connecting until answer; and speech starts without a second ICE negotiation. The iPhone `native_connected` trace event showed the first point, but that trace cannot currently be turned on or read in the app (see [Cloud audio startup diagnostics](cloud-audio-startup.md#diagnostics)). Until it can, use Android logcat: a `standalone_webrtc_stats` line with selected-path fields (`path_rtt_ms` or candidate types) before `call_event_sent state=active`. Stats are sampled every five seconds, so the ringback must outlast at least one sample. Test immediate answer and cancellation during both ICE retrieval and ringback. Physical call latency is not established by the unit tests.

Package-scoped stale-process detection remains in the app to stop a bridge left running by an older installation. It does not launch a bridge or require its old source. Pairing and SMS stores remain independent of this cleanup. See [the migration contract](webrtc-only-migration.md).
