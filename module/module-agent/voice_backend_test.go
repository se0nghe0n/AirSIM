package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func assertNoAndroidCommand(t *testing.T, a *agent) {
	t.Helper()
	if command, ok := a.android.next(context.Background(), time.Millisecond); ok {
		t.Fatalf("unsupported voice dispatched carrier action: %#v", command)
	}
}

func TestAVFVoiceUnavailableBeforeCarrierActions(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{ID: "call-current", AndroidID: "telecom-current", State: "incoming", Direction: "incoming"}
	if _, err := a.dialNumber("10086"); !errors.Is(err, errAVFVoiceUpgradeRequired) {
		t.Fatalf("dial error=%v", err)
	}
	if err := a.answerCallForID("call-current"); !errors.Is(err, errAVFVoiceUpgradeRequired) {
		t.Fatalf("answer error=%v", err)
	}
	if result := a.executeAndroidCallCommandForID("command", "answer", "call-current"); result.Success || !strings.Contains(result.Error, "upgrade_required") {
		t.Fatalf("answer=%#v", result)
	}
	if err := a.executeIncomingCloudCallAction(cloudCallAction{CallID: "call-current"}, "answer"); !errors.Is(err, errAVFVoiceUpgradeRequired) {
		t.Fatalf("cloud answer error=%v", err)
	}
	if a.calls.Active == nil || a.calls.Active.State != "incoming" || !a.calls.LastAnswerAt.IsZero() {
		t.Fatal("unsupported answer mutated the ringing carrier call")
	}
	assertNoAndroidCommand(t, a)
}

func TestAVFCloudDialFailsBeforeMissingOrClaimedMediaCanDispatch(t *testing.T) {
	for _, media := range []string{"", "webrtc", "pcm"} {
		t.Run(media, func(t *testing.T) {
			a := testAndroidAgent("secret-value")
			command := cloudDeviceCommand{CommandID: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145", Type: "dial", Number: "10086", ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339Nano)}
			if media != "" {
				command.Call = &cloudCommandCall{Direction: "outgoing", MediaTransport: media}
			}
			first := a.executeCloudCommand(command)
			again := a.executeCloudCommand(command)
			if first.Status != "failed" || !strings.Contains(first.Error, "upgrade_required") || again.Error != first.Error {
				t.Fatalf("dial results first=%#v again=%#v", first, again)
			}
			if _, ok := a.currentCloudCallDescriptor(); ok {
				t.Fatal("unsupported dial created cloud session")
			}
			assertNoAndroidCommand(t, a)
		})
	}
}

func TestAVFCloudAnswerFailsWithoutEndingRingingCarrierCall(t *testing.T) {
	a := testAndroidAgent("secret-value")
	descriptor := cloudCallDescriptor{CallID: "call-current", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", Generation: 7}
	a.cloudCallCurrent = &descriptor
	a.calls.Active = &callRecord{ID: descriptor.CallID, AndroidID: "telecom-current", State: "incoming", Direction: "incoming"}
	result := a.executeCloudCommand(cloudDeviceCommand{
		CommandID: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145", Type: "call_control", Action: "answer", Owner: "iphone",
		ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339Nano),
		Call:      &cloudCommandCall{CallID: descriptor.CallID, CallUUID: descriptor.CallUUID, Generation: descriptor.Generation, MediaTransport: "webrtc"},
	})
	if result.Status != "failed" || !strings.Contains(result.Error, "upgrade_required") {
		t.Fatalf("answer result=%#v", result)
	}
	if a.calls.Active == nil || a.calls.Active.State != "incoming" {
		t.Fatal("unsupported remote answer ended carrier call")
	}
	assertNoAndroidCommand(t, a)
}

func TestAVFAudioEndpointsExplicitlyRequireUpgrade(t *testing.T) {
	a := testAndroidAgent("secret-value")
	for _, tc := range []struct {
		method, path, body string
		handler            http.HandlerFunc
	}{
		{"GET", "/api/calls/audio/host/config", "", a.audioHostConfig},
		{"POST", "/api/calls/audio/host/register", `{"enabled":true}`, a.audioHostRegister},
		{"POST", "/api/calls/audio/host/warmup", "", a.audioHostWarmup},
		{"POST", "/api/voice/provision", `{"confirm":true}`, a.voiceProvision},
		{"POST", "/api/calls/dial", `{"number":"10086"}`, a.dial},
		{"POST", "/api/calls/answer", `{}`, a.answer},
	} {
		t.Run(tc.path, func(t *testing.T) {
			response := httptest.NewRecorder()
			tc.handler(response, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
			var body map[string]any
			if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if response.Code != http.StatusUpgradeRequired || body["code"] != "upgrade_required" || body["agent_media_ready"] != false {
				t.Fatalf("status=%d body=%v", response.Code, body)
			}
			for _, key := range []string{"host", "port", "sample_rate", "transport"} {
				if _, ok := body[key]; ok {
					t.Fatalf("retired endpoint advertised %s", key)
				}
			}
		})
	}
	assertNoAndroidCommand(t, a)
}

func TestAVFHealthIsIndependentOfRetiredMediaConfiguration(t *testing.T) {
	t.Setenv("AIRSIM_RUNTIME_PROFILE", "android-avf")
	t.Setenv("AIRSIM_VOICE_BACKEND", "qdc507")
	t.Setenv("AIRSIM_SAMSUNG_PCM_ADDRESS", "invalid-retired-address")
	service := newAgent("unused")
	for _, tc := range []struct {
		handler http.HandlerFunc
		path    string
	}{
		{service.health, "/api/health"}, {service.platform, "/api/platform"}, {service.voiceStatus, "/api/voice/status"},
	} {
		response := httptest.NewRecorder()
		tc.handler(response, httptest.NewRequest("GET", tc.path, nil))
		var body map[string]any
		if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if response.Code != http.StatusOK || body["agent_media_ready"] != false || body["media_capability_revision"] != float64(2) {
			t.Fatalf("%s status=%d body=%v", tc.path, response.Code, body)
		}
		if tc.path == "/api/health" && (body["ok"] != true || body["product"] != "airsim") {
			t.Fatalf("control plane unhealthy: %v", body)
		}
		if tc.path == "/api/platform" && body["call_audio"] != false {
			t.Fatalf("AVF claimed audio: %v", body)
		}
	}
}

func TestAVFVoiceProbeCannotConnectLegacyEndpoint(t *testing.T) {
	previous := os.Args
	defer func() { os.Args = previous }()
	os.Args = []string{"airsim-agent", "--startup-probe", "voice-backend"}
	ran, err := runStartupProbe(log.New(io.Discard, "", 0))
	if !ran || !errors.Is(err, errAVFVoiceUpgradeRequired) {
		t.Fatalf("ran=%v error=%v", ran, err)
	}
}

func TestAVFRegistrationMigrationPreservesPairingAndClearsFalseCapabilities(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	original := testPushRegistration("https://relay.example")
	original.MediaTransport = "webrtc"
	original.AgentMediaCapabilities = []string{"webrtc"}
	original.AgentMediaReady = true
	original.ForceLegacyPCM = true
	raw, err := json.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	manager := newPushManager(path)
	assert := func(got pushRegistration) {
		t.Helper()
		if got.DeviceID != original.DeviceID || got.DeviceSecret != original.DeviceSecret || got.VoIPToken != original.VoIPToken || got.AlertToken != original.AlertToken {
			t.Fatal("migration changed pairing")
		}
		if got.MediaTransport != "" || got.AgentMediaCapabilities == nil || len(got.AgentMediaCapabilities) != 0 || got.AgentMediaReady || got.MediaCapabilityRevision != 2 || got.ForceLegacyPCM {
			t.Fatal("legacy media claim survived")
		}
	}
	assert(manager.config)
	if err := manager.store(original); err != nil {
		t.Fatal(err)
	}
	assert(newPushManager(path).config)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "force_legacy_pcm") {
		t.Fatal("retired policy persisted")
	}
}

func TestCloudTextControlRejectsAnswerAndStillEndsCall(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.push = newPushManager(filepath.Join(t.TempDir(), "push.json"))
	descriptor := cloudCallDescriptor{CallID: "call-current", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", Generation: 1, Direction: "incoming"}
	a.calls.Active = &callRecord{ID: descriptor.CallID, AndroidID: "telecom-current", Direction: "incoming", State: "incoming"}
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	_ = server.SetDeadline(time.Now().Add(3 * time.Second))
	socket := &cloudWebSocket{conn: client, reader: bufio.NewReader(client)}
	remote := &cloudWebSocket{conn: server, reader: bufio.NewReader(server)}
	done := make(chan bool, 1)
	go func() { done <- a.serveCloudCall(context.Background(), socket, descriptor) }()
	assertCloudTextStatus(t, remote, "upgrade_required")
	writeCloudServerText(t, server, cloudCallAction{Action: "answer", CallID: descriptor.CallID, CallUUID: descriptor.CallUUID, Generation: 1, Owner: "iphone"})
	assertCloudTextStatus(t, remote, "action_error")
	assertNoAndroidCommand(t, a)
	writeCloudServerText(t, server, cloudCallAction{Action: "end", CallID: descriptor.CallID, CallUUID: descriptor.CallUUID, Generation: 1, Owner: "iphone"})
	go completeAndroidCall(t, a, "end", "telecom-current")
	assertCloudTextStatus(t, remote, "ended")
	if !<-done {
		t.Fatal("terminal control did not end session")
	}
}

func TestCloudCallRejectsBinaryMedia(t *testing.T) {
	a := testAndroidAgent("secret-value")
	descriptor := cloudCallDescriptor{CallID: "call-current", Direction: "incoming"}
	a.calls.Active = &callRecord{ID: descriptor.CallID, State: "incoming"}
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	_ = server.SetDeadline(time.Now().Add(3 * time.Second))
	socket := &cloudWebSocket{conn: client, reader: bufio.NewReader(client)}
	remote := &cloudWebSocket{conn: server, reader: bufio.NewReader(server)}
	done := make(chan bool, 1)
	go func() { done <- a.serveCloudCall(context.Background(), socket, descriptor) }()
	assertCloudTextStatus(t, remote, "upgrade_required")
	writeCloudServerBinary(t, server, []byte{1, 2, 3, 4})
	if !<-done {
		t.Fatal("binary media did not terminate control session")
	}
	if err := socket.writeMessage(cloudOpcodeBinary, []byte{1}); err == nil {
		t.Fatal("binary send accepted")
	}
	assertNoAndroidCommand(t, a)
}

func TestCloudWebSocketRejectsMissingOrInjectedBearerBeforeNetwork(t *testing.T) {
	for _, token := range []string{"", "token\r\nX-Injected: true"} {
		if _, err := dialCloudWebSocketAuthorized(context.Background(), "wss://relay.example/path", token); err == nil || !strings.Contains(err.Error(), "bearer") {
			t.Fatalf("token validation error=%v", err)
		}
	}
}

func TestAVFProductionSourceHasNoRetiredAudioTransport(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		source, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		for _, retired := range []string{"AIRSIMPCM1", "AIRSIMREADY", "tcp_pcm_s16le", "mavo-pcm-bridge", "--tcp-listen", "AIRSIM_SAMSUNG_PCM_ADDRESS", "cloudPCMFrameBytes", "func (socket *cloudWebSocket) WriteBinary"} {
			if strings.Contains(string(source), retired) {
				t.Errorf("%s contains retired audio transport %q", name, retired)
			}
		}
	}
}

func TestControlDiagnosticsRemainBoundedWithoutMediaLifecycle(t *testing.T) {
	callDiagnosticLogMu.Lock()
	previous := callDiagnosticLogFile
	callDiagnosticLogFile = filepath.Join(t.TempDir(), "call-control.log")
	callDiagnosticLogMu.Unlock()
	defer func() {
		callDiagnosticLogMu.Lock()
		callDiagnosticLogFile = previous
		callDiagnosticLogMu.Unlock()
	}()
	if err := os.WriteFile(callDiagnosticLogFile, make([]byte, callDiagnosticLogMaxBytes), 0600); err != nil {
		t.Fatal(err)
	}
	appendCallDiagnosticEvent("carrier call ended")
	data, err := os.ReadFile(callDiagnosticLogFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "carrier call ended") || len(data) > 1024 {
		t.Fatalf("unexpected control log length=%d", len(data))
	}
	if info, err := os.Stat(callDiagnosticLogFile + ".1"); err != nil || info.Size() != callDiagnosticLogMaxBytes {
		t.Fatalf("rotation info=%v error=%v", info, err)
	}
}

func TestAVFCapabilityWireFieldsRemainExplicitWhenFalse(t *testing.T) {
	registration := pushRegistration{}
	normalizeAVFMediaCapabilities(&registration)
	heartbeat := agentHeartbeatEvent{AgentMediaCapabilities: []string{}, MediaCapabilityRevision: agentMediaCapabilityRevision}
	for _, value := range []any{registration, heartbeat} {
		encoded, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		var fields map[string]any
		if err := json.Unmarshal(encoded, &fields); err != nil {
			t.Fatal(err)
		}
		if ready, exists := fields["agent_media_ready"]; !exists || ready != false {
			t.Fatalf("explicit false readiness missing: %s", encoded)
		}
		capabilities, exists := fields["agent_media_capabilities"].([]any)
		if !exists || len(capabilities) != 0 || fields["media_capability_revision"] != float64(2) {
			t.Fatalf("control-only capability contract missing: %s", encoded)
		}
	}
}
