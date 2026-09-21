// =====================================================================
// DistGestor — Edge Function "distgestor-usuarios"  (ARQUIVO ÚNICO para colar no editor do Dashboard)
// Só no Supabase "ERP DISTGESTOR". Configurar: Verify JWT = LIGADO.
//
// Para que serve: o proprietário (ou um usuário com o módulo "Usuários e Acessos") cria o LOGIN de um
// funcionário e redefine a senha dele. Criar usuário no Supabase Auth exige a service_role, que NUNCA pode
// ficar no navegador — por isso esta função existe. Todo o resto (listar, editar permissões, ativar/desativar)
// é feito direto pelo navegador, por RPCs protegidas no banco.
//
// Segurança:
//   - o ator vem SEMPRE do JWT (validado pelo servidor de autenticação); a empresa vem do banco (perfis) — nunca do corpo;
//   - antes de criar qualquer coisa, o banco confirma: ator ativo, empresa aprovada, ator pode administrar usuários,
//     permissões pedidas são válidas e não passam das que o próprio ator possui (só o proprietário libera "usuarios");
//   - se o vínculo ao perfil falhar depois do login criado, o login recém-criado é APAGADO (nada fica órfão);
//   - a senha inicial é enviada uma única vez, nunca é gravada em log nem devolvida;
//   - mensagens de erro do banco só sobem quando são as mensagens próprias das regras (SQLSTATE P0001/42501/28000).
//
// Ações (POST, JSON):
//   { "acao": "criar", "nome": "...", "email": "...", "senha": "...", "permissoes": ["pdv", ...] }
//   { "acao": "redefinir_senha", "usuario_id": "<uuid>", "senha": "..." }
//
// Secrets (somente NOMES) — SUPABASE_URL e a chave de servidor são injetadas pela própria Supabase:
//   DISTGESTOR_ALLOWED_ORIGINS   origem(ns) exata(s) do navegador (sem barra final), separadas por vírgula.
//                                Se não existir, usa FLOREST_ALLOWED_ORIGINS (a mesma já usada por florest-notificar).
// Depende da Migration 004 (RPCs usuarios_preparar_criacao, usuarios_vincular, usuarios_autorizar_alvo).
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const MAX_BODY_BYTES = 4096;
const SENHA_MIN = 5;
const SENHA_MAX = 18;   // regra única: de 5 a 18 caracteres, sem exigir maiúscula/minúscula/número/símbolo
const MODULOS = new Set([
  "dashboard", "clientes", "produtos", "estoque", "pdv", "fornecedores",
  "notas_entrada", "financeiro", "fiscal", "relatorios", "configuracoes", "usuarios",
]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,255}\.[^\s@]{2,}$/;
const decoder = new TextDecoder();

// ---------------------------------------------------------------------
// utilidades HTTP
// ---------------------------------------------------------------------
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
function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...extra },
  });
}
function erro(status: number, codigo: string, mensagem: string, extra: Record<string, string> = {}): Response {
  return json(status, { ok: false, erro: codigo, mensagem }, extra);
}
async function lerCorpo(req: Request): Promise<{ ok: true; obj: Record<string, unknown> } | { ok: false; status: number; erro: string }> {
  const ct = (req.headers.get("content-type") ?? "").toLowerCase();
  if (!ct.includes("application/json")) return { ok: false, status: 415, erro: "tipo_de_conteudo_invalido" };
  const buf = new Uint8Array(await req.arrayBuffer());
  if (buf.length === 0 || buf.length > MAX_BODY_BYTES) return { ok: false, status: buf.length === 0 ? 400 : 413, erro: "corpo_invalido" };
  try {
    const v = JSON.parse(decoder.decode(buf));
    if (v === null || typeof v !== "object" || Array.isArray(v)) return { ok: false, status: 400, erro: "corpo_invalido" };
    return { ok: true, obj: v as Record<string, unknown> };
  } catch { return { ok: false, status: 400, erro: "corpo_invalido" }; }
}
// Log sem dados pessoais e sem senha.
function log(nivel: "info" | "warn" | "error", evento: string, extra: Record<string, unknown> = {}) {
  console[nivel === "info" ? "log" : nivel](JSON.stringify({ evento, ...extra }));
}

// ---------------------------------------------------------------------
// banco (service_role SOMENTE aqui, no servidor)
// ---------------------------------------------------------------------
function resolveServerKey(): string | null {
  const legado = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legado && legado.length > 20) return legado;
  const j = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (j) {
    try {
      const o = JSON.parse(j) as Record<string, unknown>;
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
    db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });
  }
  return db;
}

// Erros do banco: só sobem as mensagens das nossas regras (SQLSTATE P0001, 42501, 28000).
function mensagemDoBanco(e: { code?: string; message?: string } | null): string | null {
  if (!e) return null;
  if ((e.code === "P0001" || e.code === "42501" || e.code === "28000") && e.message) return e.message;
  return null;
}

// ---------------------------------------------------------------------
// validação
// ---------------------------------------------------------------------
function validarSenha(s: unknown): string | null {
  if (typeof s !== "string") return "Informe a senha.";
  if (s.length < SENHA_MIN || s.length > SENHA_MAX) return "Use uma senha de 5 a 18 caracteres.";
  return null;
}
function validarPermissoes(p: unknown): string[] | null {
  if (!Array.isArray(p) || p.length > MODULOS.size) return null;
  const out: string[] = [];
  for (const x of p) {
    if (typeof x !== "string" || !MODULOS.has(x)) return null;
    if (!out.includes(x)) out.push(x);
  }
  return out;
}

// ---------------------------------------------------------------------
// ações
// ---------------------------------------------------------------------
async function criar(ator: string, o: Record<string, unknown>, ch: Record<string, string>): Promise<Response> {
  const nome = typeof o["nome"] === "string" ? o["nome"].trim() : "";
  const email = typeof o["email"] === "string" ? o["email"].trim().toLowerCase() : "";
  const permissoes = validarPermissoes(o["permissoes"]);
  const senha = o["senha"];
  if (nome.length < 2 || nome.length > 200) return erro(400, "nome_invalido", "Informe o nome do funcionário (2 a 200 caracteres).", ch);
  if (!EMAIL_RE.test(email) || email.length > 254) return erro(400, "email_invalido", "Informe um e-mail válido.", ch);
  if (permissoes === null) return erro(400, "permissoes_invalidas", "Permissões inválidas.", ch);
  const msgSenha = validarSenha(senha);
  if (msgSenha) return erro(400, "senha_invalida", msgSenha, ch);

  // 1) o banco decide se o ator pode criar ESTE tipo de usuário (antes de criar qualquer login)
  const pre = await client().rpc("usuarios_preparar_criacao", { p_ator: ator, p_permissoes: permissoes });
  if (pre.error) {
    const m = mensagemDoBanco(pre.error);
    if (m) return erro(403, "nao_autorizado", m, ch);
    log("error", "preparar_falhou", { code: pre.error.code });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }

  // 2) cria o login (e-mail já confirmado: o proprietário responde por essa pessoa)
  const novo = await client().auth.admin.createUser({ email, password: senha as string, email_confirm: true });
  if (novo.error || !novo.data?.user?.id) {
    const msg = (novo.error?.message ?? "").toLowerCase();
    if (novo.error && (msg.includes("already") || msg.includes("registered") || msg.includes("exists"))) {
      return erro(409, "email_em_uso", "Este e-mail já está cadastrado. Use outro e-mail para o funcionário.", ch);
    }
    if (msg.includes("password")) return erro(400, "senha_invalida", "A senha não foi aceita. Use uma senha mais forte.", ch);
    log("error", "criar_login_falhou", { status: novo.error?.status });
    return erro(500, "erro_interno", "Não foi possível criar o login. Tente novamente.", ch);
  }
  const novoId = novo.data.user.id;

  // 3) vincula à empresa do ator (o banco revalida tudo). Se falhar, apaga o login recém-criado.
  const vinc = await client().rpc("usuarios_vincular", { p_ator: ator, p_user_id: novoId, p_nome: nome, p_permissoes: permissoes });
  if (vinc.error) {
    const del = await client().auth.admin.deleteUser(novoId);
    if (del.error) log("error", "rollback_falhou", { usuario_id: novoId });
    const m = mensagemDoBanco(vinc.error);
    log("warn", "vincular_falhou", { code: vinc.error.code });
    return m ? erro(400, "nao_vinculado", m, ch) : erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
  log("info", "funcionario_criado", { ator, usuario_id: novoId });
  return json(200, { ok: true, usuario_id: novoId }, ch);
}

async function redefinirSenha(ator: string, o: Record<string, unknown>, ch: Record<string, string>): Promise<Response> {
  const alvo = typeof o["usuario_id"] === "string" ? o["usuario_id"] : "";
  if (!UUID_RE.test(alvo)) return erro(400, "usuario_invalido", "Usuário inválido.", ch);
  const msgSenha = validarSenha(o["senha"]);
  if (msgSenha) return erro(400, "senha_invalida", msgSenha, ch);

  const aut = await client().rpc("usuarios_autorizar_alvo", { p_ator: ator, p_alvo: alvo });
  if (aut.error) {
    const m = mensagemDoBanco(aut.error);
    if (m) return erro(403, "nao_autorizado", m, ch);
    log("error", "autorizar_falhou", { code: aut.error.code });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
  const r = await client().auth.admin.updateUserById(alvo, { password: o["senha"] as string });
  if (r.error) {
    const msg = (r.error.message ?? "").toLowerCase();
    if (msg.includes("password")) return erro(400, "senha_invalida", "A senha não foi aceita. Use uma senha mais forte.", ch);
    log("error", "trocar_senha_falhou", { status: r.error.status });
    return erro(500, "erro_interno", "Não foi possível trocar a senha. Tente novamente.", ch);
  }
  log("info", "senha_redefinida", { ator, usuario_id: alvo });
  return json(200, { ok: true }, ch);
}

// ---------------------------------------------------------------------
const ORIGENS = (Deno.env.get("DISTGESTOR_ALLOWED_ORIGINS") ?? Deno.env.get("FLOREST_ALLOWED_ORIGINS") ?? "")
  .split(",").map((s) => s.trim()).filter((s) => s.length > 0);

async function handler(req: Request): Promise<Response> {
  const cors = decideCors(req, ORIGENS);
  if (cors.tipo === "negada") return erro(403, "origem_nao_permitida", "Origem não permitida.");
  const ch = cors.tipo === "permitida" ? cors.headers : {};
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return erro(405, "metodo_nao_permitido", "Método não permitido.", { ...ch, allow: "POST, OPTIONS" });

  const m = /^Bearer\s+([A-Za-z0-9._~+/=-]{20,4096})$/.exec(req.headers.get("authorization") ?? "");
  if (!m) return erro(401, "nao_autenticado", "Faça login novamente.", ch);
  let ator: string | null = null;
  try {
    const { data, error } = await client().auth.getUser(m[1]);
    ator = !error && data?.user?.id ? data.user.id : null;
  } catch (e) {
    log("error", "auth_falhou", { erro: String((e as Error)?.message ?? e).slice(0, 80) });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
  if (!ator) return erro(401, "nao_autenticado", "Faça login novamente.", ch);

  const corpo = await lerCorpo(req);
  if (!corpo.ok) return erro(corpo.status, corpo.erro, "Requisição inválida.", ch);

  try {
    switch (corpo.obj["acao"]) {
      case "criar": return await criar(ator, corpo.obj, ch);
      case "redefinir_senha": return await redefinirSenha(ator, corpo.obj, ch);
      default: return erro(400, "acao_invalida", "Ação inválida.", ch);
    }
  } catch (e) {
    log("error", "excecao", { erro: String((e as Error)?.message ?? e).slice(0, 80) });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
}

Deno.serve(async (req) => {
  try { return await handler(req); } catch {
    return erro(500, "erro_interno", "Erro interno.");
  }
});
