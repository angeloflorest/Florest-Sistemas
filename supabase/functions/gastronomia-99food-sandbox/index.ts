import { createHash, timingSafeEqual } from "node:crypto";

// Only the test app and store enrolled in the 99Food developer portal.
const appId = "5764607791191296200";
const appShopId = "florest-gastronomia-teste-01";
const shopId = "5764619883330929453";
const maxBodySize = 256 * 1024;

function reply(status: number, errno: number, errmsg: string) {
  return Response.json({ errno, errmsg }, {
    status,
    headers: { "Cache-Control": "no-store" },
  });
}

function parsePayload(raw: string) {
  // Preserve 64-bit identifiers before JSON.parse rounds them.
  return JSON.parse(raw.replace(/"(?:\\[\s\S]|[^"\\])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/g, (token) =>
    token.startsWith('"') || /[.eE]/.test(token) || Number.isSafeInteger(Number(token))
      ? token : JSON.stringify(token)
  ));
}

Deno.serve(async (request: Request) => {
  if (request.method === "GET" || request.method === "HEAD") return reply(200, 0, "Webhook 99Food de teste.");
  if (request.method !== "POST") return reply(405, 1, "Método inválido.");

  const secret = Deno.env.get("FOOD99_SANDBOX_APP_SECRET");
  if (!secret) return reply(503, 1, "Sandbox aguardando configuração.");
  const signature = request.headers.get("didi-header-sign") ?? "";
  if (!/^[a-f0-9]{32}$/i.test(signature)) return reply(401, 1, "Assinatura inválida.");
  const digest = createHash("md5");
  const chunks: Uint8Array[] = [];
  let size = 0;
  const reader = request.body?.getReader();
  if (!reader) return reply(400, 1, "Corpo ausente.");
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBodySize) {
        await reader.cancel();
        return reply(413, 1, "Corpo excede o limite.");
      }
      digest.update(value);
      chunks.push(value);
    }
  } catch {
    return reply(400, 1, "Corpo inválido.");
  } finally {
    reader.releaseLock();
  }
  const expected = digest.update(secret).digest();
  const actual = Uint8Array.from(signature.match(/../g)!, (part) => Number.parseInt(part, 16));
  if (!timingSafeEqual(expected, actual)) return reply(401, 1, "Assinatura inválida.");

  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }

  let event;
  try {
    event = parsePayload(new TextDecoder("utf-8", { fatal: true }).decode(body));
  } catch {
    return reply(400, 1, "JSON inválido.");
  }
  const shop = event?.data?.order_info?.shop;
  if (String(event?.app_id) !== appId || event?.app_shop_id !== appShopId ||
    (shop?.shop_id != null && String(shop.shop_id) !== shopId)) {
    return reply(403, 1, "Evento fora da loja de teste.");
  }
  if (event.type !== "orderNew") return reply(422, 1, "Este teste recebe somente orderNew.");

  const orderId = String(event.data?.order_id ?? event.data?.order_info?.order_id ?? "");
  const orderIndex = event.data?.order_info?.order_index ?? null;
  if (!/^[1-9]\d{0,18}$/.test(orderId) ||
    (event.data?.order_info?.order_id != null && String(event.data.order_info.order_id) !== orderId) ||
    (orderIndex !== null && (!Number.isSafeInteger(orderIndex) || orderIndex < 0 || orderIndex > 2147483647))) {
    return reply(400, 1, "Identificador de pedido inválido.");
  }

  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return reply(503, 1, "Registro do sandbox indisponível.");
  try {
    const response = await fetch(
      url + "/rest/v1/gastronomia_99food_sandbox_recebimentos?on_conflict=app_shop_id,order_id",
      {
        method: "POST",
        headers: {
          apikey: key,
          Authorization: "Bearer " + key,
          "Content-Type": "application/json",
          Prefer: "resolution=ignore-duplicates,return=minimal",
        },
        body: JSON.stringify({ app_shop_id: appShopId, order_id: orderId, order_index: orderIndex }),
        signal: AbortSignal.timeout(3500),
      },
    );
    if (!response.ok) return reply(503, 1, "Registro do sandbox indisponível.");
    return reply(200, 0, "ok");
  } catch {
    return reply(503, 1, "Registro do sandbox indisponível.");
  }
});
