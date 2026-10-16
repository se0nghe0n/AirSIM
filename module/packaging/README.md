# AirSIM AVF Agent Debian Releases

AirSIM publishes one `arm64` Debian package for Android AVF Linux guests:

The Agent release documented here is [`v0.4.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.4.6) (package version `0.4.6-1`); the separate Android/iOS app release is [`v0.9.6`](https://github.com/kai-wu-cortex/AirSIM/releases/tag/v0.9.6). Do not substitute an application version for the Debian package version.

```text
airsim-avf-agent_<version>-<release>_arm64.deb
```

Samsung, Qualcomm, and MediaTek devices use the same Agent package. The Android app detects the AVF private network, Terminal, Shizuku, audio bridge, and system permissions at runtime. The Debian package contains only Linux services independent of the SoC vendor.

## Package layout

```text
/usr/bin/airsim-agent
/usr/bin/airsim-avf-pair
/usr/lib/airsim/airsim-installerd
/usr/lib/airsim/agent.env.default
/usr/lib/systemd/system/airsim-agent.service
/usr/lib/systemd/system/airsim-installerd.service
```

Persistent state resides in `/var/lib/airsim` and `/var/lib/airsim-installerd`. User configuration is in `/etc/airsim/agent.env` and survives upgrades. Service logs go to journald by default.

## Build and sign

Test the package structure:

```sh
./module/packaging/test.sh
```

For a release build, keep the Ed25519 private key outside the repository and inject the corresponding raw 32-byte public key into the installer as Base64:

```sh
AIRSIM_PACKAGE_VERSION=0.4.6 \
AIRSIM_PACKAGE_RELEASE=1 \
AIRSIM_RELEASE_PUBLIC_KEY_BASE64='<base64-raw-public-key>' \
AIRSIM_RELEASE_PRIVATE_KEY='/secure/path/release-ed25519.pem' \
./module/packaging/build-avf-deb.sh
```

The default output directory is `dist/`, containing `.deb`, `.sha256`, and a Base64-encoded `.sig`. Without a private key, the build produces only a development package and digest, which cannot pass installerd release-signature verification.

The Ed25519 release public key used since v0.4.5 is:

```text
Base64 raw key: QQPJXjO2mcx13qhv74lXen8ytjJZ2hMCz+ERlz6w5qg=
DER SHA-256:    4c39d5afdca2dddd8d22c0a5e02da18e7f07db789baac04bce4cfcd57491b3f4
```

The private key is stored in a restricted local directory outside the repository and backed up as GitHub Actions repository Secret `AIRSIM_RELEASE_PRIVATE_KEY_PEM`; never commit, print, or attach it to a Release. The old v0.4.4 public key is `7fGe7k6ZJ5xhU5Uljm97EPKRzfSJUULVnaHpUBT8Gho=`; its private key is no longer available. The old installerd cannot accept the new signature. Devices on `0.4.4-1` must rebuild trust through the [one-time key migration](../../docs/AVF_INSTALL_GUIDE.md), rather than simply uploading a newly signed package.

Upload all release files from the build directory to GitHub Releases. The Android app's update/repair action uses the versioned `.deb` and matching `.sig`; first installation uses the stable names `airsim-avf-agent_arm64.deb`, `airsim-avf-agent_arm64.deb.sig`, and `install-avf.sh`. The build embeds the same release public key in the bootstrap installer; it never downloads or trusts a replacement public key.

## Initial bootstrap

On first opening AVF Linux Terminal, wait for an interactive Debian prompt, then run this command. It supports first installation or service recovery from an existing package, but does not migrate an old signing trust root:

```sh
bash -o pipefail -c 'curl -fsSL --connect-timeout 10 --max-time 90 --retry 2 --proto =https --proto-redir =https --tlsv1.2 https://github.com/kai-wu-cortex/AirSIM/releases/download/v0.4.6/install-avf.sh | sudo sh'
```

`pipefail` prevents an empty-input `sudo sh` from masking a GitHub download failure. The script checks arm64, downloads the stable-named package, verifies its signature using the embedded Ed25519 key, and validates Debian package identity. After installation, it retains the initial rollback package and waits for `airsim-agent`, `airsim-installerd`, and the Agent health endpoint. Any failure exits nonzero and prints non-destructive troubleshooting commands instead of reporting completion. On success, run `sudo airsim-avf-pair` and save the current dynamic AVF guest address and token in the Android app. See the [AVF installation and non-destructive troubleshooting guide](../../docs/AVF_INSTALL_GUIDE.md).

This entry point also recovers an existing installation. If `current.deb` is retained, it first reloads, enables, and starts the services. Only if health checks still fail does it use `apt-get install --reinstall` with the local package to repair service files, without downloading a new package or overwriting rollback data. If recovery still fails, it prints systemd diagnostics and exits nonzero. Scripts in older GitHub Releases may still reject repeat execution; publish the updated `install-avf.sh` before expecting devices to receive this fix. Do not delete `current.deb` or clear AVF data to bypass this protection. The AVF image must provide `bash`, `curl`, `openssl`, `base64`, `dpkg-deb`, `apt-get`, `systemctl`, and `install`. Missing dependencies stop the script before system changes and are reported explicitly.

Before installation, `apt-get check` verifies the guest's existing Debian dependency state. A version mismatch between `udev` and `libudev1`, for example, stops installation; the script does not run `apt --fix-broken install`, which could remove system components. Inspect `apt-cache policy udev libudev1` and the simulated plan from `sudo apt-get -s -f install` before deciding whether to upgrade only the matching `libudev1`. See the [installation guide](../../docs/AVF_INSTALL_GUIDE.md).

When coexisting with DJOneHub, the AirSIM Agent exclusively uses `8575` and installerd uses `8576`, leaving the existing service on `7575` intact. The bootstrap checks both ports for other processes before writing the Debian package; Agent `/api/health` must also return `product=airsim`. **Older GitHub Releases do not contain this migration.** Do not run the online installer inside an AVF guest containing DJOneHub until the migrated package has been rebuilt, signed, and published.

For offline installation, use the release's `airsim-avf-bootstrap.sh` with its three-argument mode: the versioned `.deb`, `.sig`, and `.public.pem`. Verify the release public-key fingerprint through an independent trusted channel.

`rotate-avf-key.sh` is a one-time online migration asset exclusively for `0.4.4-1`. It checks the fixed old package digest, new package signature, and version, and attempts to restore the old package on failure. It is not a general updater. Since the old private key is lost, the migration script cannot be cross-signed with it. See the [v0.4.5 release notes](../../docs/releases/0.4.5.md) for migration details and the fixed SHA-256.

## Android management protocol

- `GET http://<AVF>:8576/v1/status`
- `POST http://<AVF>:8576/v1/packages/install`
- `POST http://<AVF>:8576/v1/packages/rollback`

All requests must originate from the AVF private network or loopback and include the shared bearer token. Installation requests use `application/vnd.debian.binary-package`, carry the `.deb` Ed25519 signature in `X-AirSIM-Signature`, and select `normal` or `repair` using `X-AirSIM-Install-Mode`. `normal` accepts only a newer version; `repair` accepts only the same installed version. Downgrades require the rollback endpoint and a retained server-side package. installerd accepts only package name `airsim-avf-agent` and architecture `arm64`; it exposes no arbitrary shell execution interface.

The installer retains the current and previous packages. If the initial rollback package is missing, it refuses an upgrade and requests another bootstrap. A new version is committed only after `dpkg` installation, Agent restart, and version health checks. Failed health checks automatically restore and verify the previous package. The Agent's former self-update endpoint returns `410 Gone` to prevent competing system writers.

## Uninstall behavior

A normal `apt remove` stops services but retains configuration, device identity, and rollback data. Only an explicit `apt purge airsim-avf-agent` clears `/etc/airsim`, `/var/lib/airsim`, and `/var/lib/airsim-installerd`.
