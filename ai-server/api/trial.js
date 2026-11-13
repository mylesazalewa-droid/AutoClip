import { trialEnabled } from "../lib/allowance.js";

/** GET /api/trial: whether free-trial AI is on, so trial copies of AutoClip know whether to offer it. */
export default function handler(req, res) {
  res.setHeader("Cache-Control", "public, max-age=600");
  res.status(200).json({ enabled: trialEnabled() });
}
