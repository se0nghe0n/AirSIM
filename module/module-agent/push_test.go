package main

import (
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPushHTTPClientToleratesSlowCellularTLS(t *testing.T) {
	client := newPushHTTPClient()
	transport, ok := client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("push client Transport type=%T", client.Transport)
	}
	if client.Timeout < 25*time.Second || transport.TLSHandshakeTimeout < 15*time.Second {
		t.Fatalf(
			"cellular HTTPS timeout is too short: client=%s tls=%s",
			client.Timeout, transport.TLSHandshakeTimeout,
		)
	}
}

func TestPushDNSFallbackPrefersReliableIPv4Resolvers(t *testing.T) {
	if len(pushDNSServers) < 2 || pushDNSServers[0] != "1.1.1.1:53" || pushDNSServers[1] != "8.8.8.8:53" {
		t.Fatalf("public DNS order is unreliable: %#v", pushDNSServers)
	}
	addresses := pushIPv4Addresses([]net.IPAddr{
		{IP: net.ParseIP("2606:4700:3037::6815:1e0")},
		{IP: net.ParseIP("104.21.1.224")},
	})
	if len(addresses) != 1 || addresses[0].String() != "104.21.1.224" {
		t.Fatalf("public push must filter unreachable IPv6: %#v", addresses)
	}
}

func testPushRegistration(relayURL string) pushRegistration {
	return pushRegistration{
		DeviceID: "iphone-air", DeviceSecret: strings.Repeat("s", 32),
		VoIPToken: strings.Repeat("a", 64), AlertToken: strings.Repeat("b", 64),
		WatchVoIPToken: strings.Repeat("c", 64),
		WatchBundleID:  "com.example.airsim.watchkitapp",
		BundleID:       "com.example.airsim", Environment: "sandbox", RelayURL: relayURL,
	}
}

func TestValidatePushRegistrationRequiresHTTPSRelay(t *testing.T) {
	registration := testPushRegistration("http://push.example.com")
	if err := validatePushRegistration(registration); err == nil {
		t.Fatal("public push relay must be rejected when it uses cleartext HTTP")
	}
	registration.RelayURL = "https://push.example.com"
	if err := validatePushRegistration(registration); err != nil {
		t.Fatalf("valid push registration was rejected: %v", err)
	}
}

func TestPushRegistrationAcceptsEitherTokenButNotNeither(t *testing.T) {
	registration := testPushRegistration("https://push.example.com")
	registration.AlertToken = ""
	if err := validatePushRegistration(registration); err != nil {
		t.Fatalf("VoIP token alone should be allowed to register: %v", err)
	}
	registration.VoIPToken = ""
	registration.AlertToken = strings.Repeat("b", 64)
	if err := validatePushRegistration(registration); err != nil {
		t.Fatalf("alert token alone should be allowed to register: %v", err)
	}
	registration.AlertToken = ""
	registration.WatchVoIPToken = ""
	registration.WatchBundleID = ""
	if err := validatePushRegistration(registration); err == nil {
		t.Fatal("registration with no APNs token must be rejected")
	}
}

func TestLocalModeRegistrationNeedsNoRelayOrAPNsToken(t *testing.T) {
	disabled := false
	registration := pushRegistration{LocalMode: true, CloudEnabled: &disabled}
	if err := validatePushRegistration(registration); err != nil {
		t.Fatalf("local-mode registration must not depend on cloud parameters: %v", err)
	}

	enabled := true
	registration.CloudEnabled = &enabled
	if err := validatePushRegistration(registration); err == nil {
		t.Fatal("local mode must not enable cloud mode at the same time")
	}
}

func TestLocalModeStatusIsConfiguredButCloudDisabled(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	manager := newPushManager(path)
	disabled := false
	if err := manager.store(pushRegistration{LocalMode: true, CloudEnabled: &disabled}); err != nil {
		t.Fatal(err)
	}
	status := manager.status()
	if !status.Configured || status.CloudEnabled || status.CallPushReady || status.MessagePushReady {
		t.Fatalf("local-mode status mismatch: %#v", status)
	}
}

func TestPushRegistrationPersistsWithoutLeakingTokensOrSecretInStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	manager := newPushManager(path)
	registration := testPushRegistration("https://push.example.com")
	if err := manager.store(registration); err != nil {
		t.Fatal(err)
	}

	status := newPushManager(path).status()
	if !status.Configured || status.CallPushReady || !status.MessagePushReady {
		t.Fatalf("status mismatch after persistence: %#v", status)
	}
	encoded, _ := json.Marshal(status)
	for _, secret := range []string{registration.DeviceSecret, registration.VoIPToken, registration.AlertToken} {
		if strings.Contains(string(encoded), secret) {
			t.Fatalf("status API leaked push credentials: %s", encoded)
		}
	}
}

func TestPushManagerRestoresLastGoodRegistrationWhenPrimaryIsTruncated(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	manager := newPushManager(path)
	if err := manager.store(testPushRegistration("https://push.example.com")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}

	restored := newPushManager(path).status()
	if !restored.Configured || restored.CallPushReady || !restored.MessagePushReady {
		t.Fatalf("truncated primary config did not restore the last valid registration: %#v", restored)
	}
	if restored.LastError != "" {
		t.Fatalf("config error must not remain after a successful restore: %q", restored.LastError)
	}
}

func TestWritePushConfigDataSyncFailurePreservesPublishedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	if err := os.WriteFile(path, []byte(`{"device_id":"old"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	wantError := errors.New("data sync failed")
	err := writePushConfigAtomicallyWithDurability(
		path,
		[]byte(`{"device_id":"new"}`),
		func(string) error { return wantError },
		func(string) error { return nil },
	)
	if !errors.Is(err, wantError) {
		t.Fatalf("publish must be blocked before data is durably flushed: %v", err)
	}
	data, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(data) != `{"device_id":"old"}` {
		t.Fatalf("sync failure overwrote the published config: %s", data)
	}
	if _, statErr := os.Stat(path + ".tmp"); !os.IsNotExist(statErr) {
		t.Fatalf("temporary file was not cleaned up after sync failure: %v", statErr)
	}
}

func TestWritePushConfigDirectorySyncFailureIsReported(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push.json")
	wantError := errors.New("directory sync failed")
	err := writePushConfigAtomicallyWithDurability(
		path,
		[]byte(`{"device_id":"new"}`),
		func(string) error { return nil },
		func(string) error { return wantError },
	)
	if !errors.Is(err, wantError) {
		t.Fatalf("success must not be reported before the directory entry is durably flushed: %v", err)
	}
}

func TestIncomingCallRelayUsesStableUUIDAndDeduplicates(t *testing.T) {
	type payload struct {
		CallID     string `json:"call_id"`
		CallUUID   string `json:"call_uuid"`
		CallSecret string `json:"call_secret"`
	}
	var received []payload
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/call" {
			t.Fatalf("request path=%q", request.URL.Path)
		}
		var value payload
		if err := json.NewDecoder(request.Body).Decode(&value); err != nil {
			t.Fatal(err)
		}
		received = append(received, value)
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()

	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	call := callRecord{ID: "call-9", Direction: "incoming", State: "incoming", Number: "10086"}
	if sent, err := manager.sendIncoming(call, time.Now()); err != nil || !sent {
		t.Fatalf("first incoming call was not sent: sent=%v err=%v", sent, err)
	}
	if sent, err := manager.sendIncoming(call, time.Now()); err != nil || sent {
		t.Fatalf("duplicate incoming call must not be sent again: sent=%v err=%v", sent, err)
	}
	if len(received) != 1 || received[0].CallID != call.ID || received[0].CallUUID == "" ||
		len(received[0].CallSecret) < 24 {
		t.Fatalf("relay payload mismatch: %#v", received)
	}
}

func TestPushRegistrationValidatesWatchVoIPIdentity(t *testing.T) {
	registration := testPushRegistration("https://push.example.com")
	registration.WatchBundleID = "com.attacker.watch"
	if err := validatePushRegistration(registration); err == nil {
		t.Fatal("Watch VoIP token must not be bound to a different App ID")
	}
	registration.WatchBundleID = ""
	if err := validatePushRegistration(registration); err == nil {
		t.Fatal("Watch bundle id is required when a Watch token is present")
	}
}

func TestCloudCallURLRequiresTLSAndCarriesRoleWithoutSecret(t *testing.T) {
	got, err := cloudMediaURL(
		"https://push.airsim.example", "D9B59660-05BB-4EA8-9AEB-4505B35C93F9",
		"call-secret-0123456789abcdef",
	)
	if err != nil {
		t.Fatal(err)
	}
	want := "wss://push.airsim.example/v1/calls/d9b59660-05bb-4ea8-9aeb-4505b35c93f9/connect?role=agent"
	if got != want {
		t.Fatalf("media address=%q, want %q", got, want)
	}
	if _, err := cloudMediaURL("http://push.example.com", "call", "secret"); err == nil {
		t.Fatal("cleartext Relay must not produce a media address")
	}
}

func TestDecodeCloudCallActionAllowsOnlyBoundCall(t *testing.T) {
	for _, action := range []string{"answer", "reject", "end"} {
		value, err := decodeCloudCallAction([]byte(`{"action":"`+action+`","call_id":"call-9","owner":"iphone"}`), "call-9")
		if err != nil || value.Action != action || value.Owner != "iphone" {
			t.Fatalf("action=%s value=%#v err=%v", action, value, err)
		}
	}
	if _, err := decodeCloudCallAction([]byte(`{"action":"answer","call_id":"call-9","owner":"attacker"}`), "call-9"); err == nil {
		t.Fatal("public control must not forge an unknown media owner")
	}
	if _, err := decodeCloudCallAction([]byte(`{"action":"answer","call_id":"old"}`), "call-9"); err == nil {
		t.Fatal("stale call control must not be executed")
	}
	if _, err := decodeCloudCallAction([]byte(`{"action":"dial","call_id":"call-9"}`), "call-9"); err == nil {
		t.Fatal("public media control must not execute an arbitrary action")
	}
}

func TestDecodeCloudCallActionCarriesStableTraceIdentity(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "call-9", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", Generation: 7,
	}
	value, err := decodeCloudCallActionForDescriptor([]byte(`{
		"action":"end","call_id":"call-9",
		"call_uuid":"d9b59660-05bb-4ea8-9aeb-4505b35c93f9","generation":7,
		"command_id":"9f9dc60b-3a36-4a0a-b87a-63a3ffb27145","trace_id":"9f9dc60b","owner":"iphone"
	}`), descriptor)
	if err != nil {
		t.Fatal(err)
	}
	fields := cloudCallTraceFields(descriptor, value)
	if fields["call_uuid"] != descriptor.CallUUID || fields["generation"] != "7" ||
		fields["command_id"] != value.CommandID || fields["trace_id"] != "9f9dc60b" {
		t.Fatalf("link fields were not fully preserved: %#v", fields)
	}
	if _, err := decodeCloudCallActionForDescriptor(
		[]byte(`{"action":"end","call_id":"call-9","generation":6,"owner":"iphone"}`),
		descriptor,
	); err == nil {
		t.Fatal("control command from an old generation must be rejected")
	}
}

func TestCloudCommandURLKeepsPersistentSecretOutOfURL(t *testing.T) {
	registration := testPushRegistration("https://push.airsim.example")
	endpoint, err := cloudCommandURL(registration)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(endpoint, "/v1/devices/") || strings.Contains(endpoint, registration.DeviceSecret) {
		t.Fatalf("public command address leaked the device secret or has the wrong path: %q", endpoint)
	}
}

func TestExpiredCloudCommandIsRejectedAndDeduplicatedBeforeAT(t *testing.T) {
	agent := &agent{cloudCommandResults: make(map[string]cloudCommandResult)}
	command := cloudDeviceCommand{
		CommandID: "2d33c399-1030-4e9a-90ea-bb429e16ac5a",
		Type:      "dial", Number: "10086",
		ExpiresAt: time.Now().Add(-time.Minute).UTC().Format(time.RFC3339Nano),
	}
	first := agent.executeCloudCommand(command)
	second := agent.executeCloudCommand(command)
	if first.Status != "failed" || first.Error != "Cloud command expired" ||
		second.Status != first.Status || second.Error != first.Error {
		t.Fatalf("expired command result is unstable: first=%#v second=%#v", first, second)
	}
}

func TestCallOwnershipPreservesAuthenticatedIPhoneOwner(t *testing.T) {
	var received callOwnerPushEvent
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/call-owner" {
			t.Fatalf("request path=%q", request.URL.Path)
		}
		if err := json.NewDecoder(request.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	if err := manager.sendCallOwner("call-9", "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", "iphone", "active"); err != nil {
		t.Fatal(err)
	}
	if received.Owner != "iphone" || received.Phase != "active" || received.DeviceSecret == "" {
		t.Fatalf("ownership payload mismatch: %#v", received)
	}
}

func TestPushManagerSendsActivityStateWithOriginalCallUUID(t *testing.T) {
	var received callStatePushEvent
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/call-state" {
			t.Fatalf("path=%s", request.URL.Path)
		}
		if err := json.NewDecoder(request.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	manager.config = testPushRegistration(server.URL)
	manager.lastCallID = "call-live"
	manager.lastUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9"

	manager.lastGeneration = 7
	if err := manager.sendCallState("call-live", "ringing"); err != nil {
		t.Fatal(err)
	}
	if received.CallUUID != manager.lastUUID || received.Phase != "ringing" ||
		received.Generation != 7 || received.Source != "agent" || received.Timestamp == "" {
		t.Fatalf("call-state event mismatch: %#v", received)
	}
}

func TestIncomingSMSUsesAlertEndpointAndDeduplicates(t *testing.T) {
	var received []incomingSMSPushEvent
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/sms" {
			t.Fatalf("request path=%q", request.URL.Path)
		}
		var value incomingSMSPushEvent
		if err := json.NewDecoder(request.Body).Decode(&value); err != nil {
			t.Fatal(err)
		}
		received = append(received, value)
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()

	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	message := smsMessage{
		Sender: "10010", Content: "Balance reminder", Timestamp: time.Now(), DeliveryID: "SM-7-test",
	}
	if sent, err := manager.sendSMS(message); err != nil || !sent {
		t.Fatalf("first SMS was not sent: sent=%v err=%v", sent, err)
	}
	if sent, err := manager.sendSMS(message); err != nil || sent {
		t.Fatalf("duplicate SMS must not be sent again: sent=%v err=%v", sent, err)
	}
	if len(received) != 1 || received[0].DeliveryID != message.DeliveryID || received[0].Content != message.Content {
		t.Fatalf("SMS relay payload mismatch: %#v", received)
	}
}

func TestAgentHeartbeatReportsCellularStateWithoutSecrets(t *testing.T) {
	var received agentHeartbeatEvent
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/events/heartbeat" {
			t.Fatalf("request path=%q", request.URL.Path)
		}
		if err := json.NewDecoder(request.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	if err := manager.sendHeartbeat(agentHeartbeatSnapshot{
		ATOK: true, CellularState: "searching", CellularRegistration: "Searching",
		CellularRecovery: "Selecting network automatically", ECMCarrier: "1", SignalDBM: intPointer(-91),
	}); err != nil {
		t.Fatal(err)
	}
	if received.Event != "agent_heartbeat" || received.CellularState != "searching" ||
		received.DeviceSecret == "" || received.SignalDBM == nil || *received.SignalDBM != -91 {
		t.Fatalf("heartbeat payload mismatch: %#v", received)
	}
	if received.AgentMediaCapabilities == nil || len(received.AgentMediaCapabilities) != 0 || received.AgentMediaReady || received.MediaCapabilityRevision != 2 {
		t.Fatalf("heartbeat falsely advertised media: %#v", received)
	}
}

func TestAVFRegistrationExplicitlyClearsMediaCapabilities(t *testing.T) {
	var received pushRegistration
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/v1/devices/register" {
			t.Fatalf("request path=%q", request.URL.Path)
		}
		if err := json.NewDecoder(request.Body).Decode(&received); err != nil {
			t.Fatal(err)
		}
		response.WriteHeader(http.StatusOK)
	}))
	defer server.Close()
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	registration := testPushRegistration(server.URL)
	registration.MediaTransport = "webrtc"
	if err := manager.store(registration); err != nil {
		t.Fatal(err)
	}
	if err := manager.sendRegistration(); err != nil {
		t.Fatal(err)
	}
	if received.AgentMediaCapabilities == nil || len(received.AgentMediaCapabilities) != 0 || received.AgentMediaReady || received.MediaCapabilityRevision != 2 {
		t.Fatalf("registration falsely advertised media: %#v", received)
	}
	if received.MediaTransport != "" {
		t.Fatalf("registration transport=%q, want none for AVF", received.MediaTransport)
	}
}

func TestPushManagerCloudModeDisablesPublicEvents(t *testing.T) {
	requests := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		requests++
		response.WriteHeader(http.StatusAccepted)
	}))
	defer server.Close()
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	manager.client = server.Client()
	if err := manager.store(testPushRegistration(server.URL)); err != nil {
		t.Fatal(err)
	}
	if err := manager.setCloudEnabled(false); err != nil {
		t.Fatal(err)
	}
	if err := manager.sendHeartbeat(agentHeartbeatSnapshot{ATOK: true, CellularState: "registered"}); err != nil {
		t.Fatal(err)
	}
	if sent, err := manager.sendSMS(smsMessage{
		Sender: "10010", Content: "Balance reminder", Timestamp: time.Now(), DeliveryID: "disabled-sms",
	}); err != nil || sent {
		t.Fatalf("SMS relay must not be sent after cloud mode is disabled: sent=%v err=%v", sent, err)
	}
	if requests != 0 {
		t.Fatalf("public requests were still made after cloud mode was disabled: %d", requests)
	}
	if manager.status().CloudEnabled {
		t.Fatal("status still reports cloud mode enabled")
	}
}

func intPointer(value int) *int { return &value }

func TestNonRingingCallsNeverProduceVoIPPush(t *testing.T) {
	manager := newPushManager(filepath.Join(t.TempDir(), "push.json"))
	for _, call := range []callRecord{
		{ID: "out", Direction: "outgoing", State: "incoming"},
		{ID: "active", Direction: "incoming", State: "active"},
	} {
		if sent, err := manager.sendIncoming(call, time.Now()); err != nil || sent {
			t.Fatalf("non-ringing incoming call must not send a VoIP push: call=%#v sent=%v err=%v", call, sent, err)
		}
	}
}
