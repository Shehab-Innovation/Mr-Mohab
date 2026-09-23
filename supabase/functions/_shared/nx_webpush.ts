// Minimal standalone VAPID webpush helper (no external deps).
// Implements RFC 8291 (aes128gcm encryption) + RFC 8292 (VAPID).

const encoder = new TextEncoder();

function b64urlToBytes(s: string): Uint8Array {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const b64 = (s + pad).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

function bytesToB64url(b: Uint8Array): string {
  let s = "";
  for (const byte of b) s += String.fromCharCode(byte);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function concat(...arrays: Uint8Array[]): Uint8Array {
  const total = arrays.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const a of arrays) {
    out.set(a, offset);
    offset += a.length;
  }
  return out;
}

export interface PushPayload {
  title: string;
  message: string;
  target_page: string | null;
  tag: string;
}

export interface PushError extends Error {
  statusCode?: number;
}

export async function sendWebPush(
  endpoint: string,
  p256dhB64: string,
  authB64: string,
  payload: PushPayload,
): Promise<void> {
  const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
  const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
  if (!VAPID_PUBLIC || !VAPID_PRIVATE) {
    throw new Error("vapid_keys_missing");
  }

  // ---------- RFC 8291 content encryption (aes128gcm) ----------
  const uaPublic = b64urlToBytes(p256dhB64); // 65 bytes uncompressed point
  const authSecret = b64urlToBytes(authB64);

  // Ephemeral sender key pair.
  const clientKey = (await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  )) as CryptoKeyPair;

  const clientPubRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", clientKey.publicKey),
  );

  // Shared secret with the subscription's public key.
  const uaKey = await crypto.subtle.importKey(
    "raw",
    uaPublic,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
  const ecdhSecret = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "ECDH", public: uaKey },
      clientKey.privateKey,
      256,
    ),
  );

  // IKM = ecdh_secret || auth_secret
  const ikm = await crypto.subtle.importKey(
    "raw",
    concat(ecdhSecret, authSecret),
    "HKDF",
    false,
    ["deriveBits"],
  );

  const salt = crypto.getRandomValues(new Uint8Array(16));

  // CEK: HKDF(salt, ikm, "WebPush: info\0" | ua_pub | as_pub, 16)
  // N4 fix: HkdfParams.salt must be a BufferSource (raw bytes), NOT a
  // CryptoKey. Passing an imported HKDF CryptoKey as salt throws a
  // TypeError in the Deno/WebCrypto runtime BEFORE the fetch to the push
  // service, so FCM never even received the request (root cause of
  // sent:0 / failed:N / removed:0).
  const cekInfo = concat(
    encoder.encode("WebPush: info\0"),
    uaPublic,
    clientPubRaw,
  );
  const cekIk = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt, info: cekInfo },
      ikm,
      16 * 8,
    ),
  );

  // NONCE: HKDF(salt, ikm, "Content-Encoding: nonce\0", 12)
  const nonce = new Uint8Array(
    await crypto.subtle.deriveBits(
      {
        name: "HKDF",
        hash: "SHA-256",
        salt,
        info: encoder.encode("Content-Encoding: nonce\0"),
      },
      ikm,
      12 * 8,
    ),
  );

  // ---------- VAPID JWT (ES256) ----------
  const jwtHeader = bytesToB64url(
    encoder.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })),
  );
  const audience = new URL(endpoint).origin;
  const nowSec = Math.floor(Date.now() / 1000);
  const jwtClaims = bytesToB64url(
    encoder.encode(
      JSON.stringify({
        aud: audience,
        exp: nowSec + 12 * 3600,
        sub: "mailto:admin@shehabinnovation.com",
      }),
    ),
  );
  const jwtInput = encoder.encode(`${jwtHeader}.${jwtClaims}`);

  const signingKey = await buildVapidJwk(VAPID_PUBLIC, VAPID_PRIVATE);

  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    signingKey,
    jwtInput,
  );
  const sigBytes = new Uint8Array(sig);
  const jwtSig = bytesToB64url(concat(sigBytes.slice(0, 32), sigBytes.slice(32, 64)));
  const jwt = `${jwtHeader}.${jwtClaims}.${jwtSig}`;

  // ---------- Encrypt payload ----------
  const plaintext = encoder.encode(JSON.stringify(payload));
  const padded = concat(plaintext, new Uint8Array([2])); // record delimiter

  const cek = await crypto.subtle.importKey("raw", cekIk, "AES-GCM", false, [
    "encrypt",
  ]);
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, cek, padded),
  );

  // aes128gcm body: salt(16) | rs(4 BE) | idlen(1) | keyid | ciphertext
  const rs = new Uint8Array(4);
  new DataView(rs.buffer).setUint32(0, 4096);
  const body = concat(
    salt,
    rs,
    new Uint8Array([clientPubRaw.length]),
    clientPubRaw,
    ciphertext,
  );

  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      TTL: "2419200",
      Authorization: `vapid t=${jwt}, k=${VAPID_PUBLIC}`,
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      Urgency: "high",
    },
    body: body as unknown as BodyInit,
  });

  if (!res.ok) {
    const err: PushError = new Error(`push_failed_${res.status}`);
    err.statusCode = res.status;
    throw err;
  }
}

// Build the ECDSA signing key from the stored public point (x,y)
// and the private scalar (d). All three come from the same keypair.
async function buildVapidJwk(
  pubB64: string,
  privB64: string,
): Promise<CryptoKey> {
  const pub = b64urlToBytes(pubB64); // 0x04 || X(32) || Y(32)
  return crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      x: bytesToB64url(pub.slice(1, 33)),
      y: bytesToB64url(pub.slice(33, 65)),
      d: privB64,
      ext: true,
    },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}
