package main

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
	"time"
)

func TestCloudPCMMilestonesAreMonotonic(t *testing.T) {
	sequence := []string{"answer_ok", "pcm_listening", "active", "pcm_ready", "pcm_first_frame"}
	if err := validateCloudPCMMilestoneOrder(sequence); err != nil {
		t.Fatal(err)
	}
	if validateCloudPCMMilestoneOrder([]string{"answer_ok", "active", "pcm_listening"}) == nil {
		t.Fatal("active before listener must be rejected")
	}
}

func TestCloudPCMMilestoneDurationsDescribeStartupBoundaries(t *testing.T) {
	started := time.Unix(1_800_000_000, 0)
	health := newCloudMediaHealthTracker(started, cloudCallDescriptor{})
	health.markAnswerAcknowledged(started)
	health.markListening(started.Add(1200 * time.Millisecond))
	health.beginMedia(started.Add(1500 * time.Millisecond))
	health.observeDownlink(make([]byte, cloudPCMFrameBytes), started.Add(1900*time.Millisecond), 0)
	fields := cloudPCMMilestoneFields(health.snapshot())
	for key, want := range map[string]string{
		"answer_to_listen_ms":            "1200",
		"listen_to_handshake_ms":         "300",
		"handshake_to_first_downlink_ms": "400",
	} {
		if got := fields[key]; got != want {
			t.Fatalf("%s=%q, want %q", key, got, want)
		}
	}
}

func TestCloudPCMTimeoutPolicyGivesWarmRouteOneSoftRetryBeforeRebuild(t *testing.T) {
	if got := cloudPCMRecoveryForTimeout(1); got != cloudPCMReconnectOnly {
		t.Fatalf("first PCM timeout recovery=%q, want local PCM reconnect only", got)
	}
	if got := cloudPCMRecoveryForTimeout(2); got != cloudPCMRebuildVoiceRoute {
		t.Fatalf("second consecutive PCM timeout recovery=%q, want voice route rebuild", got)
	}
}

func TestCloudPCMHealthPolicyDoesNotRestartModuleRouteForMissingRemoteUplink(t *testing.T) {
	if got := cloudPCMRecoveryForHealth(cloudMediaRebuildUplinkStalled); got != cloudPCMKeepVoiceRoute {
		t.Fatalf("remote uplink stall recovery=%q, want module voice route kept", got)
	}
}

func TestFirstDownlinkTimeoutRebuildsVoiceRouteWithoutUSBReset(t *testing.T) {
	action := cloudPCMRecoveryForHealth(cloudMediaRebuildDownlinkStalled)
	if action != cloudPCMRebuildVoiceRoute {
		t.Fatalf("action=%s, want %s", action, cloudPCMRebuildVoiceRoute)
	}
	if cloudPCMRecoveryTouchesUSB(action) {
		t.Fatal("PCM recovery must not reset ECM")
	}
}

func TestCloudMediaFirstDownlinkDeadlineIsEightSeconds(t *testing.T) {
	startedAt := time.Unix(1_800_000_000, 0)
	health := newCloudMediaHealthTracker(startedAt, cloudCallDescriptor{})
	health.beginMedia(startedAt)
	if got := health.evaluate(startedAt.Add(7990 * time.Millisecond)); got != cloudMediaHealthy {
		t.Fatalf("before deadline=%s, want healthy", got)
	}
	if got := health.evaluate(startedAt.Add(8 * time.Second)); got != cloudMediaRebuildDownlinkStalled {
		t.Fatalf("at deadline=%s, want %s", got, cloudMediaRebuildDownlinkStalled)
	}
}

func TestCloudPCMStatsCarryNegotiatedMediaProtocol(t *testing.T) {
	health := newCloudMediaHealthTracker(time.Unix(1_800_000_000, 0), cloudCallDescriptor{})
	health.setMediaProtocol(cloudPCMProtocolFramedV1)
	stats := cloudPCMTransmissionStatsFromHealth(health.snapshot())
	if stats.MediaProtocol != cloudPCMProtocolFramedV1 {
		t.Fatalf("media stats protocol=%q, want %q", stats.MediaProtocol, cloudPCMProtocolFramedV1)
	}
}

func TestCloudMediaHealthRebuildsAfterSixSecondsAndStopsAtThree(t *testing.T) {
	startedAt := time.Unix(1_800_000_000, 0)
	tracker := newCloudMediaHealthTracker(startedAt, cloudCallDescriptor{
		CallID: "call-health", CallUUID: "49f5fa4d-b8e4-4997-bb0b-dca076997344", Generation: 4,
	})
	tracker.beginMedia(startedAt)
	tracker.observeDownlink(make([]byte, 320), startedAt, 0)
	if got := tracker.evaluate(startedAt.Add(5990 * time.Millisecond)); got != cloudMediaHealthy {
		t.Fatalf("health decision before 6 seconds=%q, want %q", got, cloudMediaHealthy)
	}
	for attempt := 1; attempt <= 3; attempt++ {
		now := startedAt.Add(time.Duration(attempt) * 6100 * time.Millisecond)
		if got := tracker.evaluate(now); got != cloudMediaRebuildDownlinkStalled {
			t.Fatalf("rebuild decision %d=%q, want %q", attempt, got, cloudMediaRebuildDownlinkStalled)
		}
		if !tracker.beginRebuild(cloudMediaRebuildDownlinkStalled, now) {
			t.Fatalf("rebuild %d should be allowed", attempt)
		}
		tracker.observeDownlink(make([]byte, 320), now, 0)
	}
	if got := tracker.evaluate(startedAt.Add(24400 * time.Millisecond)); got != cloudMediaRebuildExhausted {
		t.Fatalf("budget exhausted decision=%q, want %q", got, cloudMediaRebuildExhausted)
	}
	if tracker.beginRebuild(cloudMediaRebuildDownlinkStalled, startedAt.Add(24400*time.Millisecond)) {
		t.Fatal("a call must not perform a 4th media rebuild")
	}
	if snapshot := tracker.snapshot(); snapshot.RebuildCount != 3 {
		t.Fatalf("rebuild count=%d, want 3", snapshot.RebuildCount)
	}
}

func TestCloudMediaHealthDoesNotCountRingingAsMissingAudio(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	health := newCloudMediaHealthTracker(start, cloudCallDescriptor{})
	if got := health.evaluate(start.Add(90 * time.Second)); got != cloudMediaHealthy {
		t.Fatalf("waiting for answer must not consume media rebuild budget: %s", got)
	}
}

func TestCloudMediaHealthStartsFreshWindowAfterPCMHandshake(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	health := newCloudMediaHealthTracker(start, cloudCallDescriptor{})
	connected := start.Add(90 * time.Second)
	health.beginMedia(connected)
	if got := health.evaluate(connected.Add(7900 * time.Millisecond)); got != cloudMediaHealthy {
		t.Fatalf("first PCM startup must have its own grace period: %s", got)
	}
	if got := health.evaluate(connected.Add(8100 * time.Millisecond)); got != cloudMediaRebuildDownlinkStalled {
		t.Fatalf("initial missing audio must eventually time out: %s", got)
	}
	health.observeDownlink(make([]byte, 320), connected.Add(22*time.Second), 0)
	health.observeUplink(make([]byte, 320), connected.Add(22*time.Second))
	if got := health.evaluate(connected.Add(27 * time.Second)); got != cloudMediaHealthy {
		t.Fatalf("short active-call gap must not rebuild: %s", got)
	}
	if got := health.evaluate(connected.Add(29 * time.Second)); got != cloudMediaRebuildDownlinkStalled {
		t.Fatalf("active call must detect real interruption: %s", got)
	}
	health.beginRebuild(cloudMediaRebuildDownlinkStalled, connected.Add(29*time.Second))
	health.beginMedia(connected.Add(30 * time.Second))
	if health.snapshot().RebuildCount != 1 {
		t.Fatal("reconnect erased the per-call budget")
	}
}

func TestCloudMediaHealthTreatsValidSilenceAsHealthyAndDetectsStalledUplink(t *testing.T) {
	startedAt := time.Unix(1_800_000_100, 0)
	silent := newCloudMediaHealthTracker(startedAt, cloudCallDescriptor{})
	silent.beginMedia(startedAt)
	frame := make([]byte, cloudPCMFrameBytes)
	for index := 0; index < 50; index++ {
		silent.observeDownlink(frame, startedAt.Add(time.Duration(index)*20*time.Millisecond), 2)
	}
	if got := silent.evaluate(startedAt.Add(time.Second)); got != cloudMediaHealthy {
		t.Fatalf("valid silence decision=%q, want %q", got, cloudMediaHealthy)
	}

	uplink := newCloudMediaHealthTracker(startedAt, cloudCallDescriptor{})
	uplink.beginMedia(startedAt)
	nonSilent := make([]byte, cloudPCMFrameBytes)
	nonSilent[0], nonSilent[1] = 0x60, 0x09
	uplink.observeDownlink(nonSilent, startedAt.Add(6*time.Second), 1)
	if got := uplink.evaluate(startedAt.Add(6100 * time.Millisecond)); got != cloudMediaRebuildUplinkStalled {
		t.Fatalf("uplink stall decision=%q, want %q", got, cloudMediaRebuildUplinkStalled)
	}
}

func TestECMWatchdogFieldsCarryCurrentCallIdentity(t *testing.T) {
	descriptor := cloudCallDescriptor{
		CallID: "call-ecm", CallUUID: "49f5fa4d-b8e4-4997-bb0b-dca076997344", Generation: 7,
	}
	fields := ecmWatchdogFields(
		ecmLinkMissing, "ecm-missing", "netdev removed",
		"qcom_ecm", "ecm0", "diag,ecm,ffs", &descriptor,
	)
	for key, want := range map[string]string{
		"driver": "qcom_ecm", "interface": "ecm0", "usb_functions": "diag,ecm,ffs",
		"call_id": "call-ecm", "call_uuid": "49f5fa4d-b8e4-4997-bb0b-dca076997344",
		"generation": "7", "state": "missing",
	} {
		if got := fields[key]; got != want {
			t.Fatalf("field %s=%q, want %q", key, got, want)
		}
	}
}

func TestCloudMediaTransportRejectsAnythingExceptWebRTC(t *testing.T) {
	if got := resolveCloudMediaTransport("webrtc", []string{"webrtc"}, false); got != "webrtc" {
		t.Fatalf("transport=%q when both sides support WebRTC, want webrtc", got)
	}
	if got := resolveCloudMediaTransport("", []string{"webrtc"}, false); got != "" {
		t.Fatalf("transport=%q when the request is missing, want rejection", got)
	}
	if got := resolveCloudMediaTransport("webrtc", []string{"webrtc"}, true); got != "" {
		t.Fatalf("transport=%q when fallback is forced, want rejection", got)
	}
}

func TestCloudCallTextControlAnswersAndEndsWithoutPCMCopy(t *testing.T) {
	a := testAndroidAgent("secret-value")
	a.push = newPushManager(filepath.Join(t.TempDir(), "push.json"))
	descriptor := cloudCallDescriptor{
		CallID: "agent-call-text", CallUUID: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
		Generation: 1, Direction: "incoming", MediaTransport: "webrtc",
	}
	a.calls.Active = &callRecord{
		ID: descriptor.CallID, AndroidID: "telecom-text", Direction: "incoming", State: "incoming",
	}
	client, server := net.Pipe()
	defer server.Close()
	socket := &cloudWebSocket{conn: client, reader: bufio.NewReader(client)}
	serverSocket := &cloudWebSocket{conn: server, reader: bufio.NewReader(server)}
	done := make(chan bool, 1)
	go func() {
		done <- a.serveCloudCall(context.Background(), socket, descriptor, newCloudMediaHealthTracker(time.Now(), descriptor))
	}()

	assertCloudTextStatus(t, serverSocket, "agent_ready")
	writeCloudServerText(t, server, cloudCallAction{
		Action: "answer", CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
		Generation: descriptor.Generation, Owner: "iphone",
		CommandID: "dc7c37df-ae31-4d4b-aef4-893a92c58c86",
	})
	go completeAndroidCall(t, a, "answer", "telecom-text")
	assertCloudTextStatus(t, serverSocket, "answer_ok")
	if a.voice.hostEnabled {
		t.Fatal("text answer started a PCM voice route")
	}
	writeCloudServerBinary(t, server, []byte{1, 2, 3, 4})
	writeCloudServerText(t, server, cloudCallAction{
		Action: "end", CallID: descriptor.CallID, CallUUID: descriptor.CallUUID,
		Generation: descriptor.Generation, Owner: "iphone",
		CommandID: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145",
	})
	go completeAndroidCall(t, a, "end", "telecom-text")
	assertCloudTextStatus(t, serverSocket, "ended")
	select {
	case terminal := <-done:
		if !terminal {
			t.Fatal("end did not finish the cloud call")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cloud call did not finish after end")
	}
}

func completeAndroidCall(t *testing.T, a *agent, action, callID string) {
	t.Helper()
	command, ok := a.android.next(context.Background(), time.Second)
	if !ok || command.Action != action || command.CallID != callID {
		t.Errorf("Telecom command=%#v ok=%v, want %s %s", command, ok, action, callID)
		return
	}
	if err := a.android.complete(androidCommandResult{ID: command.ID, Success: true}); err != nil {
		t.Error(err)
		return
	}
	if action == "answer" {
		a.applyAndroidCallEvent(androidCallEvent{
			EventID: "event-text-active", CallID: callID, Direction: "incoming", State: "active",
		}, time.Now())
	}
}

func assertCloudTextStatus(t *testing.T, socket *cloudWebSocket, status string) {
	t.Helper()
	opcode, payload, err := socket.ReadMessage()
	if err != nil {
		t.Fatalf("read %s: %v", status, err)
	}
	if opcode != cloudOpcodeText {
		t.Fatalf("opcode=%d, want text for %s", opcode, status)
	}
	var value map[string]any
	if err := json.Unmarshal(payload, &value); err != nil {
		t.Fatal(err)
	}
	if value["status"] != status {
		t.Fatalf("status=%v message=%v, want %s", value["status"], value["message"], status)
	}
}

func writeCloudServerText(t *testing.T, conn net.Conn, action cloudCallAction) {
	t.Helper()
	payload, err := json.Marshal(action)
	if err != nil {
		t.Fatal(err)
	}
	writeCloudServerFrame(t, conn, cloudOpcodeText, payload)
}

func writeCloudServerBinary(t *testing.T, conn net.Conn, payload []byte) {
	t.Helper()
	writeCloudServerFrame(t, conn, cloudOpcodeBinary, payload)
}

func writeCloudServerFrame(t *testing.T, conn net.Conn, opcode byte, payload []byte) {
	t.Helper()
	header := []byte{0x80 | opcode}
	switch {
	case len(payload) < 126:
		header = append(header, byte(len(payload)))
	default:
		header = append(header, 126, byte(len(payload)>>8), byte(len(payload)))
	}
	frame := append(header, payload...)
	if _, err := conn.Write(frame); err != nil {
		t.Fatal(err)
	}
}
