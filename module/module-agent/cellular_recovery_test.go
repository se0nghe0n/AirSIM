package main

import (
	"testing"
	"time"
)

func TestCellularRecoveryPolicyDoesNotResetUSBOrRadioForShortOutage(t *testing.T) {
	if action := chooseCellularRecoveryAction(2, 20*time.Second, cellularRecoveryIdle, time.Hour, false); action != cellularRecoveryNone {
		t.Fatalf("a short network search must not trigger recovery: %v", action)
	}
	if action := chooseCellularRecoveryAction(1, time.Hour, cellularRecoveryIdle, time.Hour, false); action != cellularRecoveryNone {
		t.Fatalf("a registered network must not trigger recovery: %v", action)
	}
}

func TestCellularRecoveryPolicyUsesAutomaticSelectionBeforeRadioRestart(t *testing.T) {
	if action := chooseCellularRecoveryAction(2, 45*time.Second, cellularRecoveryIdle, time.Hour, false); action != cellularRecoveryAutomaticSelection {
		t.Fatalf("a sustained search should select the network automatically first: %v", action)
	}
	if action := chooseCellularRecoveryAction(0, 3*time.Minute, cellularRecoverySelectedNetwork, 2*time.Minute, false); action != cellularRecoveryRadioRestart {
		t.Fatalf("still unregistered after automatic selection should soft-restart the radio: %v", action)
	}
}

func TestCellularRecoveryPolicyNeverDisruptsAnActiveCallAndRespectsCooldown(t *testing.T) {
	if action := chooseCellularRecoveryAction(0, 10*time.Minute, cellularRecoveryIdle, time.Hour, true); action != cellularRecoveryNone {
		t.Fatalf("radio recovery must not run during a call: %v", action)
	}
	if action := chooseCellularRecoveryAction(0, 10*time.Minute, cellularRecoveryRestartedRadio, 5*time.Minute, false); action != cellularRecoveryNone {
		t.Fatalf("radio restart must not run again during cooldown: %v", action)
	}
}

func TestRegistrationParserAcceptsQueryAndURCFormats(t *testing.T) {
	if got := parseRegistration("+CEREG: 1,5\r\nOK"); got != 5 {
		t.Fatalf("query-format registration state=%d", got)
	}
	if got := parseRegistration("+CEREG: 2"); got != 2 {
		t.Fatalf("URC-format registration state=%d", got)
	}
}
