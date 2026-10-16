package main

import (
	"sync"
	"time"
)

type cellularRecoveryStage int

const (
	cellularRecoveryIdle cellularRecoveryStage = iota
	cellularRecoverySelectedNetwork
	cellularRecoveryRestartedRadio
)

type cellularRecoveryAction int

const (
	cellularRecoveryNone cellularRecoveryAction = iota
	cellularRecoveryAutomaticSelection
	cellularRecoveryRadioRestart
)

const (
	cellularAutomaticSelectionDelay = 45 * time.Second
	cellularRadioRestartDelay       = 3 * time.Minute
	cellularRadioRestartCooldown    = 10 * time.Minute
)

func chooseCellularRecoveryAction(
	registration int,
	outageDuration time.Duration,
	stage cellularRecoveryStage,
	sinceLastAction time.Duration,
	callActive bool,
) cellularRecoveryAction {
	if registration == 1 || registration == 5 || callActive {
		return cellularRecoveryNone
	}
	if stage == cellularRecoveryRestartedRadio && sinceLastAction < cellularRadioRestartCooldown {
		return cellularRecoveryNone
	}
	if stage == cellularRecoverySelectedNetwork &&
		outageDuration >= cellularRadioRestartDelay && sinceLastAction >= 90*time.Second {
		return cellularRecoveryRadioRestart
	}
	if stage == cellularRecoveryIdle && outageDuration >= cellularAutomaticSelectionDelay {
		return cellularRecoveryAutomaticSelection
	}
	if stage == cellularRecoveryRestartedRadio && sinceLastAction >= cellularRadioRestartCooldown {
		return cellularRecoveryAutomaticSelection
	}
	return cellularRecoveryNone
}

type cellularRecoveryTracker struct {
	mu               sync.Mutex
	outageSince      time.Time
	lastActionAt     time.Time
	lastRegisteredAt time.Time
	stage            cellularRecoveryStage
	inFlight         bool
	status           string
}

func newCellularRecoveryTracker(now time.Time) *cellularRecoveryTracker {
	return &cellularRecoveryTracker{lastRegisteredAt: now, status: "Monitoring"}
}

func (tracker *cellularRecoveryTracker) snapshot() (string, time.Time) {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	return tracker.status, tracker.lastRegisteredAt
}

func (a *agent) observeCellularRegistration(registration int, source string) {
	now := time.Now()
	registered := registration == 1 || registration == 5
	defer a.syncCellularRecoverySnapshot()

	a.mu.Lock()
	a.modem.RegistrationText = registrationText(registration)
	a.modem.CellularState = cellularStateText(registration)
	a.mu.Unlock()

	tracker := a.cellularRecovery
	tracker.mu.Lock()
	if registered {
		wasRecovering := !tracker.outageSince.IsZero()
		tracker.outageSince = time.Time{}
		tracker.lastRegisteredAt = now
		tracker.stage = cellularRecoveryIdle
		tracker.status = "Registered"
		tracker.mu.Unlock()
		if wasRecovering {
			a.debug.add("cellular", "event", "Cellular network registration restored", "", map[string]string{"source": source})
		}
		return
	}
	if tracker.outageSince.IsZero() {
		tracker.outageSince = now
		tracker.status = "Waiting for network registration"
	}
	if tracker.inFlight {
		tracker.mu.Unlock()
		return
	}
	a.mu.RLock()
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	sinceLastAction := time.Duration(1<<63 - 1)
	if !tracker.lastActionAt.IsZero() {
		sinceLastAction = now.Sub(tracker.lastActionAt)
	}
	action := chooseCellularRecoveryAction(
		registration, now.Sub(tracker.outageSince), tracker.stage, sinceLastAction, callActive,
	)
	if action == cellularRecoveryNone {
		tracker.mu.Unlock()
		return
	}
	tracker.inFlight = true
	tracker.lastActionAt = now
	switch action {
	case cellularRecoveryAutomaticSelection:
		tracker.stage = cellularRecoverySelectedNetwork
		tracker.status = "Selecting network automatically"
	case cellularRecoveryRadioRestart:
		tracker.stage = cellularRecoveryRestartedRadio
		tracker.status = "Restarting radio"
	}
	tracker.mu.Unlock()
	go a.executeCellularRecovery(action, source)
}

func (a *agent) syncCellularRecoverySnapshot() {
	status, lastRegisteredAt := a.cellularRecovery.snapshot()
	a.mu.Lock()
	a.modem.RecoveryState = status
	if !lastRegisteredAt.IsZero() {
		a.modem.LastRegisteredAt = lastRegisteredAt.UTC().Format(time.RFC3339Nano)
	}
	a.mu.Unlock()
}

func (a *agent) executeCellularRecovery(action cellularRecoveryAction, source string) {
	defer func() {
		a.cellularRecovery.mu.Lock()
		a.cellularRecovery.inFlight = false
		if a.cellularRecovery.status == "Selecting network automatically" || a.cellularRecovery.status == "Restarting radio" {
			a.cellularRecovery.status = "Waiting for network registration"
		}
		a.cellularRecovery.mu.Unlock()
	}()

	a.mu.RLock()
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	if callActive {
		a.debug.add("cellular", "event", "Cellular recovery canceled", "Call in progress", map[string]string{"source": source})
		return
	}

	switch action {
	case cellularRecoveryAutomaticSelection:
		a.debug.add("cellular", "recovery", "Starting automatic carrier selection", "", map[string]string{"source": source})
		if _, err := a.at.command("AT+COPS=0", 60*time.Second); err != nil {
			a.debug.add("cellular", "error", "Automatic network selection failed", err.Error(), nil)
			return
		}
		a.debug.add("cellular", "recovery", "Automatic network selection command completed", "", nil)
	case cellularRecoveryRadioRestart:
		a.debug.add("cellular", "recovery", "Starting radio restart", "", map[string]string{"source": source})
		if _, err := a.at.command("AT+CFUN=0", 10*time.Second); err != nil {
			a.debug.add("cellular", "error", "Failed to turn off radio", err.Error(), nil)
			return
		}
		time.Sleep(2 * time.Second)
		if _, err := a.at.command("AT+CFUN=1", 20*time.Second); err != nil {
			a.debug.add("cellular", "error", "Failed to restore radio", err.Error(), nil)
			return
		}
		_, _ = a.at.command("AT+CEREG=1", 3*time.Second)
		a.debug.add("cellular", "recovery", "Radio restart complete", "", nil)
	}
}

func cellularStateText(registration int) string {
	switch registration {
	case 1, 5:
		return "registered"
	case 2:
		return "searching"
	case 3:
		return "denied"
	default:
		return "unregistered"
	}
}

func (a *agent) cloudHeartbeatLoop() {
	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	for {
		<-timer.C
		a.mu.RLock()
		state := a.modem.CellularState
		registration := a.modem.RegistrationText
		recovery := a.modem.RecoveryState
		signal := a.modem.SignalDBM
		a.mu.RUnlock()
		if state == "" {
			state = "unregistered"
		}
		atHealth := a.at.healthSnapshot()
		err := a.push.sendHeartbeat(agentHeartbeatSnapshot{
			ATOK: atHealth.ConsecutiveFailures < 3, CellularState: state,
			CellularRegistration: registration, CellularRecovery: recovery,
			ECMCarrier: readDebugFile(usbCarrierPath), SignalDBM: signal,
		})
		if err != nil {
			a.debug.add("cloud", "heartbeat", "Agent cloud heartbeat failed", err.Error(), nil)
		} else if syncErr := a.syncCloudCommandsOnce(); syncErr != nil {
			a.debug.add("cloud-command", "pull_failed", "Failed to fetch pending commands after heartbeat", syncErr.Error(), nil)
		}
		timer.Reset(30 * time.Second)
	}
}
