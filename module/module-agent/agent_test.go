package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
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
	"sync"
	"testing"
	"time"

	sgp22 "github.com/damonto/euicc-go/v2"
)

func TestRequestAdmissionReservesCallControlCapacity(t *testing.T) {
	admission := newRequestAdmission(1, 1, 1)
	release, ok := admission.acquire(context.Background(), "/api/status")
	if !ok {
		t.Fatal("the first ordinary status request should be admitted")
	}
	defer release()
	if _, ok := admission.acquire(context.Background(), "/api/router/status"); ok {
		t.Fatal("an ordinary request should be rejected quickly when its channel is saturated")
	}
	criticalRelease, ok := admission.acquire(context.Background(), "/api/calls/hangup")
	if !ok {
		t.Fatal("saturated ordinary requests must not block hangup control")
	}
	criticalRelease()
}

func TestRequestAdmissionSeparatesLongPolls(t *testing.T) {
	admission := newRequestAdmission(1, 1, 1)
	release, ok := admission.acquire(context.Background(), "/api/events")
	if !ok {
		t.Fatal("the first long poll should be admitted")
	}
	defer release()
	normalRelease, ok := admission.acquire(context.Background(), "/api/status")
	if !ok {
		t.Fatal("a long poll must not occupy the ordinary status channel")
	}
	normalRelease()
}

func TestAndroidCommandPollHasReservedAdmission(t *testing.T) {
	admission := newRequestAdmission(1, 1, 2)
	firstRelease, ok := admission.acquire(context.Background(), "/api/events")
	if !ok {
		t.Fatal("the first iPhone event long poll should be admitted")
	}
	defer firstRelease()
	secondRelease, ok := admission.acquire(context.Background(), "/api/calls/events")
	if !ok {
		t.Fatal("the second iPhone event long poll should be admitted")
	}
	defer secondRelease()

	androidRelease, ok := admission.acquire(context.Background(), "/api/android/commands/next")
	if !ok {
		t.Fatal("Android command polling must keep reserved capacity when iPhone long polls are saturated")
	}
	androidRelease()

	if got := classifyRequest("/api/android/commands/result"); got != requestClassControl {
		t.Fatalf("Android command result class=%v, want control", got)
	}
}

func TestOperationFlightCoalescesConcurrentHangups(t *testing.T) {
	var flight operationFlight
	started := make(chan struct{})
	finish := make(chan struct{})
	var mu sync.Mutex
	runs := 0
	operation := func() error {
		mu.Lock()
		runs++
		mu.Unlock()
		close(started)
		<-finish
		return nil
	}
	results := make(chan error, 2)
	go func() { results <- flight.Do(operation) }()
	<-started
	go func() { results <- flight.Do(operation) }()
	// Give the second request time to join the existing flight; the first operation stays blocked on finish.
	time.Sleep(10 * time.Millisecond)
	close(finish)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatalf("coalesced hangup returned an error: %v", err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if runs != 1 {
		t.Fatalf("concurrent hangup ran %d times, want 1", runs)
	}
}

func TestAllowedRemote(t *testing.T) {
	tests := []struct {
		remote string
		want   bool
	}{
		{"192.168.225.2:54321", true},
		{"192.168.225.254:1", true},
		{"127.0.0.1:7575", true},
		{"[::1]:7575", true},
		{"10.185.5.63:41000", true},
		{"192.168.224.2:7575", false},
		{"10.185.6.63:41000", false},
		{"8.8.8.8:53", false},
		{"invalid", false},
	}
	for _, test := range tests {
		if got := allowedRemote(test.remote); got != test.want {
			t.Errorf("allowedRemote(%q)=%v, want %v", test.remote, got, test.want)
		}
	}
}

func TestAndroidAVFAllowsPrivatePeerOnDirectlyConnectedSubnet(t *testing.T) {
	networks := []*net.IPNet{
		{IP: net.ParseIP("172.29.240.25").To4(), Mask: net.CIDRMask(24, 32)},
	}
	if !allowedRemoteWithNetworks("172.29.240.24:41000", runtimeProfileFrom("android-avf"), networks) {
		t.Fatal("current AVF host peer should be accepted")
	}
	if allowedRemoteWithNetworks("172.29.241.24:41000", runtimeProfileFrom("android-avf"), networks) {
		t.Fatal("unrelated private subnet must remain rejected")
	}
}

func TestAndroidAVFAllowsHostOnSocketSubnetWithGuest32Mask(t *testing.T) {
	profile := runtimeProfileFrom("android-avf")
	local := &net.TCPAddr{IP: net.ParseIP("10.178.104.25"), Port: 8575}
	if !allowedAVFRemoteOnSocket("10.178.104.226:41000", local, profile) {
		t.Fatal("Android host on the AVF link should be accepted even if guest has a /32 mask")
	}
	for _, remote := range []string{"10.178.105.226:41000", "192.168.31.203:41000", "203.0.113.9:41000", "invalid"} {
		if allowedAVFRemoteOnSocket(remote, local, profile) {
			t.Fatalf("unrelated peer %q must remain rejected", remote)
		}
	}
	if allowedAVFRemoteOnSocket("10.178.104.226:41000", &net.TCPAddr{IP: net.ParseIP("192.168.31.25"), Port: 8575}, profile) {
		t.Fatal("a LAN listener must not gain AVF access")
	}
	if allowedAVFRemoteOnSocket("10.178.104.226:41000", local, runtimeProfileFrom("qdc507")) {
		t.Fatal("the QDC507 runtime must not gain AVF access")
	}
}

func TestCompareModuleVersions(t *testing.T) {
	tests := []struct {
		left, right string
		want        int
	}{
		{"0.3.0", "0.2.8", 1},
		{"0.3.0", "0.3.0", 0},
		{"0.2.9", "0.3.0", -1},
		{"1.0", "1.0.0", 0},
	}
	for _, test := range tests {
		if got := compareModuleVersions(test.left, test.right); got != test.want {
			t.Errorf("compareModuleVersions(%q,%q)=%d, want %d", test.left, test.right, got, test.want)
		}
	}
}

func TestValidateModuleUpdateManifestRejectsIncompleteOrWrongTarget(t *testing.T) {
	validFiles := make([]moduleUpdateFile, 0, len(moduleUpdateTargets))
	for name, target := range moduleUpdateTargets {
		validFiles = append(validFiles, moduleUpdateFile{
			Name: name, Target: target.target, SHA256: strings.Repeat("a", 64), Size: 1, Mode: target.mode,
		})
	}
	manifest := moduleUpdateManifest{
		FormatVersion: moduleUpdateFormat,
		Version:       "0.3.7",
		Platform:      moduleUpdatePlatform,
		Files:         validFiles,
	}
	if err := validateModuleUpdateManifest(manifest); err != nil {
		t.Fatalf("valid update manifest was rejected: %v", err)
	}
	manifest.Files[0].Target = "bin/unsafe"
	if err := validateModuleUpdateManifest(manifest); err == nil {
		t.Fatal("an out-of-bounds target in the update manifest was not rejected")
	}
}

func TestParseCLCC(t *testing.T) {
	response := "+CLCC: 1,1,4,0,0,\"+8613800138000\",145\r\n" +
		"+CLCC: 2,0,0,1,0,\"data\",129\r\nOK\r\n"
	calls := parseCLCC(response)
	if len(calls) != 1 {
		t.Fatalf("voice call count=%d, want 1", len(calls))
	}
	if calls[0].Direction != "incoming" || calls[0].State != "incoming" || calls[0].Number != "+8613800138000" {
		t.Fatalf("call parse mismatch: %#v", calls[0])
	}
}

func TestParseDSCIIncomingAndEnd(t *testing.T) {
	call, ended, ok := parseDSCI(`^DSCI: 1,1,4,0,13022100000,129,0`)
	if !ok || ended || call.Index != 1 || call.Direction != "incoming" ||
		call.State != "incoming" || call.Number != "13022100000" {
		t.Fatalf("incoming DSCI parse mismatch: call=%#v ended=%v ok=%v", call, ended, ok)
	}
	_, ended, ok = parseDSCI(`^DSCI: 1,1,6,0,13022100000,129,0`)
	if !ok || !ended {
		t.Fatalf("ended DSCI parse mismatch: ended=%v ok=%v", ended, ok)
	}
	if _, _, ok := parseDSCI(`^DSCI: 1,1,4,1,data,129,0`); ok {
		t.Fatal("a PS session must not be parsed as a voice call")
	}
}

func TestATPortDispatchesChunkedURCWithoutTreatingResponsesAsEvents(t *testing.T) {
	port := newATPort("unused")
	var lines []string
	port.urcHandler = func(line string) { lines = append(lines, line) }
	pending := port.dispatchCompleteURCLines(nil, []byte("\r\n^DSCI: 1,1,"))
	pending = port.dispatchCompleteURCLines(pending, []byte("4,0,10086,129,0\r\n+CLCC: 1,1,4,0,0\r\n"))
	if len(pending) != 0 {
		t.Fatalf("URC chunking left a remainder: %q", pending)
	}
	if len(lines) != 1 || lines[0] != "^DSCI: 1,1,4,0,10086,129,0" {
		t.Fatalf("URC dispatch mismatch: %#v", lines)
	}
}

func TestParseSMSStorageURC(t *testing.T) {
	notice, ok := parseSMSStorageURC(`+CMTI: "SM",7`)
	if !ok || notice.Memory != "SM" || notice.Index != 7 {
		t.Fatalf("SMS storage URC parse mismatch: notice=%#v ok=%v", notice, ok)
	}
}

func TestApplyCallPollRecordsMissedCall(t *testing.T) {
	a := &agent{}
	started := time.Date(2026, 8, 15, 10, 0, 0, 0, time.UTC)
	a.applyCallPoll([]parsedCall{{Index: 1, Direction: "incoming", State: "incoming", Number: "10086"}}, started)
	a.applyCallPoll(nil, started.Add(3*time.Second))
	if a.calls.Active != nil || len(a.calls.History) != 1 {
		t.Fatalf("call end state mismatch: active=%#v history=%d", a.calls.Active, len(a.calls.History))
	}
	if !a.calls.History[0].Missed || a.calls.History[0].EndedAt == nil {
		t.Fatalf("missed-call record mismatch: %#v", a.calls.History[0])
	}
}

func TestEndedDSCIRejectsStaleCLCCResurrection(t *testing.T) {
	a := &agent{}
	started := time.Now()
	incoming := parsedCall{Index: 1, Direction: "incoming", State: "incoming", Number: "10086"}
	a.applyCallPoll([]parsedCall{incoming}, started)
	if a.calls.Active == nil {
		t.Fatal("incoming call did not enter the active tracker")
	}
	originalID := a.calls.Active.ID

	// The baseband first reports call end through a URC, but the immediately following AT+CLCC may still return a stale cache.
	a.handleURC(`^DSCI: 1,1,6,0,10086,129,0`)
	a.applyCallPoll([]parsedCall{incoming}, started.Add(1500*time.Millisecond))

	if a.calls.Active != nil {
		t.Fatalf("stale CLCC recreated the incoming call: %#v", a.calls.Active)
	}
	if len(a.calls.History) != 1 || a.calls.History[0].ID != originalID {
		t.Fatalf("end record was duplicated or replaced: %#v", a.calls.History)
	}
}

func TestUSBSoftwareReconnectRequiresIdleECMOnlyProfile(t *testing.T) {
	if err := validateUSBSoftwareReconnect(false, false, "diag,ecm,ffs"); err != nil {
		t.Fatalf("an idle ECM composition should allow a software reconnect: %v", err)
	}
	for name, test := range map[string]struct {
		callActive  bool
		voiceActive bool
		functions   string
	}{
		"call active":         {callActive: true, functions: "diag,ecm,ffs"},
		"media route running": {voiceActive: true, functions: "diag,ecm,ffs"},
		"missing ECM":         {functions: "diag,ffs"},
		"includes serial":     {functions: "diag,serial,ecm,ffs"},
		"includes USB audio":  {functions: "diag,ecm,ffs,audio"},
	} {
		t.Run(name, func(t *testing.T) {
			if err := validateUSBSoftwareReconnect(test.callActive, test.voiceActive, test.functions); err == nil {
				t.Fatal("a dangerous state must not allow USB software reconnect")
			}
		})
	}
}

func TestCallHistoryAckRemovesOnlyConfirmedRecords(t *testing.T) {
	a := &agent{calls: callTracker{History: []callRecord{{ID: "keep"}, {ID: "remove"}}}}
	request := httptest.NewRequest("POST", "/api/calls/history/ack", strings.NewReader(`{"ids":["remove"]}`))
	response := httptest.NewRecorder()
	a.callHistoryAck(response, request)
	if response.Code != 200 {
		t.Fatalf("ack API status=%d, body=%s", response.Code, response.Body.String())
	}
	if len(a.calls.History) != 1 || a.calls.History[0].ID != "keep" {
		t.Fatalf("call queue mismatch after ack: %#v", a.calls.History)
	}
}

func TestUCS2RoundTripAndSplit(t *testing.T) {
	value := "Verification code 123456, test🙂"
	encoded := encodeUCS2(value)
	if decoded := decodeMaybeUCS2(encoded); decoded != value {
		t.Fatalf("UCS2 round trip=%q, want %q", decoded, value)
	}
	segments := splitUCS2("A🙂B", 2)
	if len(segments) != 3 || segments[0] != "A" || segments[1] != "🙂" || segments[2] != "B" {
		t.Fatalf("surrogate-pair split mismatch: %#v", segments)
	}
}

func TestParseTextModeSMS(t *testing.T) {
	response := "+CMGL: 7,\"REC READ\",\"002B0038003600310033003800300030003100330038003000300030\",,\"26/08/15,12:34:56+32\"\r\n" +
		"0056006500720069006600690063006100740069006F006E00200063006F006400650020006900730020003100320033003400350036\r\nOK\r\n"
	items := parseTextModeSMS(response, "ME")
	if len(items) != 1 {
		t.Fatalf("SMS count=%d, want 1", len(items))
	}
	message := items[0].Message
	if message.Sender != "+8613800138000" || message.Content != "Verification code is 123456" || message.Code != "123456" {
		t.Fatalf("SMS parse mismatch: %#v", message)
	}
	_, offset := message.Timestamp.Zone()
	if offset != 8*60*60 {
		t.Fatalf("SMS timezone offset=%d, want 28800", offset)
	}
	if message.DeliveryID == "" || !containsStoredSMS(items, items[0]) {
		t.Fatalf("SMS delivery id or dedup state mismatch: %#v", items[0])
	}
}

func TestParseModemFields(t *testing.T) {
	if got := parseSignalDBM("+CSQ: 29,99\r\nOK"); got == nil || *got != -55 {
		t.Fatalf("signal parse=%v, want -55", got)
	}
	mode, band := parseNetworkInfo(`+QNWINFO: "FDD LTE","46001","LTE BAND 3",1650`)
	if mode != "FDD LTE" || band != "BAND 3" {
		t.Fatalf("network parse mode=%q band=%q", mode, band)
	}
	if got := normalizeOperator("CHN-UNICOM"); got != "China Unicom" {
		t.Fatalf("normalized operator=%q", got)
	}
}

func TestGPSRefreshExecutesQGPSLOCWhenEnabled(t *testing.T) {
	var commands []string
	a := &agent{
		gps: gpsTracker{Enabled: true},
		gpsCommand: func(command string, timeout time.Duration) (string, error) {
			commands = append(commands, command)
			return "+QGPSLOC: 120000.0,22.7261,113.8420,0.8,42.1,1,0.0,0.0,0.0,18082026,12\r\nOK", nil
		},
	}
	request := httptest.NewRequest(http.MethodPost, "/api/gps/refresh", nil)
	response := httptest.NewRecorder()

	a.gpsRefresh(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("GPS refresh status=%d, body=%s", response.Code, response.Body.String())
	}
	if len(commands) != 1 || commands[0] != "AT+QGPSLOC=2" {
		t.Fatalf("GPS refresh AT command=%#v, want [AT+QGPSLOC=2]", commands)
	}
	for _, expected := range []string{`"latitude":"22.7261"`, `"longitude":"113.8420"`, `"satellites":"12"`} {
		if !strings.Contains(response.Body.String(), expected) {
			t.Fatalf("GPS refresh response missing %s: %s", expected, response.Body.String())
		}
	}
}

func TestGPSRefreshPersistsNoFixError(t *testing.T) {
	a := &agent{
		gps: gpsTracker{Enabled: true},
		gpsCommand: func(command string, timeout time.Duration) (string, error) {
			return "OK", nil
		},
	}
	request := httptest.NewRequest(http.MethodPost, "/api/gps/refresh", nil)
	response := httptest.NewRecorder()

	a.gpsRefresh(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("GPS no-fix status=%d, want %d", response.Code, http.StatusServiceUnavailable)
	}
	if a.gps.LastError != "Location unavailable; move near a window or outdoors and try again" {
		t.Fatalf("GPS no-fix error was not stored: %q", a.gps.LastError)
	}
}

func TestParseUSBConfigurationRefusesMalformedInput(t *testing.T) {
	valid := `+QCFG: "usbcfg",0x2C7C,0x0125,1,1,1,1,1,1,1` + "\r\nOK"
	configuration, err := parseUSBConfiguration(valid)
	if err != nil || !configuration.uacEnabled() {
		t.Fatalf("valid USBCFG failed to parse: config=%#v err=%v", configuration, err)
	}
	if _, err := parseUSBConfiguration(`+QCFG: "usbcfg",0x2C7C,0x0125,1`); err == nil {
		t.Fatal("malformed USBCFG was not rejected")
	}
}

func TestInferQDC507USBConfigurationFromGadget(t *testing.T) {
	files := map[string]string{
		usbGadgetPath + "/idVendor":  "2c7c\n",
		usbGadgetPath + "/idProduct": "0125\n",
		usbGadgetPath + "/functions": "diag,ecm,ffs\n",
	}
	readFile := func(path string) ([]byte, error) {
		value, ok := files[path]
		if !ok {
			return nil, os.ErrNotExist
		}
		return []byte(value), nil
	}
	configuration, raw, err := inferQDC507USBConfiguration(readFile)
	if err != nil || configuration.uacEnabled() || raw != "gadget functions=diag,ecm,ffs" {
		t.Fatalf("mobile-mode inference mismatch: config=%#v raw=%q err=%v", configuration, raw, err)
	}
	if got := configuration.withUAC(true); got != `AT+QCFG="usbcfg",0x2C7C,0x0125,1,1,1,1,1,1,1` {
		t.Fatalf("Mac mode command=%q", got)
	}
	files[usbGadgetPath+"/functions"] = "diag,serial,ecm,ffs,audio\n"
	configuration, _, err = inferQDC507USBConfiguration(readFile)
	if err != nil || !configuration.uacEnabled() {
		t.Fatalf("Mac mode inference mismatch: config=%#v err=%v", configuration, err)
	}
}

func TestInferQDC507USBConfigurationRejectsUnknownHardware(t *testing.T) {
	readFile := func(path string) ([]byte, error) {
		values := map[string]string{
			usbGadgetPath + "/idVendor":  "ffff",
			usbGadgetPath + "/idProduct": "0125",
			usbGadgetPath + "/functions": "diag,ecm,ffs",
		}
		return []byte(values[path]), nil
	}
	if _, _, err := inferQDC507USBConfiguration(readFile); err == nil {
		t.Fatal("unknown hardware must not use the fixed USBCFG fallback")
	}
}

func TestPersistUSBModeMarkerTracksExplicitMacSelection(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "usb-mode-mac")
	if changed, err := persistUSBModeMarker(marker, "mac"); err != nil || !changed {
		t.Fatalf("failed to write the Mac mode marker: %v", err)
	}
	if data, err := os.ReadFile(marker); err != nil || string(data) != "mac\n" {
		t.Fatalf("Mac mode marker=%q err=%v", data, err)
	}
	if changed, err := persistUSBModeMarker(marker, "mobile"); err != nil || !changed {
		t.Fatalf("failed to delete the Mac mode marker: %v", err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("phone mode still kept the Mac marker: %v", err)
	}
}

func TestRoutesRejectPublicRemote(t *testing.T) {
	a := &agent{started: time.Now()}
	request := httptest.NewRequest("GET", "/api/health", nil)
	request.RemoteAddr = "203.0.113.9:54321"
	recorder := httptest.NewRecorder()
	a.routes(testLogger()).ServeHTTP(recorder, request)
	if recorder.Code != 403 {
		t.Fatalf("public access status=%d, want 403", recorder.Code)
	}
}

func TestLegacySelfUpdateRoutesDirectClientsToInstallerService(t *testing.T) {
	a := newAgent("unused")
	request := httptest.NewRequest(http.MethodPost, "/api/system/update", strings.NewReader("legacy-package"))
	request.RemoteAddr = "127.0.0.1:10001"
	response := httptest.NewRecorder()
	a.routes(testLogger()).ServeHTTP(response, request)
	if response.Code != http.StatusGone {
		t.Fatalf("legacy update status=%d body=%s", response.Code, response.Body.String())
	}
	if !strings.Contains(response.Body.String(), "8576") {
		t.Fatalf("legacy update response does not identify installerd: %s", response.Body.String())
	}
}

func TestCoreCallAndSMSRoutesRemainAvailableForLegacyApps(t *testing.T) {
	a := newAgent("unused")
	handler := a.routes(testLogger())
	paths := []string{
		"/api/calls/status",
		"/api/calls/dial",
		"/api/calls/answer",
		"/api/calls/hangup",
		"/api/calls/audio/host/register",
		"/api/sms",
		"/api/sms/status",
		"/api/sms/send",
	}
	for _, path := range paths {
		// GET executes read-only routes and makes mutation routes return 405. Both
		// prove that the exact legacy path is registered without issuing an AT command.
		request := httptest.NewRequest(http.MethodGet, path, nil)
		request.RemoteAddr = "127.0.0.1:10001"
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code == http.StatusNotFound {
			t.Errorf("legacy core route unavailable: %s status=%d body=%s", path, response.Code, response.Body.String())
		}
	}
}

func TestDebugEndpointCapturesHTTPInputAndOutput(t *testing.T) {
	a := newAgent("unused")
	handler := a.routes(testLogger())

	platformRequest := httptest.NewRequest("GET", "/api/platform", nil)
	platformRequest.RemoteAddr = "127.0.0.1:10001"
	platformRequest.Header.Set("X-AirSIM-Trace-ID", "trace-http-platform")
	platformResponse := httptest.NewRecorder()
	handler.ServeHTTP(platformResponse, platformRequest)
	if platformResponse.Code != http.StatusOK {
		t.Fatalf("platform API status=%d", platformResponse.Code)
	}

	debugRequest := httptest.NewRequest("GET", "/?limit=50", nil)
	debugRequest.RemoteAddr = "127.0.0.1:10002"
	debugResponse := httptest.NewRecorder()
	handler.ServeHTTP(debugResponse, debugRequest)
	if debugResponse.Code != http.StatusOK {
		t.Fatalf("debug API status=%d, body=%s", debugResponse.Code, debugResponse.Body.String())
	}
	body := debugResponse.Body.String()
	for _, expected := range []string{`"events"`, `GET /api/platform`, `"category":"http"`, `"trace_id":"trace-http-platform"`, `"version":"` + agentVersion + `"`} {
		if !strings.Contains(body, expected) {
			t.Fatalf("debug response missing %q: %s", expected, body)
		}
	}
}

func TestCallEventsWaitIsReleasedByMeaningfulCallChange(t *testing.T) {
	a := newAgent("unused")
	request := httptest.NewRequest(http.MethodGet, "/api/calls/events?after=0&timeout_ms=500", nil)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		a.callEvents(response, request)
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("long poll returned before the call state changed")
	case <-time.After(20 * time.Millisecond):
	}

	a.applyCallPoll([]parsedCall{{Index: 1, Direction: "incoming", State: "incoming", Number: "10086"}}, time.Now())
	select {
	case <-done:
	case <-time.After(300 * time.Millisecond):
		t.Fatal("call state change did not wake the long poll")
	}

	if response.Code != http.StatusOK {
		t.Fatalf("unexpected status: %d body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Active   *callRecord `json:"active"`
		Revision uint64      `json:"revision"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Active == nil || payload.Active.Number != "10086" || payload.Revision == 0 {
		t.Fatalf("unexpected event payload: %+v", payload)
	}
}

func TestAgentEventsWaitIsReleasedByNewSMS(t *testing.T) {
	a := newAgent("unused")
	request := httptest.NewRequest(http.MethodGet, "/api/events?after=0&timeout_ms=500", nil)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		a.agentEvents(response, request)
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("unified event wait returned before the new SMS arrived")
	case <-time.After(20 * time.Millisecond):
	}

	message := storedSMS{
		Index:  7,
		Memory: "SM",
		Message: smsMessage{
			Sender: "+8610010", Content: "Test SMS", Timestamp: time.Now(), DeliveryID: "SM-7-test",
		},
	}
	a.mergeSMS([]storedSMS{message})

	select {
	case <-done:
	case <-time.After(300 * time.Millisecond):
		t.Fatal("new SMS did not wake the unified event wait")
	}

	if response.Code != http.StatusOK {
		t.Fatalf("unified event status=%d, body=%s", response.Code, response.Body.String())
	}
	var payload struct {
		Revision    uint64 `json:"revision"`
		SMSRevision uint64 `json:"sms_revision"`
		SMSPending  int    `json:"sms_pending"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload.Revision == 0 || payload.SMSRevision == 0 || payload.SMSPending != 1 {
		t.Fatalf("unified SMS event payload mismatch: %+v", payload)
	}
}

func TestDuplicateSMSDoesNotProduceAnotherEvent(t *testing.T) {
	a := newAgent("unused")
	message := storedSMS{
		Index:  7,
		Memory: "SM",
		Message: smsMessage{
			Sender: "+8610010", Content: "Test SMS", Timestamp: time.Now(), DeliveryID: "SM-7-test",
		},
	}
	a.mergeSMS([]storedSMS{message})
	firstEventRevision := a.eventRevision
	firstSMSRevision := a.smsRevision

	a.mergeSMS([]storedSMS{message})

	if a.eventRevision != firstEventRevision || a.smsRevision != firstSMSRevision {
		t.Fatalf(
			"duplicate SMS incorrectly produced an event: event=%d->%d sms=%d->%d",
			firstEventRevision, a.eventRevision, firstSMSRevision, a.smsRevision,
		)
	}
}

func TestCallPollIntervalUsesURCAndActiveState(t *testing.T) {
	if got := callPollInterval(true, false); got != 30*time.Second {
		t.Fatalf("idle calibration interval with URC=%s, want 30s", got)
	}
	if got := callPollInterval(false, false); got != 5*time.Second {
		t.Fatalf("idle fallback interval without URC=%s, want 5s", got)
	}
	if got := callPollInterval(true, true); got != 2*time.Second {
		t.Fatalf("calibration interval during a call=%s, want 2s", got)
	}
}

func TestATKeepaliveRetriesOnceAfterIdlePortTimeout(t *testing.T) {
	attempts := 0
	err := probeATWithRecovery(func(command string, timeout time.Duration) (string, error) {
		attempts++
		if command != "AT" {
			t.Fatalf("keepalive command=%q, want AT", command)
		}
		if attempts == 1 {
			return "", errors.New("Timed out waiting for AT response")
		}
		return "OK", nil
	})

	if err != nil {
		t.Fatalf("the second probe should recover after the port is reopened: %v", err)
	}
	if attempts != 2 {
		t.Fatalf("AT recovery attempts=%d, want 2", attempts)
	}
}

func TestATKeepaliveDoesNotRepeatHealthyProbe(t *testing.T) {
	attempts := 0
	err := probeATWithRecovery(func(command string, timeout time.Duration) (string, error) {
		attempts++
		return "OK", nil
	})

	if err != nil || attempts != 1 {
		t.Fatalf("a healthy AT probe must not be repeated: attempts=%d err=%v", attempts, err)
	}
}

func TestSMSNoticeOverflowRequestsFullRescan(t *testing.T) {
	a := newAgent("unused")
	for index := 0; index < cap(a.smsNotices); index++ {
		a.enqueueSMSNotice(smsStorageRef{Memory: "SM", Index: index})
	}
	a.enqueueSMSNotice(smsStorageRef{Memory: "SM", Index: 99})

	if !a.smsRescanRequested {
		t.Fatal("SMS URC queue overflow did not request a full rescan")
	}
}

func TestDebugLogBoundsPayloadAndEventCount(t *testing.T) {
	var log debugLog
	large := strings.Repeat("x", debugMaxPayload+100)
	for index := 0; index < debugMaxEvents+20; index++ {
		log.add("test", "rx", "event", large, nil)
	}
	events, latest, storedBytes := log.snapshot(0, debugMaxEvents)
	if len(events) == 0 || len(events) > debugMaxEvents {
		t.Fatalf("ring log event count=%d", len(events))
	}
	if latest != debugMaxEvents+20 || storedBytes > debugMaxStoredBytes {
		t.Fatalf("ring log boundary mismatch: latest=%d bytes=%d", latest, storedBytes)
	}
	if !strings.Contains(events[len(events)-1].Payload, "[truncated]") {
		t.Fatal("oversized debug payload was not marked truncated")
	}
}

func testLogger() *log.Logger {
	return log.New(io.Discard, "", 0)
}

func TestNormalizeKnownEUICCAID(t *testing.T) {
	got, err := normalizeKnownEUICCAID("a06573746b6d65ffff4953442d522031")
	if err != nil || got != "A06573746B6D65FFFF4953442D522031" {
		t.Fatalf("eUICC 2 AID normalization failed: got=%q err=%v", got, err)
	}
	if _, err := normalizeKnownEUICCAID("A000000001"); err == nil {
		t.Fatal("unverified AID was not rejected")
	}
}

func TestCGLAResponsePattern(t *testing.T) {
	response := `AT+CGLA=1,10,"80E2910000"` + "\r\n+CGLA: 4,\"9000\"\r\nOK"
	match := cglaResponsePattern.FindStringSubmatch(response)
	if len(match) != 2 || match[1] != "9000" {
		t.Fatalf("CGLA response parse mismatch: %#v", match)
	}
}

func TestPhysicalSIMESIMProbeError(t *testing.T) {
	if !isPhysicalSIMESIMProbeError(errors.New("No eUICC found: Failed to open eUICC logical channel: AT command failed: ERROR")) {
		t.Fatal("English physical SIM probe error must be recognized")
	}
	err := errors.New("未发现任何 eUICC: 打开 eUICC logical channel 失败: AT 指令失败: ERROR")
	if !isPhysicalSIMESIMProbeError(err) {
		t.Fatal("a physical SIM CCHO ERROR must be recognized as a card-type result")
	}
	if isPhysicalSIMESIMProbeError(errors.New("eUICC read timed out")) {
		t.Fatal("an ordinary communication error must not be mistaken for a physical SIM")
	}
}

func TestProfilePayloadKeepsEUICCState(t *testing.T) {
	iccid, err := sgp22.NewICCID("8944305293607172968")
	if err != nil {
		t.Fatal(err)
	}
	payload := profilePayload(&sgp22.ProfileInfo{
		ICCID:               iccid,
		ProfileState:        sgp22.ProfileEnabled,
		ProfileNickname:     "CTExcel eSIM",
		ServiceProviderName: "CTExcel",
		ProfileClass:        sgp22.ProfileClassOperational,
	})
	if payload.ICCID != "8944305293607172968" || payload.State != 1 || payload.StateText != "Enabled" {
		t.Fatalf("profile mapping mismatch: %#v", payload)
	}
}

func TestModuleUpdateModeAllowsSignedRepairAndDowngrade(t *testing.T) {
	if shouldInstallModuleVersion("0.3.38", "0.3.38", "normal") {
		t.Fatal("normal mode must not reinstall the same version")
	}
	if !shouldInstallModuleVersion("0.3.38", "0.3.38", "repair") {
		t.Fatal("repair mode must reinstall the same version")
	}
	if !shouldInstallModuleVersion("0.3.38", "0.3.37", "repair") {
		t.Fatal("explicit repair mode must allow a signed downgrade")
	}
	if shouldInstallModuleVersion("0.3.38", "0.3.37", "normal") {
		t.Fatal("automatic normal mode must not downgrade")
	}
}

func TestModuleUpdateDeltaStagesOnlyChangedPayloads(t *testing.T) {
	root := t.TempDir()
	matching := []byte("already-installed")
	changed := []byte("old-runtime")
	matchingDigest := sha256.Sum256(matching)
	newDigest := sha256.Sum256([]byte("new-runtime"))
	manifest := moduleUpdateManifest{Files: []moduleUpdateFile{
		{Name: "matching", Target: "bin/matching", SHA256: hex.EncodeToString(matchingDigest[:]), Size: int64(len(matching))},
		{Name: "changed", Target: "bin/changed", SHA256: hex.EncodeToString(newDigest[:]), Size: 11},
		{Name: "missing", Target: "bin/missing", SHA256: strings.Repeat("a", 64), Size: 7},
	}}
	if err := os.MkdirAll(filepath.Join(root, "bin"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bin/matching"), matching, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "bin/changed"), changed, 0o600); err != nil {
		t.Fatal(err)
	}

	files, err := moduleUpdateFilesRequiringReplacement(manifest, root)
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 || files[0].Name != "changed" || files[1].Name != "missing" {
		t.Fatalf("delta files=%+v, want changed and missing only", files)
	}
}

func TestModuleUpdateStateUsesStableWireFields(t *testing.T) {
	encoded, err := json.Marshal(moduleUpdateState{
		OperationID: "update-1", Mode: "repair", Phase: "installing",
		InstalledVersion: "0.3.38", TargetVersion: "0.3.39",
		Progress: 55, Message: "Installing", UpdatedAt: time.Unix(1, 0).UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{
		`"operation_id":"update-1"`, `"mode":"repair"`,
		`"phase":"installing"`, `"installed_version":"0.3.38"`,
		`"target_version":"0.3.39"`, `"progress":55`,
	} {
		if !strings.Contains(string(encoded), field) {
			t.Fatalf("missing %s in %s", field, encoded)
		}
	}
}

func TestModuleUpdateLogOmitsEmptyErrorField(t *testing.T) {
	success := formatModuleUpdateLogLine("completed", 100, "New Agent passed health check", "")
	if strings.Contains(success, "error=") {
		t.Fatalf("success log must not contain an empty error field: %q", success)
	}
	failure := formatModuleUpdateLogLine("failed", 100, "Installation failed", "no space left on device")
	if !strings.Contains(failure, "error=no space left on device") {
		t.Fatalf("failure log must keep the real error: %q", failure)
	}
}

func TestModuleUpdateCompletionRecoversAfterStartupRemovedPendingMarker(t *testing.T) {
	state := moduleUpdateState{
		OperationID:      "update-restart-race",
		Mode:             "repair",
		Phase:            "restarting",
		InstalledVersion: "0.3.41",
		TargetVersion:    "0.3.42",
		Progress:         80,
		Message:          "Agent installed; restarting safely",
	}

	completed, ok := completedModuleUpdateState(state, "0.3.42", false)
	if !ok {
		t.Fatal("install state should complete when the new Agent is healthy and the version matches, even if the startup script already cleared the pending marker")
	}
	if completed.Phase != "completed" || completed.Progress != 100 {
		t.Fatalf("completion state=%+v, want completed/100", completed)
	}
}

func TestModuleUpdateCompletionWaitsForStartupToRemovePendingMarker(t *testing.T) {
	state := moduleUpdateState{
		OperationID:      "update-still-starting",
		Mode:             "repair",
		Phase:            "restarting",
		InstalledVersion: "0.3.39",
		TargetVersion:    "0.3.43",
		Progress:         80,
		Message:          "Agent installed; restarting safely",
	}

	if _, ok := completedModuleUpdateState(state, "0.3.43", true); ok {
		t.Fatal("install must not be reported complete from the version alone while the startup script still holds the pending rollback marker")
	}
}

func TestModuleUpdateCompletionDoesNotConfirmDifferentRunningVersion(t *testing.T) {
	state := moduleUpdateState{
		OperationID:   "update-rollback",
		Phase:         "restarting",
		TargetVersion: "0.3.42",
		Progress:      80,
	}

	if _, ok := completedModuleUpdateState(state, "0.3.41", false); ok {
		t.Fatal("install must not be reported complete when the running Agent version differs from the target version")
	}
}

func TestCleanupStaleModuleUpdateArtifactsPreservesPendingRollback(t *testing.T) {
	root := t.TempDir()
	temporaryRoot := filepath.Join(root, "tmp")
	dataRoot := filepath.Join(root, "airsim")
	backupRoot := filepath.Join(dataRoot, "backup")
	for _, path := range []string{
		temporaryRoot,
		backupRoot,
		filepath.Join(dataRoot, ".update-stage-stale"),
		filepath.Join(backupRoot, "app-update-stale"),
		filepath.Join(backupRoot, "app-update-pending"),
	} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	staleUpload := filepath.Join(temporaryRoot, "airsim-update-stale.tar.gz")
	if err := os.WriteFile(staleUpload, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(dataRoot, "update-pending")
	pending := filepath.Join(backupRoot, "app-update-pending")
	if err := os.WriteFile(marker, []byte(pending+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := cleanupStaleModuleUpdateArtifacts(dataRoot, temporaryRoot, marker); err != nil {
		t.Fatal(err)
	}

	for _, removed := range []string{
		staleUpload,
		filepath.Join(dataRoot, ".update-stage-stale"),
		filepath.Join(backupRoot, "app-update-stale"),
	} {
		if _, err := os.Stat(removed); !os.IsNotExist(err) {
			t.Fatalf("expected stale artifact to be removed: %s", removed)
		}
	}
	if _, err := os.Stat(pending); err != nil {
		t.Fatalf("pending rollback must be preserved: %v", err)
	}
}

func TestLifecyclePhaseForModemState(t *testing.T) {
	tests := map[string]string{
		"incoming": "ringing",
		"waiting":  "ringing",
		"dialing":  "connecting",
		"alerting": "connecting",
		"active":   "active",
		"held":     "active",
		"idle":     "",
	}
	for state, want := range tests {
		if got := lifecyclePhaseForModemState(state); got != want {
			t.Errorf("state=%s phase=%s, want %s", state, got, want)
		}
	}
}
