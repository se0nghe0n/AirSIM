#!/usr/bin/env python3
"""Extract the pinned SDK, excluding precisely the custom playout class family."""
import pathlib
import sys
import zipfile
import io

source, destination, native = map(pathlib.Path, sys.argv[1:])
with zipfile.ZipFile(source) as aar:
    with zipfile.ZipFile(io.BytesIO(aar.read('classes.jar'))) as original:
        with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as output:
            for entry in original.infolist():
                if (entry.filename == 'org/webrtc/audio/WebRtcAudioTrack.class'
                        or entry.filename.startswith('org/webrtc/audio/WebRtcAudioTrack$')):
                    continue
                output.writestr(entry, original.read(entry))
    for entry in aar.infolist():
        if entry.filename.startswith('jni/') and entry.filename.endswith('.so'):
            path = native / 'lib' / pathlib.PurePosixPath(entry.filename).relative_to('jni')
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(aar.read(entry))
