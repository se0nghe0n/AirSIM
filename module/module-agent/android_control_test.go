package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAndroidAVFPairingEntryAllowsHostOnCurrentPrivateLink(t *testing.T) {
	a := testAndroidAgent("secret-value")
	handler := a.routes(testLogger())
	request := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	request.RemoteAddr = "10.178.104.226:41000"
	request = request.WithContext(context.WithValue(request.Context(), http.LocalAddrContextKey,
		&net.TCPAddr{IP: net.ParseIP("10.178.104.25"), Port: 8575}))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("AVF private host status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestLoadAndroidControlTokenPrefersProtectedFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(path, []byte("file-secret\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	token, err := loadAndroidControlToken(func(key string) string {
		switch key {
		case androidControlTokenFileEnvironment:
			return path
		case androidControlTokenEnvironment:
			return "environment-secret"
		default:
			return ""
		}
	})
	if err != nil || token != "file-secret" {
		t.Fatalf("token=%q err=%v", token, err)
	}
}

func TestAndroidControlRequiresBearerToken(t *testing.T) {
	a := testAndroidAgent("secret-value")
	handler := a.routes(testLogger())

	request := httptest.NewRequest(http.MethodGet, "/api/android/status", nil)
	request.RemoteAddr = "10.185.5.63:41000"
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("missing token status=%d body=%s", response.Code, response.Body.String())
	}

	request = httptest.NewRequest(http.MethodGet, "/api/android/status", nil)
	request.RemoteAddr = "10.185.5.63:41000"
	request.Header.Set("Authorization", "Bearer secret-value")
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("valid token status=%d body=%s", response.Code, response.Body.String())
	}
}

func TestAndroidPairRegistrationStoresValidatedPushIdentityWithoutEchoingSecrets(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.push = newPushManager(filepath.Join(t.TempDir(), "push.json"))
	a.pairRegistrationSync = func() {}
	handler := a.routes(testLogger())
	registration := `{
		"cloud_enabled":true,"device_id":"iphone-air-12345678",
		"device_secret":"0123456789abcdef0123456789abcdef",
		"voip_token":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"alert_token":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		"bundle_id":"com.example.airsim","environment":"production",
		"relay_url":"https://push.example.com","media_transport":"legacy_pcm"
	}`
	request := httptest.NewRequest(http.MethodPost, "/api/android/pair/register", strings.NewReader(registration))
	request.RemoteAddr = "10.185.5.63:41000"
	request.Header.Set("Authorization", "Bearer secret-value")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("pair registration status=%d body=%s", response.Code, response.Body.String())
	}
	if strings.Contains(response.Body.String(), "0123456789abcdef") || strings.Contains(response.Body.String(), "aaaaaaaa") {
		t.Fatalf("pair response leaked credentials: %s", response.Body.String())
	}
	if !strings.Contains(response.Body.String(), `"device_id_hint":"…12345678"`) {
		t.Fatalf("pair response missing safe identity hint: %s", response.Body.String())
	}
	status := a.push.status()
	if !status.Configured || status.CallPushReady || !status.MessagePushReady {
		t.Fatalf("pair registration was not stored: %#v", status)
	}
}

func TestAndroidPairRegistrationRejectsInvalidIdentity(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.push = newPushManager(filepath.Join(t.TempDir(), "push.json"))
	a.pairRegistrationSync = func() {}
	handler := a.routes(testLogger())
	request := httptest.NewRequest(http.MethodPost, "/api/android/pair/register", strings.NewReader(`{"device_id":"x"}`))
	request.RemoteAddr = "10.185.5.63:41000"
	request.Header.Set("Authorization", "Bearer secret-value")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest || a.push.status().Configured {
		t.Fatalf("invalid pair registration status=%d configured=%v", response.Code, a.push.status().Configured)
	}
}

func TestAndroidCallEventDrivesSharedCallTracker(t *testing.T) {
	a := testAndroidAgent("secret-value")
	handler := a.routes(testLogger())
	postAndroidJSON(t, handler, "/api/android/calls/event", `{
		"event_id":"evt-1","call_id":"telecom-7","direction":"incoming",
		"state":"incoming","number":"+86 13800138000","mode":"remote_silent"
	}`)

	a.mu.RLock()
	if a.calls.Active == nil || a.calls.Active.AndroidID != "telecom-7" ||
		a.calls.Active.State != "incoming" || a.calls.Active.Direction != "incoming" {
		t.Fatalf("unexpected active call: %#v", a.calls.Active)
	}
	firstID := a.calls.Active.ID
	a.mu.RUnlock()

	postAndroidJSON(t, handler, "/api/android/calls/event", `{
		"event_id":"evt-2","call_id":"telecom-7","direction":"incoming",
		"state":"active","number":"+86 13800138000","mode":"remote_silent"
	}`)
	a.mu.RLock()
	if a.calls.Active == nil || a.calls.Active.ID != firstID || a.calls.Active.State != "active" {
		t.Fatalf("active transition lost identity: %#v", a.calls.Active)
	}
	a.mu.RUnlock()

	postAndroidJSON(t, handler, "/api/android/calls/event", `{
		"event_id":"evt-3","call_id":"telecom-7","direction":"incoming",
		"state":"ended","mode":"remote_silent"
	}`)
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.calls.Active != nil || len(a.calls.History) != 1 || a.calls.History[0].ID != firstID {
		t.Fatalf("ended transition incorrect: active=%#v history=%#v", a.calls.Active, a.calls.History)
	}
}

func TestAndroidCommandWaitsForMatchingAcknowledgement(t *testing.T) {
	control := newAndroidControl("secret-value")
	resultChannel := make(chan androidCommandResult, 1)
	go func() {
		resultChannel <- control.execute(context.Background(), androidCommand{
			ID: "command-1", Action: "answer", CallID: "telecom-7",
		}, time.Second)
	}()

	command, ok := control.next(context.Background(), time.Second)
	if !ok || command.ID != "command-1" || command.Action != "answer" {
		t.Fatalf("unexpected command: ok=%v command=%#v", ok, command)
	}
	select {
	case result := <-resultChannel:
		t.Fatalf("command completed before Android acknowledgement: %#v", result)
	default:
	}
	if err := control.complete(androidCommandResult{ID: "stale", Success: true}); err == nil {
		t.Fatal("stale acknowledgement must be rejected")
	}
	if err := control.complete(androidCommandResult{ID: "command-1", Success: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-resultChannel:
		if !result.Success || result.ID != "command-1" {
			t.Fatalf("unexpected result: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("matching acknowledgement did not release command")
	}
}

func TestAndroidCommandTimesOutAndIsRemoved(t *testing.T) {
	control := newAndroidControl("secret-value")
	result := control.execute(context.Background(), androidCommand{ID: "command-timeout", Action: "end"}, 10*time.Millisecond)
	if result.Success || !strings.Contains(result.Error, "timeout") {
		t.Fatalf("unexpected timeout result: %#v", result)
	}
	if err := control.complete(androidCommandResult{ID: "command-timeout", Success: true}); err == nil {
		t.Fatal("late acknowledgement must be rejected")
	}
}

func TestAndroidProfileSMSSendUsesTelephonyInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	resultChannel := make(chan struct {
		segments int
		err      error
	}, 1)
	go func() {
		segments, err := a.sendSMSMessage("+86 13800138000", "First part\nSecond part")
		resultChannel <- struct {
			segments int
			err      error
		}{segments: segments, err: err}
	}()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "send_sms" || command.Number != "+8613800138000" || command.Message != "First part\nSecond part" {
		t.Fatalf("Android SMS was not routed to Telephony: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true, Segments: 2}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-resultChannel:
		if result.err != nil || result.segments != 2 {
			t.Fatalf("unexpected Android SMS result: segments=%d err=%v", result.segments, result.err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android SMS did not finish after Telephony acknowledgement")
	}
}

func TestAndroidIncomingSMSEventFeedsSharedQueueAndDeduplicates(t *testing.T) {
	a := testAndroidAgent("secret-value")
	handler := a.routes(testLogger())
	body := `{
		"event_id":"sms-event-7","delivery_id":"android-sms-7",
		"sender":"10010","content":"Verification code 246810",
		"timestamp":"2026-09-23T10:20:30.123Z"
	}`
	postAndroidJSON(t, handler, "/api/android/sms/event", body)

	a.mu.RLock()
	if len(a.messages) != 1 || a.messages[0].Memory != "ANDROID" ||
		a.messages[0].Message.Sender != "10010" ||
		a.messages[0].Message.Content != "Verification code 246810" ||
		a.messages[0].Message.Code != "246810" ||
		a.messages[0].Message.DeliveryID != "android-sms-7" {
		t.Fatalf("unexpected Android SMS queue: %#v", a.messages)
	}
	firstRevision := a.smsRevision
	a.mu.RUnlock()

	postAndroidJSON(t, handler, "/api/android/sms/event", body)
	a.mu.RLock()
	defer a.mu.RUnlock()
	if len(a.messages) != 1 || a.smsRevision != firstRevision {
		t.Fatalf("duplicate Android SMS was re-enqueued: count=%d revision=%d->%d", len(a.messages), firstRevision, a.smsRevision)
	}
}

func TestAndroidProfileHangupUsesTelecomInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "agent-call-9", AndroidID: "telecom-9", Direction: "outgoing", State: "active",
	}
	result := make(chan error, 1)
	go func() { result <- a.hangupCall() }()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "end" || command.CallID != "telecom-9" {
		t.Fatalf("Android hangup was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android hangup did not finish after Telecom acknowledgement")
	}
}

func TestAndroidProfileRejectUsesTelecomInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "agent-call-reject", AndroidID: "telecom-reject", Direction: "incoming", State: "incoming",
	}
	result := make(chan error, 1)
	go func() { result <- a.rejectCall() }()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "reject" || command.CallID != "telecom-reject" {
		t.Fatalf("Android reject was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android reject did not finish after Telecom acknowledgement")
	}
}

func TestLocalRejectDoesNotTargetNewCallWithStaleID(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "current-call", AndroidID: "telecom-current", Direction: "incoming", State: "incoming",
	}
	request := httptest.NewRequest(http.MethodPost, "/api/calls/reject",
		strings.NewReader(`{"call_id":"previous-call"}`))
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { a.reject(response, request); close(done) }()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if command, ok := a.android.next(ctx, 100*time.Millisecond); ok {
		_ = a.android.complete(androidCommandResult{ID: command.ID, Success: true})
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stale reject did not return")
	}
	if response.Code != http.StatusBadGateway {
		t.Fatalf("stale reject status=%d; must not control a different call", response.Code)
	}
}

func TestLocalHangupDoesNotTargetNewCallWithStaleID(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "current-call", AndroidID: "telecom-current", Direction: "outgoing", State: "active",
	}
	request := httptest.NewRequest(http.MethodPost, "/api/calls/hangup",
		strings.NewReader(`{"call_id":"previous-call"}`))
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { a.hangup(response, request); close(done) }()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if command, ok := a.android.next(ctx, 100*time.Millisecond); ok {
		_ = a.android.complete(androidCommandResult{ID: command.ID, Success: true})
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stale hangup did not return")
	}
	if response.Code != http.StatusBadGateway {
		t.Fatalf("stale hangup status=%d; must not control a different call", response.Code)
	}
}

func TestLocalAnswerDoesNotTargetNewCallWithStaleID(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "current-call", AndroidID: "telecom-current", Direction: "incoming", State: "incoming",
	}
	request := httptest.NewRequest(http.MethodPost, "/api/calls/answer",
		strings.NewReader(`{"call_id":"previous-call"}`))
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { a.answer(response, request); close(done) }()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	if command, ok := a.android.next(ctx, 100*time.Millisecond); ok {
		_ = a.android.complete(androidCommandResult{ID: command.ID, Success: true})
		a.applyAndroidCallEvent(androidCallEvent{
			EventID: "new-call-active", CallID: "telecom-current", Direction: "incoming", State: "active",
		}, time.Now())
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stale answer did not return")
	}
	if response.Code != http.StatusBadGateway {
		t.Fatalf("stale answer status=%d; must not control a different call", response.Code)
	}
}

func TestAndroidProfileDTMFUsesTelecomInsteadOfATPort(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "agent-call-10", AndroidID: "telecom-10", Direction: "outgoing", State: "active",
	}
	result := make(chan error, 1)
	go func() { result <- a.sendDTMFDigit("5") }()

	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != "dtmf" || command.CallID != "telecom-10" || command.Number != "5" {
		t.Fatalf("Android DTMF was not routed to Telecom: ok=%v command=%#v", ok, command)
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Android DTMF did not finish after Telecom acknowledgement")
	}
}

func TestCloudRejectDoesNotTargetNewAndroidCall(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "old-call", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
		Generation: 2, Direction: "incoming",
	}
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "new-call", AndroidID: "telecom-new", Direction: "incoming", State: "incoming",
	}
	a.cloudCallCurrent = &descriptor
	resultChannel := make(chan cloudCommandResult, 1)
	go func() {
		resultChannel <- a.executeCloudCommand(cloudDeviceCommand{
			CommandID: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145",
			Type:      "call_control", Action: "reject", Owner: "iphone",
			ExpiresAt: time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano),
			Call: &cloudCommandCall{
				CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
				Generation: descriptor.Generation, Direction: descriptor.Direction,
			},
		})
	}()
	type nextCommand struct {
		command androidCommand
		ok      bool
	}
	commandChannel := make(chan nextCommand, 1)
	go func() {
		command, ok := a.android.next(context.Background(), time.Second)
		commandChannel <- nextCommand{command: command, ok: ok}
	}()
	select {
	case next := <-commandChannel:
		if !next.ok {
			t.Fatal("Android command poll ended unexpectedly")
		}
		_ = a.android.complete(androidCommandResult{ID: next.command.ID, Success: true})
		if next.command.CallID == "telecom-new" {
			t.Fatal("stale cloud reject targeted the new Android call")
		}
	case result := <-resultChannel:
		if result.Status != "failed" {
			t.Fatalf("stale cloud reject result=%#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("stale cloud reject did not fail promptly")
	}
}

func TestCloudMediaRejectDoesNotTargetNewAndroidCall(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.calls.Active = &callRecord{
		ID: "new-call", AndroidID: "telecom-new", Direction: "incoming", State: "incoming",
	}
	err := a.executeIncomingCloudCallAction(cloudCallAction{
		CallID: "old-call", CommandID: "cloud-media-reject",
	}, "reject")
	if err == nil || !strings.Contains(err.Error(), "Call ID is no longer valid") {
		t.Fatalf("stale media reject should fail without a Telecom command, err=%v", err)
	}
	if _, ok := a.android.next(context.Background(), 10*time.Millisecond); ok {
		t.Fatal("stale media reject dispatched an Android Telecom command")
	}
}

func testAndroidAgent(token string) *agent {
	a := newAgent(atDevice)
	a.profile = runtimeProfileFrom("android-avf")
	a.android = newAndroidControl(token)
	a.push = nil
	return a
}

func postAndroidJSON(t *testing.T, handler http.Handler, path, body string) {
	t.Helper()
	request := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	request.RemoteAddr = "10.185.5.63:41000"
	request.Header.Set("Authorization", "Bearer secret-value")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("POST %s status=%d body=%s", path, response.Code, response.Body.String())
	}
}
