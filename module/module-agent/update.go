package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	moduleUpdateFormat      = 1
	moduleUpdatePlatform    = "qdc507-armv7-linux-3.18.44"
	moduleUpdateContentType = "application/vnd.airsim.update+gzip"
	moduleUpdateMaxBytes    = 16 * 1024 * 1024
)

var moduleUpdateMarker = agentDataDirectory + "/update-pending"

type moduleUpdateManifest struct {
	FormatVersion int                `json:"format_version"`
	Version       string             `json:"version"`
	Platform      string             `json:"platform"`
	Files         []moduleUpdateFile `json:"files"`
}

type moduleUpdateFile struct {
	Name   string `json:"name"`
	Target string `json:"target"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
	Mode   uint32 `json:"mode"`
}

var moduleUpdateTargets = map[string]struct {
	target string
	mode   uint32
}{
	"qdc507-agent":            {target: "bin/qdc507-agent", mode: 0o755},
	"qdc507_data11_bridge.ko": {target: "kernel/qdc507_data11_bridge.ko", mode: 0o644},
	"qdc507_aprv3.ko":         {target: "voice-runtime/qdc507_aprv3.ko", mode: 0o644},
	"qdc507_voice.ko":         {target: "voice-runtime/qdc507_voice.ko", mode: 0o644},
	voiceHelperName:           {target: "voice-runtime/" + voiceHelperName, mode: 0o755},
}

func (a *agent) systemUpdate(response http.ResponseWriter, request *http.Request) {
	if request.Method == http.MethodGet {
		publicKey, err := moduleUpdatePublicKey()
		if err != nil {
			writeError(response, http.StatusInternalServerError, err.Error())
			return
		}
		keyID := sha256.Sum256(publicKey)
		a.mu.RLock()
		callActive := a.calls.Active != nil
		a.mu.RUnlock()
		writeJSON(response, http.StatusOK, map[string]any{
			"supported": true, "format_version": moduleUpdateFormat,
			"platform": moduleUpdatePlatform, "installed_version": agentVersion,
			"public_key_id":   hex.EncodeToString(keyID[:8]),
			"data_free_bytes": filesystemFreeBytes(agentDataDirectory),
			"temp_free_bytes": filesystemFreeBytes("/data/local/tmp"),
			"call_active":     callActive, "update_pending": fileExists(moduleUpdateMarker),
			"agent_pid": os.Getpid(), "factory_service_pid": processID("ql_manager_server"),
		})
		return
	}
	if !requireMethod(response, request, http.MethodPost) {
		return
	}
	if !moduleUpdateRunMu.TryLock() {
		writeError(response, http.StatusConflict, "Agent installation already in progress")
		return
	}
	defer moduleUpdateRunMu.Unlock()
	mode := strings.TrimSpace(request.Header.Get("X-AirSIM-Update-Mode"))
	if mode == "" {
		mode = "normal"
	}
	if mode != "normal" && mode != "repair" {
		writeError(response, http.StatusBadRequest, "Invalid Agent installation mode")
		return
	}
	operationID := fmt.Sprintf("update-%d", time.Now().UnixNano())
	updateModuleInstallState(operationID, mode, "uploading", "", 5, "Receiving signed package", nil, false)
	if mediaType := strings.TrimSpace(strings.Split(request.Header.Get("Content-Type"), ";")[0]); mediaType != moduleUpdateContentType {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "Invalid package type", errors.New("Invalid module update package Content-Type"), false)
		writeError(response, http.StatusUnsupportedMediaType, "Invalid module update package Content-Type")
		return
	}

	a.mu.RLock()
	callActive := a.calls.Active != nil
	a.mu.RUnlock()
	a.voice.mu.Lock()
	voiceActive := a.voice.command != nil || a.voice.routeCommand != nil
	a.voice.mu.Unlock()
	if callActive || voiceActive {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "Installation refused while a call or voice runtime is active", errors.New("Cannot update module while a call or voice bridge is active"), false)
		writeError(response, http.StatusConflict, "Cannot update module while a call or voice bridge is active")
		return
	}
	// Automatic upgrades and manual repairs can both follow a failed install. First
	// delete the upload cache, staging directory, and stale backups created only
	// by the updater, so leftovers do not fill the disk before the App writes a new package.
	// cleanup keeps a valid rollback point referenced by update-pending.
	before := filesystemFreeBytes(agentDataDirectory)
	if err := cleanupStaleModuleUpdateArtifacts(agentDataDirectory, "/data/local/tmp", moduleUpdateMarker); err != nil {
		appendModuleUpdateLog("low-space cleanup warning: " + err.Error())
	}
	after := filesystemFreeBytes(agentDataDirectory)
	appendModuleUpdateLog(fmt.Sprintf(
		"low-space preflight mode=%s content_length=%d free_before=%d free_after=%d",
		mode, request.ContentLength, before, after,
	))

	request.Body = http.MaxBytesReader(response, request.Body, moduleUpdateMaxBytes)
	temporary, err := os.CreateTemp("/data/local/tmp", "airsim-update-*.tar.gz")
	if err != nil {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "Cannot create installation cache", err, false)
		writeError(response, http.StatusInternalServerError, "Cannot create temporary update file: "+err.Error())
		return
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if _, err = io.Copy(temporary, request.Body); err != nil {
		temporary.Close()
		updateModuleInstallState(operationID, mode, "failed", "", 100, "Failed to receive package", err, false)
		writeError(response, http.StatusBadRequest, "Failed to read module update package: "+err.Error())
		return
	}
	if err = temporary.Sync(); err == nil {
		err = temporary.Close()
	} else {
		_ = temporary.Close()
	}
	if err != nil {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "Failed to save installation cache", err, false)
		writeError(response, http.StatusInternalServerError, "Failed to save module update package: "+err.Error())
		return
	}

	manifest, err := verifyModuleUpdateArchive(temporaryPath)
	if err != nil {
		updateModuleInstallState(operationID, mode, "failed", "", 100, "Package verification failed", err, false)
		writeError(response, http.StatusBadRequest, err.Error())
		return
	}
	updateModuleInstallState(operationID, mode, "verifying", manifest.Version, 25, "Signature, platform, and file digests verified", nil, false)
	if !shouldInstallModuleVersion(agentVersion, manifest.Version, mode) {
		writeJSON(response, http.StatusOK, map[string]any{
			"updated": false, "version": agentVersion, "message": "Module already has the same or a newer version",
		})
		updateModuleInstallState(operationID, mode, "completed", manifest.Version, 100, "Module already has the target version; no update needed", nil, false)
		return
	}

	updateModuleInstallState(operationID, mode, "installing", manifest.Version, 55, "Staging and atomically replacing Agent", nil, false)
	backupDirectory, err := installModuleUpdate(temporaryPath, manifest)
	if err != nil {
		updateModuleInstallState(operationID, mode, "failed", manifest.Version, 100, "Installation failed; existing Agent unchanged", err, false)
		writeError(response, http.StatusInternalServerError, "Failed to install module update: "+err.Error())
		return
	}
	if err := os.WriteFile(moduleUpdateMarker, []byte(backupDirectory+"\n"), 0o600); err != nil {
		if rollbackErr := rollbackModuleUpdate(backupDirectory); rollbackErr != nil {
			updateModuleInstallState(operationID, mode, "failed", manifest.Version, 100, "Confirmation marker and rollback both failed", errors.Join(err, rollbackErr), false)
			writeError(response, http.StatusInternalServerError, fmt.Sprintf("Failed to write update confirmation marker: %v; rollback also failed: %v", err, rollbackErr))
			return
		}
		updateModuleInstallState(operationID, mode, "rolled_back", manifest.Version, 100, "Failed to write confirmation marker; previous Agent restored", err, true)
		writeError(response, http.StatusInternalServerError, "Failed to write update confirmation marker; rolled back: "+err.Error())
		return
	}
	updateModuleInstallState(operationID, mode, "restarting", manifest.Version, 80, "Agent installed; restarting safely", nil, false)

	writeJSON(response, http.StatusOK, map[string]any{
		"updated": true, "version": manifest.Version, "restart_required": true,
		"message": "Update verified and installed; module Agent is restarting safely",
	})
	go func() {
		time.Sleep(750 * time.Millisecond)
		const restartScript = `
/etc/init.d/airsim_agent stop >>/data/airsim/log/update.log 2>&1
sleep 1
/etc/init.d/airsim_agent start >>/data/airsim/log/update.log 2>&1 || exit 1
count=0
while test "$count" -lt 20; do
  if wget -qO- http://127.0.0.1:8575/api/health 2>/dev/null | grep -q '"product":"airsim"'; then
    if test "$(cat /data/airsim/update-pending 2>/dev/null)" = "$1"; then
      rm -f /data/airsim/update-pending
      rm -rf "$1"
      printf 'update-confirmed backup=%s\n' "$1" >>/data/airsim/log/update.log
    fi
    exit 0
  fi
  count=$((count + 1))
  sleep 1
done
exit 1
`
		command := exec.Command("/bin/sh", "-c", restartScript, "airsim-update", backupDirectory)
		_ = command.Start()
	}()
}

// cleanupStaleModuleUpdateArtifacts only removes paths created by previous App
// update attempts. A backup referenced by update-pending is the active rollback
// point and must survive until the restarted Agent confirms health.
func cleanupStaleModuleUpdateArtifacts(dataRoot, temporaryRoot, markerPath string) error {
	pendingBackup := ""
	if marker, err := os.ReadFile(markerPath); err == nil {
		pendingBackup = filepath.Clean(strings.TrimSpace(string(marker)))
	}
	patterns := []string{
		filepath.Join(temporaryRoot, "airsim-update-*.tar.gz"),
		filepath.Join(dataRoot, ".update-stage-*"),
		filepath.Join(dataRoot, "backup", "app-update-*"),
	}
	var cleanupErrors []error
	for _, pattern := range patterns {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			cleanupErrors = append(cleanupErrors, err)
			continue
		}
		for _, match := range matches {
			if pendingBackup != "" && filepath.Clean(match) == pendingBackup {
				continue
			}
			if err := os.RemoveAll(match); err != nil {
				cleanupErrors = append(cleanupErrors, fmt.Errorf("remove %s: %w", match, err))
			}
		}
	}
	return errors.Join(cleanupErrors...)
}

func moduleUpdatePublicKey() (ed25519.PublicKey, error) {
	decoded, err := base64.StdEncoding.DecodeString(moduleUpdatePublicKeyBase64)
	if err != nil || len(decoded) != ed25519.PublicKeySize {
		return nil, errors.New("Invalid module update public key configuration")
	}
	return ed25519.PublicKey(decoded), nil
}

func verifyModuleUpdateArchive(path string) (moduleUpdateManifest, error) {
	manifestData, signature, err := readModuleUpdateMetadata(path)
	if err != nil {
		return moduleUpdateManifest{}, err
	}
	publicKey, err := moduleUpdatePublicKey()
	if err != nil {
		return moduleUpdateManifest{}, err
	}
	if len(signature) != ed25519.SignatureSize || !ed25519.Verify(publicKey, manifestData, signature) {
		return moduleUpdateManifest{}, errors.New("Invalid module update package signature")
	}

	decoder := json.NewDecoder(strings.NewReader(string(manifestData)))
	decoder.DisallowUnknownFields()
	var manifest moduleUpdateManifest
	if err := decoder.Decode(&manifest); err != nil {
		return moduleUpdateManifest{}, fmt.Errorf("Invalid module update manifest: %w", err)
	}
	if err := validateModuleUpdateManifest(manifest); err != nil {
		return moduleUpdateManifest{}, err
	}
	return manifest, nil
}

func readModuleUpdateMetadata(path string) ([]byte, []byte, error) {
	reader, closeReader, err := openModuleUpdateArchive(path)
	if err != nil {
		return nil, nil, err
	}
	defer closeReader()

	manifestHeader, err := reader.Next()
	if err != nil || manifestHeader.Name != "manifest.json" || manifestHeader.Size <= 0 || manifestHeader.Size > 64*1024 {
		return nil, nil, errors.New("Module update package must begin with a valid manifest.json")
	}
	manifestData, err := io.ReadAll(io.LimitReader(reader, manifestHeader.Size))
	if err != nil {
		return nil, nil, fmt.Errorf("Failed to read module update manifest: %w", err)
	}
	signatureHeader, err := reader.Next()
	if err != nil || signatureHeader.Name != "manifest.sig" || signatureHeader.Size != ed25519.SignatureSize {
		return nil, nil, errors.New("Module update package lacks a valid manifest.sig")
	}
	signature, err := io.ReadAll(io.LimitReader(reader, signatureHeader.Size))
	if err != nil {
		return nil, nil, fmt.Errorf("Failed to read module update signature: %w", err)
	}
	return manifestData, signature, nil
}

func openModuleUpdateArchive(path string) (*tar.Reader, func(), error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, func() {}, err
	}
	gzipReader, err := gzip.NewReader(file)
	if err != nil {
		file.Close()
		return nil, func() {}, fmt.Errorf("Module update package is not valid gzip: %w", err)
	}
	closeReader := func() {
		_ = gzipReader.Close()
		_ = file.Close()
	}
	return tar.NewReader(gzipReader), closeReader, nil
}

func validateModuleUpdateManifest(manifest moduleUpdateManifest) error {
	if manifest.FormatVersion != moduleUpdateFormat || manifest.Platform != moduleUpdatePlatform {
		return errors.New("Module update package format or hardware platform mismatch")
	}
	if !regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`).MatchString(manifest.Version) {
		return errors.New("Invalid module update version")
	}
	if len(manifest.Files) != len(moduleUpdateTargets) {
		return errors.New("Incomplete module update file set")
	}
	seen := make(map[string]bool, len(manifest.Files))
	var totalSize int64
	for _, item := range manifest.Files {
		target, ok := moduleUpdateTargets[item.Name]
		if !ok || seen[item.Name] || item.Target != target.target || item.Mode != target.mode {
			return fmt.Errorf("Invalid destination or permissions for module update file %q", item.Name)
		}
		if item.Size <= 0 || item.Size > moduleUpdateMaxBytes || !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(item.SHA256) {
			return fmt.Errorf("Invalid size or digest for module update file %q", item.Name)
		}
		seen[item.Name] = true
		totalSize += item.Size
	}
	if totalSize > moduleUpdateMaxBytes {
		return errors.New("Extracted module update package exceeds size limit")
	}
	return nil
}

func installModuleUpdate(path string, manifest moduleUpdateManifest) (string, error) {
	changedFiles, err := moduleUpdateFilesRequiringReplacement(manifest, agentDataDirectory)
	if err != nil {
		return "", err
	}
	changed := make(map[string]bool, len(changedFiles))
	var stagingBytes uint64
	for _, item := range changedFiles {
		changed[item.Name] = true
		stagingBytes += uint64(item.Size)
	}
	const stagingMargin = 256 * 1024
	available := filesystemFreeBytes(agentDataDirectory)
	if stagingBytes+stagingMargin > available {
		return "", fmt.Errorf(
			"Insufficient incremental staging space: required=%d available=%d: no space left on device",
			stagingBytes+stagingMargin,
			available,
		)
	}
	appendModuleUpdateLog(fmt.Sprintf(
		"delta-stage files=%d bytes=%d free=%d reused=%d",
		len(changedFiles), stagingBytes, available, len(manifest.Files)-len(changedFiles),
	))

	stagingDirectory, err := os.MkdirTemp(agentDataDirectory, ".update-stage-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stagingDirectory)

	manifestFiles := make(map[string]moduleUpdateFile, len(manifest.Files))
	for _, item := range manifest.Files {
		manifestFiles[item.Name] = item
	}
	reader, closeReader, err := openModuleUpdateArchive(path)
	if err != nil {
		return "", err
	}
	defer closeReader()
	seen := make(map[string]bool, len(manifest.Files))
	for {
		header, nextErr := reader.Next()
		if errors.Is(nextErr, io.EOF) {
			break
		}
		if nextErr != nil {
			return "", nextErr
		}
		if header.Name == "manifest.json" || header.Name == "manifest.sig" {
			continue
		}
		if header.Typeflag != tar.TypeReg || !strings.HasPrefix(header.Name, "payload/") {
			return "", fmt.Errorf("Module update package contains a disallowed archive entry: %s", header.Name)
		}
		name := strings.TrimPrefix(header.Name, "payload/")
		item, ok := manifestFiles[name]
		if !ok || seen[name] || header.Size != item.Size {
			return "", fmt.Errorf("Module update payload %q is missing from manifest or has an incorrect size", name)
		}
		digest := sha256.New()
		var copyErr, syncErr, closeErr error
		if changed[name] {
			destination := filepath.Join(stagingDirectory, name)
			file, createErr := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, os.FileMode(item.Mode))
			if createErr != nil {
				return "", createErr
			}
			_, copyErr = io.Copy(io.MultiWriter(file, digest), reader)
			syncErr = file.Sync()
			closeErr = file.Close()
		} else {
			_, copyErr = io.Copy(digest, reader)
		}
		if copyErr != nil || syncErr != nil || closeErr != nil {
			return "", errors.Join(copyErr, syncErr, closeErr)
		}
		if hex.EncodeToString(digest.Sum(nil)) != item.SHA256 {
			return "", fmt.Errorf("SHA-256 mismatch for module update payload %q", name)
		}
		seen[name] = true
	}
	if len(seen) != len(manifest.Files) {
		return "", errors.New("Module update package is missing a manifest payload")
	}
	probePath := func(name string) string {
		if changed[name] {
			return filepath.Join(stagingDirectory, name)
		}
		return filepath.Join(agentDataDirectory, manifestFiles[name].Target)
	}
	if output, err := exec.Command(probePath("qdc507-agent"), "--startup-probe", "runtime").CombinedOutput(); err != nil {
		return "", fmt.Errorf("New Agent startup probe failed: %v (%s)", err, strings.TrimSpace(string(output)))
	}
	if output, err := exec.Command(probePath(voiceHelperName), "--check").CombinedOutput(); err != nil {
		return "", fmt.Errorf("New PCM helper self-test failed: %v (%s)", err, strings.TrimSpace(string(output)))
	}

	backupDirectory := filepath.Join(agentDataDirectory, "backup", fmt.Sprintf("app-update-%d", time.Now().Unix()))
	if err := os.MkdirAll(backupDirectory, 0o700); err != nil {
		return "", err
	}
	installed := make([]moduleUpdateFile, 0, len(manifest.Files))
	for _, item := range manifest.Files {
		targetPath := filepath.Join(agentDataDirectory, item.Target)
		backupPath := filepath.Join(backupDirectory, item.Name)
		if !changed[item.Name] {
			// The startup rollback hook expects a complete five-file backup. A
			// hard link satisfies that contract without duplicating unchanged
			// payload bytes on the constrained /data filesystem.
			if err := os.Link(targetPath, backupPath); err != nil {
				_ = restoreInstalledUpdateFiles(backupDirectory, installed)
				return "", fmt.Errorf("Failed to create zero-copy rollback point for reused payload %s: %w", item.Name, err)
			}
			continue
		}
		if err := os.Rename(targetPath, backupPath); err != nil {
			_ = restoreInstalledUpdateFiles(backupDirectory, installed)
			return "", fmt.Errorf("Failed to back up %s: %w", item.Name, err)
		}
		if err := os.Rename(filepath.Join(stagingDirectory, item.Name), targetPath); err != nil {
			_ = os.Rename(backupPath, targetPath)
			_ = restoreInstalledUpdateFiles(backupDirectory, installed)
			return "", fmt.Errorf("Failed to commit %s: %w", item.Name, err)
		}
		if err := os.Chmod(targetPath, os.FileMode(item.Mode)); err != nil {
			_ = restoreInstalledUpdateFiles(backupDirectory, append(installed, item))
			return "", fmt.Errorf("Failed to set permissions for %s: %w", item.Name, err)
		}
		installed = append(installed, item)
	}
	return backupDirectory, nil
}

func moduleUpdateFilesRequiringReplacement(manifest moduleUpdateManifest, dataRoot string) ([]moduleUpdateFile, error) {
	changed := make([]moduleUpdateFile, 0, len(manifest.Files))
	for _, item := range manifest.Files {
		matches, err := fileMatchesSHA256(filepath.Join(dataRoot, item.Target), item.SHA256)
		if err != nil {
			return nil, fmt.Errorf("Failed to read installed payload %s: %w", item.Name, err)
		}
		if !matches {
			changed = append(changed, item)
		}
	}
	return changed, nil
}

func fileMatchesSHA256(path, expected string) (bool, error) {
	file, err := os.Open(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return false, err
	}
	return hex.EncodeToString(digest.Sum(nil)) == expected, nil
}

func restoreInstalledUpdateFiles(backupDirectory string, files []moduleUpdateFile) error {
	var restoreErrors []error
	for index := len(files) - 1; index >= 0; index-- {
		item := files[index]
		targetPath := filepath.Join(agentDataDirectory, item.Target)
		failedPath := targetPath + ".failed"
		_ = os.Remove(failedPath)
		if err := os.Rename(targetPath, failedPath); err != nil && !os.IsNotExist(err) {
			restoreErrors = append(restoreErrors, err)
		}
		if err := os.Rename(filepath.Join(backupDirectory, item.Name), targetPath); err != nil {
			restoreErrors = append(restoreErrors, err)
		}
	}
	return errors.Join(restoreErrors...)
}

func rollbackModuleUpdate(backupDirectory string) error {
	files := make([]moduleUpdateFile, 0, len(moduleUpdateTargets))
	for name, target := range moduleUpdateTargets {
		files = append(files, moduleUpdateFile{Name: name, Target: target.target})
	}
	return restoreInstalledUpdateFiles(backupDirectory, files)
}

func compareModuleVersions(left, right string) int {
	parse := func(value string) [3]int {
		var result [3]int
		parts := strings.Split(value, ".")
		for index := 0; index < len(result) && index < len(parts); index++ {
			result[index], _ = strconv.Atoi(parts[index])
		}
		return result
	}
	lhs, rhs := parse(left), parse(right)
	for index := range lhs {
		if lhs[index] < rhs[index] {
			return -1
		}
		if lhs[index] > rhs[index] {
			return 1
		}
	}
	return 0
}
