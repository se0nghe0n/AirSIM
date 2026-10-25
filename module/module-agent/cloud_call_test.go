package main

import (
	"context"
	"encoding/json"
	"net"
	"testing"
	"time"
)

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
