# AutoClip AI (included AI for churches)

A small server that lets churches use AutoClip's AI without their own API key.
AutoClip sends its normal Claude request here with its **license key** instead of an API key.
The server:

1. checks the license is genuine (same Ed25519 check as the app; only the public key is here),
2. checks the license's monthly allowance (counted in what the AI actually cost),
3. sends the request to Claude with **your** Anthropic key,
4. returns Claude's answer unchanged and adds the cost to the month's total.

Only the models AutoClip uses (Claude Haiku 5.5 and 4.5), text only, and at most 8,192 output
tokens per request are allowed, so a leaked license can't run up a large bill.

## What it costs you

Claude Haiku 5.5 costs $0.10 per million input tokens and $0.50 per million output tokens
(prompts up to 100K tokens). Picking clips from a 40-minute sermon is roughly 10,000 tokens in and
2,000 out: about **$0.002**. A $5 monthly allowance covers a few thousand AI actions.

## Set up (once)

1. **Vercel**: create a project from this folder (`ai-server`). Root directory: `ai-server`.
2. **Storage**: in the Vercel project, Storage → add **Upstash for Redis** (free tier is plenty).
   It sets `UPSTASH_REDIS_REST_URL` and `UPSTASH_REDIS_REST_TOKEN` for you.
3. **Environment variables** (Settings → Environment Variables):
   - `ANTHROPIC_API_KEY`: a key made just for this server in the Anthropic Console, with a
     monthly spend limit set on it in the Console as a safety net.
   - Optional allowances in dollars per license per month: `ALLOWANCE_SOLO` (default 2),
     `ALLOWANCE_CHURCH` (5), `ALLOWANCE_LIFETIME` (5), `ALLOWANCE_TRIAL` (0).
   - Optional `REVOKED_LICENSES`: comma-separated license ids to switch off.
4. Deploy. The app needs the address, e.g. `https://autoclip-ai.vercel.app`, put into
   `AppInfo.aiServerURL` in `src/Sources/AutoClip/Services/AppInfo.swift`, then a new release.

`maxDuration` is 120 seconds (vercel.json), which needs a Pro plan; on the Hobby plan Vercel caps
functions at 60 seconds, which is enough for nearly every AutoClip request.

## Endpoints

- `POST /api/messages`: header `X-AutoClip-License: AUTOCLIP-…`, body = a Claude Messages request.
  Errors use Claude's error shape. 401 no or bad license, 403 switched off, 429 allowance used up.
  Response headers `X-AutoClip-Remaining` and `X-AutoClip-Allowance` (millionths of a dollar).
- `GET /api/usage`: same header; returns `{ allowance, used, remaining, fraction, renews }`.

## Tests

```
npm install
npm test
```
