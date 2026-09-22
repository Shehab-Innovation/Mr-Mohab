// ============================================================
// NEXORA — nx_push_sender (Phase N4)
// ============================================================
// Sends a Web Push (VAPID) to all subscriptions owned by the
// recipient of a newly created notification.
//
// Invocation: pg_net HTTP POST from the database hook trigger
//   (AFTER INSERT on notifications). Authenticated by the
//   NEXORA_PUSH_HOOK_SECRET header — no anon access.
//
// Secrets (Supabase Edge secrets, NEVER in frontend):
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY,
//   NEXORA_PUSH_HOOK_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Failure isolation: any internal error still returns 200 so the
// database hook never retries/blocks; the notifications row and
// N1/N2/N3 remain fully independent of push delivery.
// ============================================================

import { sendWebPush } from "../_shared/nx_webpush.ts";

const HOOK_SECRET = Deno.env.get("NEXORA_PUSH_HOOK_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  if (!HOOK_SECRET || req.headers.get("x-nexora-hook") !== HOOK_SECRET) {
    return json(401, { error: "unauthorized" });
  }

  try {
    const payload = await req.json();
    const n = payload?.record;

    if (!n || !n.id) {
      return json(200, { ok: true, skipped: "no_record" });
    }

    const recipientType = n.recipient_type as string;
    const recipientId = n.recipient_id as string;
    if (!recipientType || !recipientId) {
      return json(200, { ok: true, skipped: "no_recipient" });
    }

    // Resolve the recipient's real owner scope server-side
    // (subscriptions are keyed by the owner, never by client input).
    let teacherId: string | null = null;
    let studentId: string | null = null;

    const q = new URL(
      `${SUPABASE_URL}/rest/v1/rpc/nx_push_subscriptions_for_recipient`,
    );
    const res = await fetch(q, {
      method: "POST",
      headers: {
        apikey: SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_recipient_type: recipientType,
        p_recipient_id: recipientId,
      }),
    });

    if (!res.ok) {
      // Never block the hook: report and ack.
      return json(200, { ok: true, skipped: "lookup_failed", status: res.status });
    }

    const subs = (await res.json()) as Array<{
      endpoint: string;
      p256dh: string;
      auth: string;
    }>;

    let sent = 0;
    let failed = 0;
    const dead: string[] = [];

    for (const sub of subs) {
      try {
        await sendWebPush(
          sub.endpoint,
          sub.p256dh,
          sub.auth,
          {
            title: (n.title as string) || "NEXORA",
            message: (n.message as string) || "",
            target_page: (n.target_page as string) || null,
            tag: `nx-${n.id}`,
          },
        );
        sent += 1;
      } catch (err) {
        failed += 1;
        const status = (err as { statusCode?: number }).statusCode;
        // 404/410 = subscription expired on the push service.
        if (status === 404 || status === 410) dead.push(sub.endpoint);
      }
    }

    // Best-effort cleanup of dead subscriptions.
    for (const endpoint of dead) {
      await fetch(`${SUPABASE_URL}/rest/v1/rpc/nx_push_subscription_delete`, {
        method: "POST",
        headers: {
          apikey: SERVICE_ROLE_KEY,
          Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ p_endpoint: endpoint }),
      }).catch(() => undefined);
    }

    return json(200, { ok: true, sent, failed, removed: dead.length });
  } catch (_error) {
    // Ack anyway: push must never break notification creation (N2).
    return json(200, { ok: true, skipped: "internal_error" });
  }
});
