import assert from "node:assert/strict";
import { generateKeyPairSync, webcrypto } from "node:crypto";
import test from "node:test";
import { APNsDeliveryError, createProviderToken, sendAPNs } from "../src/index.mjs";
globalThis.crypto ??= webcrypto;
function environment() {
  return { APNS_TEAM_ID: "TEAM", APNS_KEY_ID: "KEY", APNS_P8:
    generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ type: "pkcs8", format: "pem" }).toString() };
}
const options = { topic: "com.example.app", pushType: "alert", priority: "10", expiration: 123,
  collapseID: "delivery", payload: { aps: { alert: "private content" } } };
const device = { environment: "production" };

test("APNs exposes only status and allowlisted reasons without automatic retries", async t => {
  for (const [status, body, expected] of [
    [403, '{"reason":"InvalidProviderToken","extra":"private data"}', "InvalidProviderToken"],
    [403, '{"reason":"BadEnvironmentKeyIdInToken"}', "BadEnvironmentKeyIdInToken"],
    [400, '{"reason":"BadDeviceToken"}', "BadDeviceToken"],
    [429, '{"reason":"TooManyRequests"}', "TooManyRequests"],
    [503, '{"reason":"ServiceUnavailable"}', "ServiceUnavailable"],
    [403, '{"reason":"private credential"}', "UnknownReason"],
    [403, 'not JSON private data', "UnknownReason"],
    [403, JSON.stringify({ reason: "ExpiredProviderToken", extra: "x".repeat(4096) }), "UnknownReason"],
  ]) {
    const fetch = t.mock.method(globalThis, "fetch", async () => new Response(body, { status }));
    await assert.rejects(sendAPNs(environment(), device, "private-device-token", options), error => {
      assert.ok(error instanceof APNsDeliveryError);
      assert.equal(error.status, status);
      assert.equal(error.reason, expected);
      assert.equal(error.message, `APNs HTTP ${status}`);
      assert.doesNotMatch(JSON.stringify(error), /private|extra/);
      return true;
    });
    assert.equal(fetch.mock.callCount(), 1);
    fetch.mock.restore();
  }
});

test("expired JWT refresh retries once with an identical push and environment", async t => {
  const requests = [];
  t.mock.method(globalThis, "fetch", async (url, request) => {
    requests.push({ url, ...request });
    return requests.length === 1 ? new Response('{"reason":"ExpiredProviderToken"}', { status: 403 })
      : new Response(null, { status: 200 });
  });
  const env = environment();
  const old = await createProviderToken(env, Date.now() - 60_000);
  await sendAPNs(env, { environment: "sandbox" }, "device-token", options);
  assert.equal(requests.length, 2);
  assert.equal(requests[0].headers.authorization, `bearer ${old}`);
  assert.notEqual(requests[1].headers.authorization, requests[0].headers.authorization);
  assert.equal(requests[1].body, requests[0].body);
  assert.equal(requests[1].url, requests[0].url);
  assert.equal(requests[1].url, "https://api.sandbox.push.apple.com/3/device/device-token");
  const { authorization: ignored1, ...headers1 } = requests[0].headers;
  const { authorization: ignored2, ...headers2 } = requests[1].headers;
  assert.deepEqual(headers2, headers1);
});

test("repeated expired JWT refusal remains an error after two attempts", async t => {
  const fetch = t.mock.method(globalThis, "fetch", async () =>
    new Response('{"reason":"ExpiredProviderToken"}', { status: 403 }));
  await assert.rejects(sendAPNs(environment(), device, "token", options),
    { name: "APNsDeliveryError", status: 403, reason: "ExpiredProviderToken" });
  assert.equal(fetch.mock.callCount(), 2);
});

test("network failures are not retried because delivery may have occurred", async t => {
  const fetch = t.mock.method(globalThis, "fetch", async () => { throw new Error("network failure"); });
  await assert.rejects(sendAPNs(environment(), device, "token", options), /network failure/);
  assert.equal(fetch.mock.callCount(), 1);
});

test("provider cache follows signing material and rejects future cached issue times", async () => {
  const env = environment();
  const now = Date.now();
  const initial = await createProviderToken(env, now);
  assert.equal(await createProviderToken(env, now + 1000), initial);
  const rotated = { ...env, APNS_P8: environment().APNS_P8 };
  assert.notEqual(await createProviderToken(rotated, now), initial);
  const earlier = await createProviderToken(rotated, now - 60_000);
  const claims = JSON.parse(Buffer.from(earlier.split(".")[1], "base64url"));
  assert.equal(claims.iat, Math.floor((now - 60_000) / 1000));
});
