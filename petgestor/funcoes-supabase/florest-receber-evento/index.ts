// =====================================================================
// CENTRAL (Supabase ERP PETSHOP) — Edge Function "florest-receber-evento"  (ARQUIVO ÚNICO para o Dashboard)
// Servidor -> servidor. Configurar: Verify JWT = DESLIGADO (a autenticação é a assinatura HMAC-SHA256, direção s2c).
//
// v2 (Cadastro completo): além de nome/responsável/e-mail, repassa razão social, CNPJ, telefone e endereço vindos do sistema.
//   Nada mais mudou: HMAC, direção s2c, replay, idempotência por event_id, callback c2s e RPCs continuam idênticos.
//   Campos novos ausentes/inválidos viram null (cadastros antigos continuam funcionando; deploy pode ser feito antes ou depois das migrations).
// Fluxo: o sistema (ex.: DistGestor) envia um AVISO assinado { event_id, tipo, empresa_id }. O aviso NÃO é fonte de dados:
// depois de validar assinatura/timestamp/replay/sistema, o central chama o próprio sistema (florest-sync, direção c2s)
// para obter os dados canônicos e só então registra via RPC (florest_registrar_cadastro). Idempotente por event_id.
//
// Secrets (somente NOMES): FLOREST_SYNC_SECRET_DISTGESTOR  (+ opcional FLOREST_SYNC_SECRET_DISTGESTOR_NEXT na rotação)
//   (um FLOREST_SYNC_SECRET_<SLUG> por sistema futuro). SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY são injetados pela Supabase.
// O endereço do DistGestor (sync_url) vem da tabela florest_sistemas (RPC florest_sistema_obter) — nada de URL neste arquivo.
// Enquanto sync_url for NULL/inválida, a função responde 500 (erro_interno) SEM registrar o evento.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

// ---------------------------------------------------------------------
// 1) Protocolo HMAC (Florest Sync v1)
//    Assinado: "FLOREST-SYNC" \n versão \n direção \n sistema \n endpoint \n timestamp \n nonce \n SHA256(corpo bruto)
// ---------------------------------------------------------------------
const ENDPOINT = "florest-receber-evento";
const ENDPOINT_SYNC = "florest-sync";
const MAX_BODY_BYTES = 4 * 1024;
const TIPOS_ACEITOS = ["cadastro_criado"];
const PROTOCOL_VERSION = "1";
const SIGNING_PREFIX = "FLOREST-SYNC";
const MAX_SKEW_SECONDS = 300;      // ±5 min
const NONCE_TTL_SECONDS = 600;
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
function hmacKey(secret: string, usages: KeyUsage[]): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, usages);
}
function randomNonce(): string {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return bytesToHex(b);
}
function signingString(direction: string, system: string, endpoint: string, timestamp: number, nonce: string, bodySha256: string): string {
  return [SIGNING_PREFIX, PROTOCOL_VERSION, direction, system, endpoint, String(timestamp), nonce, bodySha256].join("\n");
}

/** Cabeçalhos assinados para um corpo JSON (string). Usado no callback central -> sistema (c2s). */
async function signRequest(o: { secret: string; direction: "s2c" | "c2s"; system: string; endpoint: string; body: string; nowSeconds: number }): Promise<Record<string, string>> {
  if (o.secret.length < MIN_SECRET_LENGTH) throw new Error("segredo_invalido");
  const nonce = randomNonce();
  const bodySha256 = await sha256Hex(encoder.encode(o.body));
  const sig = await crypto.subtle.sign("HMAC", await hmacKey(o.secret, ["sign"]),
    encoder.encode(signingString(o.direction, o.system, o.endpoint, o.nowSeconds, nonce, bodySha256)));
  return {
    "content-type": "application/json",
    [HEADER.version]: PROTOCOL_VERSION,
    [HEADER.system]: o.system,
    [HEADER.direction]: o.direction,
    [HEADER.timestamp]: String(o.nowSeconds),
    [HEADER.nonce]: nonce,
    [HEADER.signature]: "v1=" + bytesToHex(new Uint8Array(sig)),
  };
}

// Anti-replay em memória (por instância). Complementa a janela de 5 min e a idempotência por event_id.
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

/** Valida um aviso recebido: cabeçalhos -> versão -> direção s2c -> sistema -> timestamp ±5 min -> HMAC (tempo constante) -> replay. */
async function verifyRequest(headers: Headers, rawBody: Uint8Array, o: { secrets: string[]; expectedSystem: string; nowSeconds: number; nonceStore: MemoryNonceStore }): Promise<VerifyResult> {
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
  if (direction !== "s2c") return { ok: false, reason: "direcao" };                       // só sistemas chamam esta função
  if (!SLUG_RE.test(system) || system !== o.expectedSystem) return { ok: false, reason: "sistema" };
  if (!TS10_RE.test(tsRaw) || !NONCE_RE.test(nonce)) return { ok: false, reason: "cabecalhos" };

  const timestamp = Number(tsRaw);
  if (Math.abs(o.nowSeconds - timestamp) > MAX_SKEW_SECONDS) return { ok: false, reason: "timestamp" };

  const m = SIG_RE.exec(sigRaw);
  const sigBytes = m ? hexToBytes(m[1]) : null;
  if (!sigBytes) return { ok: false, reason: "assinatura" };

  const dados = encoder.encode(signingString("s2c", system, ENDPOINT, timestamp, nonce, await sha256Hex(rawBody)));
  const resultados = await Promise.all(secrets.map(async (s) =>
    await crypto.subtle.verify("HMAC", await hmacKey(s, ["verify"]), sigBytes as BufferSource, dados as BufferSource)));
  if (!resultados.some((r) => r === true)) return { ok: false, reason: "assinatura" };

  if (!o.nonceStore.registrarSeNovo(`${system}:${nonce}`, NONCE_TTL_SECONDS, o.nowSeconds)) return { ok: false, reason: "replay" };
  return { ok: true };
}

// ---------------------------------------------------------------------
// 2) Utilidades HTTP / validação / log seguro / anti-SSRF
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
const onlyKeys = (o: Record<string, unknown>, permitidas: readonly string[]) => Object.keys(o).every((k) => permitidas.includes(k));
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const isUuid = (v: unknown): v is string => typeof v === "string" && UUID_RE.test(v);

// log seguro: descarta chaves sensíveis; nunca registra corpo, e-mail, CNPJ, nomes ou segredos
const CHAVES_SENSIVEIS = /secret|token|authorization|signature|hmac|key|jwt|cookie|senha|password|email|cnpj|cpf|telefone|nome|dados|body|payload/i;
function log(nivel: "info" | "warn" | "error", evento: string, campos: Record<string, unknown> = {}) {
  const limpo: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(campos)) {
    if (CHAVES_SENSIVEIS.test(k)) continue;
    if (typeof v === "string") limpo[k] = v.length > 120 ? v.slice(0, 120) + "…" : v;
    else if (typeof v === "number" || typeof v === "boolean" || v === null) limpo[k] = v;
  }
  console.log(JSON.stringify({ fn: "florest-receber-evento", nivel, evento, ...limpo }));
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

// anti-SSRF: o callback só vai para https://<ref de 20 chars>.supabase.co/functions/v1/florest-sync (mesma regra do CHECK no banco)
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
  | { ok: false; motivo: "rede" | "timeout" | "http" | "resposta_grande"; status?: number };

async function postSigned(o: { url: string; endpoint: string; body: Record<string, unknown>; secret: string; system: string; nowSeconds: number }): Promise<PostResult> {
  const corpo = JSON.stringify(o.body);
  const headers = await signRequest({ secret: o.secret, direction: "c2s", system: o.system, endpoint: o.endpoint, body: corpo, nowSeconds: o.nowSeconds });
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
// 3) Banco central (service_role SOMENTE aqui, no servidor; chave vem das variáveis injetadas pela Supabase)
//    RPCs da Central Migration 001 (somente service_role): florest_sistema_obter, florest_evento_registrar,
//    florest_evento_concluir, florest_registrar_cadastro.
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
function falha(error: { code?: string }): never {
  throw Object.assign(new Error("db"), { code: error.code });   // só o SQLSTATE sobe; a mensagem do banco é descartada
}

type EstadoEvento = "processando" | "processado" | "descartado" | "erro";

const db = {
  async sistemaObter(slug: string): Promise<{ ativo: boolean; sync_url: string | null } | null> {
    const { data, error } = await client().rpc("florest_sistema_obter", { p_slug: slug });
    if (error) falha(error);
    return (data as { ativo: boolean; sync_url: string | null } | null) ?? null;
  },
  async eventoRegistrar(slug: string, eventId: string, tipo: string, ref: string): Promise<{ deve_processar: boolean; estado: EstadoEvento }> {
    const { data, error } = await client().rpc("florest_evento_registrar", { p_slug: slug, p_event_id: eventId, p_tipo: tipo, p_ref_externa: ref });
    if (error) falha(error);
    return data as { deve_processar: boolean; estado: EstadoEvento };
  },
  async eventoConcluir(slug: string, eventId: string, estado: "processado" | "descartado" | "erro", resultado: Record<string, unknown> | null, erroCurto: string | null): Promise<void> {
    const { error } = await client().rpc("florest_evento_concluir", { p_slug: slug, p_event_id: eventId, p_estado: estado, p_resultado: resultado, p_erro: erroCurto });
    if (error) falha(error);
  },
  async registrarCadastro(slug: string, ref: string, dados: DadosEmpresa): Promise<{ acao: string }> {
    const { data, error } = await client().rpc("florest_registrar_cadastro", { p_slug: slug, p_ref_externa: ref, p_dados: dados });
    if (error) falha(error);
    return data as { acao: string };
  },
};

// ---------------------------------------------------------------------
// 4) Dados canônicos: sempre reconstruídos campo a campo a partir da resposta do sistema (nunca do aviso)
//    Só os campos cadastrais que a RPC usa. status_conta/vencimento/assinatura_id/revisao NÃO são repassados
//    (a RPC os ignoraria; a assinatura nasce pendente e quem decide é o Admin).
// ---------------------------------------------------------------------
interface DadosEmpresa {
  nome: string;                    // Nome Fantasia
  responsavel: string | null;
  email: string | null;
  email_confirmado: boolean;
  criado_em: string;
  // Dados cadastrais (florest_obter_empresa, versão 1 ampliada). Opcionais: cadastros antigos não os têm.
  razao_social: string | null;
  cnpj: string | null;             // 14 dígitos
  telefone: string | null;         // 10 ou 11 dígitos
  cep: string | null;              // 8 dígitos
  logradouro: string | null;
  numero: string | null;
  complemento: string | null;
  bairro: string | null;
  cidade: string | null;
  uf: string | null;               // sigla
}
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,255}$/;
const STATUS = ["pendente", "aprovado", "bloqueado"];

function txt(v: unknown, max: number, obrigatorio: boolean): string | null | undefined {
  if (v === null || v === undefined) return obrigatorio ? undefined : null;
  if (typeof v !== "string") return undefined;
  const s = v.trim();
  if (s.length === 0) return obrigatorio ? undefined : null;
  return s.length > max ? undefined : s;
}

/** Campo cadastral opcional: texto válido ou null. Valor fora do padrão vira null (nunca derruba o evento). */
function opt(v: unknown, max: number): string | null {
  const r = txt(v, max, false);
  return r === undefined ? null : r;
}
function optDigitos(v: unknown, re: RegExp): string | null {
  return typeof v === "string" && re.test(v) ? v : null;
}
const UFS = new Set(["AC","AL","AP","AM","BA","CE","DF","ES","GO","MA","MT","MS","MG","PA","PB","PR","PE","PI","RJ","RN","RS","RO","RR","SC","SP","SE","TO"]);

/** Valida o contrato da resposta do DistGestor (florest_obter_empresa, versão 1). Devolve null se algo estiver fora do contrato. */
function normalizarEmpresa(e: Record<string, unknown>, empresaId: string): DadosEmpresa | null {
  if (e["versao"] !== 1) return null;
  if (typeof e["empresa_id"] !== "string" || e["empresa_id"].toLowerCase() !== empresaId.toLowerCase()) return null;
  const nome = txt(e["nome"], 200, true);
  const responsavel = txt(e["responsavel"], 200, false);
  const email = txt(e["email"], 320, false);
  if (nome === undefined || nome === null || responsavel === undefined || email === undefined) return null;
  if (email !== null && !EMAIL_RE.test(email)) return null;
  const status = e["status_conta"];
  if (typeof status !== "string" || !STATUS.includes(status)) return null;
  const venc = e["vencimento"];
  if (venc !== null && venc !== undefined && (typeof venc !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(venc))) return null;
  const ass = e["assinatura_id"];
  if (ass !== null && ass !== undefined && !isUuid(ass)) return null;
  const rev = e["revisao"];
  if (typeof rev !== "number" || !Number.isSafeInteger(rev) || rev < 0) return null;
  const criado = e["criado_em"];
  if (typeof criado !== "string" || Number.isNaN(Date.parse(criado))) return null;
  return {
    nome, responsavel, email: email ? email.toLowerCase() : null,
    email_confirmado: e["email_confirmado"] === true,
    criado_em: new Date(criado).toISOString(),
    razao_social: opt(e["razao_social"], 200),
    cnpj: optDigitos(e["cnpj"], /^\d{14}$/),
    telefone: optDigitos(e["telefone"], /^\d{10,11}$/),
    cep: optDigitos(e["cep"], /^\d{8}$/),
    logradouro: opt(e["logradouro"], 200),
    numero: opt(e["numero"], 20),
    complemento: opt(e["complemento"], 100),
    bairro: opt(e["bairro"], 100),
    cidade: opt(e["cidade"], 100),
    uf: typeof e["uf"] === "string" && UFS.has(e["uf"]) ? e["uf"] : null,
  };
}

// ---------------------------------------------------------------------
// 5) Handler
//    Ordem: método -> sem Origin -> Content-Type -> tamanho -> sistema/HMAC/timestamp/replay -> formato -> sistema ativo e sync_url
//           -> idempotência (event_id) -> callback assinado (dados canônicos) -> RPC de cadastro -> concluir evento
// ---------------------------------------------------------------------
const nonceStore = new MemoryNonceStore();

/** [FLOREST_SYNC_SECRET_<SLUG>, FLOREST_SYNC_SECRET_<SLUG>_NEXT] — só nomes; valores vêm de Edge Function Secrets. */
function getSecrets(slug: string): string[] {
  const base = "FLOREST_SYNC_SECRET_" + slug.toUpperCase();
  return [Deno.env.get(base), Deno.env.get(base + "_NEXT")].filter((s): s is string => typeof s === "string" && s.length > 0);
}

async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return erro(405, "metodo_nao_permitido", { allow: "POST" });
  if (req.headers.get("origin") !== null) return erro(403, "origem_nao_permitida");
  if (!isJsonContentType(req.headers)) return erro(415, "tipo_de_conteudo_invalido");

  const corpo = await readBodyLimited(req, MAX_BODY_BYTES);
  if (!corpo.ok) return erro(corpo.status, corpo.erro);

  // --- 1. autenticidade: HMAC + timestamp + replay + sistema/direção ---
  const slug = req.headers.get(HEADER.system) ?? "";
  if (!SLUG_RE.test(slug)) return erro(401, "nao_autorizado");
  const v = await verifyRequest(req.headers, corpo.bytes, {
    secrets: getSecrets(slug), expectedSystem: slug, nowSeconds: Math.floor(Date.now() / 1000), nonceStore,
  });
  if (!v.ok) {
    log("warn", "assinatura_recusada", { sistema: slug, motivo: v.reason });
    return erro(401, "nao_autorizado");                          // o motivo real fica só no log
  }

  // --- 2. formato do aviso: somente { event_id, tipo, empresa_id } ---
  const b = parseJsonObject(corpo.bytes);
  if (!b || !onlyKeys(b, ["event_id", "tipo", "empresa_id"])) return erro(400, "corpo_invalido");
  const { event_id, tipo, empresa_id } = b;
  if (!isUuid(event_id) || !isUuid(empresa_id) || typeof tipo !== "string" || !TIPOS_ACEITOS.includes(tipo)) return erro(400, "corpo_invalido");
  const eventId = event_id.toLowerCase();
  const empresaId = empresa_id.toLowerCase();

  try {
    // --- 3. o sistema existe, está ativo e tem endereço de retorno válido (guardado pelo central) ---
    const cfg = await db.sistemaObter(slug);
    if (!cfg || !cfg.ativo) return erro(403, "sistema_inativo");
    const syncUrl = validateSyncUrl(cfg.sync_url);
    if (!syncUrl) {                                              // ex.: sync_url ainda NULL: falha fechada, evento NÃO é registrado
      log("error", "sync_url_invalida", { sistema: slug });
      return erro(500, "erro_interno");
    }
    const segredo = getSecrets(slug)[0];

    // --- 4. idempotência por event_id ---
    const reg = await db.eventoRegistrar(slug, eventId, tipo, empresaId);
    if (!reg.deve_processar) {
      if (reg.estado === "processado" || reg.estado === "descartado") return jsonResponse(200, { ok: true, estado: reg.estado, duplicado: true });
      return erro(409, "em_processamento");                      // outro processamento em curso: o remetente tenta de novo depois
    }

    // --- 5. dados canônicos: perguntamos ao próprio sistema (o aviso não é confiável) ---
    const r = await postSigned({
      url: syncUrl, endpoint: ENDPOINT_SYNC, secret: segredo, system: slug,
      nowSeconds: Math.floor(Date.now() / 1000), body: { action: "obter_empresa", empresa_id: empresaId },
    });
    if (!r.ok || r.json === null || r.json["ok"] !== true) {
      const motivo = r.ok ? "callback_resposta_invalida" : `callback_${r.motivo}${r.status ? "_" + r.status : ""}`;
      await db.eventoConcluir(slug, eventId, "erro", null, motivo);
      log("warn", "callback_falhou", { sistema: slug, event_id: eventId, motivo });
      return erro(502, "callback_falhou");
    }
    const emp = r.json["empresa"];
    if (emp === null || emp === undefined) {
      await db.eventoConcluir(slug, eventId, "descartado", null, "empresa_inexistente");
      return jsonResponse(200, { ok: true, estado: "descartado" });
    }
    const dados = typeof emp === "object" && !Array.isArray(emp) ? normalizarEmpresa(emp as Record<string, unknown>, empresaId) : null;
    if (!dados) {
      await db.eventoConcluir(slug, eventId, "erro", null, "callback_dados_invalidos");
      log("warn", "callback_dados_invalidos", { sistema: slug, event_id: eventId });
      return erro(502, "callback_falhou");
    }

    // --- 6. registro (cliente + assinatura PENDENTE, ou "possível cliente existente") pela RPC do central ---
    const res = await db.registrarCadastro(slug, empresaId, dados);
    await db.eventoConcluir(slug, eventId, "processado", { acao: res.acao }, null);
    log("info", "evento_processado", { sistema: slug, event_id: eventId, acao: res.acao });
    return jsonResponse(200, { ok: true, estado: "processado", acao: res.acao });
  } catch (e) {
    log("error", "falha_interna", { sistema: slug, ...errInfo(e) });
    try { await db.eventoConcluir(slug, eventId, "erro", null, "erro_interno"); } catch { /* melhor esforço */ }
    return erro(500, "erro_interno");
  }
}

Deno.serve(async (req) => {
  try { return await handler(req); } catch (e) {
    log("error", "excecao_nao_tratada", errInfo(e));
    return jsonResponse(500, { ok: false, erro: "erro_interno" });
  }
});
