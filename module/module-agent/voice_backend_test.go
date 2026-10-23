package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http/httptest"
	"testing"
	"time"
)

func TestVoiceBackendDefaultsToSamsungAndRequiresPrivateEndpoint(t *testing.T) {
	_, err := loadVoiceBackend(func(string) string { return "" })
	if err == nil {
		t.Fatal("startup must be rejected when the Samsung PCM private endpoint is unset")
	}
	config, err := loadVoiceBackend(func(key string) string {
		if key == "AIRSIM_SAMSUNG_PCM_ADDRESS" { return "192.168.240.1:7580" }
		return ""
	})
	if err != nil {
		t.Fatalf("default voice backend failed: %v", err)
	}
	if config.kind != voiceBackendSamsungAndroid {
		t.Fatalf("default backend=%q, want %q", config.kind, voiceBackendSamsungAndroid)
	}
	if config.endpoint != "192.168.240.1:7580" {
		t.Fatalf("default endpoint=%q", config.endpoint)
	}
	if config.requiresLocalRuntime() {
		t.Fatal("AirSIM must not prepare the QDC507 on-device voice runtime")
	}
}

func TestSamsungVoiceBackendRequiresExplicitPrivateEndpoint(t *testing.T) {
	lookup := func(key string) string {
		values := map[string]string{
			"AIRSIM_VOICE_BACKEND":       "samsung_android",
			"AIRSIM_SAMSUNG_PCM_ADDRESS": "192.168.240.1:7580",
		}
		return values[key]
	}
	config, err := loadVoiceBackend(lookup)
	if err != nil {
		t.Fatalf("Samsung voice backend failed: %v", err)
	}
	if config.kind != voiceBackendSamsungAndroid {
		t.Fatalf("Samsung backend=%q", config.kind)
	}
	if config.endpoint != "192.168.240.1:7580" {
		t.Fatalf("Samsung endpoint=%q", config.endpoint)
	}
	if config.requiresLocalRuntime() {
		t.Fatal("Samsung backend must not start the QDC507 kernel or mixer runtime")
	}
}

func TestSamsungVoiceBackendRejectsUnsafeEndpoints(t *testing.T) {
	for _, endpoint := range []string{
		"", "0.0.0.0:7580", "127.0.0.1:7580", "8.8.8.8:7580",
		"bridge.example.com:7580", "192.168.240.1:80", "192.168.240.1:70000",
	} {
		t.Run(endpoint, func(t *testing.T) {
			_, err := loadVoiceBackend(func(key string) string {
				if key == "AIRSIM_VOICE_BACKEND" {
					return "samsung_android"
				}
				return endpoint
			})
			if err == nil {
				t.Fatalf("unsafe endpoint %q must be rejected", endpoint)
			}
		})
	}
}

func TestVoiceBackendRejectsUnknownKind(t *testing.T) {
	_, err := loadVoiceBackend(func(key string) string {
		if key == "AIRSIM_VOICE_BACKEND" {
			return "other"
		}
		return ""
	})
	if err == nil {
		t.Fatal("unknown voice backend must be rejected")
	}
}

func TestHealthReportsVoiceBackendWithoutEndpoint(t *testing.T) {
	service := &agent{
		at: newATPort("unused"), started: time.Now(),
		voiceBackend: voiceBackendConfig{
			kind: voiceBackendSamsungAndroid, endpoint: "192.168.240.1:7580",
		},
	}
	request := httptest.NewRequest("GET", "/api/health", nil)
	recorder := httptest.NewRecorder()
	service.health(recorder, request)
	var payload map[string]any
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["voice_backend"] != "samsung_android" {
		t.Fatalf("health API voice backend=%v", payload["voice_backend"])
	}
	if payload["product"] != "airsim" {
		t.Fatalf("health API product identity=%v", payload["product"])
	}
	if payload["ok"] != true {
		t.Fatalf("Agent should be online when the Samsung external backend is valid: ok=%v", payload["ok"])
	}
	if _, exposed := payload["voice_pcm_endpoint"]; exposed {
		t.Fatal("health API must not expose the Samsung PCM private endpoint")
	}

	platformRequest := httptest.NewRequest("GET", "/api/platform", nil)
	platformRecorder := httptest.NewRecorder()
	service.platform(platformRecorder, platformRequest)
	var platform map[string]any
	if err := json.Unmarshal(platformRecorder.Body.Bytes(), &platform); err != nil {
		t.Fatal(err)
	}
	if platform["call_audio"] != true {
		t.Fatalf("Samsung external backend should report call audio capability: %v", platform["call_audio"])
	}
}

func TestAgentExposesConfiguredPCMEndpointAndRuntimeBoundary(t *testing.T) {
	service := &agent{voiceBackend: voiceBackendConfig{
		kind: voiceBackendSamsungAndroid, endpoint: "192.168.240.1:7580",
	}}
	endpoint, err := service.voicePCMEndpoint()
	if err != nil {
		t.Fatalf("failed to read PCM endpoint: %v", err)
	}
	if endpoint != "192.168.240.1:7580" {
		t.Fatalf("PCM endpoint=%q", endpoint)
	}
	if service.usesLocalVoiceRuntime() {
		t.Fatal("Samsung Agent must not prepare the QDC507 on-device runtime")
	}

	invalid := &agent{voiceBackendErr: errTestVoiceBackend}
	if _, err := invalid.voicePCMEndpoint(); err == nil {
		t.Fatal("invalid backend config must not return a PCM endpoint")
	}
}

func TestSamsungVoiceBackendFollowsCurrentAVFDefaultGateway(t *testing.T) {
	service := &agent{
		profile: runtimeProfileFrom("android-avf"),
		voiceBackend: voiceBackendConfig{
			kind: voiceBackendSamsungAndroid, endpoint: "10.185.5.63:7580",
		},
		defaultRoute: func() map[string]string {
			return map[string]string{"interface": "enp0s7", "gateway": "172.29.240.24"}
		},
	}
	endpoint, err := service.voicePCMEndpoint()
	if err != nil {
		t.Fatalf("failed to read dynamic PCM endpoint: %v", err)
	}
	if endpoint != "172.29.240.24:7580" {
		t.Fatalf("PCM endpoint=%q, want current AVF gateway 172.29.240.24:7580", endpoint)
	}
}

func TestQDC507VoiceBackendKeepsFixedEndpoint(t *testing.T) {
	service := &agent{
		profile:      runtimeProfileFrom("qdc507"),
		voiceBackend: voiceBackendConfig{kind: voiceBackendQDC507, endpoint: qdc507PCMEndpoint},
		defaultRoute: func() map[string]string {
			return map[string]string{"interface": "ecm0", "gateway": "172.29.240.24"}
		},
	}
	endpoint, err := service.voicePCMEndpoint()
	if err != nil {
		t.Fatal(err)
	}
	if endpoint != qdc507PCMEndpoint {
		t.Fatalf("QDC507 PCM endpoint was incorrectly rewritten to %q", endpoint)
	}
}

func TestSamsungVoiceRouteDoesNotStartQDC507Processes(t *testing.T) {
	service := &agent{voiceBackend: voiceBackendConfig{
		kind: voiceBackendSamsungAndroid, endpoint: "192.168.240.1:7580",
	}}
	service.ensureVoiceRoute()
	snapshot := service.voice.snapshot()
	if !snapshot.Listening || snapshot.Ready {
		t.Fatalf("only listening should be marked before handshake: listening=%v ready=%v error=%q",
			snapshot.Listening, snapshot.Ready, snapshot.LastError)
	}
	if snapshot.Command != nil || snapshot.RouteCommand != nil || snapshot.MediaRouteStarted {
		t.Fatal("Samsung backend must not start the QDC507 helper, route process, or baseband media route")
	}
	service.markVoiceBackendHandshakeReady()
	if !service.voice.snapshot().Ready {
		t.Fatal("Samsung PCM backend should be marked ready after the AIRSIMREADY handshake")
	}
	service.stopVoiceRoute()
	stopped := service.voice.snapshot()
	if stopped.Ready || stopped.Listening {
		t.Fatal("listening and ready must be cleared after the Samsung voice route stops")
	}
}

func TestProbeVoicePCMBackendPerformsLegacyHandshake(t *testing.T) {
	client, server := net.Pipe()
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		hello := make([]byte, len("AIRSIMPCM1\n"))
		if _, err := io.ReadFull(server, hello); err != nil {
			done <- err
			return
		}
		if string(hello) != "AIRSIMPCM1\n" {
			done <- &voiceBackendTestError{}
			return
		}
		if _, err := server.Write([]byte("AIRSIMREADY")); err != nil {
			done <- err
			return
		}
		one := make([]byte, 1)
		_, err := server.Read(one)
		if err == io.EOF {
			err = nil
		}
		done <- err
	}()

	err := probeVoicePCMBackend("192.168.240.1:7580", func(_, _ string) (net.Conn, error) {
		return client, nil
	})
	if err != nil {
		t.Fatalf("PCM backend handshake failed: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatalf("simulated bridge failed: %v", err)
	}
}

var errTestVoiceBackend = &voiceBackendTestError{}

type voiceBackendTestError struct{}

func (*voiceBackendTestError) Error() string { return "voice backend invalid" }
