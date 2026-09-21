// =====================================================================
// CENTRAL (Supabase ERP PETSHOP) — Edge Function "florest-admin-assinatura"  (ARQUIVO ÚNICO para o Dashboard)
// Navegador (admin.html, JWT do administrador) -> ESTA função -> banco central (RPC) -> [se sistema remoto] florest-sync (HMAC c2s).
//
// Configurar: Verify JWT = LIGADO.
// Secrets (somente NOMES; valores só no painel):
//   FLOREST_ALLOWED_ORIGINS               origem(ns) exata(s) onde o admin.html é aberto, separadas por vírgula, sem barra final
//                                         (ex.: https://admin.seudominio.com.br). Sem isso, chamadas do navegador são recusadas (403).
//   FLOREST_SYNC_SECRET_DISTGESTOR        já existe (HMAC Central -> DistGestor). Um FLOREST_SYNC_SECRET_<SLUG> por sistema remoto futuro.
//   FLOREST_SYNC_SECRET_DISTGESTOR_NEXT   opcional, só durante rotação.
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY são injetados pela Supabase. Nada disso vai para o navegador.
//
// Corpo (POST JSON, <= 2 KB):
//   { "assinatura_id": "<uuid>", "acao": "aprovar|bloquear|reativar|renovar|atualizar|sincronizar",
//     "dados": { "status_conta", "status_pagamento", "vencimento"|null, "valor_mensal"|null }   // só em "atualizar" }
// Resposta 200: { ok:true, sincronizado:boolean, sync:"local"|"ok", central:{...} }
// Falha remota: 502 { ok:false, erro:"sync_falhou", central_atualizada:true, liberado:false, sync_status:"erro", mensagem }
//   -> a Central foi atualizada, o sistema remoto NÃO. Repetir com acao="sincronizar" (mesma revisão = idempotente).
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const ENDPOINT_SYNC = "florest-sync";
const MAX_BODY_BYTES = 2 * 1024;
const PROTOCOL_VERSION = "1";
const SIGNING_PREFIX = "FLOREST-SYNC";
const MIN_SECRET_LENGTH = 32;
const ACOES = ["aprovar", "bloquear", "reativar", "renovar", "atualizar", "sincronizar"] as const;
type Acao = typeof ACOES[number];

const HEADER = {
  version: "x-florest-version",
  system: "x-florest-system",
  direction: "x-florest-direction",
  timestamp: "x-florest-timestamp",
  nonce: "x-florest-nonce",
  signature: "x-florest-signature",
} as const;

const encoder = new TextEncoder();
const SLUG_RE = /^[a-z][a-z0-9_]{1,31}$/;

// ---------------------------------------------------------------------
// 1) Assinatura HMAC (Florest Sync v1) — direção c2s (central -> sistema)
//    Assinado: "FLOREST-SYNC" \n versão \n direção \n sistema \n endpoint \n timestamp \n nonce \n SHA256(corpo bruto)
// ---------------------------------------------------------------------
function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}
async function sha256Hex(data: Uint8Array): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", data as BufferSource)));
}
function randomNonce(): string {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return bytesToHex(b);
}
async function signRequest(o: { secret: string; system: string; endpoint: string; body: string; nowSeconds: number }): Promise<Record<string, string>> {
  if (o.secret.length < MIN_SECRET_LENGTH) throw new Error("segredo_invalido");
  const nonce = randomNonce();
  const bodySha256 = await sha256Hex(encoder.encode(o.body));
  const texto = [SIGNING_PREFIX, PROTOCOL_VERSION, "c2s", o.system, o.endpoint, String(o.nowSeconds), nonce, bodySha256].join("\n");
  const key = await crypto.subtle.importKey("raw", encoder.encode(o.secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(texto));
  return {
    "content-type": "application/json",
    [HEADER.version]: PROTOCOL_VERSION,
    [HEADER.system]: o.system,
    [HEADER.direction]: "c2s",
    [HEADER.timestamp]: String(o.nowSeconds),
    [HEADER.nonce]: nonce,
    [HEADER.signature]: "v1=" + bytesToHex(new Uint8Array(sig)),
  };
}
/** Só nomes de secret; valores vêm de Edge Function Secrets. O primeiro válido assina. */
function getSecret(slug: string): string | null {
  const base = "FLOREST_SYNC_SECRET_" + slug.toUpperCase();
  for (const nome of [base, base + "_NEXT"]) {
    const v = Deno.env.get(nome);
    if (typeof v === "string" && v.length >= MIN_SECRET_LENGTH) return v;
  }
  return null;
}

// ---------------------------------------------------------------------
// 2) Utilidades HTTP / validação / log seguro
// ---------------------------------------------------------------------
function jsonResponse(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff", ...extra },
  });
}
const erro = (status: number, codigo: string, mensagem: string, extra: Record<string, string> = {}) =>
  jsonResponse(status, { ok: false, erro: codigo, mensagem }, extra);
const isJsonContentType = (h: Headers) => /^application\/json\s*(;\s*charset=utf-8\s*)?$/.test((h.get("content-type") ?? "").toLowerCase());

type BodyResult = { ok: true; bytes: Uint8Array } | { ok: false; status: number; erro: string };
async function readStreamLimited(body: ReadableStream<Uint8Array> | null, maxBytes: number): Promise<BodyResult> {
  if (!body) return { ok: true, bytes: new Uint8Array(0) };
  const reader = body.getReader();
  const partes: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        try { await reader.cancel(); } catch { /* ignora */ }
        return { ok: false, status: 413, erro: "corpo_grande_demais" };
      }
      partes.push(value);
    }
  } catch {
    return { ok: false, status: 400, erro: "requisicao_invalida" };
  }
  const bytes = new Uint8Array(total);
  let off = 0;
  for (const p of partes) { bytes.set(p, off); off += p.byteLength; }
  return { ok: true, bytes };
}
async function readBodyLimited(req: Request, maxBytes: number): Promise<BodyResult> {
  const cl = req.headers.get("content-length");
  if (cl !== null) {
    if (!/^\d{1,10}$/.test(cl)) return { ok: false, status: 400, erro: "requisicao_invalida" };
    if (Number(cl) > maxBytes) return { ok: false, status: 413, erro: "corpo_grande_demais" };
  }
  return await readStreamLimited(req.body, maxBytes);
}
function parseJsonObject(bytes: Uint8Array): Record<string, unknown> | null {
  try {
    const v = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    return v === null || typeof v !== "object" || Array.isArray(v) ? null : (v as Record<string, unknown>);
  } catch { return null; }
}
const onlyKeys = (o: Record<string, unknown>, permitidas: readonly string[]) => Object.keys(o).every((k) => permitidas.includes(k));
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isUuid = (v: unknown): v is string => typeof v === "string" && UUID_RE.test(v);

// CORS mínimo: só as origens da lista FLOREST_ALLOWED_ORIGINS
type CorsDecision = { tipo: "sem_origem" } | { tipo: "permitida"; headers: Record<string, string> } | { tipo: "negada" };
function decideCors(req: Request, permitidas: string[]): CorsDecision {
  const origin = req.headers.get("origin");
  if (origin === null) return { tipo: "sem_origem" };
  if (!permitidas.includes(origin)) return { tipo: "negada" };
  return {
    tipo: "permitida",
    headers: {
      "access-control-allow-origin": origin,
      "access-control-allow-methods": "POST, OPTIONS",
      "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
      "access-control-max-age": "600",
      "vary": "Origin",
    },
  };
}

// log seguro: descarta chaves sensíveis; nunca registra corpo, e-mail, CNPJ, nomes, tokens ou segredos
const CHAVES_SENSIVEIS = /secret|token|authorization|signature|hmac|key|jwt|cookie|senha|password|email|cnpj|cpf|telefone|nome|dados|body|payload/i;
function log(nivel: "info" | "warn" | "error", evento: string, campos: Record<string, unknown> = {}) {
  const limpo: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(campos)) {
    if (CHAVES_SENSIVEIS.test(k)) continue;
    if (typeof v === "string") limpo[k] = v.length > 120 ? v.slice(0, 120) + "…" : v;
    else if (typeof v === "number" || typeof v === "boolean" || v === null) limpo[k] = v;
  }
  console.log(JSON.stringify({ fn: "florest-admin-assinatura", nivel, evento, ...limpo }));
}
function errInfo(e: unknown): { erro_tipo: string; erro_codigo?: string } {
  if (e && typeof e === "object") {
    const o = e as { name?: unknown; code?: unknown };
    return {
      erro_tipo: typeof o.name === "string" ? o.name : "Error",
      ...(typeof o.code === "string" && /^[A-Za-z0-9_]{1,12}$/.test(o.code) ? { erro_codigo: o.code } : {}),
    };
  }
  return { erro_tipo: "desconhecido" };
}

// anti-SSRF: só https://<ref de 20 chars>.supabase.co/functions/v1/florest-sync (mesma regra do CHECK no banco)
function validateSyncUrl(u: unknown): string | null {
  if (typeof u !== "string") return null;
  let url: URL;
  try { url = new URL(u); } catch { return null; }
  if (url.protocol !== "https:" || url.username || url.password || url.port || url.search || url.hash) return null;
  if (!/^[a-z0-9]{20}\.supabase\.co$/.test(url.hostname)) return null;
  if (url.pathname !== "/functions/v1/florest-sync") return null;
  return url.toString();
}

type PostResult =
  | { ok: true; status: number; json: Record<string, unknown> | null }
  | { ok: false; motivo: "rede" | "timeout" | "http" | "resposta_grande"; status?: number; json?: Record<string, unknown> | null };

async function postSigned(o: { url: string; body: Record<string, unknown>; secret: string; system: string }): Promise<PostResult> {
  const corpo = JSON.stringify(o.body);
  const headers = await signRequest({ secret: o.secret, system: o.system, endpoint: ENDPOINT_SYNC, body: corpo, nowSeconds: Math.floor(Date.now() / 1000) });
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 8000);
  try {
    const resp = await fetch(o.url, { method: "POST", headers, body: corpo, redirect: "error", signal: ctrl.signal });
    const lido = await readStreamLimited(resp.body, 64 * 1024);
    if (!lido.ok) return { ok: false, motivo: "resposta_grande", status: resp.status };
    const json = parseJsonObject(lido.bytes);
    if (resp.status < 200 || resp.status >= 300) return { ok: false, motivo: "http", status: resp.status, json };
    return { ok: true, status: resp.status, json };
  } catch (e) {
    const nome = e && typeof e === "object" ? (e as { name?: string }).name : "";
    return { ok: false, motivo: nome === "AbortError" ? "timeout" : "rede" };
  } finally {
    clearTimeout(t);
  }
}

// ---------------------------------------------------------------------
// 3) Banco central (service_role SOMENTE aqui, no servidor)
// ---------------------------------------------------------------------
function resolveServerKey(): string | null {
  const legado = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legado && legado.length > 20) return legado;
  const json = Deno.env.get("SUPABASE_SECRET_KEYS");           // modelo novo: {"default":"sb_secret_..."}
  if (json) {
    try {
      const o = JSON.parse(json) as Record<string, unknown>;
      const v = typeof o["default"] === "string" ? o["default"] : Object.values(o).find((x) => typeof x === "string");
      if (typeof v === "string" && v.length > 20) return v;
    } catch { /* cai para null */ }
  }
  return null;
}
let dbc: ReturnType<typeof createClient> | null = null;
function client() {
  if (!dbc) {
    const url = Deno.env.get("SUPABASE_URL");
    const key = resolveServerKey();
    if (!url || !key) throw new Error("configuracao_supabase_ausente");
    dbc = createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { headers: { "x-florest-origem": "edge-function" } },
    });
  }
  return dbc;
}
async function autenticar(jwt: string): Promise<string | null> {
  const { data, error } = await client().auth.getUser(jwt);
  if (error || !data?.user?.id) return null;
  return data.user.id;
}

interface Preparado {
  ok: true;
  assinatura_id: string;
  sistema_slug: string;
  modo_sync: "local" | "remoto";
  sync_url: string | null;
  ref_externa: string | null;
  revisao: number;
  status_conta: "pendente" | "aprovado" | "bloqueado";
  status_pagamento: "em_dia" | "atrasado";
  vencimento: string | null;
  valor_mensal: number | null;
  mudou: boolean;
  precisa_sync: boolean;
}

// SQLSTATE das RPCs (Central Migration 003) -> resposta ao Admin
const ERROS_RPC: Record<string, { status: number; erro: string; mensagem: string }> = {
  FA001: { status: 403, erro: "acesso_restrito", mensagem: "Essa conta não tem acesso de administrador." },
  FA002: { status: 404, erro: "assinatura_nao_encontrada", mensagem: "Assinatura não encontrada." },
  FA003: { status: 409, erro: "estado_invalido", mensagem: "Essa ação não é permitida para o status atual da assinatura. Atualize a lista." },
  FA004: { status: 400, erro: "dados_invalidos", mensagem: "Dados inválidos." },
  FA005: { status: 409, erro: "sistema_indisponivel", mensagem: "Nada foi alterado: o sistema remoto não está configurado para sincronizar (inativo, sem sync_url ou assinatura sem vínculo)." },
};

// ---------------------------------------------------------------------
// 4) Sincronização remota (action "aplicar" do florest-sync)
// ---------------------------------------------------------------------
function codigoRemoto(json: Record<string, unknown> | null | undefined): string | null {
  const e = json ? json["erro"] : null;
  return typeof e === "string" && /^[a-z_]{1,40}$/.test(e) ? e : null;
}

/** Devolve null se o remoto aplicou (ou já tinha aplicado) EXATAMENTE o estado enviado; senão, um código curto de erro. */
async function sincronizarRemoto(p: Preparado, ator: string): Promise<string | null> {
  const url = validateSyncUrl(p.sync_url);
  if (!url) return "url_invalida";
  if (!p.ref_externa || !isUuid(p.ref_externa)) return "sem_vinculo";
  if (!SLUG_RE.test(p.sistema_slug)) return "sistema_invalido";
  const segredo = getSecret(p.sistema_slug);
  if (!segredo) return "segredo_ausente";

  const r = await postSigned({
    url, secret: segredo, system: p.sistema_slug,
    body: {
      action: "aplicar",
      empresa_id: p.ref_externa,
      assinatura_id: p.assinatura_id,
      revisao: p.revisao,
      status_conta: p.status_conta,
      vencimento: p.vencimento,
      motivo: p.status_conta === "bloqueado" ? "bloqueio_admin_central" : null,
      ator,
    },
  });
  if (!r.ok) {
    if (r.motivo === "http") return `http_${r.status ?? 0}` + (codigoRemoto(r.json) ? `:${codigoRemoto(r.json)}` : "");
    return r.motivo;
  }
  const j = r.json;
  const res = j && j["ok"] === true && j["resultado"] && typeof j["resultado"] === "object" ? j["resultado"] as Record<string, unknown> : null;
  if (!res || res["ok"] !== true) return "resposta_invalida";
  if (res["aplicado"] !== true && res["motivo"] === "revisao_antiga") return "revisao_antiga_no_destino";
  // confere o estado final no destino: nunca "libera" o cliente com base só em HTTP 200
  if (res["status_conta"] !== p.status_conta) return "divergente";
  if (p.status_conta === "aprovado") {
    if (res["vencimento"] !== p.vencimento) return "divergente";
    if (res["aplicado"] === true && res["bloqueado"] !== false) return "divergente";
  }
  return null;
}

// ---------------------------------------------------------------------
// 5) Handler
// ---------------------------------------------------------------------
const ORIGENS = (Deno.env.get("FLOREST_ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter((s) => s.length > 0);
const DADOS_KEYS = ["status_conta", "status_pagamento", "vencimento", "valor_mensal"] as const;

async function handler(req: Request): Promise<Response> {
  const cors = decideCors(req, ORIGENS);
  if (cors.tipo === "negada") return erro(403, "origem_nao_permitida", "Origem não permitida.");
  const ch = cors.tipo === "permitida" ? cors.headers : {};

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return erro(405, "metodo_nao_permitido", "Método não permitido.", { ...ch, allow: "POST, OPTIONS" });

  // --- autenticação: JWT do administrador (a checagem de admin é feita pelo banco, dentro da RPC) ---
  const m = /^Bearer\s+([A-Za-z0-9._~+/=-]{20,4096})$/.exec(req.headers.get("authorization") ?? "");
  if (!m) return erro(401, "nao_autenticado", "Sessão inválida. Entre novamente.", ch);
  let uid: string | null;
  try { uid = await autenticar(m[1]); } catch (e) {
    log("error", "auth_falhou", errInfo(e));
    return erro(500, "erro_interno", "Erro interno. Tente novamente.", ch);
  }
  if (!uid) return erro(401, "nao_autenticado", "Sessão inválida. Entre novamente.", ch);

  // --- corpo ---
  if (!isJsonContentType(req.headers)) return erro(415, "tipo_de_conteudo_invalido", "Tipo de conteúdo inválido.", ch);
  const corpo = await readBodyLimited(req, MAX_BODY_BYTES);
  if (!corpo.ok) return erro(corpo.status, corpo.erro, "Requisição inválida.", ch);
  const b = parseJsonObject(corpo.bytes);
  if (!b || !onlyKeys(b, ["assinatura_id", "acao", "dados"])) return erro(400, "dados_invalidos", "Dados inválidos.", ch);
  const acao = b["acao"];
  if (!isUuid(b["assinatura_id"]) || typeof acao !== "string" || !(ACOES as readonly string[]).includes(acao)) {
    return erro(400, "dados_invalidos", "Dados inválidos.", ch);
  }
  let dados: Record<string, unknown> | null = null;
  if (acao === "atualizar") {
    const d = b["dados"];
    if (d === null || typeof d !== "object" || Array.isArray(d) || !onlyKeys(d as Record<string, unknown>, DADOS_KEYS)) {
      return erro(400, "dados_invalidos", "Dados inválidos.", ch);
    }
    dados = d as Record<string, unknown>;
  } else if (b["dados"] !== undefined) {
    return erro(400, "dados_invalidos", "Dados inválidos.", ch);
  }
  const assinaturaId = b["assinatura_id"] as string;

  // --- 1) Central: atualiza, incrementa revisão e marca sync pendente (uma transação, com trava) ---
  let p: Preparado;
  try {
    const { data, error } = await client().rpc("florest_admin_assinatura_preparar", {
      p_admin_id: uid, p_assinatura_id: assinaturaId, p_acao: acao as Acao, p_dados: dados,
    });
    if (error) {
      const conhecido = typeof error.code === "string" ? ERROS_RPC[error.code] : undefined;
      if (conhecido) return erro(conhecido.status, conhecido.erro, conhecido.mensagem, ch);
      log("error", "preparar_falhou", errInfo(error));
      return erro(500, "erro_interno", "Erro interno. Nada foi confirmado; atualize a lista e tente novamente.", ch);
    }
    p = data as Preparado;
  } catch (e) {
    log("error", "preparar_excecao", errInfo(e));
    return erro(500, "erro_interno", "Erro interno. Nada foi confirmado; atualize a lista e tente novamente.", ch);
  }

  const central = {
    assinatura_id: p.assinatura_id, status_conta: p.status_conta, status_pagamento: p.status_pagamento,
    vencimento: p.vencimento, valor_mensal: p.valor_mensal, sistema: p.sistema_slug, revisao: p.revisao,
  };

  // --- 2) PetGestor / nada a enviar ---
  if (!p.precisa_sync) {
    log("info", "aplicado", { acao, sistema: p.sistema_slug, modo: p.modo_sync, revisao: p.revisao, mudou: p.mudou });
    return jsonResponse(200, { ok: true, sincronizado: true, sync: p.modo_sync === "local" ? "local" : "ok", central }, ch);
  }

  // --- 3) Sistema remoto: envia server -> server (HMAC) e registra o resultado ---
  let motivoErro: string | null;
  try {
    motivoErro = await sincronizarRemoto(p, "admin:" + uid);
  } catch (e) {
    log("error", "sync_excecao", errInfo(e));
    motivoErro = "erro_interno";
  }

  try {
    const { error } = await client().rpc("florest_admin_assinatura_sync_resultado", {
      p_assinatura_id: p.assinatura_id, p_revisao: p.revisao, p_ok: motivoErro === null, p_erro: motivoErro,
    });
    if (error) throw Object.assign(new Error("db"), { code: error.code });
  } catch (e) {
    log("error", "registrar_resultado_falhou", errInfo(e));
    // O remoto pode ter aplicado, mas o registro não foi gravado: não confirmar. Repetir é seguro (mesma revisão).
    if (motivoErro === null) motivoErro = "registro_falhou";
  }

  log(motivoErro === null ? "info" : "warn", motivoErro === null ? "sincronizado" : "sync_falhou",
    { acao, sistema: p.sistema_slug, revisao: p.revisao, motivo: motivoErro });

  if (motivoErro !== null) {
    return jsonResponse(502, {
      ok: false, erro: "sync_falhou", central_atualizada: true, liberado: false, sync_status: "erro", motivo: motivoErro, central,
      mensagem: "Salvo na Central, mas NÃO sincronizado com o sistema do cliente. O cliente ainda não foi liberado/atualizado lá. Use \"Sincronizar novamente\".",
    }, ch);
  }
  return jsonResponse(200, { ok: true, sincronizado: true, sync: "ok", central }, ch);
}

Deno.serve(async (req) => {
  try { return await handler(req); } catch (e) {
    log("error", "excecao_nao_tratada", errInfo(e));
    return erro(500, "erro_interno", "Erro interno. Tente novamente.");
  }
});
