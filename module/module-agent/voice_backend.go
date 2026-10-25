package main

import (
	"errors"
	"net/http"
)

// AVF retains pairing, SMS, state and terminal call control, but has no native
// WebRTC peer. Never advertise a transport or dispatch dial/answer on its behalf.
const agentMediaCapabilityRevision = 2
const avfVoiceUpgradeMessage = "upgrade_required: AVF is control-only; use Android Standalone with native WebRTC for remote calling"

var errAVFVoiceUpgradeRequired = errors.New(avfVoiceUpgradeMessage)

func writeVoiceUpgradeRequired(response http.ResponseWriter) {
	writeJSON(response, http.StatusUpgradeRequired, map[string]any{
		"error": avfVoiceUpgradeMessage, "code": "upgrade_required",
		"call_audio": false, "agent_media_ready": false,
		"agent_media_capabilities":  []string{},
		"media_capability_revision": agentMediaCapabilityRevision,
	})
}
