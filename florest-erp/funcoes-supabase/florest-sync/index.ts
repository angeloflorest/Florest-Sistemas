// =====================================================================
// DistGestor — Edge Function "florest-sync" (ARQUIVO ÚNICO, para colar no editor do Dashboard)
// Servidor -> servidor. Chamada SOMENTE pelo Admin central, assinada com HMAC-SHA256 (direção c2s).
// Configurar: verify_jwt = DESLIGADO (a autenticação é a assinatura HMAC, não há JWT de usuário).
// Ações: obter_empresa | aplicar | listar  -> RPCs da Migration 002 (service_role, só no servidor).
// Secrets (somente NOMES): FLOREST_SYNC_SECRET_DISTGESTOR  (+ opcional _NEXT na rotação; + opcional FLOREST_SYSTEM_SLUG)
// Nenhuma chave/segredo neste arquivo. SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY são injetados pela própria Supabase.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

// ---------------------------------------------------------------------
// 1) Protocolo HMAC (Florest Sync v1)
//    Assinado: "FLOREST-SYNC" \n versão \n direção \n sistema \n endpoint \n timestamp \n nonce \n SHA256(corpo bruto)
// ---------------------------------------------------------------------
const ENDPOINT = "florest-sync";
const MAX_BODY_BYTES = 8 * 1024;
const PROTOCOL_VERSION = "1";
const SIGNING_PREFIX = "FLOREST-SYNC";
const MAX_SKEW_SECONDS = 300;      // janela de timestamp: ±5 min
const NONCE_TTL_SECONDS = 600;
const MIN_SECRET_LENGTH = 32;      // segredo curto = recusado (falha fechada)

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
const NONCE_RE = /^[A-Za-z0-9_-]{16,64}$/;
const TS10_RE = /^\d{10}$/;
const SIG_RE = /^v1=([0-9a-f]{64})$/i;

function bytesToHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}
function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0 || !/^[0-9a-f]*$/i.test(hex)) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}
async function sha256Hex(data: Uint8Array): Promise<string> {
  return bytesToHex(new Uint8Array(await crypto.subtle.digest("SHA-256", data as BufferSource)));
}
async function hmacKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
}

// Anti-replay em memória (por instância). Complementa a janela de 5 min e a idempotência por revisão.
class MemoryNonceStore {
  private mapa = new Map<string, number>();
  private limite = 20000;
  registrarSeNovo(chave: string, ttl: number, agora: number): boolean {
    if (this.mapa.size >= this.limite) {
      for (const [k, exp] of this.mapa) if (exp <= agora) this.mapa.delete(k);
      while (this.mapa.size >= this.limite) {
        const p = this.mapa.keys().next();
        if (p.done) break;
        this.mapa.delete(p.value);
      }
    }
    const exp = this.mapa.get(chave);
    if (exp !== undefined && exp > agora) return false;
    this.mapa.set(chave, agora + ttl);
    return true;
  }
}

type VerifyResult = { ok: true } | { ok: false; reason: string };

async function verifyRequest(
  headers: Headers, rawBody: Uint8Array,
  o: { secrets: string[]; expectedSystem: string; nowSeconds: number; nonceStore: MemoryNonceStore },
): Promise<VerifyResult> {
  const secrets = o.secrets.filter((s) => s.length >= MIN_SECRET_LENGTH).slice(0, 2);
  if (secrets.length === 0) return { ok: false, reason: "segredo_nao_configurado" };

  const version = headers.get(HEADER.version);
  const system = headers.get(HEADER.system);
  const direction = headers.get(HEADER.direction);
  const tsRaw = headers.get(HEADER.timestamp);
  const nonce = headers.get(HEADER.nonce);
  const sigRaw = headers.get(HEADER.signature);
  if (!version || !system || !direction || !tsRaw || !nonce || !sigRaw) return { ok: false, reason: "cabecalhos" };
  if (version !== PROTOCOL_VERSION) return { ok: false, reason: "versao" };
  if (direction !== "c2s") return { ok: false, reason: "direcao" };                       // só o central chama
  if (!SLUG_RE.test(system) || system !== o.expectedSystem) return { ok: false, reason: "sistema" };
  if (!TS10_RE.test(tsRaw) || !NONCE_RE.test(nonce)) return { ok: false, reason: "cabecalhos" };

  const timestamp = Number(tsRaw);
  if (Math.abs(o.nowSeconds - timestamp) > MAX_SKEW_SECONDS) return { ok: false, reason: "timestamp" };

  const m = SIG_RE.exec(sigRaw);
  const sigBytes = m ? hexToBytes(m[1]) : null;
  if (!sigBytes) return { ok: false, reason: "assinatura" };

  const bodySha256 = await sha256Hex(rawBody);
  const dados = encoder.encode([SIGNING_PREFIX, version, "c2s", system, ENDPOINT, String(timestamp), nonce, bodySha256].join("\n"));

  // verificação em tempo constante (crypto.subtle.verify); todas as chaves candidatas são avaliadas
  const resultados = await Promise.all(secrets.map(async (s) =>
    await crypto.subtle.verify("HMAC", await hmacKey(s), sigBytes as BufferSource, dados as BufferSource)));
  if (!resultados.some((r) => r === true)) return { ok: false, reason: "assinatura" };

  // o nonce só é registrado DEPOIS de a assinatura ser válida
  if (!o.nonceStore.registrarSeNovo(`${system}:${nonce}`, NONCE_TTL_SECONDS, o.nowSeconds)) return { ok: false, reason: "replay" };
  return { ok: true };
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
const erro = (status: number, codigo: string, extra: Record<string, string> = {}) => jsonResponse(status, { ok: false, erro: codigo }, extra);

const isJsonContentType = (h: Headers) => /^application\/json\s*(;\s*charset=utf-8\s*)?$/.test((h.get("content-type") ?? "").toLowerCase());

async function readBodyLimited(req: Request, maxBytes: number): Promise<{ ok: true; bytes: Uint8Array } | { ok: false; status: number; erro: string }> {
  const cl = req.headers.get("content-length");
  if (cl !== null) {
    if (!/^\d{1,10}$/.test(cl)) return { ok: false, status: 400, erro: "requisicao_invalida" };
    if (Number(cl) > maxBytes) return { ok: false, status: 413, erro: "corpo_grande_demais" };
  }
  if (!req.body) return { ok: true, bytes: new Uint8Array(0) };
  const reader = req.body.getReader();
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

function parseJsonObject(bytes: Uint8Array): Record<string, unknown> | null {
  try {
    const v = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    return v === null || typeof v !== "object" || Array.isArray(v) ? null : (v as Record<string, unknown>);
  } catch { return null; }
}
const onlyKeys = (o: Record<string, unknown>, permitidas: readonly string[]) => Object.keys(o).every((k) => permitidas.includes(k));

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;
const isUuid = (v: unknown): v is string => typeof v === "string" && UUID_RE.test(v);
function isIsoDate(v: unknown): v is string {
  if (typeof v !== "string" || !DATE_RE.test(v)) return false;
  const d = new Date(v + "T00:00:00Z");
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === v;
}
const isIntInRange = (v: unknown, min: number, max: number): v is number =>
  typeof v === "number" && Number.isSafeInteger(v) && v >= min && v <= max;

// log seguro: descarta chaves sensíveis e nunca registra corpo, e-mail, CNPJ, nomes ou segredos
const CHAVES_SENSIVEIS = /secret|token|authorization|signature|hmac|key|jwt|cookie|senha|password|email|cnpj|cpf|telefone|nome|dados|body|payload/i;
function log(nivel: "info" | "warn" | "error", evento: string, campos: Record<string, unknown> = {}) {
  const limpo: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(campos)) {
    if (CHAVES_SENSIVEIS.test(k)) continue;
    if (typeof v === "string") limpo[k] = v.length > 120 ? v.slice(0, 120) + "…" : v;
    else if (typeof v === "number" || typeof v === "boolean" || v === null) limpo[k] = v;
  }
  console.log(JSON.stringify({ fn: "florest-sync", nivel, evento, ...limpo }));
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

// ---------------------------------------------------------------------
// 3) Banco (service_role SOMENTE aqui, no servidor; a chave vem das variáveis injetadas pela Supabase)
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

/** Erros FS00x das RPCs da Migration 002 -> resposta segura. */
function mapaErroRpc(e: unknown): { status: number; codigo: string } {
  const code = e && typeof e === "object" ? (e as { code?: unknown }).code : undefined;
  switch (code) {
    case "FS001": case "FS002": case "FS003": return { status: 400, codigo: "dados_invalidos" };
    case "FS004": return { status: 404, codigo: "empresa_nao_encontrada" };
    case "FS005": case "FS006": return { status: 409, codigo: "conflito_de_vinculo" };
    default: return { status: 500, codigo: "erro_interno" };
  }
}

// ---------------------------------------------------------------------
// 4) Handler
//    Ordem das defesas: método -> sem Origin -> Content-Type -> tamanho -> HMAC/timestamp/replay -> JSON -> ação
// ---------------------------------------------------------------------
const SLUG = (Deno.env.get("FLOREST_SYSTEM_SLUG") ?? "distgestor").toLowerCase();
const nonceStore = new MemoryNonceStore();
const STATUS = ["pendente", "aprovado", "bloqueado"];

function lerSegredos(): string[] {
  const base = "FLOREST_SYNC_SECRET_" + SLUG.toUpperCase();     // FLOREST_SYNC_SECRET_DISTGESTOR (+ _NEXT na rotação)
  return [Deno.env.get(base), Deno.env.get(base + "_NEXT")].filter((s): s is string => typeof s === "string" && s.length > 0);
}

async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return erro(405, "metodo_nao_permitido", { allow: "POST" });
  if (req.headers.get("origin") !== null) return erro(403, "origem_nao_permitida");   // navegador não chama isto
  if (!isJsonContentType(req.headers)) return erro(415, "tipo_de_conteudo_invalido");

  const corpo = await readBodyLimited(req, MAX_BODY_BYTES);
  if (!corpo.ok) return erro(corpo.status, corpo.erro);

  const v = await verifyRequest(req.headers, corpo.bytes, {
    secrets: lerSegredos(), expectedSystem: SLUG, nowSeconds: Math.floor(Date.now() / 1000), nonceStore,
  });
  if (!v.ok) {
    log("warn", "assinatura_recusada", { motivo: v.reason });
    return erro(401, "nao_autorizado");                          // o motivo real fica só no log
  }

  const b = parseJsonObject(corpo.bytes);
  if (!b) return erro(400, "corpo_invalido");
  const acao = b["action"];

  try {
    if (acao === "obter_empresa") {
      if (!onlyKeys(b, ["action", "empresa_id"]) || !isUuid(b["empresa_id"])) return erro(400, "dados_invalidos");
      const { data, error } = await client().rpc("florest_obter_empresa", { p_empresa_id: b["empresa_id"] });
      if (error) falha(error);
      return jsonResponse(200, { ok: true, empresa: (data as Record<string, unknown> | null) ?? null });
    }

    if (acao === "aplicar") {
      if (!onlyKeys(b, ["action", "empresa_id", "assinatura_id", "revisao", "status_conta", "vencimento", "motivo", "ator"])) return erro(400, "dados_invalidos");
      const { empresa_id, assinatura_id, revisao, status_conta, vencimento, motivo, ator } = b;
      if (!isUuid(empresa_id) || !isUuid(assinatura_id)) return erro(400, "dados_invalidos");
      if (!isIntInRange(revisao, 1, Number.MAX_SAFE_INTEGER)) return erro(400, "dados_invalidos");
      if (typeof status_conta !== "string" || !STATUS.includes(status_conta)) return erro(400, "dados_invalidos");
      if (vencimento !== null && vencimento !== undefined && !isIsoDate(vencimento)) return erro(400, "dados_invalidos");
      if (status_conta === "aprovado" && !isIsoDate(vencimento)) return erro(400, "dados_invalidos");
      if (motivo !== undefined && motivo !== null && (typeof motivo !== "string" || motivo.length > 500)) return erro(400, "dados_invalidos");
      if (ator !== undefined && ator !== null && (typeof ator !== "string" || ator.length > 200)) return erro(400, "dados_invalidos");
      const { data, error } = await client().rpc("florest_aplicar_assinatura", {
        p_empresa_id: empresa_id, p_assinatura_id: assinatura_id, p_revisao: revisao,
        p_status_conta: status_conta, p_vencimento: (vencimento as string | null | undefined) ?? null,
        p_motivo: (motivo as string | null | undefined) ?? null, p_ator: (ator as string | null | undefined) ?? null,
      });
      if (error) falha(error);
      const r = data as Record<string, unknown>;
      log("info", "aplicar", { empresa_id, revisao, aplicado: r?.["aplicado"] === true });
      return jsonResponse(200, { ok: true, resultado: r });
    }

    if (acao === "listar") {
      if (!onlyKeys(b, ["action", "apos_atualizado", "apos_id", "limite"])) return erro(400, "dados_invalidos");
      const { apos_atualizado, apos_id, limite } = b;
      if (apos_atualizado !== undefined && apos_atualizado !== null && (typeof apos_atualizado !== "string" || !TS_RE.test(apos_atualizado) || Number.isNaN(Date.parse(apos_atualizado)))) return erro(400, "dados_invalidos");
      if (apos_id !== undefined && apos_id !== null && !isUuid(apos_id)) return erro(400, "dados_invalidos");
      if (limite !== undefined && !isIntInRange(limite, 1, 500)) return erro(400, "dados_invalidos");
      const { data, error } = await client().rpc("florest_listar_empresas", {
        p_apos_atualizado: (apos_atualizado as string | null | undefined) ?? null,
        p_apos_id: (apos_id as string | null | undefined) ?? null,
        p_limite: (limite as number | undefined) ?? 200,
      });
      if (error) falha(error);
      const linhas = (data ?? []) as Array<Record<string, unknown>>;
      const ultima = linhas.length > 0 ? linhas[linhas.length - 1] : null;
      return jsonResponse(200, {
        ok: true, empresas: linhas,
        proximo: ultima ? { apos_atualizado: ultima["atualizado_em"], apos_id: ultima["empresa_id"] } : null,
      });
    }

    return erro(400, "acao_invalida");
  } catch (e) {
    const m = mapaErroRpc(e);
    log(m.status >= 500 ? "error" : "warn", "acao_falhou", { acao: typeof acao === "string" ? acao : "?", ...errInfo(e) });
    return erro(m.status, m.codigo);
  }
}

Deno.serve(async (req) => {
  try { return await handler(req); } catch (e) {
    log("error", "excecao_nao_tratada", errInfo(e));
    return jsonResponse(500, { ok: false, erro: "erro_interno" });
  }
});
