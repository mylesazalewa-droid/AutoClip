import { test } from "node:test";
import assert from "node:assert/strict";
import { generateKeyPairSync, sign } from "node:crypto";
import { checkLicense } from "../lib/license.js";
import { costMicros, monthlyAllowance, monthKey } from "../lib/allowance.js";

// A throwaway key pair, made the way license-tool.swift makes keys (Ed25519)
const { publicKey, privateKey } = generateKeyPairSync("ed25519");
function makeKey(info) {
  const body = Buffer.from(JSON.stringify(info));
  return "AUTOCLIP-" + body.toString("base64") + "." + sign(null, body, privateKey).toString("base64");
}

test("a genuine license is accepted", () => {
  const k = makeKey({ id: "abc", name: "Grace Church", plan: "church", issued: 1_790_000_000 });
  assert.equal(checkLicense(k, Date.now(), publicKey)?.plan, "church");
});

test("an expired license is refused", () => {
  const k = makeKey({ id: "abc", name: "x", plan: "church", issued: 1, expires: 2 });
  assert.equal(checkLicense(k, Date.now(), publicKey), null);
});

test("a changed license is refused", () => {
  const k = makeKey({ id: "abc", name: "x", plan: "solo", issued: 1 });
  const [body, sig] = k.slice(9).split(".");
  const forged = JSON.parse(Buffer.from(body, "base64")); forged.plan = "lifetime";
  assert.equal(checkLicense("AUTOCLIP-" + Buffer.from(JSON.stringify(forged)).toString("base64") + "." + sig, Date.now(), publicKey), null);
});

test("a key signed by someone else is refused by the real public key", () => {
  assert.equal(checkLicense(makeKey({ id: "abc", name: "x", plan: "church", issued: 1 })), null);
  assert.equal(checkLicense("nonsense"), null);
  assert.equal(checkLicense(undefined), null);
});

test("cost follows Haiku prices", () => {
  assert.equal(costMicros("claude-haiku-5-5", 10_000, 1_000), 1_500);       // $0.0015
  assert.equal(costMicros("claude-haiku-5-5", 200_000, 1_000), 102_500);    // long prompt rate
  assert.equal(costMicros("claude-haiku-4-5", 10_000, 1_000), 15_000);
});

test("allowances default and follow the environment", () => {
  assert.equal(monthlyAllowance("church"), 5_000_000);
  assert.equal(monthlyAllowance("trial"), 250_000);
  process.env.ALLOWANCE_CHURCH = "12.5";
  assert.equal(monthlyAllowance("church"), 12_500_000);
  delete process.env.ALLOWANCE_CHURCH;
  assert.match(monthKey("abc", new Date("2026-11-12T00:00:00Z")), /^usage:abc:2026-11$/);
});

test("trial AI stays off without storage, and its allowance lasts the whole trial", async () => {
  const { trialEnabled, monthKey } = await import("../lib/allowance.js");
  delete process.env.UPSTASH_REDIS_REST_URL;
  assert.equal(trialEnabled(), false);
  process.env.UPSTASH_REDIS_REST_URL = "https://example.invalid";
  assert.equal(trialEnabled(), true);
  delete process.env.UPSTASH_REDIS_REST_URL;
  assert.match(monthKey("trial-abc"), /^usage:trial-abc:all$/);
});
