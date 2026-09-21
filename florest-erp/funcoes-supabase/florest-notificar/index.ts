// =====================================================================
// DistGestor — Edge Function "florest-notificar"  (ARQUIVO ÚNICO para colar no editor do Dashboard)
// Chamada pelo NAVEGADOR (usuário logado) logo após o cadastro. Configurar: Verify JWT = LIGADO.
//
// Não confia em nada vindo do navegador:
//   - a empresa vem SEMPRE de auth.uid() -> perfis.empresa_id (o corpo da requisição é ignorado);
//   - só eventos PENDENTES dessa empresa são reservados (florest_outbox_reservar da Migration 002);
//   - ao central vão SOMENTE { event_id, tipo, empresa_id }, assinados com HMAC-SHA256 (direção s2c, sistema distgestor,
//     endpoint florest-receber-evento). O segredo e a service_role ficam só aqui, no servidor;
//   - o evento só vira "enviado" se o central confirmar { ok: true }; em falha, florest_outbox_concluir(p_ok=false)
//     reagenda com backoff (60s, 5min, 15min, 1h, 6h; após 20 tentativas = falhou).
//
// Secrets (somente NOMES):
//   FLOREST_SYNC_SECRET_DISTGESTOR   segredo HMAC (≥ 32 caracteres), mesmo valor do central
//   FLOREST_CENTRAL_FUNCTIONS_URL    https://<ref do ERP PETSHOP>.supabase.co/functions/v1   (fica só no servidor)
//   FLOREST_ALLOWED_ORIGINS          origem(ns) exata(s) do navegador que abre o DistGestor, separadas por vírgula, sem barra final
//   FLOREST_SYSTEM_SLUG              opcional (padrão: distgestor)
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY são injetados pela própria Supabase. Nenhum segredo neste arquivo.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const ENDPOINT_CENTRAL = "florest-receber-evento";
const TIPO_SUPORTADO = "cadastro_criado";
const MAX_BODY_BYTES = 1024;
const MAX_EVENTOS_POR_CHAMADA = 10;
const PROTOCOL_VERSION = "1";
const SIGNING_PREFIX = "FLOREST-SYNC";
const MIN_SECRET_LENGTH = 32;

const HEADER = {
  version: "x-florest-version",
  system: "x-florest-system",
  direction: "x-florest-direction",
  timestamp: "x-florest-timestamp",
  nonce: "x-florest-nonce",
  signature: "x-florest-signature",
} as const;

const encoder = new TextEncoder();

// ---------------------------------------------------------------------
// 1) Assinatura HMAC (Florest Sync v1)
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
  const texto = [SIGNING_PREFIX, PROTOCOL_VERSION, "s2c", o.system, o.endpoint, String(o.nowSeconds), nonce, bodySha256].join("\n");
  const key = await crypto.subtle.importKey("raw", encoder.encode(o.secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(texto));
  return {
    "content-type": "application/json",
    [HEADER.version]: PROTOCOL_VERSION,
    [HEADER.system]: o.system,
    [HEADER.direction]: "s2c",
    [HEADER.timestamp]: String(o.nowSeconds),
    [HEADER.nonce]: nonce,
    [HEADER.signature]: "v1=" + bytesToHex(new Uint8Array(sig)),
  };
}

// ---------------------------------------------------------------------
// 2) Utilidades HTTP / CORS / log seguro / anti-SSRF
// ---------------------------------------------------------------------
function jsonResponse(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff", ...extra },
  });
}
const erro = (status: number, codigo: string, extra: Record<string, string> = {}) => jsonResponse(status, { ok: false, erro: codigo }, extra);
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

// log seguro: descarta chaves sensíveis; nunca registra e-mail, CNPJ, nomes, tokens ou segredos
const CHAVES_SENSIVEIS = /secret|token|authorization|signature|hmac|key|jwt|cookie|senha|password|email|cnpj|cpf|telefone|nome|dados|body|payload/i;
function log(nivel: "info" | "warn" | "error", evento: string, campos: Record<string, unknown> = {}) {
  const limpo: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(campos)) {
    if (CHAVES_SENSIVEIS.test(k)) continue;
    if (typeof v === "string") limpo[k] = v.length > 120 ? v.slice(0, 120) + "…" : v;
    else if (typeof v === "number" || typeof v === "boolean" || v === null) limpo[k] = v;
  }
  console.log(JSON.stringify({ fn: "florest-notificar", nivel, evento, ...limpo }));
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

// anti-SSRF: só https://<ref de 20 chars>.supabase.co/functions/v1/<endpoint>
function centralEndpointUrl(base: unknown, endpoint: string): string | null {
  if (typeof base !== "string") return null;
  let url: URL;
  try { url = new URL(base.replace(/\/+$/, "")); } catch { return null; }
  if (url.protocol !== "https:" || url.username || url.password || url.port || url.search || url.hash) return null;
  if (!/^[a-z0-9]{20}\.supabase\.co$/.test(url.hostname) || url.pathname !== "/functions/v1") return null;
  return `https://${url.hostname}/functions/v1/${endpoint}`;
}

type PostResult =
  | { ok: true; status: number; json: Record<string, unknown> | null }
  | { ok: false; motivo: "rede" | "timeout" | "http" | "resposta_grande"; status?: number };

async function postSigned(o: { url: string; endpoint: string; body: Record<string, unknown>; secret: string; system: string; nowSeconds: number }): Promise<PostResult> {
  const corpo = JSON.stringify(o.body);
  const headers = await signRequest({ secret: o.secret, system: o.system, endpoint: o.endpoint, body: corpo, nowSeconds: o.nowSeconds });
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 8000);
  try {
    const resp = await fetch(o.url, { method: "POST", headers, body: corpo, redirect: "error", signal: ctrl.signal });
    const lido = await readStreamLimited(resp.body, 64 * 1024);
    if (!lido.ok) return { ok: false, motivo: "resposta_grande", status: resp.status };
    if (resp.status < 200 || resp.status >= 300) return { ok: false, motivo: "http", status: resp.status };
    return { ok: true, status: resp.status, json: parseJsonObject(lido.bytes) };
  } catch (e) {
    const nome = e && typeof e === "object" ? (e as { name?: string }).name : "";
    return { ok: false, motivo: nome === "AbortError" ? "timeout" : "rede" };
  } finally {
    clearTimeout(t);
  }
}

// ---------------------------------------------------------------------
// 3) Banco (service_role SOMENTE aqui, no servidor; chave vem das variáveis injetadas pela Supabase)
//    RPCs da Migration 002 (somente service_role): florest_outbox_reservar(p_limite, p_lease_segundos, p_empresa_id)
//    e florest_outbox_concluir(p_id, p_ok, p_erro).
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

let db: ReturnType<typeof createClient> | null = null;
function client() {
  if (!db) {
    const url = Deno.env.get("SUPABASE_URL");
    const key = resolveServerKey();
    if (!url || !key) throw new Error("configuracao_supabase_ausente");
    db = createClient(url, key, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
      global: { headers: { "x-florest-origem": "edge-function" } },
    });
  }
  return db;
}
function falha(error: { code?: string }): never {
  throw Object.assign(new Error("db"), { code: error.code });   // só o SQLSTATE sobe; a mensagem do banco é descartada
}

interface EventoOutbox { id: number; event_id: string; tipo: string; empresa_id: string }

// O JWT é validado pelo servidor de autenticação; usamos só o id do usuário devolvido.
async function autenticar(jwt: string): Promise<string | null> {
  const { data, error } = await client().auth.getUser(jwt);
  if (error || !data?.user?.id) return null;
  return data.user.id;
}
// Empresa do usuário: leitura por auth.uid() -> perfis.empresa_id. Nunca vem do navegador.
async function obterEmpresaId(userId: string): Promise<string | null> {
  const { data, error } = await client().from("perfis").select("empresa_id").eq("id", userId).maybeSingle();
  if (error) falha(error);
  return (data as { empresa_id?: string } | null)?.empresa_id ?? null;
}
async function reservar(empresaId: string): Promise<EventoOutbox[]> {
  const { data, error } = await client().rpc("florest_outbox_reservar", { p_limite: MAX_EVENTOS_POR_CHAMADA, p_lease_segundos: 60, p_empresa_id: empresaId });
  if (error) falha(error);
  return (data ?? []) as EventoOutbox[];
}
async function concluir(id: number, ok: boolean, erroCurto: string | null): Promise<void> {
  const { error } = await client().rpc("florest_outbox_concluir", { p_id: id, p_ok: ok, p_erro: erroCurto });
  if (error) falha(error);
}

// ---------------------------------------------------------------------
// 4) Handler
// ---------------------------------------------------------------------
const SLUG = (Deno.env.get("FLOREST_SYSTEM_SLUG") ?? "distgestor").toLowerCase();
const CENTRAL_URL = centralEndpointUrl(Deno.env.get("FLOREST_CENTRAL_FUNCTIONS_URL"), ENDPOINT_CENTRAL);
const SEGREDO = Deno.env.get("FLOREST_SYNC_SECRET_" + SLUG.toUpperCase()) ?? null;
const ORIGENS = (Deno.env.get("FLOREST_ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter((s) => s.length > 0);

async function handler(req: Request): Promise<Response> {
  const cors = decideCors(req, ORIGENS);
  if (cors.tipo === "negada") return erro(403, "origem_nao_permitida");
  const ch = cors.tipo === "permitida" ? cors.headers : {};

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return erro(405, "metodo_nao_permitido", { ...ch, allow: "POST, OPTIONS" });

  // --- autenticação (o navegador só entrega o JWT do usuário) ---
  const m = /^Bearer\s+([A-Za-z0-9._~+/=-]{20,4096})$/.exec(req.headers.get("authorization") ?? "");
  if (!m) return erro(401, "nao_autenticado", ch);
  let userId: string | null;
  try { userId = await autenticar(m[1]); } catch (e) {
    log("error", "auth_falhou", errInfo(e));
    return erro(500, "erro_interno", ch);
  }
  if (!userId) return erro(401, "nao_autenticado", ch);

  // --- corpo: limitado e IGNORADO (nunca é autoridade). Se vier, precisa ser JSON. ---
  const corpo = await readBodyLimited(req, MAX_BODY_BYTES);
  if (!corpo.ok) return erro(corpo.status, corpo.erro, ch);
  if (corpo.bytes.length > 0 && !isJsonContentType(req.headers)) return erro(415, "tipo_de_conteudo_invalido", ch);

  // --- empresa do usuário, vinda do banco ---
  let empresaId: string | null;
  try { empresaId = await obterEmpresaId(userId); } catch (e) {
    log("error", "empresa_falhou", errInfo(e));
    return erro(500, "erro_interno", ch);
  }
  if (!empresaId) return erro(403, "sem_empresa", ch);

  // --- configuração (falha fechada; nada é reservado se não dá para enviar) ---
  if (!CENTRAL_URL || !SEGREDO) {
    log("error", "nao_configurado");
    return erro(503, "nao_configurado", ch);
  }

  let eventos: EventoOutbox[];
  try { eventos = (await reservar(empresaId)).slice(0, MAX_EVENTOS_POR_CHAMADA); } catch (e) {
    log("error", "reservar_falhou", errInfo(e));
    return erro(500, "erro_interno", ch);
  }

  let enviados = 0;
  let pendentes = 0;
  for (const ev of eventos) {
    let ok = false;
    let motivo: string | null;
    if (ev.empresa_id !== empresaId) {
      motivo = "empresa_divergente";                    // defesa em profundidade: nunca envia evento de outra empresa
    } else if (ev.tipo !== TIPO_SUPORTADO) {
      motivo = "tipo_nao_suportado";
    } else {
      // ao central vão SOMENTE { event_id, tipo, empresa_id }
      const r = await postSigned({
        url: CENTRAL_URL, endpoint: ENDPOINT_CENTRAL, secret: SEGREDO, system: SLUG,
        nowSeconds: Math.floor(Date.now() / 1000), body: { event_id: ev.event_id, tipo: ev.tipo, empresa_id: ev.empresa_id },
      });
      ok = r.ok && r.json !== null && r.json["ok"] === true;      // "enviado" só se o central confirmar sucesso
      motivo = ok ? null : r.ok ? "central_resposta_invalida" : `central_${r.motivo}${r.status ? "_" + r.status : ""}`;
    }
    try { await concluir(ev.id, ok, motivo); } catch (e) { log("error", "concluir_falhou", errInfo(e)); }   // ok=false -> reagenda com backoff
    if (ok) enviados++; else pendentes++;
    log(ok ? "info" : "warn", ok ? "evento_enviado" : "evento_nao_enviado", { event_id: ev.event_id, motivo });
  }

  return jsonResponse(200, { ok: true, total: eventos.length, enviados, pendentes }, ch);
}

Deno.serve(async (req) => {
  try { return await handler(req); } catch (e) {
    log("error", "excecao_nao_tratada", errInfo(e));
    return jsonResponse(500, { ok: false, erro: "erro_interno" });
  }
});
