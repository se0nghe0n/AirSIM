// Trace v2 wraps exactly one 20 ms / 8 kHz / PCM16 frame. Raw 320-byte
// messages and their nonempty batches remain raw, even when samples spell ASPM.
export function inspectPCMTrace(message) {
  const bytes = message instanceof ArrayBuffer
    ? new Uint8Array(message)
    : ArrayBuffer.isView(message)
      ? new Uint8Array(message.buffer, message.byteOffset, message.byteLength)
      : null;
  if (!bytes || (bytes.length > 0 && bytes.length % 320 === 0) || bytes.length < 5 ||
      bytes[0] !== 65 || bytes[1] !== 83 || bytes[2] !== 80 || bytes[3] !== 77 || bytes[4] !== 2) {
    return { kind: "legacy" };
  }
  if (bytes.length !== 368 || bytes[5] !== 0 || new DataView(
    bytes.buffer, bytes.byteOffset, bytes.byteLength,
  ).getUint16(6) !== 48) return { kind: "invalid_v2" };
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { kind: "v2", bytes, seq: view.getUint32(8), sourceMono: view.getBigUint64(16) };
}

export function stampPCMTrace(trace, receivedAt, forwardedAt) {
  const copy = trace.bytes.slice();
  const view = new DataView(copy.buffer);
  view.setBigUint64(32, BigInt(receivedAt));
  view.setBigUint64(40, BigInt(forwardedAt));
  return copy.buffer;
}

function interval() {
  return {
    received: 0, forwarded: 0, send_errors: 0, malformed_v2: 0,
    ingress_gap_max_ms: 0, forward_gap_max_ms: 0,
    source_delta_max_ms: 0, ingress_minus_source_delta_max_ms: null,
    source_seq_first: null, source_seq_last: null,
  };
}

// Deliberately memory-only: hibernation/reconstruction starts a new instance ID
// and loses interval history. There are no per-frame attachments or storage writes.
export class PCMRelayTrace {
  constructor() {
    this.instanceID = crypto.randomUUID();
    this.streams = new WeakMap();
    this.nextStreamID = 0;
  }

  receive(socket, role, trace, now) {
    let stream = this.streams.get(socket);
    if (!stream) {
      stream = {
        id: ++this.nextStreamID, role, since: now, lastLog: now,
        lastErrorLog: -Infinity, previousIngress: null, previousSource: null,
        previousForward: null, counts: interval(),
      };
      this.streams.set(socket, stream);
    }
    const counts = stream.counts;
    counts.received += 1;
    if (stream.previousIngress !== null) {
      const ingressDelta = now - stream.previousIngress;
      counts.ingress_gap_max_ms = Math.max(counts.ingress_gap_max_ms, ingressDelta);
      if (trace.kind === "v2" && stream.previousSource !== null) {
        // Compare durations, never subtract timestamps from different clocks.
        const sourceDelta = Number(trace.sourceMono - stream.previousSource);
        counts.source_delta_max_ms = Math.max(counts.source_delta_max_ms, sourceDelta);
        const excess = ingressDelta - sourceDelta;
        counts.ingress_minus_source_delta_max_ms = counts.ingress_minus_source_delta_max_ms === null
          ? excess : Math.max(counts.ingress_minus_source_delta_max_ms, excess);
      }
    }
    stream.previousIngress = now;
    stream.previousSource = trace.kind === "v2" ? trace.sourceMono : null;
    if (trace.kind === "v2") {
      counts.source_seq_first ??= trace.seq;
      counts.source_seq_last = trace.seq;
    }
    if (trace.kind === "invalid_v2") {
      counts.malformed_v2 += 1;
      this.error(stream, "invalid_v2_dropped", now);
    }
    return stream;
  }

  forwarded(stream, now) {
    stream.counts.forwarded += 1;
    if (stream.previousForward !== null) {
      stream.counts.forward_gap_max_ms = Math.max(
        stream.counts.forward_gap_max_ms, now - stream.previousForward,
      );
    }
    stream.previousForward = now;
  }

  sendFailed(stream, now) {
    stream.counts.send_errors += 1;
    this.error(stream, "send_failed", now);
  }

  error(stream, reason, now) {
    if (now - stream.lastErrorLog < 1000) return;
    stream.lastErrorLog = now;
    console.warn(JSON.stringify({
      event: "pcm_relay_error", instance_id: this.instanceID,
      stream_id: stream.id, role: stream.role, reason,
    }));
  }

  flush(stream, now) {
    if (now - stream.lastLog < 1000) return;
    console.log(JSON.stringify({
      event: "pcm_relay_trace", instance_id: this.instanceID,
      stream_id: stream.id, role: stream.role,
      interval_ms: now - stream.since, ...stream.counts,
    }));
    stream.lastLog = now;
    stream.since = now;
    stream.counts = interval();
  }
}
