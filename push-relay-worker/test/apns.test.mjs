import assert from "node:assert/strict";
import { createPublicKey, generateKeyPairSync, verify, webcrypto } from "node:crypto";
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
    [403, '{"reason":"BadEnvironmentKeyInToken"}', "BadEnvironmentKeyInToken"],
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
  const old = await createProviderToken(env, Date.now() - 60_000, "sandbox");
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

test("environment selects its complete signing pair and keeps separate cached JWTs", async t => {
  const fallback = environment();
  const production = environment();
  const sandbox = environment();
  const env = { ...fallback, APNS_PRODUCTION_KEY_ID: "PROD", APNS_PRODUCTION_P8: production.APNS_P8,
    APNS_SANDBOX_KEY_ID: "SANDBOX", APNS_SANDBOX_P8: sandbox.APNS_P8 };
  const captured = [];
  t.mock.method(globalThis, "fetch", async (url, request) => {
    captured.push({ url, token: request.headers.authorization.slice(7) });
    return new Response(null, { status: 200 });
  });
  for (const environment of ["production", "sandbox", "production", "sandbox"]) {
    await sendAPNs(env, { environment }, "token", options);
  }
  for (const [index, keyID, p8, origin] of [
    [0, "PROD", production.APNS_P8, "https://api.push.apple.com/"],
    [1, "SANDBOX", sandbox.APNS_P8, "https://api.sandbox.push.apple.com/"],
  ]) {
    const { token, url } = captured[index];
    const [header, claims, signature] = token.split(".");
    assert.equal(JSON.parse(Buffer.from(header, "base64url")).kid, keyID);
    assert.equal(JSON.parse(Buffer.from(claims, "base64url")).iss, fallback.APNS_TEAM_ID);
    assert.ok(url.startsWith(origin));
    assert.ok(verify("sha256", Buffer.from(`${header}.${claims}`),
      { key: createPublicKey(p8), dsaEncoding: "ieee-p1363" }, Buffer.from(signature, "base64url")));
    assert.equal(captured[index + 2].token, token);
  }
});

test("unset environment pair falls back without inheriting the other environment override", async () => {
  const fallback = environment();
  const env = { ...fallback, APNS_PRODUCTION_KEY_ID: "PROD", APNS_PRODUCTION_P8: environment().APNS_P8 };
  const sandbox = await createProviderToken(env, Date.now(), "sandbox");
  assert.equal(JSON.parse(Buffer.from(sandbox.split(".")[0], "base64url")).kid, fallback.APNS_KEY_ID);
  const onlyScoped = { APNS_TEAM_ID: env.APNS_TEAM_ID,
    APNS_PRODUCTION_KEY_ID: env.APNS_PRODUCTION_KEY_ID, APNS_PRODUCTION_P8: env.APNS_PRODUCTION_P8 };
  assert.equal(JSON.parse(Buffer.from((await createProviderToken(onlyScoped)).split(".")[0], "base64url")).kid, "PROD");
  await assert.rejects(createProviderToken(onlyScoped, Date.now(), "sandbox"), /credentials are incomplete/);
});

test("partial or empty environment override fails before sending instead of mixing credentials", async t => {
  const fetch = t.mock.method(globalThis, "fetch", async () => new Response(null, { status: 200 }));
  for (const scope of ["PRODUCTION", "SANDBOX"]) {
    for (const override of [
      { [`APNS_${scope}_KEY_ID`]: "SCOPED" },
      { [`APNS_${scope}_P8`]: environment().APNS_P8 },
      { [`APNS_${scope}_KEY_ID`]: "", [`APNS_${scope}_P8`]: environment().APNS_P8 },
      { [`APNS_${scope}_KEY_ID`]: "SCOPED", [`APNS_${scope}_P8`]: " " },
    ]) {
      await assert.rejects(sendAPNs({ ...environment(), ...override },
        { environment: scope.toLowerCase() }, "token", options), /credentials are incomplete/);
    }
  }
  assert.equal(fetch.mock.callCount(), 0);
});

test("concurrent token creation shares signing work while environments retain independent tokens", async () => {
  const env = environment();
  const now = Date.now();
  const tokens = await Promise.all(Array.from({ length: 8 }, () => createProviderToken(env, now, "production")));
  assert.equal(new Set(tokens).size, 1);
  const sandbox = await createProviderToken(env, now, "sandbox");
  assert.equal(await createProviderToken(env, now + 1000, "production"), tokens[0]);
  assert.equal(await createProviderToken(env, now + 1000, "sandbox"), sandbox);
});

test("expired production override refresh preserves sandbox cache and production credential selection", async t => {
  const env = { ...environment(), APNS_PRODUCTION_KEY_ID: "PROD", APNS_PRODUCTION_P8: environment().APNS_P8 };
  const now = Date.now();
  const sandbox = await createProviderToken(env, now - 60_000, "sandbox");
  const production = await createProviderToken(env, now - 60_000, "production");
  const tokens = [];
  t.mock.method(globalThis, "fetch", async (_url, request) => {
    tokens.push(request.headers.authorization.slice(7));
    return tokens.length === 1 ? new Response('{"reason":"ExpiredProviderToken"}', { status: 403 })
      : new Response(null, { status: 200 });
  });
  await sendAPNs(env, device, "token", options);
  assert.equal(tokens.length, 2);
  assert.equal(tokens[0], production);
  assert.notEqual(tokens[1], production);
  assert.equal(JSON.parse(Buffer.from(tokens[1].split(".")[0], "base64url")).kid, "PROD");
  assert.equal(await createProviderToken(env, now, "sandbox"), sandbox);
});
