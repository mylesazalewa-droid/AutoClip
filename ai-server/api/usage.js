import { checkLicense } from "../lib/license.js";
import { monthlyAllowance, used } from "../lib/allowance.js";

/** GET /api/usage: how much of this month's included AI is left, for the app's AI usage chip. */
export default async function handler(req, res) {
  const license = checkLicense(req.headers["x-autoclip-license"]);
  if (!license) return res.status(401).json({ type: "error", error: { type: "authentication_error", message: "No active license." } });
  const allowance = monthlyAllowance(license.plan);
  const spent = await used(license);
  const now = new Date();
  const renews = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  res.status(200).json({
    allowance,
    used: spent,
    remaining: Math.max(0, allowance - spent),
    fraction: allowance > 0 ? Math.min(1, spent / allowance) : 1,
    renews: renews.toISOString(),
  });
}
