# AirSIM AVF Linux Agent Installation and Non-destructive Troubleshooting

This guide applies to Samsung phones supporting Android AVF Linux Terminal. The AirSIM Android app, AVF `airsim-agent`, and separate `airsim-installerd` are three distinct components. Opening Terminal does not prove Agent installation; a reachable Agent health endpoint on `8575` does not prove installer `8576` or the control token is ready.

The documented app release is [`v0.9.7.1`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.7.1). This guide installs the separately versioned AVF Agent [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6) (Debian `0.4.6-1`). These version lines serve different purposes and are not interchangeable.

For Android 10–13, the recommended Standalone hotfix `0.9.7.1 (81)` needs none of this Linux installation. Shared legacy AVF Bridge fixes below API 34 use only a tappable notification asking the user to open Terminal and reconnect; they do not invoke unavailable ActivityOptions methods or bypass background-start restrictions.

If DJOneHub is already in AVF, preserve its services and port `7575`. AirSIM uses separate ports `8575` / `8576`, and its health response must contain `"product":"airsim"`; success on `7575` does not establish AirSIM installation. First installation is pinned to v0.4.6. Devices on `0.4.4-1` must first migrate the signing key to v0.4.5 as below, then upgrade through the installer. Neither the initial installer nor the app's old installerd can skip that migration.

## Safety boundaries

- Do not immediately disable Linux Terminal in Developer Options, clear Terminal app data, or delete the AVF image after a Terminal error. Those operations may remove the guest, Agent configuration, and pairing state.
- Do not delete `/var/lib/airsim-installerd/packages/current.deb`; subsequent updates depend on it for rollback.
- Enter the control token only in AirSIM's private configuration, never chat, screenshots, logs, or the repository. Inspect logs for sensitive data before sharing.
- IP addresses and versions here are examples. AVF subnets vary by device and startup; verify the current address.

## 1. Confirm Linux Terminal is usable

Check AVF status under “Settings → AVF Linux Initial Installation.” If Terminal is running, select “Open Linux Terminal” and confirm a Debian prompt such as `droid@localhost`. Do not repeatedly launch multiple VM runners. `cannot create runner / VM is not in stopped state` is an Android Terminal startup conflict preceding Agent installation. Return to the existing Terminal session, or close the error view and reopen the existing Terminal while preserving AVF data. Consider a system reset only after confirming backups and the consequences of data loss.

If Terminal is missing or the system does not expose AVF, a normal third-party app cannot install OEM system components. A supported system version or vendor image is required.

## 2. First signed installation

Run this line at the Debian prompt. `pipefail` propagates download errors as a nonzero exit instead of letting empty-input `sudo sh` appear successful:

```sh
bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh | sudo sh'
```

The app button **only copies the command**; it cannot run guest Linux commands directly on Android. Paste at the Debian Terminal prompt and press Enter. The script verifies the Ed25519 signature, package name, and `arm64` architecture, installs, and retains `current.deb`. The repaired script requires `airsim-agent`, `airsim-installerd`, and Agent health to be ready; failure of any is not installation success. If `current.deb` already exists, it restores current services first, reinstalling service files from that package if needed without deleting rollback data, downloading again, or upgrading the Agent without authorization.

If the command produces no output for a long time, run `curl -I --connect-timeout 10 --max-time 20 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh` separately to check GitHub access from AVF Debian itself. Android host connectivity does not establish guest connectivity. A `curl` timeout, missing `sudo`, no Debian prompt, and refusal to rerun an existing installation are separate failures. Record exact terminal output and exit codes rather than grouping them as “installation failed.”

The installation script is a GitHub Release asset. Editing repository `install-avf.sh.in` does not update an existing Release; a new signed package and Release are needed to deliver fixes. If the online script still says initial installation is complete and future updates must use the Android app, it is the older script. Restore services using section 4; **do not delete `current.deb` to bypass it**.

### Installed 0.4.4-1: one-time release-signing-key migration

The v0.4.4 private release key was not retained, so old `airsim-installerd` cannot verify the new v0.4.5 signature. Repeatedly selecting “Update to latest,” reusing an old `.sig`, or skipping verification cannot solve this. Run in the same AVF Linux Terminal containing the installed AirSIM Agent:

```sh
curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 -o /tmp/airsim-rotate-v0.4.5.sh https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.5/rotate-avf-key.sh
printf '%s  %s\n' '9ae6b8c69d5d9877638a50240282a67d06b73d807dba444c816c5efb9c5ec04d' /tmp/airsim-rotate-v0.4.5.sh | sha256sum -c - && sudo sh /tmp/airsim-rotate-v0.4.5.sh
```

This command accepts only a guest with `airsim-avf-agent 0.4.4-1` whose retained package SHA-256 exactly matches released v0.4.4. It also stops rather than overwriting another rollback package. It downloads the fixed v0.4.5 package/signature from GitHub, verifies with its embedded new Ed25519 public key, retains the old package, installs, restarts both AirSIM services, and checks health. Failure triggers an attempted rollback. It does not clear AVF data, the AirSIM control token, or DJOneHub. The v0.4.5 public-key DER SHA-256 is `4c39d5afdca2dddd8d22c0a5e02da18e7f07db789baac04bce4cfcd57491b3f4`; see the [0.4.5 release notes](releases/0.4.5.md) for script SHA-256. Download uses GitHub HTTPS. Since the old key is lost, cross-signing the migration script with it is impossible; verify the domain and fingerprints carefully.

After migration, `0.4.4-1` remains in `previous.deb` for installerd rollback; later versions can again use signed in-app updates. Download, version, old-package digest, or Debian dependency-preflight failure prevents installation. Do not delete `current.deb` or use `dpkg --force` to bypass checks.

## 3. Pair the Android app

Run in Debian Terminal:

```sh
sudo airsim-avf-pair
```

Save the printed control token under “Settings → Linux Agent → Control Token.” Use the current AVF guest address with port `8575`. The app currently infers guest `.25` from the private subnet containing `avf_tap_fixed`; the reachable address on this device is authoritative, not a fixed `10.185.5.25`. From a Mac, these read-only checks inspect the host interface and connectivity (replace the serial and actual guest address):

```sh
adb -s DEVICE shell ip -o -4 addr show dev avf_tap_fixed
adb -s DEVICE shell ping -c 1 -W 1 AVF_GUEST_IP
adb -s DEVICE shell 'printf "GET /api/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" | toybox nc -w 3 AVF_GUEST_IP 8575'
adb -s DEVICE shell toybox nc -z -w 2 AVF_GUEST_IP 8576
```

`ok: true` from `/api/health` proves only that the Agent process is reachable. If the app shows “Reachable · Control token not paired,” finish pairing here before updating. In-app update, repair, and rollback require reachable `8576` and readable installerd status.

## 4. Agent reachable but installerd unavailable

If `8575` returns an Agent version but `8576` gives `Connection refused`, AVF is not necessarily offline, and repeatedly selecting Update will not fix it. Start with read-only checks in Debian Terminal:

```sh
sudo systemctl status airsim-agent airsim-installerd --no-pager
sudo journalctl -u airsim-installerd -n 80 --no-pager
dpkg-query -W airsim-avf-agent
```

If `airsim-installerd.service` exists but is not running:

```sh
sudo systemctl enable --now airsim-installerd.service
sudo systemctl is-active airsim-installerd.service
sudo airsim-avf-pair
```

A missing unit indicates an incomplete installation or older layout; first check for `current.deb`. The repaired bootstrap validates its Debian identity and reinstalls service files if starting services fails. If the repair is not published or still fails, **preserve the package and data**, record `systemctl`/`journalctl` errors, and have the maintainer prepare a signed repair. Do not delete `current.deb` to bypass rollback protection. For a service that exits immediately, logs explain missing tokens, permissions, or binaries better than a port probe.

### `udev` / `libudev1` version mismatch

An error such as `udev depends libudev1 (= 252.39-1~deb12u2) but 252.38-1~deb12u1 is installed` concerns AVF Debian system-package state, not an AirSIM Agent dependency omission: `udev` requires exactly matching `libudev1`. Run read-only checks in the guest first:

```sh
apt-cache policy udev libudev1
sudo apt-get -s -f install
```

Inspect `Inst`, `Conf`, and `Remv` in the simulation. If it contains removals, system-package downgrades, packages from another distribution, or other unexpected changes, **stop** and do not run actual `apt --fix-broken install`. If the repository provides `libudev1` matching the current `udev`, simulate that exact version first (replace the example with the version from `apt-cache policy`):

```sh
sudo apt-get -s --no-remove install 'libudev1=252.39-1~deb12u2'
```

Only after confirming no other packages are removed or downgraded should you run the same command without `-s`, then `sudo apt-get check`, and retry AirSIM installation. `--no-remove` aborts if removal is required. Do not force completion with `--allow-remove-essential`, `--allow-downgrades`, or `dpkg --force`. The repaired AirSIM bootstrap uses `apt-get check` before installing the signed package and suggests these read-only checks on failure, without automatically changing system packages.

## 5. Acceptance and failure records

1. Terminal has an interactive Debian prompt; `avf_tap_fixed` exists.
2. Both `airsim-agent` and `airsim-installerd` are `active`; `/api/health` on `8575` returns `ok: true`, and `8576` is reachable.
3. `sudo airsim-avf-pair` shows address guidance and the control token; after saving, the app reports Agent and installerd online.
4. Then validate the default phone role, Shizuku authorization, VoWLAN/Relay, real calls, and bidirectional PCM. Agent health alone is not phone-link acceptance.

For failure reports, include phone model, Android/Terminal versions, Agent package version, both `systemctl status` results, redacted `journalctl`, connectivity to both ports, and installer exit code. Omit control tokens, real numbers, SMS, and PCM.
