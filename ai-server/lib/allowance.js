import { Redis } from "@upstash/redis";


/**
 * Each license gets a monthly AI allowance, counted in millionths of a dollar of what the AI
 * actually cost (so it can't be gamed by counting requests). Amounts are set with environment
 * variables in dollars, e.g. ALLOWANCE_CHURCH=5. Defaults below.
 */
const DEFAULT_DOLLARS = { solo: 2, church: 5, lifetime: 5, trial: 0 };

export function monthlyAllowance(plan) {
  const fromEnv = process.env[`ALLOWANCE_${plan.toUpperCase()}`];
  const dollars = fromEnv !== undefined && fromEnv !== "" ? Number(fromEnv) : (DEFAULT_DOLLARS[plan] ?? 0);
  return Math.max(0, Math.round((Number.isFinite(dollars) ? dollars : 0) * 1_000_000));
}

/** Licenses switched off by hand (refunds, sharing): comma-separated ids in REVOKED_LICENSES */
export function isRevoked(id) {
  return (process.env.REVOKED_LICENSES ?? "").split(",").map((s) => s.trim()).filter(Boolean).includes(id);
}

/**
 * Price per million tokens, in dollars, by model and prompt size. From Anthropic's pricing:
 * Claude Haiku 5.5 is $0.10 in / $0.50 out up to 100K prompt tokens, $0.50 / $2.50 above;
 * Claude Haiku 4.5 is $1 / $5. Update when prices change.
 */
export function costMicros(model, input, output) {
  let inRate, outRate;
  if (model === "claude-haiku-5-5") {
    [inRate, outRate] = input > 100_000 ? [0.5, 2.5] : [0.1, 0.5];
  } else if (model === "claude-haiku-4-5") {
    [inRate, outRate] = [1, 5];
  } else {
    // Unknown model: count it at a high rate rather than for free
    [inRate, outRate] = [5, 25];
  }
  return Math.ceil(input * inRate + output * outRate); // tokens × $/MTok = millionths of a dollar
}

export function monthKey(id, now = new Date()) {
  return `usage:${id}:${now.toISOString().slice(0, 7)}`;
}

let redis = null;
function store() {
  // Reads UPSTASH_REDIS_REST_URL and UPSTASH_REDIS_REST_TOKEN (set automatically by Vercel's Upstash integration)
  redis ??= Redis.fromEnv();
  return redis;
}

export async function used(license) {
  return Number((await store().get(monthKey(license.id))) ?? 0);
}

export async function addUse(license, micros) {
  const k = monthKey(license.id);
  const total = await store().incrby(k, micros);
  await store().expire(k, 60 * 60 * 24 * 40);
  return total;
}
