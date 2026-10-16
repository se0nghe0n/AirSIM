package main

import (
	"crypto/ed25519"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	debianPackageContentType = "application/vnd.debian.binary-package"
	maximumPackageBytes      = 64 * 1024 * 1024
	expectedPackageName      = "airsim-avf-agent"
	expectedArchitecture     = "arm64"
)

var debianVersionPattern = regexp.MustCompile(`^[0-9][0-9A-Za-z.+:~_-]{0,127}$`)

type packageMetadata struct {
	Name         string `json:"name"`
	Architecture string `json:"architecture"`
	Version      string `json:"version"`
}

type installationState struct {
	Phase             string `json:"phase"`
	InstalledVersion  string `json:"installed_version,omitempty"`
	TargetVersion     string `json:"target_version,omitempty"`
	Message           string `json:"message"`
	Error             string `json:"error,omitempty"`
	RollbackAvailable bool   `json:"rollback_available"`
	UpdatedAt         string `json:"updated_at"`
}

type installerBackend interface {
	packageMetadata(path string) (packageMetadata, error)
	installedVersion() (string, error)
	install(path string) error
	restartAgent() error
	agentHealthy(version string) bool
	compareVersions(left, right string) (int, error)
}

type installerConfig struct {
	Token          string
	PublicKey      ed25519.PublicKey
	StateDirectory string
}

type installerServer struct {
	config  installerConfig
	backend installerBackend
	mu      sync.Mutex
}

func newInstallerServer(config installerConfig, backend installerBackend) http.Handler {
	return &installerServer{config: config, backend: backend}
}

func (server *installerServer) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	if !allowedInstallerPeer(request.RemoteAddr) {
		writeInstallerError(response, http.StatusForbidden, "Installer only accepts AVF private-network or local connections")
		return
	}
	if !validBearer(request.Header.Get("Authorization"), server.config.Token) {
		response.Header().Set("WWW-Authenticate", "Bearer")
		writeInstallerError(response, http.StatusUnauthorized, "Installer authentication failed")
		return
	}
	switch request.URL.Path {
	case "/v1/status":
		server.status(response, request)
	case "/v1/packages/install":
		server.install(response, request)
	case "/v1/packages/rollback":
		server.rollback(response, request)
	default:
		writeInstallerError(response, http.StatusNotFound, "Installer path not found")
	}
}

func allowedInstallerPeer(remote string) bool {
	host, _, err := net.SplitHostPort(remote)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	v4 := ip.To4()
	return v4 != nil && (v4[0] == 10 || (v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31))
}

func validBearer(header, expected string) bool {
	const prefix = "Bearer "
	if len(expected) < 24 || !strings.HasPrefix(header, prefix) {
		return false
	}
	provided := strings.TrimSpace(strings.TrimPrefix(header, prefix))
	return len(provided) == len(expected) &&
		subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) == 1
}

func (server *installerServer) status(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeInstallerError(response, http.StatusMethodNotAllowed, "status only supports GET")
		return
	}
	state := server.readState()
	if version, err := server.backend.installedVersion(); err == nil {
		state.InstalledVersion = version
	}
	state.RollbackAvailable = fileExists(server.previousPackagePath())
	writeInstallerJSON(response, http.StatusOK, state)
}

func (server *installerServer) install(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writeInstallerError(response, http.StatusMethodNotAllowed, "install only supports POST")
		return
	}
	if mediaType := strings.TrimSpace(strings.Split(request.Header.Get("Content-Type"), ";")[0]); mediaType != debianPackageContentType {
		writeInstallerError(response, http.StatusUnsupportedMediaType, "Invalid package Content-Type")
		return
	}
	signature, err := decodeSignature(request.Header.Get("X-AirSIM-Signature"))
	if err != nil {
		writeInstallerError(response, http.StatusBadRequest, err.Error())
		return
	}
	payload, err := io.ReadAll(io.LimitReader(request.Body, maximumPackageBytes+1))
	if err != nil {
		writeInstallerError(response, http.StatusBadRequest, "Failed to read package")
		return
	}
	if len(payload) == 0 || len(payload) > maximumPackageBytes {
		writeInstallerError(response, http.StatusRequestEntityTooLarge, "Package is empty or exceeds 64 MiB")
		return
	}
	if len(server.config.PublicKey) != ed25519.PublicKeySize || !ed25519.Verify(server.config.PublicKey, payload, signature) {
		writeInstallerError(response, http.StatusBadRequest, "Invalid package signature")
		return
	}

	server.mu.Lock()
	defer server.mu.Unlock()
	if err := os.MkdirAll(filepath.Join(server.config.StateDirectory, "packages"), 0o700); err != nil {
		writeInstallerError(response, http.StatusInternalServerError, "Cannot prepare installer state directory")
		return
	}
	stagedPath := filepath.Join(server.config.StateDirectory, "packages", "staged.deb")
	if err := writeAtomic(stagedPath, payload, 0o600); err != nil {
		writeInstallerError(response, http.StatusInternalServerError, "Cannot save package")
		return
	}
	defer os.Remove(stagedPath)
	metadata, err := server.backend.packageMetadata(stagedPath)
	if err != nil {
		writeInstallerError(response, http.StatusBadRequest, "Cannot read Debian package metadata")
		return
	}
	if err := validatePackageMetadata(metadata); err != nil {
		writeInstallerError(response, http.StatusBadRequest, err.Error())
		return
	}
	mode := strings.TrimSpace(request.Header.Get("X-AirSIM-Install-Mode"))
	if mode == "" {
		mode = "normal"
	}
	if mode != "normal" && mode != "repair" {
		writeInstallerError(response, http.StatusBadRequest, "Installation mode must be normal or repair")
		return
	}
	currentPath := server.currentPackagePath()
	installedVersion, installedErr := server.backend.installedVersion()
	if installedErr == nil && installedVersion != "" && !fileExists(currentPath) {
		writeInstallerError(response, http.StatusConflict,
			"Initial package missing; cannot upgrade without a rollback point. Run the one-time AVF bootstrap again")
		return
	}
	if installedErr == nil && installedVersion != "" {
		relation, compareErr := server.backend.compareVersions(metadata.Version, installedVersion)
		if compareErr != nil {
			writeInstallerError(response, http.StatusInternalServerError, "Cannot compare Debian package versions")
			return
		}
		if mode == "normal" && relation <= 0 {
			writeInstallerError(response, http.StatusConflict, "normal mode only accepts a signed package newer than the installed version")
			return
		}
		if mode == "repair" && relation != 0 {
			writeInstallerError(response, http.StatusConflict, "repair mode only accepts a signed package matching the installed version")
			return
		}
	} else if mode == "repair" {
		writeInstallerError(response, http.StatusConflict, "Cannot use repair mode before Agent is installed")
		return
	}
	server.writeState(installationState{
		Phase: "installing", TargetVersion: metadata.Version,
		Message: "Signature and arm64 package identity verified; installing",
	})

	previousPath := server.previousPackagePath()
	if fileExists(currentPath) {
		if err := copyFileAtomic(currentPath, previousPath); err != nil {
			writeInstallerError(response, http.StatusInternalServerError, "Cannot create rollback package")
			return
		}
	}
	if err := server.backend.install(stagedPath); err != nil {
		installErr := err
		if fileExists(previousPath) {
			previousMetadata, metadataErr := server.backend.packageMetadata(previousPath)
			if metadataErr == nil && validatePackageMetadata(previousMetadata) == nil {
				restoreErr := server.backend.install(previousPath)
				if restoreErr == nil {
					restoreErr = server.backend.restartAgent()
				}
				if restoreErr == nil && !server.backend.agentHealthy(agentVersionForPackage(previousMetadata.Version)) {
					restoreErr = errors.New("Restored version failed health check")
				}
				if restoreErr != nil {
					installErr = errors.Join(installErr, fmt.Errorf("Restore failed: %w", restoreErr))
				} else {
					_ = os.Remove(previousPath)
				}
			} else {
				installErr = errors.Join(installErr, errors.New("Invalid rollback package metadata"))
			}
		}
		server.failState(metadata.Version, "dpkg installation failed; attempted to restore the installed version", installErr)
		writeInstallerError(response, http.StatusInternalServerError, "Debian package installation failed")
		return
	}
	agentVersion := agentVersionForPackage(metadata.Version)
	if err := server.backend.restartAgent(); err != nil || !server.backend.agentHealthy(agentVersion) {
		healthErr := err
		if healthErr == nil {
			healthErr = errors.New("New Agent failed health check")
		}
		if fileExists(previousPath) {
			previousMetadata, metadataErr := server.backend.packageMetadata(previousPath)
			if metadataErr != nil || validatePackageMetadata(previousMetadata) != nil {
				healthErr = errors.Join(healthErr, errors.New("Invalid rollback package metadata"))
				server.failState(metadata.Version, "New version is unhealthy and rollback package is invalid", healthErr)
				writeInstallerError(response, http.StatusInternalServerError, "New version is unhealthy and rollback package is invalid")
				return
			}
			rollbackErr := server.backend.install(previousPath)
			if rollbackErr == nil {
				rollbackErr = server.backend.restartAgent()
			}
			if rollbackErr == nil && !server.backend.agentHealthy(agentVersionForPackage(previousMetadata.Version)) {
				rollbackErr = errors.New("Rolled-back Agent failed health check")
			}
			if rollbackErr != nil {
				healthErr = errors.Join(healthErr, fmt.Errorf("Rollback failed: %w", rollbackErr))
				server.failState(metadata.Version, "New version is unhealthy and rollback failed", healthErr)
				writeInstallerError(response, http.StatusInternalServerError, "New version is unhealthy and rollback failed")
				return
			}
			_ = os.Remove(previousPath)
			server.writeState(installationState{
				Phase: "rolled_back", TargetVersion: metadata.Version,
				Message: "New Agent failed health check; previous version restored",
				Error:   healthErr.Error(), RollbackAvailable: false,
			})
			writeInstallerError(response, http.StatusBadGateway, "New Agent failed health check; rolled back automatically")
			return
		}
		server.failState(metadata.Version, "New Agent failed health check and no rollback package is available", healthErr)
		writeInstallerError(response, http.StatusBadGateway, "New Agent failed health check and no rollback package is available")
		return
	}
	if err := copyFileAtomic(stagedPath, currentPath); err != nil {
		server.failState(metadata.Version, "Agent is running, but rollback package could not be retained", err)
		writeInstallerError(response, http.StatusInternalServerError, "Cannot retain installed package")
		return
	}
	state := installationState{
		Phase: "completed", InstalledVersion: metadata.Version, TargetVersion: metadata.Version,
		Message:           "AirSIM AVF Agent installed and health check passed",
		RollbackAvailable: fileExists(previousPath),
	}
	server.writeState(state)
	writeInstallerJSON(response, http.StatusOK, state)
}

func (server *installerServer) rollback(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writeInstallerError(response, http.StatusMethodNotAllowed, "rollback only supports POST")
		return
	}
	server.mu.Lock()
	defer server.mu.Unlock()
	previousPath := server.previousPackagePath()
	if !fileExists(previousPath) {
		writeInstallerError(response, http.StatusConflict, "No rollback package available")
		return
	}
	metadata, err := server.backend.packageMetadata(previousPath)
	if err != nil || validatePackageMetadata(metadata) != nil {
		writeInstallerError(response, http.StatusInternalServerError, "Invalid rollback package metadata")
		return
	}
	if err := server.backend.install(previousPath); err != nil {
		writeInstallerError(response, http.StatusInternalServerError, "Rollback installation failed")
		return
	}
	if err := server.backend.restartAgent(); err != nil || !server.backend.agentHealthy(agentVersionForPackage(metadata.Version)) {
		writeInstallerError(response, http.StatusBadGateway, "Rolled-back version failed health check")
		return
	}
	if err := swapRetainedPackages(server.currentPackagePath(), previousPath); err != nil {
		writeInstallerError(response, http.StatusInternalServerError, "Agent rolled back, but retained packages could not be swapped")
		return
	}
	state := installationState{
		Phase: "completed", InstalledVersion: metadata.Version, TargetVersion: metadata.Version,
		Message: "Rolled back and health check passed", RollbackAvailable: true,
	}
	server.writeState(state)
	writeInstallerJSON(response, http.StatusOK, state)
}

func decodeSignature(value string) ([]byte, error) {
	signature, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil || len(signature) != ed25519.SignatureSize {
		return nil, errors.New("Valid Ed25519 package signature required")
	}
	return signature, nil
}

func validatePackageMetadata(metadata packageMetadata) error {
	if metadata.Name != expectedPackageName {
		return fmt.Errorf("Only %s may be installed", expectedPackageName)
	}
	if metadata.Architecture != expectedArchitecture {
		return errors.New("Only arm64 Debian packages may be installed")
	}
	if !debianVersionPattern.MatchString(metadata.Version) {
		return errors.New("Invalid Debian package version")
	}
	return nil
}

// agentVersionForPackage converts a Debian package version such as 0.4.2-1
// into the upstream version reported by the Agent health endpoint.
func agentVersionForPackage(version string) string {
	if epoch := strings.IndexByte(version, ':'); epoch >= 0 {
		version = version[epoch+1:]
	}
	if revision := strings.LastIndexByte(version, '-'); revision >= 0 {
		version = version[:revision]
	}
	return version
}

func (server *installerServer) currentPackagePath() string {
	return filepath.Join(server.config.StateDirectory, "packages", "current.deb")
}

func (server *installerServer) previousPackagePath() string {
	return filepath.Join(server.config.StateDirectory, "packages", "previous.deb")
}

func (server *installerServer) statePath() string {
	return filepath.Join(server.config.StateDirectory, "state.json")
}

func (server *installerServer) readState() installationState {
	data, err := os.ReadFile(server.statePath())
	if err != nil {
		return installationState{Phase: "idle", Message: "Waiting for management from Android app", UpdatedAt: time.Now().UTC().Format(time.RFC3339)}
	}
	var state installationState
	if json.Unmarshal(data, &state) != nil || state.Phase == "" {
		return installationState{Phase: "idle", Message: "Installer state needs to be rebuilt", UpdatedAt: time.Now().UTC().Format(time.RFC3339)}
	}
	return state
}

func (server *installerServer) writeState(state installationState) {
	state.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	state.RollbackAvailable = state.RollbackAvailable || fileExists(server.previousPackagePath())
	data, err := json.Marshal(state)
	if err == nil {
		_ = os.MkdirAll(server.config.StateDirectory, 0o700)
		_ = writeAtomic(server.statePath(), append(data, '\n'), 0o600)
	}
}

func (server *installerServer) failState(target, message string, err error) {
	state := installationState{Phase: "failed", TargetVersion: target, Message: message}
	if err != nil {
		state.Error = err.Error()
	}
	server.writeState(state)
}

func writeAtomic(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".airsim-write-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err = temporary.Write(data); err == nil {
		err = temporary.Sync()
	}
	closeErr := temporary.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(temporaryPath, path)
}

func copyFileAtomic(source, destination string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return writeAtomic(destination, data, 0o600)
}

func swapRetainedPackages(currentPath, previousPath string) error {
	temporaryPath := filepath.Join(filepath.Dir(currentPath), ".swap.deb")
	_ = os.Remove(temporaryPath)
	if err := os.Rename(currentPath, temporaryPath); err != nil {
		return err
	}
	if err := os.Rename(previousPath, currentPath); err != nil {
		_ = os.Rename(temporaryPath, currentPath)
		return err
	}
	if err := os.Rename(temporaryPath, previousPath); err != nil {
		_ = os.Rename(currentPath, previousPath)
		_ = os.Rename(temporaryPath, currentPath)
		return err
	}
	return nil
}

func fileExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func writeInstallerJSON(response http.ResponseWriter, status int, value any) {
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}

func writeInstallerError(response http.ResponseWriter, status int, message string) {
	writeInstallerJSON(response, status, map[string]string{"error": message})
}
