import Anthropic from "@anthropic-ai/sdk";
import { checkLicense } from "../lib/license.js";
import { addTrialSpend, addUse, costMicros, isRevoked, monthlyAllowance, trialEnabled, trialDailyCap, trialSpentToday, used } from "../lib/allowance.js";

/**
 * POST /api/messages: AutoClip's included AI.
 * The app sends the same Messages request it would send to Claude, with its license key in the
 * X-AutoClip-License header instead of an API key. This checks the license, checks the month's
 * allowance, sends the request with AutoClip's own key (ANTHROPIC_API_KEY), counts what it cost,
 * and returns Claude's answer unchanged.
 */

/** Models AutoClip uses. Anything else is refused so a leaked license can't run up a big bill. */
const MODELS = new Set(["claude-haiku-5-5", "claude-haiku-4-5"]);
const MAX_TOKENS = 8192;
const MAX_PROMPT_CHARS = 600_000; // about a 3-hour sermon transcript

let client = null;
/** Made on first use, so a missing key is reported clearly instead of breaking every request */
function claude() {
  client ??= new Anthropic(); // ANTHROPIC_API_KEY from the environment
  return client;
}

function fail(res, status, type, message, extra = {}) {
  // The shape Claude's own errors have, so the app shows the message as it already does
  res.status(status).json({ type: "error", error: { type, message }, ...extra });
}

/** Only plain text prompts, as the app sends them */
export function cleanRequest(body) {
  if (!body || typeof body !== "object") return { error: "The request was empty." };
  const model = body.model ?? "claude-haiku-5-5";
  if (!MODELS.has(model)) return { error: `AutoClip AI doesn't offer ${model}.` };
  const messages = Array.isArray(body.messages) ? body.messages : [];
  if (messages.length === 0 || messages.length > 20) return { error: "The request had no messages." };
  let chars = 0;
  for (const m of messages) {
    if (m?.role !== "user" && m?.role !== "assistant") return { error: "Unexpected message." };
    if (typeof m.content === "string") chars += m.content.length;
    else if (Array.isArray(m.content) && m.content.every((b) => b?.type === "text" && typeof b.text === "string"))
      chars += m.content.reduce((n, b) => n + b.text.length, 0);
    else return { error: "AutoClip AI takes text only." };
  }
  if (chars > MAX_PROMPT_CHARS) return { error: "This is longer than AutoClip AI takes in one go." };
  const req = { model, max_tokens: Math.min(Number(body.max_tokens) || MAX_TOKENS, MAX_TOKENS), messages };
  if (typeof body.system === "string") req.system = body.system;
  const effort = body.output_config?.effort;
  if (model === "claude-haiku-5-5" && ["low", "medium", "high"].includes(effort)) req.output_config = { effort };
  return { req };
}

export default async function handler(req, res) {
  if (req.method !== "POST") return fail(res, 405, "invalid_request_error", "Use POST.");

  let license = checkLicense(req.headers["x-autoclip-license"]);
  const trialID = String(req.headers["x-autoclip-trial"] ?? "");
  const trial = !license && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(trialID);
  if (trial && trialEnabled()) {
    // A free trial: a small allowance for the whole trial, inside a shared daily budget
    if ((await trialSpentToday()) >= trialDailyCap()) {
      return fail(res, 429, "rate_limit_error",
        "Free-trial AI is busy for today. Please try again tomorrow, or add your own AI key in Settings → AI.");
    }
    license = { id: "trial-" + trialID.toLowerCase(), plan: "trial" };
  }
  if (!license) {
    return fail(res, 401, "authentication_error",
      trial
        ? "AI in the free trial isn't available yet. Buy AutoClip to include it, or add your own AI key in Settings → AI."
        : "AutoClip AI needs an active AutoClip license. Add yours in AutoClip → Activate AutoClip, or add your own AI key in Settings → AI.");
  }
  if (isRevoked(license.id)) {
    return fail(res, 403, "permission_error", "This AutoClip license has been switched off. Please contact AutoClip support.");
  }

  if (!process.env.ANTHROPIC_API_KEY) {
    return fail(res, 503, "api_error", "AutoClip AI isn't switched on yet. Please try again later, or add your own AI key in Settings → AI.");
  }
  // Without storage (no Upstash yet) each license's use isn't counted; the spending limit on
  // the Anthropic key caps the total instead. Plans with no allowance are still refused.
  const counting = Boolean(process.env.UPSTASH_REDIS_REST_URL);
  const allowance = monthlyAllowance(license.plan);
  const spent = counting ? await used(license) : 0;
  if (allowance === 0 || spent >= allowance) {
    return fail(res, 429, "rate_limit_error",
      license.plan === "trial"
        ? "You've used the AI included with the free trial. Buy AutoClip for AI every month, or add your own AI key in Settings → AI."
        : allowance === 0
        ? "Your plan doesn't include AutoClip AI. You can add your own AI key in Settings → AI."
        : "This month's included AI is used up. It renews on the 1st, or you can add your own AI key in Settings → AI.",
      { remaining: 0 });
  }

  const { req: request, error } = cleanRequest(req.body);
  if (error) return fail(res, 400, "invalid_request_error", error);

  let message;
  try {
    message = await claude().messages.create(request);
  } catch (e) {
    if (e instanceof Anthropic.APIError) {
      // Overloaded or rate limited upstream: the app's normal retry handles these
      const status = e.status === 529 || e.status === 429 ? 503 : e.status >= 500 ? 502 : 400;
      return fail(res, status, "api_error", "AutoClip AI is busy right now. Please try again in a minute.");
    }
    throw e;
  }

  const cost = costMicros(request.model, message.usage?.input_tokens ?? 0, message.usage?.output_tokens ?? 0);
  if (counting) {
    if (license.plan === "trial") await addTrialSpend(cost);
    const total = await addUse(license, cost);
    res.setHeader("X-AutoClip-Remaining", String(Math.max(0, allowance - total)));
    res.setHeader("X-AutoClip-Allowance", String(allowance));
  }
  res.status(200).json(message);
}
