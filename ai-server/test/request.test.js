import { test } from "node:test";
import assert from "node:assert/strict";

process.env.ANTHROPIC_API_KEY ??= "test-key-not-used";
const { cleanRequest } = await import("../api/messages.js");

test("the app's normal request passes, capped", () => {
  const { req } = cleanRequest({ model: "claude-haiku-5-5", max_tokens: 99999, output_config: { effort: "low" },
    messages: [{ role: "user", content: "Pick clips" }] });
  assert.equal(req.max_tokens, 8192);
  assert.deepEqual(req.output_config, { effort: "low" });
});

test("other models, tools and images are refused", () => {
  assert.ok(cleanRequest({ model: "claude-opus-5-5", messages: [{ role: "user", content: "x" }] }).error);
  assert.ok(cleanRequest({ messages: [{ role: "user", content: [{ type: "image", source: {} }] }] }).error);
  assert.ok(cleanRequest({ messages: [] }).error);
  assert.ok(cleanRequest({ messages: [{ role: "user", content: "x".repeat(700_000) }] }).error);
});
