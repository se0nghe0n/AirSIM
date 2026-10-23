package main

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestECMLinkPowerCycleDoesNotDisconnectUSBDevice(t *testing.T) {
	var commands []string
	run := func(name string, arguments ...string) error {
		commands = append(commands, name+" "+strings.Join(arguments, " "))
		return nil
	}
	if err := powerCycleECMLink(run, func(time.Duration) {}); err != nil {
		t.Fatalf("Failed to power-cycle ECM interface: %v", err)
	}
	want := []string{"ifconfig ecm0 down", "ifconfig ecm0 up"}
	if !reflect.DeepEqual(commands, want) {
		t.Fatalf("system commands=%#v, want %#v; must not switch the whole USB gadget", commands, want)
	}
}

func TestMissingECMRecoveryRebindsOnlyExistingGadgetFunctions(t *testing.T) {
	type write struct {
		path  string
		value string
	}
	var writes []write
	err := rebindMissingECMGadget("1", "diag,ecm,ffs", func(path, value string) error {
		writes = append(writes, write{path: path, value: value})
		return nil
	}, func(time.Duration) {})
	if err != nil {
		t.Fatalf("ECM gadget rebind failed: %v", err)
	}
	want := []write{
		{path: usbGadgetPath + "/enable", value: "0\n"},
		{path: usbGadgetPath + "/functions", value: "diag,ecm,ffs\n"},
		{path: usbGadgetPath + "/enable", value: "1\n"},
	}
	if !reflect.DeepEqual(writes, want) {
		t.Fatalf("gadget writes=%#v, want %#v", writes, want)
	}
}

func TestMissingECMRecoveryRefusesFunctionSetWithoutECM(t *testing.T) {
	writes := 0
	err := rebindMissingECMGadget("1", "diag,ffs", func(string, string) error {
		writes++
		return nil
	}, func(time.Duration) {})
	if err == nil {
		t.Fatal("automatic rebind must be rejected when functions do not include ECM")
	}
	if writes != 0 {
		t.Fatalf("gadget must not be modified before recovery is rejected, write count=%d", writes)
	}
}

func TestMissingECMGadgetRecoveryAllowsExistingCompositeAfterCallIsIdle(t *testing.T) {
	if err := validateMissingECMGadgetRecovery(
		false,
		false,
		"diag,serial,ecm,ffs,audio",
	); err != nil {
		t.Fatalf("original composition reload should be allowed after ECM is gone and the call has ended: %v", err)
	}

	if err := validateMissingECMGadgetRecovery(
		true,
		false,
		"diag,serial,ecm,ffs,audio",
	); err == nil {
		t.Fatal("the whole USB composition must not be reloaded while a call is still active")
	}

	if err := validateMissingECMGadgetRecovery(false, false, "diag,serial,ffs,audio"); err == nil {
		t.Fatal("ECM recovery must not run when the original composition has no ECM")
	}
}

func TestUSBReconnectRequiresContinuousCarrierOutage(t *testing.T) {
	recovered := make(chan struct{}, 1)
	debouncer := &usbReconnectDebouncer{
		agent:    &agent{},
		logger:   log.New(io.Discard, "", 0),
		debounce: 80 * time.Millisecond,
		reconnect: func() usbRebindOutcome {
			recovered <- struct{}{}
			return usbRebindOutcome{}
		},
	}

	debouncer.carrierChanged(true)
	time.Sleep(30 * time.Millisecond)
	debouncer.carrierChanged(false)
	select {
	case <-recovered:
		t.Fatal("an ECM outage shorter than the threshold that already recovered must not power-cycle USB")
	case <-time.After(90 * time.Millisecond):
	}

	debouncer.carrierChanged(true)
	select {
	case <-recovered:
	case <-time.After(200 * time.Millisecond):
		t.Fatal("an ECM outage past the threshold did not power-cycle USB")
	}
}

func TestUSBReconnectUsesMissingInterfaceRecovery(t *testing.T) {
	recovered := make(chan ecmLinkState, 1)
	debouncer := &usbReconnectDebouncer{
		agent:    &agent{},
		logger:   log.New(io.Discard, "", 0),
		debounce: 20 * time.Millisecond,
		recover: func(state ecmLinkState) usbRebindOutcome {
			recovered <- state
			return usbRebindOutcome{}
		},
	}

	debouncer.linkStateChanged(ecmLinkMissing)
	select {
	case state := <-recovered:
		if state != ecmLinkMissing {
			t.Fatalf("recovery state=%v, want missing", state)
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("recovery was not triggered when ecm0 disappeared entirely")
	}
}

func TestPollECMCarrierReportsChangesWithoutNetlink(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var mu sync.Mutex
	reads := 0
	readCarrier := func() (bool, error) {
		mu.Lock()
		defer mu.Unlock()
		reads++
		return reads < 3, nil
	}
	states := make(chan bool, 4)
	go pollECMCarrier(ctx, 10*time.Millisecond, readCarrier, func(down bool) {
		states <- down
	})

	var got []bool
	deadline := time.After(200 * time.Millisecond)
	for len(got) < 2 {
		select {
		case state := <-states:
			got = append(got, state)
		case <-deadline:
			t.Fatalf("poll did not report an ECM state change, received %#v", got)
		}
	}
	if !got[0] || got[1] {
		t.Fatalf("ECM state change=%#v, want [down, recovered]", got)
	}
}

func TestPollECMLinkStateReportsMissingInterface(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var mu sync.Mutex
	reads := 0
	probe := func() ecmLinkState {
		mu.Lock()
		defer mu.Unlock()
		reads++
		if reads < 3 {
			return detectECMLinkState([]byte("1\n"), nil)
		}
		return detectECMLinkState(nil, os.ErrNotExist)
	}
	states := make(chan ecmLinkState, 4)
	go pollECMLinkState(ctx, 10*time.Millisecond, probe, func(state ecmLinkState) {
		states <- state
	})

	want := []ecmLinkState{ecmLinkUp, ecmLinkMissing}
	got := make([]ecmLinkState, 0, len(want))
	deadline := time.After(200 * time.Millisecond)
	for len(got) < len(want) {
		select {
		case state := <-states:
			got = append(got, state)
		case <-deadline:
			t.Fatalf("ECM interface disappearance was not reported, received %#v", got)
		}
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ECM state change=%#v, want %#v", got, want)
	}
}

func TestDetectECMLinkStateKeepsTransientReadErrorsUnknown(t *testing.T) {
	if got := detectECMLinkState(nil, errors.New("temporary I/O error")); got != ecmLinkUnknown {
		t.Fatalf("transient read error state=%v, want unknown", got)
	}
}
