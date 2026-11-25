const company = "773dfacb-c0e7-4bd9-8eb4-5208818b1848";
const appId = "5764607791191296200";
const appShopId = "florest-gastronomia-teste-01";
const shopId = "5764619883330929453";
const api = "https://openapi.99food.com";
const project = Deno.env.get("SUPABASE_URL") ?? "";
const privilegedKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const publicKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const cors = {
  "Access-Control-Allow-Origin": "https://erp.florestsistemas.com.br",
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
let cachedToken: { value: string; expiry: number } | undefined;
let tokenLookup: Promise<string> | undefined;
let nextLookup = 0;
let nextRefresh = 0;

function reply(data: object, status = 200) {
  return Response.json(data, { status, headers: { ...cors, "Cache-Control": "no-store" } });
}

class Food99Error extends Error {
  constructor(message: string, readonly code = 0) { super(message); }
}

async function food99(path: string, query: Record<string, string>, body?: string) {
  const url = new URL(api + path);
  url.search = new URLSearchParams(query).toString();
  const response = await fetch(url, {
    method: body ? "POST" : "GET",
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body,
    redirect: "error",
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Food99Error("A 99Food retornou HTTP " + response.status + ".");
  const raw = await response.text();
  const data = JSON.parse(raw.replace(/"(?:\\[\s\S]|[^"\\])*"|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/g, (value) =>
    value.startsWith('"') || /[.eE]/.test(value) || Number.isSafeInteger(Number(value)) ? value : JSON.stringify(value)
  ));
  if (data.errno !== 0) {
    const code = Number(data.errno) || 0;
    throw new Food99Error("A 99Food recusou a operação. Código " + code + ".", code);
  }
  return data.data;
}

function getToken() {
  if (cachedToken && cachedToken.expiry > Date.now()) return Promise.resolve(cachedToken.value);
  if (tokenLookup) return tokenLookup;
  if (Date.now() < nextLookup) throw new Food99Error("Aguarde o intervalo da 99Food antes de tentar novamente.");
  const secret = Deno.env.get("FOOD99_SANDBOX_APP_SECRET");
  if (!secret) throw new Food99Error("Credencial da loja de teste indisponível.");
  const query = { app_id: appId, app_secret: secret, app_shop_id: appShopId };
  nextLookup = Date.now() + 30000;
  tokenLookup = (async () => {
    try {
      const auth = await food99("/v1/auth/authtoken/get", query);
      if (String(auth?.app_id) !== appId || auth?.app_shop_id !== appShopId || typeof auth?.auth_token !== "string") {
        throw new Food99Error("Credencial da loja de teste divergente.");
      }
      const expiry = Number(auth.token_expiration_time) * 1000;
      if (!Number.isFinite(expiry) || expiry <= Date.now()) throw new Food99Error("Token expirado.", 10102);
      cachedToken = { value: auth.auth_token, expiry };
      return cachedToken.value;
    } catch (error) {
      if (!(error instanceof Food99Error) || error.code !== 10102) throw error;
      if (Date.now() < nextRefresh) throw new Food99Error("Aguarde a renovação do token da loja de teste.");
      nextRefresh = Date.now() + 120000;
      if (await food99("/v1/auth/authtoken/refresh", query) !== true) {
        throw new Food99Error("A 99Food não confirmou a renovação do token.");
      }
      throw new Food99Error("Token renovado. Aguarde 30 segundos e tente novamente.");
    }
  })().finally(() => { tokenLookup = undefined; });
  return tokenLookup;
}

async function update(id: string, filters: Record<string, string>, values: object) {
  const query = new URLSearchParams({ app_shop_id: "eq." + appShopId, order_id: "eq." + id, ...filters });
  const response = await fetch(project + "/rest/v1/gastronomia_99food_sandbox_recebimentos?" + query, {
    method: "PATCH",
    headers: {
      apikey: privilegedKey, Authorization: "Bearer " + privilegedKey,
      "Content-Type": "application/json", Prefer: "return=representation",
    },
    body: JSON.stringify(values),
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error("Falha ao registrar o resultado no sandbox.");
  return (await response.json()).length === 1;
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (request.method !== "POST") return reply({ erro: "Método inválido." }, 405);
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return reply({ erro: "Entre no ERP." }, 401);
  let id: string;
  try {
    const dados = await request.json();
    if (dados.empresa_id !== company || typeof dados.order_id !== "string" || !/^[1-9]\d{0,18}$/.test(dados.order_id)) {
      return reply({ erro: "Pedido de teste inválido." }, 400);
    }
    id = dados.order_id;
  } catch {
    return reply({ erro: "Pedido de teste inválido." }, 400);
  }
  try {
    const allowed = await fetch(project + "/rest/v1/rpc/gastronomia_99food_sandbox_pedidos", {
      method: "POST",
      headers: { Authorization: authorization, apikey: publicKey, "Content-Type": "application/json" },
      body: JSON.stringify({ p_empresa: company, p_order_id: id }),
      signal: AbortSignal.timeout(5000),
    });
    if (!allowed.ok) return reply({ erro: "Acesso ao pedido de teste recusado." }, 403);
    const [order] = await allowed.json();
    if (!order) return reply({ erro: "Pedido de teste indisponível nesta empresa." }, 403);
    if (order.estado !== "recebido") return reply({ estado: order.estado });

    const start = new Date();
    const lease = new Date(start.getTime() + 60000).toISOString();
    const claimed = await update(id, {
      estado: "eq.recebido",
      or: "(aceite_reservado_ate.is.null,aceite_reservado_ate.lt." + start.toISOString() + ")",
    }, { aceite_reservado_ate: lease });
    if (!claimed) return reply({ erro: "O pedido está sendo atualizado. Aguarde e consulte novamente." });

    let estado = "recebido";
    let erro: string | undefined;
    try {
      const auth = await getToken();
      const data = await food99("/v1/order/order/detail", { auth_token: auth, order_id: id });
      const detail = data?.order_info ?? data;
      if (String(detail?.order_id) !== id || String(detail?.shop?.shop_id ?? detail?.shop_id) !== shopId) {
        throw new Food99Error("A 99Food não retornou um pedido desta loja de teste. Crie um pedido na ferramenta de pedidos de teste.");
      }
      if ([200, 400, 500, 600].includes(detail.status)) {
        estado = "aceito";
      } else if (detail.status === 100) {
        // The API requires a JSON integer, so serialize the validated ID without Number().
        const body = '{"auth_token":' + JSON.stringify(auth) + ',"order_id":' + id + '}';
        if (await food99("/v1/order/order/confirm", {}, body) !== true) {
          throw new Food99Error("O aceite ainda não foi confirmado pela 99Food.");
        }
        estado = "aceito";
      } else if (detail.status >= 900 && detail.status <= 999) {
        estado = "encerrado";
        erro = "O pedido já foi cancelado na 99Food. Gere um novo pedido de teste.";
      } else {
        throw new Food99Error("A 99Food retornou um estado que impede o aceite.");
      }
    } catch (error) {
      if (error instanceof Food99Error && error.code === 10102) cachedToken = undefined;
      erro = error instanceof Food99Error ? error.message : "Resultado ainda não confirmado. Ao tentar novamente, o ERP consulta primeiro o estado na 99Food.";
    }
    const saved = await update(id, { aceite_reservado_ate: "eq." + lease }, {
      estado, atualizado_em: new Date().toISOString(), aceite_reservado_ate: null,
    });
    if (!saved) throw new Error("Não foi possível confirmar o registro do resultado.");
    return reply({ estado, erro });
  } catch {
    return reply({ erro: "Não foi possível concluir. Atualize a lista e tente novamente." });
  }
});
