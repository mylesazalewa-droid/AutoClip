import { createPublicKey, verify } from "node:crypto";

/**
 * AutoClip license keys, checked exactly as the app checks them (src/Sources/AutoClip/Services/License.swift):
 * "AUTOCLIP-" + base64(JSON body) + "." + base64(Ed25519 signature of the body).
 * Only the public half of the signing key is here. The private key never leaves your Mac.
 */
export const PUBLIC_KEY = "l26JCqT9QcIw5BHv+kVDaNoZbn4dJVcYlcavqJXfUVc=";




const key = createPublicKey({
  key: { kty: "OKP", crv: "Ed25519", x: Buffer.from(PUBLIC_KEY, "base64").toString("base64url") },
  format: "jwk",
});

/** The license's details when the key is genuine and not expired, otherwise null. */
/** @returns {{id:string,name:string,email?:string,plan:string,issued:number,expires?:number}|null} */
export function checkLicense(raw, now = Date.now(), publicKey = key) {
  if (!raw) return null;
  let text = raw.trim();
  if (text.startsWith("AUTOCLIP-")) text = text.slice("AUTOCLIP-".length);
  const parts = text.split(".");
  if (parts.length !== 2) return null;
  const body = Buffer.from(parts[0], "base64");
  const sig = Buffer.from(parts[1], "base64");
  if (body.length === 0 || sig.length !== 64) return null;
  let ok = false;
  try {
    ok = verify(null, body, publicKey, sig);
  } catch {
    return null;
  }
  if (!ok) return null;
  let info;
  try {
    info = JSON.parse(body.toString("utf8"));
  } catch {
    return null;
  }
  if (typeof info.id !== "string" || !info.id) return null;
  if (typeof info.expires === "number" && info.expires * 1000 < now) return null;
  return info;
}
