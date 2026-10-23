package main

import (
	"os"
	"strings"
	"testing"
	"time"
)

func TestUSBRecoveryRetriesWhenRebindCooldownHasNotExpired(t *testing.T) {
	outcome := usbCooldownOutcome(1_000, 900, 5*time.Minute)
	if !outcome.Retry {
		t.Fatal("a later recovery task must be kept when the rebind cooldown is active")
	}
	if outcome.RetryAfter != 200*time.Second {
		t.Fatalf("cooldown remaining=%s, want 200s", outcome.RetryAfter)
	}
}

func TestUSBRecoveryRetriesTemporarySafetyBlocks(t *testing.T) {
	for _, reason := range []string{"Call in progress", "Media route running", "USB composition cannot be rebound yet"} {
		outcome := usbBlockedOutcome(reason)
		if !outcome.Retry || outcome.RetryAfter <= 0 {
			t.Fatalf("temporary block %q must not permanently give up recovery: %#v", reason, outcome)
		}
	}
}

func TestUSBFaultStorePersistsBoundedHistoryAcrossRestart(t *testing.T) {
	path := t.TempDir() + "/usb-faults.json"
	store := newUSBFaultStore(path, 2)
	for _, phase := range []string{"carrier-down", "rebind-start", "rebind-complete"} {
		if err := store.append(usbFaultSnapshot{Timestamp: time.Now().UTC(), Phase: phase}); err != nil {
			t.Fatal(err)
		}
	}

	reloaded := newUSBFaultStore(path, 2)
	records := reloaded.records()
	if len(records) != 2 {
		t.Fatalf("persisted snapshot count=%d, want 2", len(records))
	}
	if records[0].Phase != "rebind-start" || records[1].Phase != "rebind-complete" {
		t.Fatalf("persisted snapshot order or trim mismatch: %#v", records)
	}
}

func TestUSBFaultStoreCoalescesRepeatedIdenticalFaults(t *testing.T) {
	path := t.TempDir() + "/usb-faults.json"
	store := newUSBFaultStore(path, 8)
	first := usbFaultSnapshot{
		Timestamp:       time.Date(2026, 8, 21, 1, 0, 0, 0, time.UTC),
		Phase:           "rebind-deferred",
		Trigger:         "netlink-carrier-down",
		Reason:          "Call in progress",
		Carrier:         "0",
		FactoryPID:      "12",
		AgentListening:  true,
		GadgetFunctions: "diag,ecm,ffs",
	}
	if err := store.append(first); err != nil {
		t.Fatal(err)
	}
	second := first
	second.Timestamp = first.Timestamp.Add(10 * time.Second)
	if err := store.append(second); err != nil {
		t.Fatal(err)
	}
	if got := len(store.records()); got != 1 {
		t.Fatalf("identical faults within one minute should be coalesced, records=%d", got)
	}

	changed := second
	changed.Timestamp = first.Timestamp.Add(20 * time.Second)
	changed.Reason = "Media route running"
	if err := store.append(changed); err != nil {
		t.Fatal(err)
	}
	if got := len(store.records()); got != 2 {
		t.Fatalf("a changed fault reason must be recorded immediately, records=%d", got)
	}
}

func TestUSBFaultStoreRollsBackMemoryWhenPersistenceFails(t *testing.T) {
	directory := t.TempDir()
	blocker := directory + "/not-a-directory"
	if err := os.WriteFile(blocker, []byte("block"), 0o600); err != nil {
		t.Fatal(err)
	}
	store := newUSBFaultStore(blocker+"/usb-faults.json", 8)
	err := store.append(usbFaultSnapshot{
		Timestamp:  time.Now().UTC(),
		Phase:      "carrier-down",
		Carrier:    "0",
		FactoryPID: "12",
	})
	if err == nil {
		t.Fatal("an unwritable path must return a persistence error")
	}
	if got := len(store.records()); got != 0 {
		t.Fatalf("in-memory state must roll back after persistence failure, records=%d", got)
	}
	if got := store.previousFactoryPID(); got != "" {
		t.Fatalf("factory PID baseline must roll back after persistence failure, got=%q", got)
	}
}

func TestClassifyUSBFaultMatchesFieldDiagnosticTree(t *testing.T) {
	tests := []struct {
		name string
		in   usbFaultSnapshot
		want string
	}{
		{"interface missing", usbFaultSnapshot{Carrier: "unavailable: no such file", GadgetFunctions: "diag,ecm,ffs", GadgetEnabled: "1", AgentListening: true, FactoryPID: "12"}, "ecm-interface-missing"},
		{"carrier down", usbFaultSnapshot{Carrier: "0", AgentListening: true, FactoryPID: "12"}, "usb-link-down"},
		{"host missing", usbFaultSnapshot{Carrier: "1", HasECMPeer: false, AgentListening: true, FactoryPID: "12"}, "ios-address-or-route-missing"},
		{"agent listener", usbFaultSnapshot{Carrier: "1", HasECMPeer: true, AgentListening: false, FactoryPID: "12"}, "agent-listener-down"},
		{"factory missing", usbFaultSnapshot{Carrier: "1", HasECMPeer: true, AgentListening: true}, "factory-service-missing"},
		{"factory changed", usbFaultSnapshot{Carrier: "1", HasECMPeer: true, AgentListening: true, FactoryPID: "13", FactoryPIDChanged: true}, "factory-service-changed"},
		{"healthy", usbFaultSnapshot{Carrier: "1", HasECMPeer: true, AgentListening: true, FactoryPID: "12"}, "ready"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := classifyUSBFault(test.in); got != test.want {
				t.Fatalf("classification=%q, want %q", got, test.want)
			}
		})
	}
}

func TestSelectPushWANInterfaceAvoidsECMDefaultRoute(t *testing.T) {
	routes := "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n" +
		"ecm0\t00000000\t0168A8C0\t0003\t0\t0\t0\t00000000\n" +
		"rmnet_data0\t00000000\t00000000\t0003\t0\t0\t100\t00000000\n"
	if got := selectPushWANInterface(strings.NewReader(routes)); got != "rmnet_data0" {
		t.Fatalf("public push interface=%q, want rmnet_data0", got)
	}
	if got := selectPushWANInterface(strings.NewReader(strings.Split(routes, "rmnet_data0")[0])); got != "" {
		t.Fatalf("public push interface must not be forced when only ECM is present: %q", got)
	}
}
