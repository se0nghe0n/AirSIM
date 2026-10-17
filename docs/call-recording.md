# iPhone call recording

During a connected AirSIM call, tap the Record button at the top right. The red button indicates that recording is active. Tap again to stop and save. Ending the call also saves the recording; brief reconnections do not start a new file. Recording does not start automatically on later calls.

Open **Recents → Recordings** to play a file, use the share button to export it, or swipe to delete it. Playback is available after the current call ends. Files stay on this iPhone and are excluded from iCloud/device backups. No recording is sent to Android, Relay, or TURN. The iPhone must own the call audio; a call being handled on Apple Watch cannot be recorded on the iPhone.

Both directions are saved as 8 kHz stereo WAV: local voice in the left channel and remote voice in the right. Muting the iPhone microphone also silences the local recording channel. WebRTC, legacy cloud PCM, local VoWLAN, and iPhone Bluetooth audio have recording taps. Each file is limited to two hours; storage errors stop recording and report a failure. A recording with no audio is removed instead of appearing as an empty saved file.

The button previously called the unsupported local Android recording endpoint. Recording now observes the iPhone's existing call streams. WebRTC uses passive capture/render processing delegates with default voice-processing settings; PCM modes copy their existing audio buffers. A bounded utility queue performs disk I/O and file finalization away from the call-audio threads. Stored file names contain random UUIDs, not phone numbers.
