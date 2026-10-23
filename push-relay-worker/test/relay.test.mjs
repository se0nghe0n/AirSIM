import assert from "node:assert/strict";
import { createHash, createHmac, generateKeyPairSync, webcrypto } from "node:crypto";
import test from "node:test";
import worker, {
  bindMediaOwner,
  applyCallLifecycle,
  callControlMetadata,
  CallMediaSession,
  createProviderToken,
  DeviceCommandSession,
  selectMediaTransport,
  turnConfigured,
  validateRegistration,
} from "../src/index.mjs";
import { AgentStatusRegistry } from "../src/status-store.mjs";
import { readBoundedJSON, RequestBodyError } from "../src/request-body.mjs";

globalThis.crypto ??= webcrypto;

class MemoryKV {
  constructor() { this.values = new Map(); }
  async get(key) { return this.values.get(key) ?? null; }
  async put(key, value) { this.values.set(key, value); }
  async delete(key) { this.values.delete(key); }
  async list({ prefix = "", limit = 1000 } = {}) {
    return {
      keys: [...this.values.keys()].filter((key) => key.startsWith(prefix)).sort().slice(0, limit).map((name) => ({ name })),
      list_complete: true,
    };
  }
}

class WriteLimitedKV extends MemoryKV {
  async put() { throw new Error("KV daily write limit reached"); }
}

class ListLimitedKV extends MemoryKV {
  async list() { throw new Error("KV daily list limit reached"); }
}

class CountingKV extends MemoryKV {
  constructor() {
    super();
    this.operations = { get: 0, put: 0, delete: 0, list: 0 };
  }
  async get(key) { this.operations.get += 1; return super.get(key); }
  async put(key, value) { this.operations.put += 1; return super.put(key, value); }
  async delete(key) { this.operations.delete += 1; return super.delete(key); }
  async list(options) { this.operations.list += 1; return super.list(options); }
  resetOperations() { this.operations = { get: 0, put: 0, delete: 0, list: 0 }; }
}

class MemoryDurableStorage {
  constructor() {
    this.values = new Map();
    this.alarmAt = null;
  }
  async get(key) { return this.values.get(key); }
  async put(key, value) { this.values.set(key, value); }
  async delete(key) { this.values.delete(key); }
  async list({ prefix = "" } = {}) {
    return new Map([...this.values].filter(([key]) => key.startsWith(prefix)));
  }
  async setAlarm(value) { this.alarmAt = Number(value); }
  async getAlarm() { return this.alarmAt; }
  async deleteAlarm() { this.alarmAt = null; }
}

class MemoryStatusNamespace {
  constructor() {
    this.storage = new MemoryDurableStorage();
    this.registry = new AgentStatusRegistry({ storage: this.storage });
    this.fetchCount = 0;
  }
  idFromName(name) { return name; }
  get() { return { fetch: (request, options) => {
    this.fetchCount += 1;
    return this.registry.fetch(new Request(request, options));
  } }; }
}

class UnavailableStatusNamespace {
  idFromName(name) { return name; }
  get() { return { fetch: async () => new Response("unavailable", { status: 503 }) }; }
}

class MemoryMediaSocket {
  constructor(role) {
    this.attachment = { role, owner: false, pendingControl: "" };
    this.sent = [];
    this.closed = false;
  }
  deserializeAttachment() { return this.attachment; }
  serializeAttachment(value) { this.attachment = value; }
  send(value) { this.sent.push(value); }
  close() { this.closed = true; }
}

class MemoryMediaState {
  constructor(sockets = [], storage = new MemoryDurableStorage()) {
    this.sockets = sockets;
    this.storage = storage;
  }
  blockConcurrencyWhile(callback) { return callback(); }
  acceptWebSocket(socket) { this.sockets.push(socket); }
  getWebSockets(role) {
    return this.sockets.filter((socket) => !socket.closed && (!role || socket.attachment.role === role));
  }
}

class MemoryMediaNamespace {
  constructor() { this.sessions = new Map(); }
  idFromName(name) { return name; }
  get(id) {
    if (!this.sessions.has(id)) {
      const state = new MemoryMediaState();
      this.sessions.set(id, { state, session: new CallMediaSession(state, {}) });
    }
    return { fetch: (request, options) => this.sessions.get(id).session.fetch(new Request(request, options)) };
  }
  entry(id) { this.get(id); return this.sessions.get(id); }
  recreate(id) {
    const { state } = this.entry(id);
    const recreated = new MemoryMediaState(state.sockets, state.storage);
    this.sessions.set(id, { state: recreated, session: new CallMediaSession(recreated, {}) });
    return this.entry(id);
  }
}

class MemoryCommandState extends MemoryMediaState {
  constructor(sockets = []) {
    super(sockets);
    this.storage = new MemoryDurableStorage();
  }
}

class MemoryCommandNamespace {
  constructor() { this.sessions = new Map(); }
  idFromName(name) { return name; }
  get(id) {
    if (!this.sessions.has(id)) {
      const state = new MemoryCommandState();
      this.sessions.set(id, { state, session: new DeviceCommandSession(state) });
    }
    const value = this.sessions.get(id);
    return { fetch: (request, options) => value.session.fetch(new Request(request, options)) };
  }
  addAgent(deviceID, socket = new MemoryMediaSocket("agent")) {
    this.get(deviceID);
    this.sessions.get(deviceID).state.sockets.push(socket);
    return socket;
  }
  session(deviceID) { this.get(deviceID); return this.sessions.get(deviceID).session; }
}

function testEnvironment() {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  return {
    DEVICES: new MemoryKV(),
    APNS_TEAM_ID: "TEAMTEST01",
    APNS_KEY_ID: "KEYTEST001",
    APNS_P8: privateKey.export({ type: "pkcs8", format: "pem" }).toString(),
    ALLOWED_BUNDLE_ID: "com.example.airsim",
    DASHBOARD_TOKEN: "dashboard-test-token-0123456789",
    NEW_DEVICE_ENROLLMENT_ENABLED: "true",
  };
}

function post(path, value) {
  return new Request(`https://push.airsim.example${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(value),
  });
}

const registration = {
  device_id: "iphone-air",
  device_secret: "s".repeat(32),
  voip_token: "a".repeat(64),
  alert_token: "b".repeat(64),
  watch_voip_token: "c".repeat(64),
  watch_bundle_id: "com.example.airsim.watchkitapp",
  live_activity_push_to_start_token: "d".repeat(64),
  bundle_id: "com.example.airsim",
  environment: "sandbox",
  relay_url: "https://push.airsim.example",
};

test("health and registration persist without returning credentials", async () => {
  const env = testEnvironment();
  const health = await worker.fetch(new Request("https://push.airsim.example/healthz"), env);
  assert.equal(health.status, 200);
  assert.equal((await health.json()).version, "0.2.1");
  const response = await worker.fetch(post("/v1/devices/register", registration), env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { registered: true, media_transport: null });
  const stored = JSON.parse(await env.DEVICES.get("device:iphone-air"));
  assert.equal(stored.device_secret, undefined);
  assert.equal(stored.secret_hash.length, 64);
});

test("new enrollment is closed by default, while an existing device can renew its registration", async () => {
  const env = testEnvironment();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), {
    ...env, NEW_DEVICE_ENROLLMENT_ENABLED: "false",
  })).status, 403);
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), {
    ...env, NEW_DEVICE_ENROLLMENT_ENABLED: "false",
  })).status, 200);
});

test("temporary enrollment window has a global hourly quota", async () => {
  const env = { ...testEnvironment(), STATUS: new MemoryStatusNamespace() };
  for (let index = 0; index < 8; index++) {
    const candidate = { ...registration, device_id: `new-device-${index}` };
    assert.equal((await worker.fetch(post("/v1/devices/register", candidate), env)).status, 200);
  }
  assert.equal((await worker.fetch(post("/v1/devices/register", {
    ...registration, device_id: "new-device-9",
  }), env)).status, 429);
});

test("request bodies stop at their byte limit before buffering unbounded input", async () => {
  let cancelled = false;
  const body = new ReadableStream({
    pull(controller) { controller.enqueue(new Uint8Array(65 * 1024)); },
    cancel() { cancelled = true; },
  });
  const request = new Request("https://push.airsim.example/v1/devices/register", {
    method: "POST", body, duplex: "half",
  });
  const response = await worker.fetch(request, testEnvironment());
  assert.equal(response.status, 413);
  assert.equal(cancelled, true);
  await assert.rejects(readBoundedJSON(post("/test", [1]), 1024),
    (error) => error instanceof RequestBodyError && error.status === 400);
});

test("device registration remains available when KV daily writes are exhausted", async () => {
  const env = testEnvironment();
  env.DEVICES = new WriteLimitedKV();
  env.STATUS = new MemoryStatusNamespace();

  const response = await worker.fetch(post("/v1/devices/register", registration), env);

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { registered: true, media_transport: null });
  const stored = await env.STATUS.storage.get("device:iphone-air");
  assert.equal(stored.device_secret, undefined);
  assert.equal(stored.secret_hash.length, 64);
  const heartbeat = await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_version: "0.3.42",
    at_ok: true,
    cellular_state: "registered",
  }), env);
  assert.equal(heartbeat.status, 202);
});

test("incoming call delivery remains available when KV daily writes are exhausted", async () => {
  const env = testEnvironment();
  env.DEVICES = new WriteLimitedKV();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("", { status: 200 });
  try {
    const now = Date.now();
    const response = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call",
      device_id: registration.device_id,
      device_secret: registration.device_secret,
      call_id: "quota-call",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      call_secret: "quota-call-secret-0123456789abcdef",
      number: "10010",
      issued_at: new Date(now).toISOString(),
      expires_at: new Date(now + 45_000).toISOString(),
    }), env);
    assert.equal(response.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("healthy status registry keeps heartbeat and dashboard refresh off KV", async () => {
  const env = testEnvironment();
  env.DEVICES = new CountingKV();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  env.DEVICES.resetOperations();

  assert.equal((await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_version: "0.3.43",
    at_ok: true,
    cellular_state: "registered",
  }), env)).status, 202);
  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);

  assert.equal(response.status, 200);
  assert.equal((await response.json()).metrics.online, 1);
  assert.deepEqual(env.DEVICES.operations, { get: 0, put: 0, delete: 0, list: 0 });
});

test("heartbeat authenticates and writes with one durable request", async () => {
  const env = testEnvironment();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  env.STATUS.fetchCount = 0;

  const response = await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_id: "samsung-standalone",
    agent_kind: "standalone",
    agent_version: "standalone-0.1.0",
    at_ok: true,
    cellular_state: "registered",
  }), env);

  assert.equal(response.status, 202);
  assert.equal(env.STATUS.fetchCount, 1);
  const latest = await env.STATUS.storage.get("heartbeat:iphone-air");
  const agent = await env.STATUS.storage.get("heartbeat:iphone-air:agent:samsung-standalone");
  assert.equal(latest.agent_id, "samsung-standalone");
  assert.deepEqual(agent, latest);
  assert.equal(latest.device_secret, undefined);

  env.STATUS.fetchCount = 0;
  const denied = await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: "wrong-secret",
    agent_id: "attacker",
    at_ok: true,
    cellular_state: "registered",
  }), env);
  assert.equal(denied.status, 401);
  assert.equal(env.STATUS.fetchCount, 1);
  assert.equal(await env.STATUS.storage.get("heartbeat:iphone-air:agent:attacker"), undefined);
});

test("device status authenticates and reads agents with one durable request", async () => {
  const env = testEnvironment();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  assert.equal((await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat", device_id: registration.device_id,
    device_secret: registration.device_secret, agent_id: "samsung-standalone",
    at_ok: true, cellular_state: "registered",
  }), env)).status, 202);
  env.STATUS.fetchCount = 0;

  const response = await worker.fetch(post("/v1/devices/status", {
    device_id: registration.device_id, device_secret: registration.device_secret,
  }), env);
  const status = await response.json();
  assert.equal(response.status, 200);
  assert.equal(env.STATUS.fetchCount, 1);
  assert.equal(status.cloud_online, true);
  assert.equal(status.active_agent_id, "samsung-standalone");
  assert.equal(status.agents.length, 1);

  env.STATUS.fetchCount = 0;
  const denied = await worker.fetch(post("/v1/devices/status", {
    device_id: registration.device_id, device_secret: "wrong-secret",
  }), env);
  assert.equal(denied.status, 401);
  assert.equal(env.STATUS.fetchCount, 1);
});

test("one-request status still reads a pre-roster legacy heartbeat", async () => {
  const env = testEnvironment();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  await env.STATUS.storage.put("heartbeat:iphone-air", {
    received_at_ms: Date.now(), agent_id: "legacy", agent_version: "0.3.42",
    at_ok: true, cellular_state: "registered",
  });
  env.STATUS.fetchCount = 0;

  const response = await worker.fetch(post("/v1/devices/status", {
    device_id: registration.device_id, device_secret: registration.device_secret,
  }), env);
  const status = await response.json();
  assert.equal(response.status, 200);
  assert.equal(env.STATUS.fetchCount, 1);
  assert.equal(status.cloud_online, true);
  assert.equal(status.active_agent_id, "legacy");
  assert.equal(status.agents.length, 1);
});

test("one-request status falls back to a KV heartbeat during registry migration", async () => {
  const env = testEnvironment();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  await env.DEVICES.put("heartbeat:iphone-air:agent:legacy", JSON.stringify({
    received_at_ms: Date.now(), agent_id: "legacy", agent_version: "0.3.41",
    at_ok: true, cellular_state: "registered",
  }));
  env.STATUS.fetchCount = 0;

  const response = await worker.fetch(post("/v1/devices/status", {
    device_id: registration.device_id, device_secret: registration.device_secret,
  }), env);
  const status = await response.json();
  assert.equal(response.status, 200);
  assert.equal(env.STATUS.fetchCount, 1);
  assert.equal(status.cloud_online, true);
  assert.equal(status.active_agent_id, "legacy");
});

test("different devices register and authenticate independently", async () => {
  const env = testEnvironment();
  const second = {
    ...registration,
    device_id: "iphone-second",
    device_secret: "t".repeat(32),
    voip_token: "e".repeat(64),
    alert_token: "f".repeat(64),
  };
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  assert.equal((await worker.fetch(post("/v1/devices/register", second), env)).status, 200);

  for (const device of [registration, second]) {
    const response = await worker.fetch(post("/v1/events/heartbeat", {
      event: "agent_heartbeat",
      device_id: device.device_id,
      device_secret: device.device_secret,
      agent_version: "0.3.40",
      at_ok: true,
      cellular_state: "registered",
    }), env);
    assert.equal(response.status, 202);
  }
  assert.notEqual(
    (await env.DEVICES.get(`device:${registration.device_id}`)),
    (await env.DEVICES.get(`device:${second.device_id}`)),
  );
});

test("cloud dial and SMS commands are authenticated, device-scoped, and return Agent results", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  const second = {
    ...registration,
    device_id: "iphone-second",
    device_secret: "t".repeat(32),
    voip_token: "e".repeat(64),
    alert_token: "f".repeat(64),
  };
  await worker.fetch(post("/v1/devices/register", registration), env);
  await worker.fetch(post("/v1/devices/register", second), env);
  const agent = env.COMMANDS.addAgent(registration.device_id);
  const commandID = "2d33c399-1030-4e9a-90ea-bb429e16ac5a";
  const dial = await worker.fetch(post("/v1/commands/enqueue", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: commandID,
    type: "dial",
    number: "+86 186-8867-2253",
  }), env);
  assert.equal(dial.status, 202);
  const accepted = await dial.json();
  assert.equal(accepted.agent_connected, true);
  assert.equal(accepted.call.call_uuid.length, 36);
  assert.match(accepted.call.media_url, /^wss:\/\/push\.airsim\.example\/v1\/calls\//);
  assert.equal(agent.sent.length, 1);
  const delivered = JSON.parse(agent.sent[0]);
  assert.equal(delivered.number, "+8618688672253");
  assert.equal(delivered.call.direction, "outgoing");
  assert.equal(delivered.call.call_secret, accepted.call.call_secret);

  await env.COMMANDS.session(registration.device_id).webSocketMessage(agent, JSON.stringify({
    command_id: commandID,
    status: "completed",
    result: { dialing: true },
  }));
  const completed = await worker.fetch(post("/v1/commands/result", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: commandID,
  }), env);
  assert.equal(completed.status, 200);
  assert.equal((await completed.json()).result.dialing, true);

  const isolated = await worker.fetch(post("/v1/commands/result", {
    device_id: second.device_id,
    device_secret: second.device_secret,
    command_id: commandID,
  }), env);
  assert.equal(isolated.status, 404);
  const forged = await worker.fetch(post("/v1/commands/enqueue", {
    device_id: registration.device_id,
    device_secret: second.device_secret,
    command_id: crypto.randomUUID(),
    type: "send_sms",
    number: "10086",
    message: "Test",
  }), env);
  assert.equal(forged.status, 401);
});

test("dial accepts WebRTC and rejects a legacy PCM request", async () => {
  const env = { ...testEnvironment(), ...turnTestConfig, WEBRTC_TRANSPORT_READY: "true", WEBRTC_ROLLOUT_PERCENT: "100" };
  env.COMMANDS = new MemoryCommandNamespace();
  const capable = {
    ...registration,
    media_transport: "webrtc",
    app_media_capabilities: ["webrtc"],
    agent_media_capabilities: ["webrtc"],
  };
  assert.equal((await worker.fetch(post("/v1/devices/register", capable), env)).status, 200);
  env.COMMANDS.addAgent(registration.device_id);
  const dial = await worker.fetch(post("/v1/commands/enqueue", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: crypto.randomUUID(),
    type: "dial",
    number: "10086",
    media_transport: "legacy_pcm",
  }), env);
  assert.equal(dial.status, 400);
  const webRTC = await worker.fetch(post("/v1/commands/enqueue", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: crypto.randomUUID(),
    type: "dial",
    number: "10086",
    media_transport: "webrtc",
  }), env);
  assert.equal(webRTC.status, 202);
  assert.equal((await webRTC.json()).call.media_transport, "webrtc");
});

test("call control is durable, idempotent, and delivered after the Agent reconnects", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  const commandID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  await env.DEVICES.put(`call:${callUUID}`, JSON.stringify({
    device_id: registration.device_id,
    call_id: "call-9",
    call_uuid: callUUID,
    generation: 7,
    direction: "incoming",
    secret_hash: "unused-by-device-authenticated-control",
    expires_at: new Date(Date.now() + 45_000).toISOString(),
    media_expires_at: new Date(Date.now() + 60_000).toISOString(),
  }));
  const body = {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    action: "end",
    call_id: "call-9",
    call_uuid: callUUID,
    generation: 7,
    command_id: commandID,
    trace_id: "9f9dc60b",
    owner: "iphone",
  };

  const first = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, body), env);
  assert.equal(first.status, 202);
  assert.deepEqual(await first.json(), {
    accepted: true,
    command_id: commandID,
    status: "pending",
    agent_connected: false,
  });
  const second = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, body), env);
  assert.equal(second.status, 202);
  assert.equal((await second.json()).duplicate, true);
  const collision = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, {
    ...body,
    action: "reject",
  }), env);
  assert.equal(collision.status, 409);
  const state = env.COMMANDS.sessions.get(registration.device_id).state;
  assert.equal((await state.storage.list({ prefix: "command:" })).size, 1);
  assert.ok((await state.storage.getAlarm()) > Date.now());

  const agent = env.COMMANDS.addAgent(registration.device_id);
  await env.COMMANDS.session(registration.device_id).flushPending(agent);
  assert.equal(agent.sent.length, 1);
  const delivered = JSON.parse(agent.sent[0]);
  assert.equal(delivered.type, "call_control");
  assert.equal(delivered.action, "end");
  assert.equal(delivered.call.call_uuid, callUUID);
  assert.equal(delivered.call.generation, 7);

  await env.COMMANDS.session(registration.device_id).webSocketMessage(agent, JSON.stringify({
    command_id: commandID,
    status: "completed",
    result: { ended: true, modem_confirmed: true, clcc_attempts: 2 },
  }));
  const result = await worker.fetch(new Request(
    `https://push.airsim.example/v1/calls/${callUUID}/actions/${commandID}`,
    {
      headers: {
        authorization: `Bearer ${registration.device_secret}`,
        "x-airsim-device-id": registration.device_id,
      },
    },
  ), env);
  assert.equal(result.status, 200);
  const completed = await result.json();
  assert.equal(completed.status, "completed");
  assert.equal(completed.result.modem_confirmed, true);
  assert.equal(completed.result.clcc_attempts, 2);

  const completedDuplicate = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, body), env);
  assert.equal(completedDuplicate.status, 202);
  assert.deepEqual(await completedDuplicate.json(), {
    accepted: true,
    command_id: commandID,
    status: "completed",
    agent_connected: true,
    duplicate: true,
    result: { ended: true, modem_confirmed: true, clcc_attempts: 2 },
  });
});

test("call control rejects stale generations and cross-device reads", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  const secondDevice = {
    ...registration,
    device_id: "iphone-second",
    device_secret: "t".repeat(32),
    voip_token: "e".repeat(64),
  };
  await worker.fetch(post("/v1/devices/register", registration), env);
  await worker.fetch(post("/v1/devices/register", secondDevice), env);
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  const commandID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  await env.DEVICES.put(`call:${callUUID}`, JSON.stringify({
    device_id: registration.device_id,
    call_id: "call-9",
    call_uuid: callUUID,
    generation: 3,
    direction: "incoming",
    expires_at: new Date(Date.now() + 45_000).toISOString(),
    media_expires_at: new Date(Date.now() + 60_000).toISOString(),
  }));
  const stale = await worker.fetch(post(`/v1/calls/${callUUID}/actions`, {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    action: "end",
    call_id: "call-9",
    call_uuid: callUUID,
    generation: 2,
    command_id: commandID,
    trace_id: "trace-stale",
    owner: "iphone",
  }), env);
  assert.equal(stale.status, 409);

  const crossDevice = await worker.fetch(new Request(
    `https://push.airsim.example/v1/calls/${callUUID}/actions/${commandID}`,
    {
      headers: {
        authorization: `Bearer ${secondDevice.device_secret}`,
        "x-airsim-device-id": secondDevice.device_id,
      },
    },
  ), env);
  assert.equal(crossDevice.status, 403);
});

test("call control alarm backs off and expires an unconfirmed command without an Agent", async () => {
  const state = new MemoryCommandState();
  const storage = state.storage;
  const session = new DeviceCommandSession(state, {});
  const commandID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  const command = {
    command_id: commandID,
    type: "call_control",
    action: "end",
    expires_at: new Date(Date.now() + 30_000).toISOString(),
    call: { call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9" },
  };
  const accepted = await session.fetch(post("/enqueue", command));
  assert.equal(accepted.status, 202);
  const key = `command:${commandID}`;
  let stored = await storage.get(key);
  const firstAlarm = await storage.getAlarm();
  assert.ok(firstAlarm >= Date.now());
  assert.ok(firstAlarm <= Date.now() + 1_100);

  await session.alarm();
  stored = await storage.get(key);
  assert.equal(stored.retry_count, 1);
  const secondAlarm = await storage.getAlarm();
  assert.ok(secondAlarm >= Date.now() + 1_900);
  assert.ok(secondAlarm <= Date.now() + 2_100);

  stored.expires_at_ms = Date.now() - 1;
  await storage.put(key, stored);

  await session.alarm();

  const expired = await storage.get(key);
  assert.equal(expired.status, "expired");
  assert.match(expired.error, /expired/);
  assert.equal(await storage.getAlarm(), null);
});

test("unconfirmed hangup creates exactly one rescue command after eight seconds", async () => {
  const state = new MemoryCommandState();
  const session = new DeviceCommandSession(state, {});
  const parentID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  await session.fetch(post("/enqueue", {
    command_id: parentID,
    type: "call_control",
    action: "end",
    owner: "iphone",
    trace_id: "trace-rescue",
    issued_at: new Date().toISOString(),
    expires_at: new Date(Date.now() + 30_000).toISOString(),
    call: { call_id: "call-9", call_uuid: callUUID, generation: 7, direction: "incoming" },
  }));
  const parentKey = `command:${parentID}`;
  const parent = await state.storage.get(parentKey);
  parent.rescue_due_at_ms = Date.now() - 1;
  await state.storage.put(parentKey, parent);

  await session.alarm();
  await session.alarm();

  const records = await state.storage.list({ prefix: "command:" });
  const rescues = [...records.values()].filter((record) =>
    record.command?.action === "rescue_hangup");
  assert.equal(rescues.length, 1);
  assert.equal(rescues[0].command.parent_command_id, parentID);
  assert.equal(rescues[0].command.call.call_uuid, callUUID);
  assert.equal(rescues[0].command.call.generation, 7);
  const updatedParent = await state.storage.get(parentKey);
  assert.equal(updatedParent.rescue_command_id, rescues[0].command.command_id);

  const duplicate = await session.fetch(post("/enqueue", parent.command));
  const duplicateReceipt = await duplicate.json();
  assert.equal(duplicateReceipt.rescue_command_id, rescues[0].command.command_id);
});

test("heartbeat pull completes a rescue and propagates its modem result to the parent", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const parentID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145";
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  const session = env.COMMANDS.session(registration.device_id);
  await session.fetch(post("/enqueue", {
    command_id: parentID,
    type: "call_control",
    action: "end",
    owner: "iphone",
    trace_id: "trace-rescue",
    issued_at: new Date().toISOString(),
    expires_at: new Date(Date.now() + 30_000).toISOString(),
    call: { call_id: "call-9", call_uuid: callUUID, generation: 7, direction: "incoming" },
  }));
  const parentKey = `command:${parentID}`;
  const parent = await env.COMMANDS.sessions.get(registration.device_id).state.storage.get(parentKey);
  parent.rescue_due_at_ms = Date.now() - 1;
  await env.COMMANDS.sessions.get(registration.device_id).state.storage.put(parentKey, parent);
  await session.alarm();

  const pulled = await worker.fetch(post("/v1/commands/pull", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
  }), env);
  assert.equal(pulled.status, 200);
  const batch = await pulled.json();
  const rescue = batch.commands.find((command) => command.action === "rescue_hangup");
  assert.ok(rescue);
  assert.equal(rescue.parent_command_id, parentID);

  const completed = await worker.fetch(post("/v1/commands/complete", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    command_id: rescue.command_id,
    status: "completed",
    result: { ended: true, modem_confirmed: true, clcc_attempts: 1 },
  }), env);
  assert.equal(completed.status, 202);

  const parentResult = await session.fetch(new Request(
    `https://commands.internal/result/${parentID}?call_uuid=${callUUID}`,
  ));
  const parentReceipt = await parentResult.json();
  assert.equal(parentReceipt.status, "completed");
  assert.equal(parentReceipt.result.modem_confirmed, true);
  assert.equal(parentReceipt.rescue_command_id, rescue.command_id);
});

test("dashboard is public as a shell but protects and sanitizes operational data", async () => {
  const env = testEnvironment();
  const page = await worker.fetch(new Request("https://push.airsim.example/dashboard"), env);
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-security-policy"), /frame-ancestors 'none'/);
  const html = await page.text();
  assert.match(html, /Voice Relay/);
  assert.match(html, /<html lang="en">/);
  assert.doesNotMatch(html, /[\u3400-\u9fff]/);

  const denied = await worker.fetch(new Request("https://push.airsim.example/dashboard/api/summary"), env);
  assert.equal(denied.status, 401);

  await worker.fetch(post("/v1/devices/register", registration), env);
  await env.DEVICES.put(`heartbeat:${registration.device_id}`, JSON.stringify({
    received_at_ms: Date.now(), agent_version: "0.3.38", at_ok: true,
    cellular_state: "registered", ecm_carrier: "1", signal_dbm: -73,
  }));
  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);
  assert.equal(response.status, 200);
  const summary = await response.json();
  assert.equal(summary.metrics.devices, 1);
  assert.equal(summary.metrics.online, 1);
  assert.equal(summary.devices[0].environment, "sandbox");
  assert.equal(summary.devices[0].push.iphone, true);
  assert.notEqual(summary.devices[0].id, registration.device_id);
  const serialized = JSON.stringify(summary);
  for (const secret of [registration.device_secret, registration.voip_token, registration.alert_token]) {
    assert.equal(serialized.includes(secret), false);
  }
});

test("dashboard API reports missing server-side authentication configuration", async () => {
  const env = { ...testEnvironment(), DASHBOARD_TOKEN: "" };
  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: "Bearer anything" } },
  ), env);
  assert.equal(response.status, 503);
});

test("dashboard falls back to KV mirrors when status registry is unavailable", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  await env.DEVICES.put(`heartbeat:${registration.device_id}`, JSON.stringify({
    received_at_ms: Date.now(), agent_version: "0.3.43", at_ok: true,
    cellular_state: "registered", ecm_carrier: "1", signal_dbm: -71,
  }));
  env.STATUS = new UnavailableStatusNamespace();

  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);

  assert.equal(response.status, 200);
  const summary = await response.json();
  assert.equal(summary.service.version, "0.2.1");
  assert.equal(summary.metrics.devices, 1);
  assert.equal(summary.metrics.online, 1);
  assert.equal(summary.devices[0].agent_version, "0.3.43");
});

test("dashboard remains available when KV list quota is exhausted", async () => {
  const env = testEnvironment();
  env.DEVICES = new ListLimitedKV();
  env.STATUS = new MemoryStatusNamespace();
  assert.equal((await worker.fetch(post("/v1/devices/register", registration), env)).status, 200);
  assert.equal((await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_version: "0.3.43",
    at_ok: true,
    cellular_state: "registered",
  }), env)).status, 202);

  const response = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);

  assert.equal(response.status, 200);
  const summary = await response.json();
  assert.equal(summary.metrics.devices, 1);
  assert.equal(summary.metrics.online, 1);
  assert.equal(summary.events[0].type, "registration");
});

test("dashboard virtual call selects an opaque device and never stores TTS content", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const summaryResponse = await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env);
  const summary = await summaryResponse.json();
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const response = await worker.fetch(new Request(
      "https://push.airsim.example/dashboard/api/virtual-call",
      {
        method: "POST",
        headers: {
          authorization: `Bearer ${env.DASHBOARD_TOKEN}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          device_id: summary.devices[0].control_id,
          title: "Vibe Coding",
          content: "The content is complete. Please review this message.",
        }),
      },
    ), env);
    assert.equal(response.status, 202);
    assert.equal((await response.json()).sent, true);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 1);
  assert.equal(captured[0].options.headers["apns-push-type"], "voip");
  assert.equal(captured[0].payload.virtual_call, true);
  assert.equal(captured[0].payload.caller_name, "Vibe Coding");
  assert.equal(captured[0].payload.tts_text, "The content is complete. Please review this message.");
  assert.equal(JSON.stringify([...env.DEVICES.values.values()]).includes("The content is complete"), false);
});

test("dashboard virtual call requires auth, validates fields, and rate limits a device", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const summary = await (await worker.fetch(new Request(
    "https://push.airsim.example/dashboard/api/summary",
    { headers: { authorization: `Bearer ${env.DASHBOARD_TOKEN}` } },
  ), env)).json();
  const request = (headers, content = "Test announcement") => new Request(
    "https://push.airsim.example/dashboard/api/virtual-call",
    { method: "POST", headers, body: JSON.stringify({ device_id: summary.devices[0].control_id, title: "Test incoming call", content }) },
  );
  assert.equal((await worker.fetch(request({}), env)).status, 401);
  assert.equal((await worker.fetch(request({ authorization: `Bearer ${env.DASHBOARD_TOKEN}` }, ""), env)).status, 400);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("", { status: 200 });
  try {
    assert.equal((await worker.fetch(request({ authorization: `Bearer ${env.DASHBOARD_TOKEN}` }), env)).status, 202);
    assert.equal((await worker.fetch(request({ authorization: `Bearer ${env.DASHBOARD_TOKEN}` }), env)).status, 429);
  } finally { globalThis.fetch = originalFetch; }
});

test("relay sends iPhone VoIP, Watch VoIP, mirror alert, and SMS on distinct APNs topics", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    const call = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-1",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      call_secret: "watch-call-secret-0123456789abcdef",
      number: "10010", issued_at: now.toISOString(),
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    assert.equal(call.status, 202);
    const sms = await worker.fetch(post("/v1/events/sms", {
      event: "incoming_sms", device_id: registration.device_id,
      device_secret: registration.device_secret, delivery_id: "sms-1",
      sender: "10010", content: "Balance reminder", timestamp: now.toISOString(),
    }), env);
    assert.equal(sms.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 5);
  assert.equal(captured[0].options.headers["apns-push-type"], "voip");
  assert.equal(captured[0].options.headers["apns-topic"], "com.example.airsim.voip");
  assert.equal(captured[0].options.headers["apns-collapse-id"], "d9b59660-05bb-4ea8-9aeb-4505b35c93f9");
  assert.equal(captured[0].payload.call_secret, "watch-call-secret-0123456789abcdef");
  assert.equal(captured[0].payload.media_url, "wss://push.airsim.example/v1/calls/d9b59660-05bb-4ea8-9aeb-4505b35c93f9/connect");
  assert.equal(captured[1].options.headers["apns-push-type"], "voip");
  assert.equal(captured[1].options.headers["apns-topic"], "com.example.airsim.watchkitapp.voip");
  assert.equal(captured[1].options.headers["apns-collapse-id"], "d9b59660-05bb-4ea8-9aeb-4505b35c93f9");
  assert.equal(captured[1].payload.event, "incoming_call");
  assert.equal(captured[1].payload.call_secret, "watch-call-secret-0123456789abcdef");
  assert.equal(captured[2].options.headers["apns-push-type"], "alert");
  assert.equal(captured[2].options.headers["apns-topic"], "com.example.airsim");
  assert.equal(captured[2].payload.event, "incoming_call_mirror");
  assert.equal(captured[2].payload.aps.alert.title, "10010");
  assert.equal(captured[3].options.headers["apns-push-type"], "liveactivity");
  assert.equal(captured[3].options.headers["apns-topic"], "com.example.airsim.push-type.liveactivity");
  assert.equal(captured[3].payload.aps.event, "start");
  assert.equal(captured[3].payload.aps["input-push-token"], 1);
  assert.equal(captured[3].payload.aps["attributes-type"], "AirSIMCallActivityAttributes");
  assert.equal(captured[3].payload.aps["content-state"].callID, "call-1");
  assert.equal(captured[4].options.headers["apns-push-type"], "alert");
  assert.equal(captured[4].options.headers["apns-topic"], "com.example.airsim");
  assert.equal(captured[4].payload.aps.alert.body, "Balance reminder");

  const storedCall = JSON.parse(await env.DEVICES.get("call:d9b59660-05bb-4ea8-9aeb-4505b35c93f9"));
  assert.equal(storedCall.device_id, registration.device_id);
  assert.equal(storedCall.call_id, "call-1");
  assert.equal(storedCall.secret_hash.length, 64);
  assert.equal(storedCall.call_secret, undefined);
});

test("incoming call retries deduplicate VoIP and Watch alert by call UUID", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    const payload = {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-dedupe",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      call_secret: "watch-call-secret-0123456789abcdef",
      number: "10086", issued_at: now.toISOString(),
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    };
    const first = await worker.fetch(post("/v1/events/call", payload), env);
    const second = await worker.fetch(post("/v1/events/call", payload), env);
    assert.equal(first.status, 202);
    assert.equal(second.status, 202);
    assert.deepEqual(await second.json(), { duplicate: true, media_transport: null });
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 4);
});

test("registered ActivityKit update token is preferred over push-to-start and owner updates it", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const registered = await worker.fetch(post("/v1/live-activities/register", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    activity_id: "activity-1",
    call_id: "",
    update_token: "e".repeat(64),
  }), env);
  assert.equal(registered.status, 200);

  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-live",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      number: "10010", issued_at: now.toISOString(),
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    await worker.fetch(post("/v1/events/call-owner", {
      event: "call_owner", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-live",
      call_uuid: "d9b59660-05bb-4ea8-9aEB-4505b35c93f9",
      owner: "iphone", phase: "active",
    }), env);
  } finally {
    globalThis.fetch = originalFetch;
  }
  const live = captured.filter(item => item.options.headers["apns-push-type"] === "liveactivity");
  assert.equal(live.length, 2);
  assert.match(live[0].url, /e{64}$/);
  assert.equal(live[0].payload.aps.event, "update");
  assert.equal(live[0].payload.aps["content-state"].phase, "incoming");
  assert.equal(live[1].payload.aps["content-state"].phase, "active");
});

test("watch token requires the signed companion bundle id", () => {
  assert.equal(
    validateRegistration({ ...registration, watch_bundle_id: "com.attacker.watch" }, "com.example.airsim"),
    "watch bundle id is not allowed",
  );
  assert.equal(
    validateRegistration({ ...registration, watch_bundle_id: "" }, "com.example.airsim"),
    "watch bundle id is not allowed",
  );
});

test("Watch-only VoIP registration can receive a native Watch call", async () => {
  const env = testEnvironment();
  const watchOnly = { ...registration, voip_token: "", alert_token: "", live_activity_push_to_start_token: "" };
  assert.equal((await worker.fetch(post("/v1/devices/register", watchOnly), env)).status, 200);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    const response = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "watch-only-call",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      call_secret: "watch-call-secret-0123456789abcdef",
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    assert.equal(response.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 1);
  assert.equal(captured[0].options.headers["apns-topic"], "com.example.airsim.watchkitapp.voip");
});

test("Watch answer sends a background ownership event to iPhone CallKit", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const response = await worker.fetch(post("/v1/events/call-owner", {
      event: "call_owner", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "watch-call",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      owner: "watch", phase: "active",
    }), env);
    assert.equal(response.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 1);
  assert.equal(captured[0].options.headers["apns-push-type"], "background");
  assert.equal(captured[0].options.headers["apns-priority"], "5");
  assert.equal(captured[0].payload.event, "call_owner");
  assert.equal(captured[0].payload.owner, "watch");
});

test("legacy Agent call remains available on iPhone while Watch media is skipped", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ url, options });
    return new Response("", { status: 200 });
  };
  try {
    const now = new Date();
    const response = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "legacy-call",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    assert.equal(response.status, 202);
  } finally {
    globalThis.fetch = originalFetch;
  }
  assert.equal(captured.length, 3);
  assert.equal(captured[0].options.headers["apns-topic"], "com.example.airsim.voip");
  assert.equal(captured[1].options.headers["apns-push-type"], "alert");
  assert.equal(captured[2].options.headers["apns-push-type"], "liveactivity");
});

test("call websocket authenticates the per-call secret before reaching its durable object", async () => {
  const env = testEnvironment();
  const callUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
  const secret = "watch-call-secret-0123456789abcdef";
  await env.DEVICES.put(`call:${callUUID}`, JSON.stringify({
    device_id: registration.device_id,
    call_id: "call-media",
    secret_hash: createHash("sha256").update(secret).digest("hex"),
    expires_at: new Date(Date.now() - 10_000).toISOString(),
    media_expires_at: new Date(Date.now() + 60_000).toISOString(),
  }));
  const forwarded = [];
  env.MEDIA = {
    idFromName(name) { return name; },
    get(id) {
      return {
        async fetch(request) {
          forwarded.push({ id, role: request.headers.get("x-airsim-role") });
          return new Response("forwarded", { status: 200 });
        },
      };
    },
  };

  const connect = (role, token) => worker.fetch(new Request(
    `https://push.airsim.example/v1/calls/${callUUID}/connect?role=${role}&token=${token}`,
    { headers: { upgrade: "websocket" } },
  ), env);

  assert.equal((await connect("watch", "wrong-secret-value-0123456789")).status, 401);
  assert.equal((await connect("attacker", secret)).status, 400);
  assert.equal((await connect("watch", secret)).status, 200);
  assert.equal((await connect("iphone", secret)).status, 200);
  assert.deepEqual(forwarded, [
    { id: callUUID, role: "watch" },
    { id: callUUID, role: "iphone" },
  ]);
});

test("relay binds the authenticated client role into call control", () => {
  assert.equal(
    bindMediaOwner('{"action":"answer","call_id":"call-9"}', "iphone"),
    '{"action":"answer","call_id":"call-9","owner":"iphone"}',
  );
  assert.equal(bindMediaOwner(new Uint8Array([1, 2]), "iphone") instanceof Uint8Array, true);
});

test("relay preserves call control trace identity in receipts", () => {
  const message = bindMediaOwner(JSON.stringify({
    action: "end",
    call_id: "call-9",
    call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
    generation: 7,
    command_id: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145",
    trace_id: "9f9dc60b",
  }), "iphone");
  assert.deepEqual(callControlMetadata(message), {
    action: "end",
    call_id: "call-9",
    call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
    generation: 7,
    command_id: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145",
    trace_id: "9f9dc60b",
  });
});

test("relay queues answer until the Agent media socket connects", () => {
  const iphone = new MemoryMediaSocket("iphone");
  const state = new MemoryMediaState([iphone]);
  const session = new CallMediaSession(state, {});

  session.webSocketMessage(iphone, JSON.stringify({
    action: "answer", call_id: "call-9",
    call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", generation: 2,
    command_id: "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145", trace_id: "9f9dc60b",
  }));

  assert.equal(iphone.attachment.owner, true);
  assert.match(iphone.attachment.pendingControl, /"action":"answer"/);
  assert.match(iphone.attachment.pendingControl, /"owner":"iphone"/);
  assert.ok(iphone.sent.some((message) => message.includes("action_queued")));
  assert.ok(iphone.sent.some((message) => message.includes("9f9dc60b-3a36-4a0a-b87a-63a3ffb27145")));

  const agent = new MemoryMediaSocket("agent");
  state.sockets.push(agent);
  session.flushPendingControls(agent);

  assert.equal(agent.sent.length, 1);
  assert.match(agent.sent[0], /"action":"answer"/);
  assert.equal(iphone.attachment.pendingControl, "");
  assert.ok(iphone.sent.some((message) => message.includes("action_forwarded")));
});

test("binary frames close every media role and are not forwarded", () => {
  const agent = new MemoryMediaSocket("agent");
  const iphone = new MemoryMediaSocket("iphone");
  const watch = new MemoryMediaSocket("watch");
  const state = new MemoryMediaState([agent, iphone, watch]);
  const session = new CallMediaSession(state, {});

  session.webSocketMessage(iphone, JSON.stringify({ action: "answer", call_id: "call-9" }));
  agent.sent = [];
  iphone.sent = [];
  watch.sent = [];

  session.webSocketMessage(iphone, new Uint8Array([1, 2, 3, 4]));
  session.webSocketMessage(agent, new Uint8Array([5, 6, 7, 8]));
  session.webSocketMessage(watch, new Uint8Array([9]));

  assert.equal(iphone.closed, true);
  assert.equal(agent.closed, true);
  assert.equal(watch.closed, true);
  assert.deepEqual(agent.sent, []);
  assert.deepEqual(iphone.sent, []);
  assert.deepEqual(watch.sent, []);
});

test("selectMediaTransport returns webrtc or a rejection", () => {
  const capable = {
    deviceID: "device-rollout-a",
    requested: "webrtc",
    appCapabilities: ["webrtc"],
    agentCapabilities: ["webrtc"],
    relayCapabilities: ["webrtc"],
  };
  assert.equal(selectMediaTransport({ ...capable, rolloutPercent: 0 }), null);
  assert.equal(selectMediaTransport({ ...capable, requested: "", rolloutPercent: 100 }), null);
  assert.equal(selectMediaTransport({ ...capable, rolloutPercent: 100, forceLegacy: true }), null);
  assert.equal(selectMediaTransport({ ...capable, rolloutPercent: 100 }), "webrtc");
  assert.equal(
    selectMediaTransport({ ...capable, rolloutPercent: 100 }),
    selectMediaTransport({ ...capable, rolloutPercent: 100 }),
  );
  assert.equal(selectMediaTransport({
    ...capable, agentCapabilities: ["legacy_pcm"], rolloutPercent: 100,
  }), null);
});

test("media relay survives 50 answer reconnect and hangup cycles without cross-device control", () => {
  for (let round = 0; round < 50; round += 1) {
    const agent = new MemoryMediaSocket("agent");
    const iphone = new MemoryMediaSocket("iphone");
    const otherPhone = new MemoryMediaSocket("iphone");
    const state = new MemoryMediaState([agent, iphone, otherPhone]);
    const session = new CallMediaSession(state, {});
    const callID = `stress-${round}`;

    session.webSocketMessage(iphone, JSON.stringify({ action: "answer", call_id: callID }));
    assert.ok(agent.sent.some((message) => typeof message === "string" && message.includes('"action":"answer"')));
    assert.deepEqual(otherPhone.sent.filter((message) => typeof message === "string" && message.includes('"action":"answer"')), [], `round ${round} isolation`);
    agent.sent = [];
    iphone.sent = [];
    otherPhone.sent = [];

    state.sockets.splice(state.sockets.indexOf(agent), 1);
    const reconnectedAgent = new MemoryMediaSocket("agent");
    state.sockets.push(reconnectedAgent);
    session.flushPendingControls(reconnectedAgent);
    session.webSocketMessage(iphone, JSON.stringify({ action: "end", call_id: callID }));
    assert.ok(
      reconnectedAgent.sent.some((message) => typeof message === "string" && message.includes('"action":"end"')),
      `round ${round} hangup`,
    );
    session.webSocketMessage(reconnectedAgent, JSON.stringify({
      status: "remote_ended", call_id: callID,
    }));
    session.webSocketClose(iphone, 1000, "call ended");
    assert.equal(session.ownerRole(), "", `round ${round} residual owner`);
  }
});

test("agent heartbeat lets iPhone distinguish cloud-only from fully offline", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const heartbeat = await worker.fetch(post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_version: "0.3.35",
    agent_media_capabilities: ["webrtc"],
    at_ok: true,
    cellular_state: "searching",
    cellular_registration: "Searching",
    cellular_recovery: "Selecting a network automatically",
    ecm_carrier: "1",
  }), env);
  assert.equal(heartbeat.status, 202);

  const status = await worker.fetch(post("/v1/devices/status", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
  }), env);
  assert.equal(status.status, 200);
  assert.deepEqual(await status.json(), {
    cloud_online: true,
    agent_id: "legacy",
    agent_version: "0.3.35",
    agent_media_capabilities: ["webrtc"],
    at_ok: true,
    cellular_state: "searching",
    cellular_registration: "Searching",
    cellular_recovery: "Selecting a network automatically",
    ecm_carrier: "1",
    active_agent_id: "legacy",
    agents: [{
      agent_id: "legacy",
      agent_version: "0.3.35",
      agent_media_capabilities: ["webrtc"],
      at_ok: true,
      cellular_state: "searching",
      cellular_registration: "Searching",
      cellular_recovery: "Selecting a network automatically",
      ecm_carrier: "1",
      cloud_online: true,
    }],
  });
});

test("device status keeps standalone and AVF agents as separate routes", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const heartbeat = (agentID, kind, name, number) => post("/v1/events/heartbeat", {
    event: "agent_heartbeat",
    device_id: registration.device_id,
    device_secret: registration.device_secret,
    agent_id: agentID,
    agent_kind: kind,
    device_name: name,
    phone_number: number,
    agent_version: kind === "standalone" ? "standalone-0.1.0" : "0.4.4",
    at_ok: true,
    cellular_state: "registered",
  });

  assert.equal((await worker.fetch(heartbeat("xiaomi-standalone", "standalone", "Xiaomi 15", "+8613800000001"), env)).status, 202);
  await new Promise((resolve) => setTimeout(resolve, 2));
  assert.equal((await worker.fetch(heartbeat("samsung-avf", "avf", "Samsung Flip7", "+8613800000002"), env)).status, 202);

  const response = await worker.fetch(post("/v1/devices/status", {
    device_id: registration.device_id,
    device_secret: registration.device_secret,
  }), env);
  const status = await response.json();
  assert.equal(status.active_agent_id, "samsung-avf");
  assert.equal(status.agents.length, 2);
  assert.deepEqual(status.agents.map((agent) => agent.agent_id).sort(), ["samsung-avf", "xiaomi-standalone"]);
  assert.equal(status.agents.find((agent) => agent.agent_id === "xiaomi-standalone").phone_number, "+8613800000001");
});

test("wrong device secret is rejected before APNs", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const response = await worker.fetch(post("/v1/events/sms", {
    event: "incoming_sms", device_id: registration.device_id,
    device_secret: "wrong-secret-value", delivery_id: "sms-2",
    sender: "10010", content: "test", timestamp: new Date().toISOString(),
  }), env);
  assert.equal(response.status, 401);
});

test("delayed incoming SMS is delivered using its relay arrival time", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_url, options) => {
    captured.push(JSON.parse(options.body));
    return new Response("", { status: 200 });
  };
  try {
    const before = Date.now();
    const response = await worker.fetch(post("/v1/events/sms", {
      event: "incoming_sms", device_id: registration.device_id,
      device_secret: registration.device_secret, delivery_id: "delayed-sms-1",
      sender: "10010", content: "Late reminder",
      timestamp: new Date(before - 8 * 24 * 60 * 60 * 1000).toISOString(),
    }), env);
    const after = Date.now();
    assert.equal(response.status, 202);
    assert.equal(captured.length, 1);
    assert.equal(captured[0].delivery_id, "delayed-sms-1");
    assert.equal(captured[0].content, "Late reminder");
    assert.ok(Date.parse(captured[0].timestamp) >= before);
    assert.ok(Date.parse(captured[0].timestamp) <= after);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("incoming SMS without an originating address still reaches iPhone", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_url, options) => {
    captured.push(JSON.parse(options.body));
    return new Response("", { status: 200 });
  };
  try {
    const response = await worker.fetch(post("/v1/events/sms", {
      event: "incoming_sms", device_id: registration.device_id,
      device_secret: registration.device_secret, delivery_id: "senderless-sms-1",
      sender: "", content: "Carrier reminder", timestamp: new Date().toISOString(),
    }), env);
    assert.equal(response.status, 202);
    assert.equal(captured.length, 1);
    assert.equal(captured[0].sender, "Unknown number");
    assert.equal(captured[0].aps.alert.title, "Unknown number");
    assert.equal(captured[0].content, "Carrier reminder");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("registration is pinned to the signed app bundle", () => {
  assert.equal(validateRegistration({ ...registration, bundle_id: "com.attacker.app" }, "com.example.airsim"), "bundle id is not allowed");
  assert.equal(validateRegistration({ ...registration, device_id: "bad\nheader" }, "com.example.airsim"), "invalid device identity");
  assert.equal(validateRegistration({ ...registration, device_secret: `safe${"s".repeat(20)}\r\nInjected: yes` }, "com.example.airsim"), "invalid device identity");
});

test("provider JWT is ES256-shaped and names the Apple key", async () => {
  const env = testEnvironment();
  const token = await createProviderToken(env, Date.parse("2026-08-20T12:00:00Z"));
  const parts = token.split(".");
  assert.equal(parts.length, 3);
  const header = JSON.parse(Buffer.from(parts[0], "base64url").toString());
  const claims = JSON.parse(Buffer.from(parts[1], "base64url").toString());
  assert.deepEqual(header, { alg: "ES256", kid: "KEYTEST001" });
  assert.equal(claims.iss, "TEAMTEST01");
  assert.equal(Buffer.from(parts[2], "base64url").length, 64);
});

test("Agent call-state end returns the current Live Activity to cloud standby", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  await worker.fetch(post("/v1/live-activities/register", {
    device_id: registration.device_id, device_secret: registration.device_secret,
    activity_id: "activity-state", call_id: "call-state", update_token: "f".repeat(64),
  }), env);
  env.MEDIA = new MemoryMediaNamespace();
  await env.DEVICES.put("call:d9b59660-05bb-4ea8-9aeb-4505b35c93f9", JSON.stringify({
    device_id: registration.device_id, call_id: "call-state",
    call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", generation: 1,
  }));
  const captured = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    captured.push({ options, payload: JSON.parse(options.body) });
    return new Response("", { status: 200 });
  };
  try {
    const response = await worker.fetch(post("/v1/events/call-state", {
      event: "call_state", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-state",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9", phase: "ended",
    }), env);
    assert.equal(response.status, 202);
  } finally { globalThis.fetch = originalFetch; }
  assert.equal(captured.length, 1);
  assert.equal(captured[0].payload.aps.event, "update");
  assert.equal(captured[0].payload.aps["content-state"].phase, "cloud_standby");
  assert.equal(captured[0].payload.aps["content-state"].displayName, "Internet relay connected");
});

test("call lifecycle reducer rejects stale and terminal resurrection events", () => {
  const base = {
    call_id: "call-state", call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
    generation: 2, phase: "ended", source: "agent",
    timestamp: "2026-09-04T10:00:02.000Z", trace_id: "trace-ended",
  };
  assert.equal(applyCallLifecycle(base, {
    ...base, phase: "active", timestamp: "2026-09-04T10:00:03.000Z",
  }).accepted, false);
  assert.equal(applyCallLifecycle(base, {
    ...base, generation: 1, phase: "active", timestamp: "2026-09-04T10:00:03.000Z",
  }).reason, "stale_generation");
  const next = applyCallLifecycle(base, {
    ...base, generation: 3, phase: "ringing", timestamp: "2026-09-04T10:00:04.000Z",
  });
  assert.equal(next.accepted, true);
  assert.equal(next.snapshot.phase, "ringing");
});

test("expired ActivityKit token never turns a delivered VoIP call into a relay failure", async () => {
  const env = testEnvironment();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, options) => new Response(
    options.headers["apns-push-type"] === "liveactivity" ? '{"reason":"BadDeviceToken"}' : "",
    { status: options.headers["apns-push-type"] === "liveactivity" ? 410 : 200 },
  );
  try {
    const now = new Date();
    const response = await worker.fetch(post("/v1/events/call", {
      event: "incoming_call", device_id: registration.device_id,
      device_secret: registration.device_secret, call_id: "call-expired-activity",
      call_uuid: "d9b59660-05bb-4ea8-9aeb-4505b35c93f9",
      number: "10086", issued_at: now.toISOString(),
      expires_at: new Date(now.getTime() + 45_000).toISOString(),
    }), env);
    assert.equal(response.status, 202);
    assert.equal((await response.json()).pushed, true);
  } finally { globalThis.fetch = originalFetch; }
});

const webRTCCallUUID = "d9b59660-05bb-4ea8-9aeb-4505b35c93f9";
const turnTestConfig = {
  TURN_URLS: '["turn:relay.example:3478?transport=udp","turns:relay.example:5349?transport=tcp"]',
  TURN_SHARED_SECRET: "test-only-turn-rest-secret",
  STUN_URLS: '["stun:relay.example:3478"]',
};

async function iceTestEnvironment(overrides = {}) {
  const env = { ...testEnvironment(), ...turnTestConfig, ...overrides };
  await env.DEVICES.put(`call:${webRTCCallUUID}`, JSON.stringify({
    call_uuid: webRTCCallUUID, call_id: "ice-call", generation: 3,
    media_transport: "webrtc", secret_hash: createHash("sha256").update("call-secret").digest("hex"),
    media_expires_at: new Date(Date.now() + 7200_000).toISOString(),
  }));
  return env;
}

function iceRequest(role = "iphone", token = "call-secret") {
  return new Request(`https://push.airsim.example/v1/calls/${webRTCCallUUID}/ice?role=${role}`, {
    headers: { authorization: `Bearer ${token}` },
  });
}

test("ICE endpoint generates coturn REST HMAC-SHA1 credentials without caching", async () => {
  const env = await iceTestEnvironment();
  for (const role of ["iphone", "agent"]) {
    const response = await worker.fetch(iceRequest(role), env);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("cache-control"), "no-store");
    const body = await response.json();
    assert.equal(body.ttl, 3600);
    assert.deepEqual(body.ice_servers[0], { urls: ["stun:relay.example:3478"] });
    const turn = body.ice_servers[1];
    assert.deepEqual(turn.urls, JSON.parse(env.TURN_URLS));
    assert.ok(Math.abs(Number(turn.username.split(":")[0]) - Date.now() / 1000 - 3600) < 2);
    assert.ok(turn.username.endsWith(`:${webRTCCallUUID}:${role}`));
    assert.equal(turn.credential, createHmac("sha1", env.TURN_SHARED_SECRET).update(turn.username).digest("base64"));
    assert.equal(JSON.stringify(body).includes(env.TURN_SHARED_SECRET), false);
  }
  const record = JSON.parse(await env.DEVICES.get(`call:${webRTCCallUUID}`));
  assert.equal(record.credential, undefined);
});

test("ICE rejects unauthenticated, expired, invalid role, and missing TURN requests", async () => {
  const env = await iceTestEnvironment();
  assert.equal((await worker.fetch(iceRequest("iphone", "wrong"), env)).status, 401);
  assert.equal((await worker.fetch(iceRequest("watch"), env)).status, 400);
  assert.equal((await worker.fetch(iceRequest("iphone"), { ...env, TURN_SHARED_SECRET: "" })).status, 503);
  assert.equal((await worker.fetch(iceRequest("iphone"), { ...env, STUN_URLS: '["https://bad"]' })).status, 503);
  await env.DEVICES.put(`call:${webRTCCallUUID}`, JSON.stringify({
    secret_hash: createHash("sha256").update("call-secret").digest("hex"),
    expires_at: new Date(Date.now() - 6000).toISOString(),
  }));
  const response = await worker.fetch(iceRequest(), env);
  assert.equal(response.status, 410);
  assert.equal(response.headers.get("cache-control"), "no-store");
});

test("TURN URL validation and credential TTL are bounded by configuration and call expiry", async () => {
  for (const TURN_URLS of ['["https://relay.example"]', '["turn:user:secret@relay.example"]',
    '["turn:relay.example?transport=http"]', '["turn:relay.example/path"]', '["turn:relay.example:99999"]', '["turn:relay.example:0"]', 'null', '{}', '[]', 'invalid']) {
    assert.equal(turnConfigured({ ...turnTestConfig, TURN_URLS }), false, TURN_URLS);
  }
  assert.equal(turnConfigured(turnTestConfig), true);
  assert.equal(turnConfigured({ ...turnTestConfig, TURN_URLS: '["turn:[::1]:3478?transport=udp"]' }), true);
  for (const [configured, expected] of [["1", 60], ["invalid", 3600], ["999999", 86400]]) {
    const env = await iceTestEnvironment({ TURN_TTL_SECONDS: configured });
    const call = JSON.parse(await env.DEVICES.get(`call:${webRTCCallUUID}`));
    call.media_expires_at = new Date(Date.now() + 172800_000).toISOString();
    await env.DEVICES.put(`call:${webRTCCallUUID}`, JSON.stringify(call));
    const body = await (await worker.fetch(iceRequest(), env)).json();
    assert.equal(body.ttl, expected);
  }
  const env = await iceTestEnvironment();
  const call = JSON.parse(await env.DEVICES.get(`call:${webRTCCallUUID}`));
  call.media_expires_at = new Date(Date.now() + 30_000).toISOString();
  await env.DEVICES.put(`call:${webRTCCallUUID}`, JSON.stringify(call));
  const body = await (await worker.fetch(iceRequest(), env)).json();
  assert.ok(body.ttl > 0 && body.ttl <= 30);
  assert.ok(Number(body.ice_servers[1].username.split(":")[0]) * 1000 <= Date.parse(call.media_expires_at));
});

test("server rollout requires TURN and returns the negotiated registration and dial transport", async () => {
  const env = { ...testEnvironment(), WEBRTC_TRANSPORT_READY: "true", WEBRTC_ROLLOUT_PERCENT: "100" };
  env.COMMANDS = new MemoryCommandNamespace();
  const capable = { ...registration, media_transport: "webrtc",
    app_media_capabilities: ["webrtc"], agent_media_capabilities: ["webrtc"] };
  let response = await worker.fetch(post("/v1/devices/register", capable), env);
  assert.equal((await response.json()).media_transport, null);
  Object.assign(env, turnTestConfig);
  response = await worker.fetch(post("/v1/devices/register", capable), env);
  assert.equal((await response.json()).media_transport, "webrtc");
  env.COMMANDS.addAgent(registration.device_id);
  const dial = await worker.fetch(post("/v1/commands/enqueue", { device_id: registration.device_id,
    device_secret: registration.device_secret, command_id: crypto.randomUUID(), type: "dial",
    number: "10086", media_transport: "webrtc" }), env);
  assert.equal(dial.status, 202);
  assert.equal((await dial.json()).call.media_transport, "webrtc");
  const rejected = await worker.fetch(post("/v1/commands/enqueue", { device_id: registration.device_id,
    device_secret: registration.device_secret, command_id: crypto.randomUUID(), type: "dial",
    number: "10086", media_transport: "legacy_pcm" }), env);
  assert.equal(rejected.status, 400);
  const legacy = { ...capable, agent_media_capabilities: ["legacy_pcm"] };
  assert.equal((await (await worker.fetch(post("/v1/devices/register", legacy), env)).json()).media_transport, null);
});

function webRTCSession() {
  const iphone = new MemoryMediaSocket("iphone");
  const agent = new MemoryMediaSocket("agent");
  const watch = new MemoryMediaSocket("watch");
  for (const socket of [iphone, agent, watch]) Object.assign(socket.attachment, {
    callUUID: webRTCCallUUID, generation: 3,
    mediaTransport: socket === watch ? "" : "webrtc",
  });
  const state = new MemoryMediaState([iphone, agent, watch]);
  const relay = new CallMediaSession(state, {});
  relay.webSocketMessage(iphone, JSON.stringify({ action: "answer" }));
  for (const socket of [iphone, agent, watch]) socket.sent = [];
  return { relay, state, iphone, agent, watch };
}

function signaling(action, sessionID = "9f9dc60b-3a36-4a0a-b87a-63a3ffb27145", extras = {}) {
  return JSON.stringify({ action, call_uuid: webRTCCallUUID, generation: 3, session_id: sessionID,
    ...(action === "webrtc_ice" ? { candidate: { candidate: "candidate:1 1 UDP 1 127.0.0.1 9000 typ host", sdp_mid: "0", sdp_mline_index: 0 } } : { sdp: "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n" }), ...extras });
}

test("WebRTC relays bounded offer, answer and early ICE only between owning iPhone and agent", () => {
  const { relay, iphone, agent, watch } = webRTCSession();
  relay.webSocketMessage(iphone, signaling("webrtc_offer"));
  relay.webSocketMessage(iphone, signaling("webrtc_ice"));
  relay.webSocketMessage(agent, signaling("webrtc_ice"));
  relay.webSocketMessage(agent, signaling("webrtc_answer"));
  assert.equal(agent.sent.length, 2);
  assert.equal(iphone.sent.length, 2);
  assert.equal(watch.sent.length, 0);
  assert.equal(JSON.stringify(agent.attachment).includes("v=0"), false);
  assert.equal(JSON.stringify(agent.attachment).includes("candidate:"), false);
  relay.webSocketMessage(agent, signaling("webrtc_answer"));
  assert.match(agent.sent.at(-1), /session already answered/);
});

test("WebRTC rejects wrong roles, identity, stale sessions and oversized payloads", () => {
  const { relay, iphone, agent, watch } = webRTCSession();
  for (const [sender, message] of [
    [agent, signaling("webrtc_offer")], [iphone, signaling("webrtc_answer")],
    [iphone, signaling("webrtc_offer", undefined, { generation: 2 })],
    [iphone, signaling("webrtc_offer", undefined, { call_uuid: crypto.randomUUID() })],
    [iphone, signaling("webrtc_offer", "not-a-uuid")],
    [iphone, signaling("webrtc_offer", undefined, { sdp: "x".repeat(49 * 1024) })],
    [agent, signaling("webrtc_ice")],
  ]) {
    relay.webSocketMessage(sender, message);
    assert.match(sender.sent.at(-1), /webrtc_failed/);
  }
  agent.sent = []; iphone.sent = [];
  relay.webSocketMessage(iphone, signaling("webrtc_offer"));
  const sessionID = crypto.randomUUID();
  relay.webSocketMessage(iphone, signaling("webrtc_offer", sessionID));
  relay.webSocketMessage(agent, signaling("webrtc_answer"));
  assert.match(agent.sent.at(-1), /stale signaling session/);
  relay.webSocketMessage(iphone, signaling("webrtc_offer"));
  assert.match(iphone.sent.at(-1), /stale signaling session/);
  for (const candidate of [{ candidate: "x".repeat(4097), sdp_mline_index: 0 },
    { candidate: "x", sdp_mline_index: -1 }, { candidate: "x", sdp_mline_index: 0.5 },
    { candidate: "x", sdp_mid: "x".repeat(257), sdp_mline_index: 0 }]) {
    relay.webSocketMessage(agent, signaling("webrtc_ice", sessionID, { candidate }));
    assert.match(agent.sent.at(-1), /invalid ICE candidate/);
  }
});

test("binary frames close Watch sockets and Watch answers do not select legacy PCM", () => {
  const { relay, iphone, agent, watch } = webRTCSession();
  relay.webSocketMessage(iphone, new Uint8Array([1]));
  relay.webSocketMessage(agent, new Uint8Array([1]));
  relay.webSocketMessage(watch, new Uint8Array([1]));
  assert.equal(iphone.closed, true);
  assert.equal(agent.closed, true);
  assert.equal(watch.closed, true);
  const watch2 = new MemoryMediaSocket("watch");
  const agent2 = new MemoryMediaSocket("agent");
  agent2.attachment.mediaTransport = "webrtc";
  const relay2 = new CallMediaSession(new MemoryMediaState([watch2, agent2]), {});
  relay2.webSocketMessage(watch2, JSON.stringify({ action: "answer", media_transport: "webrtc" }));
  assert.equal(JSON.parse(agent2.sent.at(-1)).media_transport, undefined);
  relay2.webSocketMessage(agent2, new Uint8Array([2]));
  assert.equal(agent2.closed, true);
  assert.equal(watch2.sent.some((message) => message instanceof Uint8Array), false);
});

test("missing peers never queue SDP, and reconnect requires a fresh negotiation", async (t) => {
  const { relay, state, iphone, agent } = webRTCSession();
  relay.webSocketMessage(iphone, signaling("webrtc_offer"));
  relay.webSocketClose(agent, 1000, "disconnected");
  assert.equal(iphone.attachment.negotiation, undefined);
  relay.webSocketMessage(iphone, signaling("webrtc_offer", crypto.randomUUID()));
  assert.match(iphone.sent.at(-1), /peer unavailable/);
  assert.equal(iphone.attachment.pendingControl, "");
  const NativeResponse = globalThis.Response;
  t.mock.method(globalThis, "Response", function(body, init) {
    return init?.status === 101 ? { status: 101, webSocket: init.webSocket } : new NativeResponse(body, init);
  });
  globalThis.WebSocketPair = class {
    constructor() { this[0] = new MemoryMediaSocket("agent"); this[1] = new MemoryMediaSocket("agent"); }
  };
  t.after(() => { delete globalThis.WebSocketPair; });
  state.acceptWebSocket = (socket) => state.sockets.push(socket);
  const response = await relay.fetch(new Request("https://media.internal/session", { headers: {
    upgrade: "websocket", "x-airsim-role": "agent", "x-airsim-media-transport": "webrtc",
    "x-airsim-call-uuid": webRTCCallUUID, "x-airsim-generation": "3",
  } }));
  assert.equal(response.status, 101);
  const reconnected = state.getWebSockets("agent")[0];
  relay.webSocketMessage(reconnected, signaling("webrtc_answer"));
  assert.match(reconnected.sent.at(-1), /stale signaling session/);
  relay.webSocketMessage(agent, signaling("webrtc_answer"));
  assert.equal(agent.sent.filter((message) => typeof message === "string" && message.includes("webrtc_answer")).length, 0);
  const newSession = crypto.randomUUID();
  relay.webSocketMessage(iphone, signaling("webrtc_offer", newSession));
  relay.webSocketClose(agent, 1000, "late close callback");
  assert.equal(iphone.attachment.negotiation.sessionID, newSession);
  relay.webSocketMessage(reconnected, signaling("webrtc_answer", newSession));
  assert.equal(JSON.parse(iphone.sent.at(-1)).action, "webrtc_answer");
});

test("incoming transport is server negotiated for iPhone and Watch", async (t) => {
  const env = { ...testEnvironment(), ...turnTestConfig,
    WEBRTC_TRANSPORT_READY: "true", WEBRTC_ROLLOUT_PERCENT: "100" };
  const captured = [];
  t.mock.method(globalThis, "fetch", async (url, options) => {
    captured.push(JSON.parse(options.body));
    return new Response("", { status: 200 });
  });
  await worker.fetch(post("/v1/devices/register", { ...registration, media_transport: "webrtc",
    app_media_capabilities: ["webrtc"], agent_media_capabilities: ["webrtc"] }), env);
  const event = { event: "incoming_call", device_id: registration.device_id,
    device_secret: registration.device_secret, call_id: "negotiated-call",
    call_uuid: crypto.randomUUID(), call_secret: "call-secret-for-negotiation",
    number: "10010", issued_at: new Date().toISOString(),
    expires_at: new Date(Date.now() + 45000).toISOString(), media_transport: "webrtc" };
  const response = await worker.fetch(post("/v1/events/call", event), env);
  assert.equal(response.status, 202);
  assert.equal((await response.json()).media_transport, "webrtc");
  assert.equal(captured[0].media_transport, "webrtc");
  assert.equal(captured[1].media_transport, "webrtc");
  await worker.fetch(post("/v1/devices/register", { ...registration,
    media_transport: "legacy_pcm", app_media_capabilities: ["legacy_pcm"],
    agent_media_capabilities: ["legacy_pcm"] }), env);
  await env.DEVICES.delete(`call-lifecycle:${registration.device_id}`);
  const legacy = await worker.fetch(post("/v1/events/call", { ...event,
    call_uuid: crypto.randomUUID(), call_id: "legacy-call", generation: 2 }), env);
  assert.equal(legacy.status, 202);
  assert.equal((await legacy.json()).media_transport, null);
});

test("call connect authenticates and forwards authoritative transport and identity", async () => {
  const env = await iceTestEnvironment();
  let forwarded;
  env.MEDIA = { idFromName: (name) => name, get: () => ({ fetch: async (request) => {
    forwarded = request;
    return new Response("ok");
  } }) };
  const connect = (token, role = "iphone") => new Request(
    `https://push.airsim.example/v1/calls/${webRTCCallUUID}/connect?role=${role}`,
    { headers: { upgrade: "websocket", authorization: `Bearer ${token}`,
      "x-visitor-supplied": "should-not-pass",
      "x-airsim-media-transport": "legacy_pcm" } });
  assert.equal((await worker.fetch(connect("wrong"), env)).status, 401);
  assert.equal((await worker.fetch(connect("call-secret", "other"), env)).status, 400);
  assert.equal((await worker.fetch(new Request(
    `https://push.airsim.example/v1/calls/${webRTCCallUUID}/connect?role=iphone&token=call-secret`,
    { headers: { upgrade: "websocket" } }), env)).status, 401);
  env.WEBRTC_AGENT_QUERY_AUTH_ALLOWED = "true";
  assert.equal((await worker.fetch(new Request(
    `https://push.airsim.example/v1/calls/${webRTCCallUUID}/connect?role=iphone&token=call-secret`,
    { headers: { upgrade: "websocket" } }), env)).status, 401);
  assert.equal((await worker.fetch(new Request(
    `https://push.airsim.example/v1/calls/${webRTCCallUUID}/connect?role=agent&token=call-secret`,
    { headers: { upgrade: "websocket" } }), env)).status, 200);
  delete env.WEBRTC_AGENT_QUERY_AUTH_ALLOWED;
  assert.equal((await worker.fetch(connect("call-secret"), env)).status, 200);
  assert.equal(forwarded.headers.get("x-airsim-media-transport"), "webrtc");
  assert.equal(forwarded.headers.get("x-airsim-call-uuid"), webRTCCallUUID);
  assert.equal(forwarded.headers.get("x-airsim-generation"), "3");
  assert.equal(forwarded.headers.get("authorization"), null);
  assert.equal(forwarded.headers.get("x-visitor-supplied"), null);
  const call = JSON.parse(await env.DEVICES.get(`call:${webRTCCallUUID}`));
  call.media_expires_at = new Date(Date.now() - 6000).toISOString();
  await env.DEVICES.put(`call:${webRTCCallUUID}`, JSON.stringify(call));
  assert.equal((await worker.fetch(connect("call-secret"), env)).status, 410);
});

test("legacy and nonowner connections cannot send WebRTC and queued answer retains transport", () => {
  const iphone = new MemoryMediaSocket("iphone");
  iphone.attachment.mediaTransport = "webrtc";
  const state = new MemoryMediaState([iphone]);
  const relay = new CallMediaSession(state, {});
  relay.webSocketMessage(iphone, JSON.stringify({ action: "answer", media_transport: "legacy_pcm" }));
  assert.equal(JSON.parse(iphone.attachment.pendingControl).media_transport, "webrtc");
  const agent = new MemoryMediaSocket("agent");
  state.sockets.push(agent);
  relay.flushPendingControls(agent);
  assert.equal(JSON.parse(agent.sent.at(-1)).media_transport, "webrtc");
  agent.sent = [];
  relay.webSocketMessage(agent, signaling("webrtc_offer"));
  assert.match(agent.sent.at(-1), /invalid WebRTC owner or transport/);
  const intruder = new MemoryMediaSocket("iphone");
  intruder.attachment = { ...iphone.attachment, owner: false, pcmTraceKey: "intruder" };
  relay.webSocketMessage(intruder, signaling("webrtc_offer"));
  assert.equal(intruder.sent.length, 0);
});

test("heartbeat refreshes native capabilities on registry fast path and KV fallback without losing app capabilities", async () => {
  for (const useRegistry of [false, true]) {
    const env = { ...testEnvironment(), ...turnTestConfig, WEBRTC_TRANSPORT_READY: "true", WEBRTC_ROLLOUT_PERCENT: "100" };
    if (useRegistry) env.STATUS = new MemoryStatusNamespace();
    await worker.fetch(post("/v1/devices/register", { ...registration, media_transport: "webrtc",
      app_media_capabilities: ["legacy_pcm", "webrtc"] }), env);
    const heartbeat = { event: "agent_heartbeat", device_id: registration.device_id,
      device_secret: registration.device_secret, agent_id: "q25", at_ok: true,
      cellular_state: "registered", agent_media_capabilities: ["legacy_pcm", "webrtc"] };
    assert.equal((await worker.fetch(post("/v1/events/heartbeat", heartbeat), env)).status, 202);
    let registrationResponse = await worker.fetch(post("/v1/devices/register", registration), env);
    assert.equal((await registrationResponse.json()).media_transport, "webrtc");
    const oldAgent = { ...heartbeat };
    delete oldAgent.agent_media_capabilities;
    assert.equal((await worker.fetch(post("/v1/events/heartbeat", oldAgent), env)).status, 202);
    registrationResponse = await worker.fetch(post("/v1/devices/register", registration), env);
    assert.equal((await registrationResponse.json()).media_transport, "webrtc");
    const stored = useRegistry
      ? await env.STATUS.storage.get(`device:${registration.device_id}`)
      : JSON.parse(await env.DEVICES.get(`device:${registration.device_id}`));
    assert.deepEqual(stored.app_media_capabilities, ["webrtc"]);
    assert.deepEqual(stored.agent_media_capabilities, ["webrtc"]);
    assert.equal((await worker.fetch(post("/v1/events/heartbeat", {
      ...heartbeat, device_secret: "wrong",
    }), env)).status, 401);
  }
});

test("partial registrations preserve capabilities and explicit legacy override regardless registration order", async () => {
  for (const appFirst of [false, true]) {
    const env = { ...testEnvironment(), ...turnTestConfig, WEBRTC_TRANSPORT_READY: "true", WEBRTC_ROLLOUT_PERCENT: "100" };
    const app = { ...registration, media_transport: "webrtc", app_media_capabilities: ["webrtc"] };
    const agent = { ...registration, agent_media_capabilities: ["webrtc"] };
    await worker.fetch(post("/v1/devices/register", appFirst ? app : agent), env);
    const second = await worker.fetch(post("/v1/devices/register", appFirst ? agent : app), env);
    assert.equal((await second.json()).media_transport, "webrtc");
    await worker.fetch(post("/v1/devices/register", { ...registration, force_legacy_pcm: true }), env);
    const partial = await worker.fetch(post("/v1/devices/register", registration), env);
    assert.equal((await partial.json()).media_transport, null);
  }
});


test("signaling history fits hibernation attachments and cannot grow without bound", () => {
  const { relay, iphone, agent, state } = webRTCSession();
  const intruder = new MemoryMediaSocket("iphone");
  intruder.attachment = { ...iphone.attachment, owner: false };
  state.sockets.push(intruder);
  relay.webSocketMessage(intruder, signaling("webrtc_offer"));
  assert.match(intruder.sent.at(-1), /invalid WebRTC owner/);
  state.sockets.pop();
  for (let count = 0; count < 24; count++) relay.webSocketMessage(iphone, signaling("webrtc_offer", crypto.randomUUID()));
  assert.ok(new TextEncoder().encode(JSON.stringify(iphone.attachment)).length < 2048);
  relay.webSocketMessage(iphone, signaling("webrtc_offer", crypto.randomUUID()));
  assert.match(iphone.sent.at(-1), /negotiation limit/);
  assert.equal(agent.attachment.usedSessions.length, 24);
});

const managedTURNConfig = {
  TURN_PROVIDER: "cloudflare", CLOUDFLARE_TURN_KEY_ID: "test-key-id",
  CLOUDFLARE_TURN_API_TOKEN: "test-only-managed-token",
};

test("managed Cloudflare TURN validates configuration and returns sanitized credentials", async (t) => {
  const env = await iceTestEnvironment(managedTURNConfig);
  assert.equal(turnConfigured(env), true);
  assert.equal(turnConfigured({ ...env, CLOUDFLARE_TURN_API_TOKEN: "" }), false);
  assert.equal(turnConfigured({ ...env, CLOUDFLARE_TURN_KEY_ID: "../another/key" }), false);
  assert.equal(turnConfigured({ ...env, TURN_PROVIDER: "unknown" }), false);
  let requested;
  t.mock.method(globalThis, "fetch", async (url, options) => {
    requested = { url, options };
    return new Response(JSON.stringify({ iceServers: [
      { urls: "stun:managed.example:3478", ignored: "discard" },
      { urls: ["turn:managed.example:3478?transport=udp"], username: "temporary-user", credential: "temporary-password", ignored: "discard" },
    ] }), { status: 201 });
  });
  const response = await worker.fetch(iceRequest(), env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const body = await response.json();
  assert.equal(body.ttl, 3600);
  assert.equal(requested.url, "https://rtc.live.cloudflare.com/v1/turn/keys/test-key-id/credentials/generate-ice-servers");
  assert.equal(requested.options.headers.authorization, `Bearer ${managedTURNConfig.CLOUDFLARE_TURN_API_TOKEN}`);
  assert.deepEqual(JSON.parse(requested.options.body), { ttl: 3600 });
  assert.equal(JSON.stringify(body).includes("ignored"), false);
  assert.equal(body.ice_servers.at(-1).credential, "temporary-password");
  assert.equal(JSON.stringify(body).includes(managedTURNConfig.CLOUDFLARE_TURN_API_TOKEN), false);
});

test("managed TURN credentials are reused for the same authenticated call and role", async (t) => {
  const env = await iceTestEnvironment(managedTURNConfig);
  env.STATUS = new MemoryStatusNamespace();
  let issued = 0;
  t.mock.method(globalThis, "fetch", async () => {
    issued += 1;
    return new Response(JSON.stringify({ iceServers: [{
      urls: ["turn:managed.example:3478?transport=udp"],
      username: "temporary-user", credential: "temporary-password",
    }] }), { status: 201 });
  });
  const first = await worker.fetch(iceRequest(), env);
  const second = await worker.fetch(iceRequest(), env);
  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.equal(issued, 1);
  assert.deepEqual((await first.json()).ice_servers, (await second.json()).ice_servers);
  assert.equal((await worker.fetch(iceRequest("iphone", "wrong"), env)).status, 401);
  assert.equal(issued, 1);
});

test("managed TURN failures, malformed responses and timeout fail closed without exposing provider secrets", async (t) => {
  const env = await iceTestEnvironment(managedTURNConfig);
  const invalidBodies = [ {}, { iceServers: [] },
    { iceServers: [{ urls: "stun:only-stun.example" }] },
    { iceServers: [{ urls: "turn:managed.example", username: "u" }] },
    { iceServers: [{ urls: "https://bad.example", username: "u", credential: "secret" }] },
    { iceServers: [{ urls: "turn:managed.example", username: "u", credential: "x".repeat(4097) }] },
  ];
  for (const body of invalidBodies) {
    const mock = t.mock.method(globalThis, "fetch", async () => new Response(JSON.stringify(body), { status: 201 }));
    const response = await worker.fetch(iceRequest(), env);
    assert.equal(response.status, 503);
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.equal((await response.text()).includes("secret"), false);
    mock.mock.restore();
  }
  let mock = t.mock.method(globalThis, "fetch", async () => new Response("provider secret", { status: 401 }));
  assert.equal((await worker.fetch(iceRequest(), env)).status, 503);
  mock.mock.restore();
  const nativeSetTimeout = globalThis.setTimeout;
  let requestedTimeout;
  t.mock.method(globalThis, "setTimeout", (callback, duration) => {
    requestedTimeout = duration;
    return nativeSetTimeout(callback, 1);
  });
  mock = t.mock.method(globalThis, "fetch", async (url, options) => new Promise((resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(new Error("provider secret aborted")));
  }));
  const response = await worker.fetch(iceRequest(), env);
  assert.equal(requestedTimeout, 5000);
  assert.equal(response.status, 503);
  assert.equal((await response.text()).includes("provider secret"), false);
});

test("late Watch connections and replacements preserve the owning iPhone WebRTC session", async (t) => {
  const { relay, state, iphone, agent } = webRTCSession();
  const sessionID = crypto.randomUUID();
  relay.webSocketMessage(iphone, signaling("webrtc_offer", sessionID));
  relay.webSocketMessage(agent, signaling("webrtc_answer", sessionID));
  const NativeResponse = globalThis.Response;
  t.mock.method(globalThis, "Response", function(body, init) {
    return init?.status === 101 ? { status: 101, webSocket: init.webSocket } : new NativeResponse(body, init);
  });
  globalThis.WebSocketPair = class {
    constructor() { this[0] = new MemoryMediaSocket("watch"); this[1] = new MemoryMediaSocket("watch"); }
  };
  t.after(() => { delete globalThis.WebSocketPair; });
  state.acceptWebSocket = (socket) => state.sockets.push(socket);
  for (let reconnect = 0; reconnect < 2; reconnect++) {
    const response = await relay.fetch(new Request("https://media.internal/session", { headers: {
      upgrade: "websocket", "x-airsim-role": "watch", "x-airsim-media-transport": "webrtc",
      "x-airsim-call-uuid": webRTCCallUUID, "x-airsim-generation": "3",
    } }));
    assert.equal(response.status, 101);
    assert.equal(iphone.attachment.negotiation.sessionID, sessionID);
    assert.equal(agent.attachment.negotiation.sessionID, sessionID);
    relay.webSocketMessage(iphone, signaling("webrtc_ice", sessionID));
    assert.equal(JSON.parse(agent.sent.at(-1)).action, "webrtc_ice");
    relay.webSocketMessage(agent, signaling("webrtc_ice", sessionID));
    assert.equal(JSON.parse(iphone.sent.at(-1)).action, "webrtc_ice");
    assert.equal(state.getWebSockets("watch")[0].attachment.mediaTransport, "webrtc");
  }
});

test("agent registration bootstraps app settings but cannot overwrite existing app transport policy", async () => {
  const env = { ...testEnvironment(), ...turnTestConfig,
    WEBRTC_TRANSPORT_READY: "true", WEBRTC_ROLLOUT_PERCENT: "100" };
  const bootstrap = { ...registration, registration_source: "agent", media_transport: "webrtc",
    app_media_capabilities: ["legacy_pcm", "webrtc"], agent_media_capabilities: ["legacy_pcm", "webrtc"] };
  const initial = await worker.fetch(post("/v1/devices/register", bootstrap), env);
  assert.equal((await initial.json()).media_transport, "webrtc");
  const stale = { ...bootstrap, media_transport: "legacy_pcm",
    app_media_capabilities: ["legacy_pcm"], force_legacy_pcm: true };
  const updated = await worker.fetch(post("/v1/devices/register", stale), env);
  assert.equal((await updated.json()).media_transport, "webrtc");
  let stored = JSON.parse(await env.DEVICES.get(`device:${registration.device_id}`));
  assert.equal(stored.media_transport_requested, "webrtc");
  assert.deepEqual(stored.app_media_capabilities, ["webrtc"]);
  assert.equal(stored.force_legacy_pcm, false);

  // A normal app registration still owns the policy and may force a rejection.
  await worker.fetch(post("/v1/devices/register", { ...registration, force_legacy_pcm: true }), env);
  await worker.fetch(post("/v1/devices/register", { ...stale, force_legacy_pcm: false,
    agent_media_capabilities: ["legacy_pcm"] }), env);
  stored = JSON.parse(await env.DEVICES.get(`device:${registration.device_id}`));
  assert.equal(stored.force_legacy_pcm, true);
  assert.equal(stored.media_transport_requested, "webrtc");
  assert.deepEqual(stored.app_media_capabilities, ["webrtc"]);
  assert.deepEqual(stored.agent_media_capabilities, []);
  assert.equal(stored.media_transport, null);

  // A registration that still names the removed transport cannot restore it.
  const noSource = { ...stale, force_legacy_pcm: false };
  delete noSource.registration_source;
  await worker.fetch(post("/v1/devices/register", noSource), env);
  stored = JSON.parse(await env.DEVICES.get(`device:${registration.device_id}`));
  assert.equal(stored.media_transport_requested, "webrtc");
  assert.deepEqual(stored.app_media_capabilities, []);
  assert.equal(stored.force_legacy_pcm, false);
});

async function terminalEnvironment() {
  const env = { ...testEnvironment(), MEDIA: new MemoryMediaNamespace() };
  await worker.fetch(post("/v1/devices/register", registration), env);
  await env.DEVICES.put(`call:${webRTCCallUUID}`, JSON.stringify({
    device_id: registration.device_id, call_id: "terminal-call", call_uuid: webRTCCallUUID,
    generation: 3, media_transport: "webrtc",
    secret_hash: createHash("sha256").update("call-secret").digest("hex"),
    media_expires_at: new Date(Date.now() + 7200_000).toISOString(),
  }));
  const event = { event: "call_state", device_id: registration.device_id,
    device_secret: registration.device_secret, call_id: "terminal-call", call_uuid: webRTCCallUUID,
    generation: 3, phase: "ended", timestamp: "2026-10-17T12:00:00Z" };
  return { env, event, ...env.MEDIA.entry(webRTCCallUUID) };
}

function terminalSocket(role, overrides = {}) {
  const socket = new MemoryMediaSocket(role);
  Object.assign(socket.attachment, { callID: "terminal-call", callUUID: webRTCCallUUID,
    generation: 3, mediaTransport: "webrtc", ...overrides });
  return socket;
}

function mockMediaUpgrade(t) {
  const NativeResponse = globalThis.Response;
  t.mock.method(globalThis, "Response", function(body, init) {
    return init?.status === 101 ? { status: 101, webSocket: init.webSocket } : new NativeResponse(body, init);
  });
  globalThis.WebSocketPair = class {
    constructor() { this[0] = new MemoryMediaSocket("iphone"); this[1] = new MemoryMediaSocket("iphone"); }
  };
  t.after(() => { delete globalThis.WebSocketPair; });
}

function terminalConnect(role = "iphone") {
  return new Request(`https://push.airsim.example/v1/calls/${webRTCCallUUID}/connect?role=${role}`, {
    headers: { upgrade: "websocket", authorization: "Bearer call-secret" },
  });
}

test("HTTP terminal lifecycle reaches matching WebRTC clients without ownership or socket closure", async () => {
  const { env, event, state } = await terminalEnvironment();
  const iphone = terminalSocket("iphone");
  const watch = terminalSocket("watch");
  const unrelated = terminalSocket("iphone", { generation: 2 });
  state.sockets.push(iphone, watch, unrelated, terminalSocket("agent"));
  const response = await worker.fetch(post("/v1/events/call-state", event), env);
  assert.equal(response.status, 202);
  const expected = { status: "remote_ended", call_id: event.call_id,
    call_uuid: event.call_uuid, generation: 3 };
  assert.deepEqual(iphone.sent.map(JSON.parse), [expected]);
  assert.deepEqual(watch.sent.map(JSON.parse), [expected]);
  assert.deepEqual(unrelated.sent, []);
  assert.equal(iphone.closed, false);
  const { session } = env.MEDIA.entry(webRTCCallUUID);
  session.webSocketClose(state.getWebSockets("agent")[0], 1000, "remote ended");
  assert.deepEqual(iphone.sent.map(JSON.parse), [expected]);
  assert.deepEqual(await state.storage.get("terminal"), expected);
});

test("terminal survives DO recreation and replays before reconnect can flush answers or negotiate", async (t) => {
  mockMediaUpgrade(t);
  const { env, event, state } = await terminalEnvironment();
  const iphone = terminalSocket("iphone", { owner: true, pendingControl: JSON.stringify({ action: "answer" }) });
  state.sockets.push(iphone);
  assert.equal((await worker.fetch(post("/v1/events/call-state", event), env)).status, 202);
  assert.equal(iphone.attachment.pendingControl, "");
  iphone.closed = true;
  const { session, state: recreated } = env.MEDIA.recreate(webRTCCallUUID);
  assert.equal((await worker.fetch(terminalConnect(), env)).status, 101);
  const reconnected = recreated.getWebSockets("iphone")[0];
  assert.deepEqual(reconnected.sent.map(JSON.parse).map((message) => message.status), ["remote_ended"]);
  assert.equal(reconnected.closed, false);
  assert.equal((await worker.fetch(terminalConnect("agent"), env)).status, 101);
  const agent = recreated.getWebSockets("agent")[0];
  assert.deepEqual(agent.sent, []);
  for (const message of [JSON.stringify({ action: "answer" }), signaling("webrtc_offer"),
    signaling("webrtc_ice"), new Uint8Array([1, 2])]) session.webSocketMessage(reconnected, message);
  session.webSocketMessage(agent, signaling("webrtc_answer"));
  session.webSocketMessage(agent, new Uint8Array([3, 4]));
  session.flushPendingControls(agent);
  assert.deepEqual(agent.sent, []);
  assert.ok(reconnected.sent.every((message) => JSON.parse(message).status === "remote_ended"));
  assert.equal(reconnected.attachment.owner, false);
});

test("terminal rejects wrong stored owner, call ID, UUID and both stale and future generations before mutation", async () => {
  for (const change of [{ device_id: "other-device" }, { call_id: "other-call" },
    { call_uuid: crypto.randomUUID() }, { generation: 2 }, { generation: 4 }]) {
    const { env, event, state } = await terminalEnvironment();
    const iphone = terminalSocket("iphone");
    state.sockets.push(iphone);
    const key = `call:${webRTCCallUUID}`;
    await env.DEVICES.put(key, JSON.stringify({ ...JSON.parse(await env.DEVICES.get(key)), ...change }));
    const lifecycleKey = `call-lifecycle:${registration.device_id}`;
    const before = JSON.stringify({ ...event, source: "agent", phase: "active", timestamp: "2026-10-17T11:00:00Z" });
    await env.DEVICES.put(lifecycleKey, before);
    const response = await worker.fetch(post("/v1/events/call-state", event), env);
    assert.equal(response.status, 409, JSON.stringify(change));
    assert.equal(await env.DEVICES.get(lifecycleKey), before);
    assert.deepEqual(iphone.sent, []);
    assert.equal(await state.storage.get("terminal"), undefined);
  }
});

test("terminal retries remain deliverable across APNs failure, duplicate and media failure", async (t) => {
  const { env, event, state } = await terminalEnvironment();
  const iphone = terminalSocket("iphone");
  state.sockets.push(iphone);
  await worker.fetch(post("/v1/live-activities/register", {
    device_id: registration.device_id, device_secret: registration.device_secret,
    activity_id: "terminal-activity", call_id: event.call_id, update_token: "f".repeat(64),
  }), env);
  let attempts = 0;
  t.mock.method(globalThis, "fetch", async () => {
    attempts += 1;
    return new Response(attempts === 1 ? '{"reason":"InternalServerError"}' : "", { status: attempts === 1 ? 500 : 200 });
  });
  assert.equal((await worker.fetch(post("/v1/events/call-state", event), env)).status, 502);
  assert.equal(iphone.sent.length, 1);
  assert.equal((await worker.fetch(post("/v1/events/call-state", event), env)).status, 202);
  const duplicate = await worker.fetch(post("/v1/events/call-state", event), env);
  assert.equal((await duplicate.json()).duplicate, true);
  assert.equal(iphone.sent.length, 3);
  assert.equal(attempts, 2);
  const send = iphone.send;
  iphone.send = () => { throw new Error("socket unavailable"); };
  assert.equal((await worker.fetch(post("/v1/events/call-state", event), env)).status, 503);
  iphone.send = send;
  assert.equal((await worker.fetch(post("/v1/events/call-state", event), env)).status, 202);
  assert.equal(iphone.sent.length, 4);
});

test("terminal storage failure leaves HTTP event retryable", async () => {
  const { env, event, state } = await terminalEnvironment();
  const put = state.storage.put;
  state.storage.put = async () => { throw new Error("storage unavailable"); };
  assert.equal((await worker.fetch(post("/v1/events/call-state", event), env)).status, 503);
  assert.equal(await env.DEVICES.get(`dedupe:call-state:${registration.device_id}:${webRTCCallUUID}:3:ended`), null);
  state.storage.put = put;
  assert.equal((await worker.fetch(post("/v1/events/call-state", event), env)).status, 202);
  assert.equal((await state.storage.get("terminal")).status, "remote_ended");
});

test("failed lifecycle while all clients are offline is replayed from durable storage", async (t) => {
  mockMediaUpgrade(t);
  const { env, event, state } = await terminalEnvironment();
  assert.equal(state.getWebSockets().length, 0);
  assert.equal((await worker.fetch(post("/v1/events/call-state", { ...event, phase: "failed" }), env)).status, 202);
  const { state: recreated } = env.MEDIA.recreate(webRTCCallUUID);
  assert.equal((await worker.fetch(terminalConnect(), env)).status, 101);
  const messages = recreated.getWebSockets("iphone")[0].sent.map(JSON.parse);
  assert.deepEqual(messages, [{ status: "remote_ended", call_id: event.call_id,
    call_uuid: event.call_uuid, generation: 3 }]);
});

test("old terminal retry after APNs failure drains without changing a newer call or its activity", async (t) => {
  mockMediaUpgrade(t);
  const { env, event, state } = await terminalEnvironment();
  const iphone = terminalSocket("iphone");
  state.sockets.push(iphone);
  await worker.fetch(post("/v1/live-activities/register", {
    device_id: registration.device_id, device_secret: registration.device_secret,
    activity_id: "old-activity", call_id: event.call_id, update_token: "f".repeat(64),
  }), env);
  let attempts = 0;
  t.mock.method(globalThis, "fetch", async () => {
    attempts += 1;
    return new Response('{"reason":"InternalServerError"}', { status: 500 });
  });
  assert.equal((await worker.fetch(post("/v1/events/call-state", event), env)).status, 502);
  assert.equal(iphone.sent.length, 1);
  const lifecycleKey = `call-lifecycle:${registration.device_id}`;
  const newer = JSON.stringify({ ...event, call_id: "new-call", call_uuid: crypto.randomUUID(),
    generation: 1, phase: "active", timestamp: "2026-10-17T12:01:00Z" });
  await env.DEVICES.put(lifecycleKey, newer);
  await worker.fetch(post("/v1/live-activities/register", {
    device_id: registration.device_id, device_secret: registration.device_secret,
    activity_id: "new-activity", call_id: "new-call", update_token: "e".repeat(64),
  }), env);
  const activityKey = `liveactivity:current:${registration.device_id}`;
  const activity = await env.DEVICES.get(activityKey);
  const retry = await worker.fetch(post("/v1/events/call-state", event), env);
  assert.equal(retry.status, 202);
  assert.equal((await retry.json()).obsolete, true);
  assert.equal(iphone.sent.length, 2);
  assert.equal(await env.DEVICES.get(lifecycleKey), newer);
  assert.equal(await env.DEVICES.get(activityKey), activity);
  assert.equal(attempts, 1);
  iphone.closed = true;
  const { state: recreated } = env.MEDIA.recreate(webRTCCallUUID);
  assert.equal((await worker.fetch(terminalConnect(), env)).status, 101);
  assert.deepEqual(recreated.getWebSockets("iphone")[0].sent.map(JSON.parse), [{
    status: "remote_ended", call_id: event.call_id, call_uuid: event.call_uuid, generation: 3,
  }]);
});

test("call history is authenticated, read-only, bounded, and device scoped", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  const second = { ...registration, device_id: "second", device_secret: "t".repeat(32) };
  await worker.fetch(post("/v1/devices/register", registration), env);
  await worker.fetch(post("/v1/devices/register", second), env);
  const agent = env.COMMANDS.addAgent(registration.device_id);
  const commandID = crypto.randomUUID();
  const input = { device_id: registration.device_id, device_secret: registration.device_secret,
    command_id: commandID, type: "call_history" };
  assert.equal((await worker.fetch(post("/v1/commands/enqueue", { ...input, device_secret: second.device_secret }), env)).status, 401);
  for (const fields of [{ limit: 0 }, { limit: 101 }, { limit: 1.2 }, { number: "123" },
    { message: "text" }, { call: {} }, { action: "dial" }, { media_transport: "webrtc" }]) {
    assert.equal((await worker.fetch(post("/v1/commands/enqueue", { ...input, ...fields }), env)).status, 400);
  }
  const response = await worker.fetch(post("/v1/commands/enqueue", input), env);
  assert.equal(response.status, 202);
  assert.equal((await response.json()).call, undefined);
  const command = JSON.parse(agent.sent[0]);
  assert.equal(command.limit, 100);
  assert.equal(command.number, undefined);
  assert.equal(command.call, undefined);
  assert.equal([...env.DEVICES.values.keys()].some(key => key.startsWith("call:")), false);
  assert.equal((await worker.fetch(post("/v1/commands/enqueue", { ...input, limit: 1 }), env)).status, 409);
  const row = { id: "calllog-android-test-1", index: 1, direction: "outgoing", state: "ended",
    number: "123", started_at: "2026-10-16T01:00:00Z", updated_at: "2026-10-16T01:01:00Z",
    ended_at: "2026-10-16T01:01:00Z", missed: false };
  const completion = { ...input, status: "completed", result: { history: Array.from({ length: 100 }, () => row) } };
  assert.equal((await worker.fetch(post("/v1/commands/complete", { ...completion, device_secret: "x".repeat(32) }), env)).status, 401);
  assert.equal((await worker.fetch(post("/v1/commands/complete", { ...completion,
    result: { history: Array.from({ length: 101 }, () => row) } }), env)).status, 400);
  assert.equal((await worker.fetch(post("/v1/commands/complete", { ...completion,
    result: { history: [row], extra: "x".repeat(61 * 1024) } }), env)).status, 400);
  for (const fields of [{ number: "x".repeat(83) }, { missed: "false" }, { started_at: "invalid" }, { state: "active" }]) {
    assert.equal((await worker.fetch(post("/v1/commands/complete", { ...completion,
      result: { history: [{ ...row, ...fields }] } }), env)).status, 400);
  }
  await env.COMMANDS.session(registration.device_id).webSocketMessage(agent, JSON.stringify({ ...completion,
    result: { history: Array.from({ length: 101 }, () => row) } }));
  const pending = await worker.fetch(post("/v1/commands/result", input), env);
  assert.notEqual((await pending.json()).status, "completed");
  assert.equal((await worker.fetch(post("/v1/commands/complete", completion), env)).status, 202);
  const result = await worker.fetch(post("/v1/commands/result", input), env);
  assert.equal((await result.json()).result.history.length, 100);
  assert.equal((await worker.fetch(post("/v1/commands/result", { ...input,
    device_id: second.device_id, device_secret: second.device_secret }), env)).status, 404);
});

test("history respects requested bounds and preserves explicit permission failures", async () => {
  const env = testEnvironment();
  env.COMMANDS = new MemoryCommandNamespace();
  await worker.fetch(post("/v1/devices/register", registration), env);
  const input = { device_id: registration.device_id, device_secret: registration.device_secret,
    command_id: crypto.randomUUID(), type: "call_history", limit: 1 };
  assert.equal((await worker.fetch(post("/v1/commands/enqueue", input), env)).status, 202);
  const row = { id: "native-1", index: 1, direction: "incoming", state: "ended", number: "",
    started_at: "2026-10-16T01:00:00Z", updated_at: "2026-10-16T01:00:00Z",
    ended_at: "2026-10-16T01:00:00Z", missed: true };
  assert.equal((await worker.fetch(post("/v1/commands/complete", { ...input, status: "completed",
    result: { history: [row, row] } }), env)).status, 400);
  assert.equal((await worker.fetch(post("/v1/commands/complete", { ...input, status: "failed",
    error: "Call history permission is not granted" }), env)).status, 202);
  const result = await (await worker.fetch(post("/v1/commands/result", input), env)).json();
  assert.equal(result.status, "failed");
  assert.equal(result.error, "Call history permission is not granted");
});
