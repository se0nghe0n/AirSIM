import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { CallMediaSession } from "../src/index.mjs";
import { inspectPCMTrace, PCMRelayTrace } from "../src/pcm-trace.mjs";

globalThis.crypto ??= webcrypto;

function frame({ seq = 1, mono = 5000n, unix = 999999999999n } = {}) {
  const bytes = new Uint8Array(368);
  bytes.set([65, 83, 80, 77, 2, 0, 0, 48]);
  const view = new DataView(bytes.buffer);
  view.setUint32(8, seq);
  view.setUint32(12, 4);
  view.setBigUint64(16, mono);
  view.setBigUint64(24, unix);
  for (let index = 48; index < bytes.length; index += 1) bytes[index] = index % 256;
  return bytes;
}

class Socket {
  constructor(role, owner = false) {
    this.attachment = { role, owner };
    this.sent = [];
  }
  deserializeAttachment() { return this.attachment; }
  serializeAttachment(value) { this.attachment = value; }
  send(value) { this.sent.push(value); }
  close() {}
}

function session(sockets) {
  return new CallMediaSession({
    storage: { async get() { return undefined; } },
    blockConcurrencyWhile(callback) { return callback(); },
    getWebSockets(role) { return sockets.filter((socket) => !role || socket.attachment.role === role); },
  }, {});
}

test("v2 stamps independent peer copies with big endian receive/forward times and preserves source/PCM", (t) => {
  const agent = new Socket("agent");
  const iphone = new Socket("iphone");
  const watch = new Socket("watch");
  const relay = session([agent, iphone, watch]);
  const source = frame();
  const original = source.slice();
  let clock = 1700000000000;
  t.mock.method(Date, "now", () => clock++);
  relay.webSocketMessage(agent, source.buffer);
  assert.deepEqual(source, original);
  assert.equal(iphone.sent.length, 1);
  assert.equal(watch.sent.length, 1);
  assert.notEqual(iphone.sent[0], watch.sent[0]);
  // mediaPeers lists watch before iPhone when no owner is claimed.
  for (const [peer, expectedForward] of [[watch, 1700000000001n], [iphone, 1700000000002n]]) {
    const bytes = new Uint8Array(peer.sent[0]);
    const view = new DataView(peer.sent[0]);
    assert.equal(bytes.length, 368);
    assert.deepEqual(bytes.slice(0, 32), original.slice(0, 32));
    assert.deepEqual(bytes.slice(48), original.slice(48));
    assert.equal(view.getBigUint64(32), 1700000000000n);
    assert.equal(view.getBigUint64(40), expectedForward);
  }
});

test("raw 320 and batched 640 including ASPM v2 sample bytes and v1 pass through unchanged", () => {
  const agent = new Socket("agent");
  const iphone = new Socket("iphone", true);
  const relay = session([agent, iphone]);
  const raw = frame().slice(0, 320);
  const batched = new Uint8Array(640);
  batched.set(frame());
  const v1 = frame();
  v1[4] = 1;
  relay.webSocketMessage(agent, raw);
  relay.webSocketMessage(agent, batched);
  relay.webSocketMessage(agent, v1);
  assert.equal(iphone.sent[0], raw);
  assert.equal(iphone.sent[1], batched);
  assert.equal(iphone.sent[2], v1);
});

test("v2 malformed flags/header/size drop explicitly; non-v2 legacy remains compatible", (t) => {
  const warnings = [];
  t.mock.method(console, "warn", (message) => warnings.push(JSON.parse(message)));
  const agent = new Socket("agent");
  const iphone = new Socket("iphone", true);
  const relay = session([agent, iphone]);
  const badFlags = frame(); badFlags[5] = 1;
  const badHeader = frame(); badHeader[7] = 47;
  for (const bad of [badFlags, badHeader, frame().slice(0, 367), frame().slice(0, 5)]) {
    assert.equal(inspectPCMTrace(bad).kind, "invalid_v2");
    relay.webSocketMessage(agent, bad);
  }
  assert.equal(iphone.sent.length, 0);
  assert.equal(warnings.length, 1);
  assert.equal(warnings[0].reason, "invalid_v2_dropped");
  assert.equal(inspectPCMTrace(new Uint8Array([65, 83, 80, 77])).kind, "legacy");
});

test("v2 respects claimed owner in both directions and rejects nonowner PCM", () => {
  const agent = new Socket("agent");
  const iphone = new Socket("iphone", true);
  const watch = new Socket("watch");
  const relay = session([agent, iphone, watch]);
  relay.webSocketMessage(agent, frame());
  relay.webSocketMessage(iphone, frame());
  relay.webSocketMessage(watch, frame());
  assert.equal(iphone.sent.length, 1);
  assert.equal(agent.sent.length, 1);
  assert.ok(watch.sent.every((value) => typeof value === "string"));
});

test("relay send failure is bounded and counted without retry or throwing", (t) => {
  const warnings = [];
  const logs = [];
  t.mock.method(console, "warn", (message) => warnings.push(JSON.parse(message)));
  t.mock.method(console, "log", (message) => logs.push(JSON.parse(message)));
  const agent = new Socket("agent");
  const iphone = new Socket("iphone", true);
  let attempts = 0;
  iphone.send = () => { attempts += 1; throw new Error("must not appear in logs: secret URL"); };
  const relay = session([agent, iphone]);
  let now = 0;
  t.mock.method(performance, "now", () => now);
  relay.webSocketMessage(agent, frame());
  now = 500;
  relay.webSocketMessage(agent, frame());
  now = 1000;
  relay.webSocketMessage(agent, frame());
  assert.equal(attempts, 3);
  assert.equal(warnings.length, 2);
  assert.equal(warnings[0].reason, "send_failed");
  assert.equal(logs.length, 1);
  assert.equal(logs[0].received, 3);
  assert.equal(logs[0].forwarded, 0);
  assert.equal(logs[0].send_errors, 3);
  assert.ok(!JSON.stringify([...logs, ...warnings]).includes("secret URL"));
});

test("intervals compare source monotonic deltas to ingress independently of Unix clock offset", (t) => {
  const logs = [];
  t.mock.method(console, "log", (message) => logs.push(JSON.parse(message)));
  const telemetry = new PCMRelayTrace();
  const socket = {};
  let stream = telemetry.receive(socket, "agent", inspectPCMTrace(frame({ seq: 41 })), 100);
  telemetry.forwarded(stream, 101);
  stream = telemetry.receive(socket, "agent", inspectPCMTrace(frame({ seq: 42, mono: 5020n, unix: 1n })), 600);
  telemetry.forwarded(stream, 601);
  telemetry.flush(stream, 600);
  assert.equal(logs.length, 0);
  stream = telemetry.receive(socket, "agent", inspectPCMTrace(frame({ seq: 43, mono: 5040n, unix: 9999999999999n })), 1100);
  telemetry.forwarded(stream, 1101);
  telemetry.flush(stream, 1101);
  assert.equal(logs.length, 1);
  assert.equal(logs[0].source_delta_max_ms, 20);
  assert.equal(logs[0].ingress_gap_max_ms, 500);
  assert.equal(logs[0].ingress_minus_source_delta_max_ms, 480);
  assert.equal(logs[0].forward_gap_max_ms, 500);
  assert.equal(logs[0].source_seq_first, 41);
  assert.equal(logs[0].source_seq_last, 43);
  assert.equal(logs[0].forwarded, 3);
  telemetry.flush(stream, 1102);
  assert.equal(logs.length, 1);
  assert.notEqual(new PCMRelayTrace().instanceID, telemetry.instanceID);
});

test("stable connection attachment keeps interval history across host socket wrappers", (t) => {
  const logs = [];
  t.mock.method(console, "log", (message) => logs.push(JSON.parse(message)));
  let now = 100;
  t.mock.method(performance, "now", () => now);
  const firstWrapper = new Socket("agent");
  firstWrapper.attachment.pcmTraceKey = "connection-one";
  const iphone = new Socket("iphone", true);
  const relay = session([firstWrapper, iphone]);
  relay.webSocketMessage(firstWrapper, frame({ seq: 1 }));
  const secondWrapper = new Socket("agent");
  secondWrapper.attachment.pcmTraceKey = "connection-one";
  now = 1100;
  relay.webSocketMessage(secondWrapper, frame({ seq: 2, mono: 5020n }));
  assert.equal(logs.length, 1);
  assert.equal(logs[0].received, 2);
  assert.equal(logs[0].forwarded, 2);
  assert.equal(logs[0].source_seq_first, 1);
  assert.equal(logs[0].source_seq_last, 2);
  assert.equal(logs[0].ingress_gap_max_ms, 1000);
  assert.equal(logs[0].ingress_minus_source_delta_max_ms, 980);

  const replacement = new Socket("agent");
  replacement.attachment.pcmTraceKey = "connection-two";
  now = 1200;
  relay.webSocketMessage(replacement, frame({ seq: 3 }));
  assert.equal(logs.length, 1);
  now = 2200;
  relay.webSocketMessage(replacement, frame({ seq: 4, mono: 5020n }));
  assert.equal(logs.length, 2);
  assert.notEqual(logs[1].stream_id, logs[0].stream_id);
  assert.equal(logs[1].received, 2);
  assert.equal(logs[1].source_seq_first, 3);
  assert.equal(relay.pcmTrace.streams.size, 1);
});

test("trace stream map retains at most one connection per supported role", () => {
  const telemetry = new PCMRelayTrace();
  for (let generation = 0; generation < 20; generation += 1) {
    for (const role of ["agent", "iphone", "watch"]) {
      telemetry.receive({}, role, inspectPCMTrace(frame()), generation, `${role}-${generation}`);
    }
  }
  assert.equal(telemetry.streams.size, 3);
});
