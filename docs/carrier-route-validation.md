# Carrier-route validation after legacy removal

The retired `android/phone-audio-bridge` implementation is available in Git history at commit `90c06928b41530ef24e9255e645868af06dfeadf`. It is no longer a source, build, launch or recovery path in this tree.

The current adapter is `TelephonyAudioDevice` beside the native WebRTC peer in the privileged Shizuku process. It captures `VOICE_DOWNLINK`, injects into the telephony uplink and exchanges bounded in-process 8 kHz mono samples with WebRTC. No samples cross Binder, a pipe or a separate network-PCM service.

## Evidence still needed

- On both Q25 and Pixel 8 Pro, verify signed APK native loading and bidirectional speech during a real carrier call. A build, tone, SDP answer, RTP count or service heartbeat does not prove this.
- Observe the actual telephony output route. A Samsung `VOICE_TX` tag alone is insufficient. A hidden OEM route needs explicit device evidence before changing the current fail-closed adapter.
- Test repeated calls, mute and route changes, phone lock/background, service death, Shizuku restart and APK upgrade. Confirm native/audio workers terminate and local output is restored before another owner starts.
- Test local host ICE and cloud/forced TURN separately. Inspect sockets and processes for the absence of the retired raw-audio listeners.
- Measure latency, underruns and backlog on sustained speech; a NetEq packet cap is not a latency result.

Package-scoped stale-process detection remains in the app to stop a bridge left running by an older installation. It does not launch a bridge or require its old source. Pairing and SMS stores remain independent of this cleanup. See [the migration contract](webrtc-only-migration.md).
