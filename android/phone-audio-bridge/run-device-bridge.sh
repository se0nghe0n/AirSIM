#!/bin/sh
set -eu
echo 'The raw-audio device bridge is retired. Build Android Standalone and use its privileged WebRTC service.' >&2
echo 'Physical route validation is still required; see docs/webrtc-only-migration.md.' >&2
exit 1
