// =====================================================================
// DISTGESTOR (Supabase ERP DISTGESTOR) — Edge Function "florest-admin-usuarios-remoto"  (ARQUIVO ÚNICO para o Dashboard)
// Servidor -> servidor. Chamada SOMENTE pela Central (Edge Function "florest-admin-usuarios"), assinada com HMAC (direção c2s).
//
// Configurar: Verify JWT = DESLIGADO (a autenticação é a assinatura HMAC; não há JWT de usuário aqui).
// Secrets (somente NOMES; valores só no painel):
//   FLOREST_SYNC_SECRET_DISTGESTOR        JÁ EXISTE (o mesmo que o florest-sync usa). Opcional _NEXT só durante rotação.
//   FLOREST_SYSTEM_SLUG                   opcional (padrão "distgestor")
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY são injetados pela Supabase. Nenhum segredo neste arquivo.
//
// O endpoint entra na assinatura ("florest-admin-usuarios-remoto"): uma assinatura feita para o florest-sync
// NÃO vale aqui, e vice-versa.
//
// Ações (corpo JSON <= 4 KB):
//   { "action":"listar",          "empresa_id":uuid, "assinatura_id":uuid, "ator":"admin:<uuid>" }
//        -> { ok:true, usuarios:[{ user_id, nome, email, papel, ativo, permissoes }] }
//   { "action":"redefinir_senha", "empresa_id":uuid, "assinatura_id":uuid, "user_id":uuid, "senha":"...", "ator":"admin:<uuid>" }
//        -> { ok:true }      (nunca devolve senha, hash ou token)
//
// Regras de segurança:
//   * a empresa é confirmada NO BANCO DESTE PROJETO: empresas.id = empresa_id E empresas.assinatura_id = assinatura_id;
//   * o usuário alvo só é alterado se existir em perfis COM O MESMO empresa_id (nunca por id solto);
//   * a senha é aplicada pela Admin API (service_role, só aqui). Não é gravada, não é logada, não volta na resposta;
//   * nenhuma resposta traz password / hash / token.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

// ---------------------------------------------------------------------
// 1) Protocolo HMAC (Florest Sync v1) — igual ao florest-sync, com endpoint próprio
//    Assinado: "FLOREST-SYNC" \n versão \n direção \n sistema \n endpoint \n timestamp \n nonce \n SHA256(corpo bruto)
// ---------------------------------------------------------------------
const ENDPOINT = "florest-admin-usuarios-remoto";
const MAX_BODY_BYTES = 4 * 1024;
const PROTOCOL_VERSION = "1";
const SIGNING_PREFIX = "FLOREST-SYNC";
const MAX_SKEW_SECONDS = 300;
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
async function hmacKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
}

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
  if (direction !== "c2s") return { ok: false, reason: "direcao" };
  if (!SLUG_RE.test(system) || system !== o.expectedSystem) return { ok: false, reason: "sistema" };
  if (!TS10_RE.test(tsRaw) || !NONCE_RE.test(nonce)) return { ok: false, reason: "cabecalhos" };

  const timestamp = Number(tsRaw);
  if (Math.abs(o.nowSeconds - timestamp) > MAX_SKEW_SECONDS) return { ok: false, reason: "timestamp" };

  const m = SIG_RE.exec(sigRaw);
  const sigBytes = m ? hexToBytes(m[1]) : null;
  if (!sigBytes) return { ok: false, reason: "assinatura" };

  const bodySha256 = await sha256Hex(rawBody);
  const dados = encoder.encode([SIGNING_PREFIX, version, "c2s", system, ENDPOINT, String(timestamp), nonce, bodySha256].join("\n"));

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
function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" },
  });
}
const erro = (status: number, codigo: string) => jsonResponse(status, { ok: false, erro: codigo });
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
const isUuid = (v: unknown): v is string => typeof v === "string" && UUID_RE.test(v);

/** Regra única da senha: de 5 a 18 caracteres. Não exige maiúscula, minúscula, número nem símbolo. */
function senhaValida(s: unknown): s is string {
  return typeof s === "string" && s.length >= 5 && s.length <= 18;
}

// log seguro: nunca registra corpo, senha, e-mail, nome, tokens ou segredos
const CHAVES_SENSIVEIS = /secret|token|authorization|signature|hmac|key|jwt|cookie|senha|password|email|cnpj|cpf|telefone|nome|dados|body|payload/i;
function log(nivel: "info" | "warn" | "error", evento: string, campos: Record<string, unknown> = {}) {
  const limpo: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(campos)) {
    if (CHAVES_SENSIVEIS.test(k)) continue;
    if (typeof v === "string") limpo[k] = v.length > 120 ? v.slice(0, 120) + "…" : v;
    else if (typeof v === "number" || typeof v === "boolean" || v === null) limpo[k] = v;
  }
  console.log(JSON.stringify({ fn: "florest-admin-usuarios-remoto", nivel, evento, ...limpo }));
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
// 3) Banco (service_role SOMENTE aqui, no servidor)
// ---------------------------------------------------------------------
function resolveServerKey(): string | null {
  const legado = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legado && legado.length > 20) return legado;
  const json = Deno.env.get("SUPABASE_SECRET_KEYS");
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

class ErroNegocio extends Error {
  constructor(public status: number, public codigo: string) { super(codigo); }
}

/** A empresa só vale se o ID E a assinatura batem NESTE banco. Qualquer divergência = 404, sem detalhe. */
async function confirmarEmpresa(empresaId: string, assinaturaId: string): Promise<void> {
  const { data, error } = await client().from("empresas").select("id, assinatura_id").eq("id", empresaId).maybeSingle();
  if (error) throw Object.assign(new Error("db"), { code: (error as { code?: string }).code });
  if (!data) throw new ErroNegocio(404, "empresa_nao_encontrada");
  if ((data as { assinatura_id: string | null }).assinatura_id !== assinaturaId) throw new ErroNegocio(404, "empresa_nao_encontrada");
}

// ---------------------------------------------------------------------
// 4) Handler
//    Ordem das defesas: método -> sem Origin -> Content-Type -> tamanho -> HMAC/timestamp/replay -> JSON -> ação
// ---------------------------------------------------------------------
const SLUG = (Deno.env.get("FLOREST_SYSTEM_SLUG") ?? "distgestor").toLowerCase();
const nonceStore = new MemoryNonceStore();
const PAPEIS = ["proprietario", "funcionario"];

function lerSegredos(): string[] {
  const base = "FLOREST_SYNC_SECRET_" + SLUG.toUpperCase();
  return [Deno.env.get(base), Deno.env.get(base + "_NEXT")].filter((s): s is string => typeof s === "string" && s.length > 0);
}

async function listar(empresaId: string): Promise<Array<Record<string, unknown>>> {
  const { data, error } = await client().from("perfis")
    .select("id, nome, papel, permissoes, ativo, criado_em")
    .eq("empresa_id", empresaId)
    .order("criado_em", { ascending: true })
    .limit(200);
  if (error) throw Object.assign(new Error("db"), { code: (error as { code?: string }).code });
  const perfis = (data ?? []) as Array<{ id: string; nome: string | null; papel: string; permissoes: string[] | null; ativo: boolean }>;

  // e-mail (login) vem do Supabase Auth, via Admin API. Só o e-mail é lido; nenhum outro campo do usuário sai daqui.
  const emails = new Map<string, string>();
  for (let i = 0; i < perfis.length; i += 10) {
    await Promise.all(perfis.slice(i, i + 10).map(async (p) => {
      try {
        const r = await client().auth.admin.getUserById(p.id);
        const em = r.data?.user?.email;
        if (typeof em === "string") emails.set(p.id, em);
      } catch { /* sem e-mail: aparece como vazio */ }
    }));
  }

  const ordenados = perfis.slice().sort((a, b) =>
    (a.papel === "proprietario" ? 0 : 1) - (b.papel === "proprietario" ? 0 : 1) || String(a.nome ?? "").localeCompare(String(b.nome ?? ""), "pt-BR"));
  return ordenados.map((p) => ({
    user_id: p.id,
    nome: p.nome ?? "",
    email: emails.get(p.id) ?? "",
    papel: PAPEIS.includes(p.papel) ? p.papel : "funcionario",
    ativo: p.ativo === true,
    permissoes: Array.isArray(p.permissoes) ? p.permissoes.filter((x) => typeof x === "string").slice(0, 20) : [],
  }));
}

async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return erro(405, "metodo_nao_permitido");
  if (req.headers.get("origin") !== null) return erro(403, "origem_nao_permitida");   // navegador não chama isto
  if (!isJsonContentType(req.headers)) return erro(415, "tipo_de_conteudo_invalido");

  const corpo = await readBodyLimited(req, MAX_BODY_BYTES);
  if (!corpo.ok) return erro(corpo.status, corpo.erro);

  const v = await verifyRequest(req.headers, corpo.bytes, {
    secrets: lerSegredos(), expectedSystem: SLUG, nowSeconds: Math.floor(Date.now() / 1000), nonceStore,
  });
  if (!v.ok) {
    log("warn", "assinatura_recusada", { motivo: v.reason });
    return erro(401, "nao_autorizado");
  }

  const b = parseJsonObject(corpo.bytes);
  if (!b) return erro(400, "corpo_invalido");
  const acao = b["action"];
  const ator = typeof b["ator"] === "string" && b["ator"].length <= 200 ? b["ator"] : "desconhecido";

  try {
    if (acao === "listar") {
      if (!onlyKeys(b, ["action", "empresa_id", "assinatura_id", "ator"]) || !isUuid(b["empresa_id"]) || !isUuid(b["assinatura_id"])) return erro(400, "dados_invalidos");
      await confirmarEmpresa(b["empresa_id"], b["assinatura_id"]);
      const usuarios = await listar(b["empresa_id"]);
      log("info", "listar", { empresa_id: b["empresa_id"], total: usuarios.length, ator });
      return jsonResponse(200, { ok: true, usuarios });
    }

    if (acao === "redefinir_senha") {
      if (!onlyKeys(b, ["action", "empresa_id", "assinatura_id", "user_id", "senha", "ator"])
          || !isUuid(b["empresa_id"]) || !isUuid(b["assinatura_id"]) || !isUuid(b["user_id"])) return erro(400, "dados_invalidos");
      if (!senhaValida(b["senha"])) return erro(400, "senha_fraca");
      await confirmarEmpresa(b["empresa_id"], b["assinatura_id"]);

      // o alvo TEM de ser perfil desta empresa (id + empresa_id juntos); id de outra empresa = "não encontrado"
      const { data: alvo, error: eAlvo } = await client().from("perfis").select("id")
        .eq("id", b["user_id"]).eq("empresa_id", b["empresa_id"]).maybeSingle();
      if (eAlvo) throw Object.assign(new Error("db"), { code: (eAlvo as { code?: string }).code });
      if (!alvo) throw new ErroNegocio(404, "usuario_nao_encontrado");

      const { error: eSenha } = await client().auth.admin.updateUserById(b["user_id"], { password: b["senha"] });
      if (eSenha) {
        // a mensagem do Auth pode citar a política de senha; nada dela sobe. Só o status.
        const st = (eSenha as { status?: number }).status;
        log("warn", "redefinir_recusado", { empresa_id: b["empresa_id"], user_id: b["user_id"], http: typeof st === "number" ? st : 0, ator });
        return erro(st === 422 ? 400 : 502, st === 422 ? "senha_recusada" : "falha_auth");
      }
      log("info", "senha_redefinida", { empresa_id: b["empresa_id"], user_id: b["user_id"], ator });
      return jsonResponse(200, { ok: true });
    }

    return erro(400, "acao_invalida");
  } catch (e) {
    if (e instanceof ErroNegocio) return erro(e.status, e.codigo);
    log("error", "acao_falhou", { acao: typeof acao === "string" ? acao : "?", ...errInfo(e) });
    return erro(500, "erro_interno");
  }
}

Deno.serve(async (req) => {
  try { return await handler(req); } catch (e) {
    log("error", "excecao_nao_tratada", errInfo(e));
    return jsonResponse(500, { ok: false, erro: "erro_interno" });
  }
});
