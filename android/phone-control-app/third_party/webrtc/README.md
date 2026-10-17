# Native WebRTC dependency

Pinned Maven artifact `io.github.webrtc-sdk:android:144.7559.15`, built from
https://github.com/webrtc-sdk/webrtc/commit/30d5e63ae91da483e06577b5c35ee91cc5e5c3db.

AAR: https://repo.maven.apache.org/maven2/io/github/webrtc-sdk/android/144.7559.15/android-144.7559.15.aar
SHA-256: `fc7c8d027eb33860ccbb7847988f7f942d44a92d1f575348bba6c0250cde4071`.
The build downloads, verifies and extracts the AAR. Binaries are not committed.

`org/webrtc/audio/WebRtcAudioTrack.java` replaces that one upstream class and its
nested classes in the compile/dex jar. It retains all JNI-referenced signatures
from the pinned source. The native JNI registration still resolves the same class.
No Android AudioTrack is created: a paced 10 ms loop sends decoded PCM to the
external loopback queue. Capture uses the SDK's `setAudioRecordEnabled(false)`
and `setAudioBufferCallback`, with a 10 ms callback clock and no AudioRecord.
Do not update the AAR without revalidating this ABI and running native loopback.

The AAR contains ARMv7, ARM64, x86 and x86_64 libraries, all packaged in the APK.
Java class version 61 matches the existing Java 17 build. The APK packages
uncompressed native libraries and uses zipalign's 16 KB shared-library alignment.

Upstream copyright and patent license are retained beside this file and packaged
as APK assets. `THIRD_PARTY_NOTICES.txt` supplements the release's BSD license with
35 dependency license files collected from the pinned SDK and DEPS revisions.
`notice-sources.json` records source URLs and hashes. This inclusive runtime
notice collection includes optional components; it is not an exact GN link audit.
