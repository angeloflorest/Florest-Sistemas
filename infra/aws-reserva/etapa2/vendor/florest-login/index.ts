// =====================================================================
// Florest ERP — Edge Function "florest-login"  (ARQUIVO ÚNICO para colar no editor do Dashboard)
// Só no Supabase "ERP FLOREST". Configurar: Verify JWT = DESLIGADO (ver explicação ao final).
//
// Para que serve: autentica um funcionário pelo novo formato de login
// "e-mail da empresa + usuário + senha" (ex.: bar@gmail.com / angelo / ******),
// sem mudar o que já existe: a identidade continua sendo o Supabase Auth
// (auth.users), perfis.id continua sendo o mesmo uuid de auth.users.id, e o
// login antigo (e-mail pessoal + senha, via supabase.auth.signInWithPassword
// direto do navegador) continua funcionando sem qualquer alteração — esta
// função é um CAMINHO A MAIS, não uma substituição.
//
// Por que isto tem que ser uma Edge Function (e não uma função SQL/RPC):
//   - resolver "qual empresa, qual perfil, qual é o e-mail real no Auth" tem
//     que acontecer ANTES de existir qualquer sessão logada — ou seja, antes
//     de auth.uid() existir. private.empresa_id_ativa(), private.perm(),
//     private.perm_alguma() e private.exigir_empresa_ativa() dependem todos
//     de (select auth.uid()) por dentro; chamá-los aqui sempre devolveria
//     NULL/negaria acesso, exatamente a falha já vista antes com
//     private.empresa_tem_modulo('bar') fora de uma sessão. Por isso esta
//     função NÃO usa nenhuma dessas funções — ela lê as colunas
//     (empresas.status_conta, empresas.bloqueado, perfis.ativo) diretamente,
//     usando a service_role (que tem acesso total e ignora RLS por padrão
//     no Supabase), e repete a mesma regra ("aprovada e não bloqueada",
//     "perfil ativo") manualmente em código.
//   - a senha em si NUNCA é validada aqui: quem valida é o próprio Supabase
//     Auth, através de supabase.auth.signInWithPassword() chamado no final,
//     com o e-mail REAL resolvido (que pode ser um e-mail técnico de garçom,
//     ex. <uuid>@garcons.florest.app — isso nunca é devolvido ao cliente).
//     Isso significa que o limite de tentativas / rate limit do próprio
//     Supabase Auth no endpoint de login continua valendo normalmente.
//
// Segurança (anti-enumeração):
//   - qualquer falha de autenticação (empresa não encontrada, empresa
//     bloqueada/não aprovada, usuário não encontrado, perfil inativo, senha
//     errada) devolve exatamente a MESMA mensagem genérica e o MESMO status
//     HTTP (401, "Empresa, usuário ou senha inválidos.") — nunca revela qual
//     delas falhou;
//   - erros de FORMATO (campo ausente, tipo errado, formato claramente
//     inválido) são validados ANTES de qualquer consulta ao banco e podem
//     ter mensagem específica, porque não revelam se uma conta existe;
//   - a service_role só é usada aqui para: (1) consultar empresas/perfis
//     diretamente (leitura, bypassa RLS) e (2) auth.admin.getUserById() para
//     descobrir o e-mail real do Auth a partir do perfil encontrado. A
//     verificação da senha em si usa um cliente separado, com a chave anon
//     (padrão do Supabase para supabase.auth.signInWithPassword), nunca a
//     service_role — menor privilégio possível em cada etapa;
//   - nenhuma senha, token ou e-mail técnico de garçom é gravado em log;
//   - mensagens de erro nunca incluem stack trace nem detalhes internos.
//
// Entrada (POST, JSON):
//   { "empresa": "bar@gmail.com", "usuario": "angelo", "senha": "******" }
//   { "empresa": "bar@gmail.com", "usuario": "angelo", "senha": "******", "superficie": "erp" }
//     "superficie" é OPCIONAL (Etapa 2). Quando enviado como "erp" (novo login do Florest ERP),
//     esta function passa a exigir perfis.tipo_acesso = 'erp' (Migration 024) — um perfil de
//     garçom (tipo_acesso = 'garcom') não consegue entrar pelo ERP mesmo com usuário/senha certos,
//     caindo na mesma mensagem genérica de credenciais inválidas. Quando "superficie" está ausente
//     (caso do app Florest Garçom hoje, que não foi alterado nesta etapa), o comportamento continua
//     IDÊNTICO ao que já estava em produção: nenhuma checagem de tipo_acesso é feita.
//
// Saída em caso de sucesso (200):
//   {
//     "ok": true,
//     "session": { "access_token", "refresh_token", "expires_in", "expires_at", "token_type" },
//     "empresa": { "id", "nome" },
//     "perfil": { "id", "nome", "papel" }
//   }
//   O front-end usa isso para chamar supabase.auth.setSession({ access_token, refresh_token }).
//
// Saída em caso de falha de credenciais (401):
//   { "ok": false, "erro": "credenciais_invalidas", "mensagem": "Empresa, usuário ou senha inválidos." }
//
// Secrets (somente NOMES) — todos já existem/são injetados automaticamente pelo Supabase,
// nenhum secret novo precisa ser criado manualmente:
//   SUPABASE_URL                 injetado automaticamente.
//   SUPABASE_SERVICE_ROLE_KEY    injetado automaticamente (com fallback para SUPABASE_SECRET_KEYS,
//                                mesmo esquema já usado em distgestor-usuarios.ts, para o caso de
//                                o projeto já ter migrado para a nova rotação de chaves do Supabase).
//   SUPABASE_ANON_KEY            injetado automaticamente — usado SÓ para a chamada de
//                                signInWithPassword (nunca para ler empresas/perfis).
//   FLORESTLOGIN_ALLOWED_ORIGINS origem(ns) exata(s) do navegador (sem barra final), separadas por
//                                vírgula. Se não existir, usa FLOREST_ALLOWED_ORIGINS (o mesmo
//                                secret compartilhado já usado por outras functions do projeto).
//                                Chamadas sem cabeçalho Origin (ex.: o app Florest Garçom) não são
//                                afetadas por isso — CORS só existe para o navegador.
//
// Depende apenas da Migration 021 (coluna perfis.usuario, índice único
// perfis_usuario_empresa_ci_uk, índice único empresas_email_ci_uk) e de tabelas já existentes
// (public.empresas, public.perfis, auth.users via Admin API). Não depende de nenhuma função SQL
// nova — toda a resolução é feita aqui, em código, com a service_role.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2.117.2";

const MAX_BODY_BYTES = 2048;
// Limite de sanidade para a senha recebida (não é a regra de criação de senha — essa é decidida
// em distgestor-usuarios.ts no momento de criar/redefinir. Aqui só evita mandar uma string enorme
// para o Auth). 72 é o limite efetivo do bcrypt usado pelo GoTrue.
const SENHA_MAX = 72;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,255}\.[^\s@]{2,}$/;
// Mesmo formato exigido pela constraint perfis_usuario_formato_ck da Migration 021.
const USUARIO_RE = /^\S{2,60}$/;
const decoder = new TextDecoder();

const GENERIC_ERRO = "Empresa, usuário ou senha inválidos.";

// ---------------------------------------------------------------------
// utilidades HTTP (mesmo padrão de distgestor-usuarios.ts)
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
function erroCredenciais(extra: Record<string, string>): Response {
  return erro(401, "credenciais_invalidas", GENERIC_ERRO, extra);
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
// Log sem dados pessoais: nunca a senha, nunca o e-mail da empresa, nunca o usuário digitado,
// nunca o e-mail real (possivelmente técnico) resolvido no Auth. Só ids (uuid) e motivos internos.
function log(nivel: "info" | "warn" | "error", evento: string, extra: Record<string, unknown> = {}) {
  console[nivel === "info" ? "log" : nivel](JSON.stringify({ evento, ...extra }));
}

// ---------------------------------------------------------------------
// banco (service_role SOMENTE para resolver empresa/perfil/e-mail real; nunca para validar a senha)
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
let dbAdmin: ReturnType<typeof createClient> | null = null;
function clienteAdmin() {
  if (!dbAdmin) {
    const url = Deno.env.get("SUPABASE_URL");
    const key = resolveServerKey();
    if (!url || !key) throw new Error("configuracao_supabase_ausente");
    dbAdmin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });
  }
  return dbAdmin;
}
// Cliente separado, com a chave anon — usado SÓ para checar a senha via signInWithPassword.
// Nunca reaproveita a service_role aqui: a verificação da senha não precisa (nem deve) de
// privilégio administrativo, e manter os dois clientes separados limita o raio de um eventual bug.
let dbAuth: ReturnType<typeof createClient> | null = null;
function clienteAuth() {
  if (!dbAuth) {
    const url = Deno.env.get("SUPABASE_URL");
    const key = Deno.env.get("SUPABASE_ANON_KEY");
    if (!url || !key) throw new Error("configuracao_supabase_ausente");
    dbAuth = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } });
  }
  return dbAuth;
}

// Escapa os coringas do LIKE/ILIKE (%, _ e a própria barra invertida, que é o caractere de escape
// padrão do Postgres) para que .ilike(coluna, valor) funcione como uma comparação de IGUALDADE
// case-insensitive — exatamente equivalente aos índices únicos lower(email)/lower(usuario) criados
// na Migration 021 — e não como um padrão. Sem isso, um valor como "%" no campo "usuario" poderia
// casar com qualquer linha.
function escaparParaIlike(v: string): string {
  return v.replace(/\\/g, "\\\\").replace(/%/g, "\\%").replace(/_/g, "\\_");
}

// ---------------------------------------------------------------------
// validação de formato (não revela se a conta existe — só exige um formato plausível)
// ---------------------------------------------------------------------
function validarEntrada(o: Record<string, unknown>):
  | { ok: true; empresaEmail: string; usuario: string; senha: string; superficie: string | null }
  | { ok: false; resposta: Response } {
  const empresaBruta = o["empresa"];
  const usuarioBruto = o["usuario"];
  const senha = o["senha"];
  // "superficie" é OPCIONAL e só existe para quem já foi atualizado para enviá-lo (o novo login do
  // Florest ERP). Quando ausente — exatamente o caso do app Florest Garçom hoje —, o comportamento
  // desta function não muda em nada em relação ao que já estava em produção.
  const superficieBruta = o["superficie"];

  if (typeof empresaBruta !== "string" || typeof usuarioBruto !== "string" || typeof senha !== "string") {
    return { ok: false, resposta: erro(400, "dados_invalidos", "Informe empresa, usuário e senha.") };
  }
  if (superficieBruta !== undefined && typeof superficieBruta !== "string") {
    return { ok: false, resposta: erro(400, "dados_invalidos", "Campo superficie inválido.") };
  }
  const empresaEmail = empresaBruta.trim().toLowerCase();
  const usuario = usuarioBruto.trim().toLowerCase();
  const superficie = typeof superficieBruta === "string" ? superficieBruta.trim().toLowerCase() : null;

  if (empresaEmail.length === 0 || empresaEmail.length > 254 || !EMAIL_RE.test(empresaEmail)) {
    return { ok: false, resposta: erro(400, "empresa_invalida", "Informe o e-mail da empresa.") };
  }
  if (usuario.length === 0 || !USUARIO_RE.test(usuario)) {
    return { ok: false, resposta: erro(400, "usuario_invalido", "Informe o usuário.") };
  }
  if (senha.length === 0 || senha.length > SENHA_MAX) {
    return { ok: false, resposta: erro(400, "senha_invalida", "Informe a senha.") };
  }
  return { ok: true, empresaEmail, usuario, senha, superficie };
}

// ---------------------------------------------------------------------
// login
// ---------------------------------------------------------------------
async function login(o: Record<string, unknown>, ch: Record<string, string>): Promise<Response> {
  const campos = validarEntrada(o);
  if (!campos.ok) return campos.resposta;
  const { empresaEmail, usuario, senha, superficie } = campos;

  // 1) resolve a empresa pelo e-mail (case-insensitive, equivalente ao índice único
  //    empresas_email_ci_uk). Empresas antigas sem e-mail (ainda não migradas) simplesmente não
  //    terão correspondência aqui — cai no mesmo erro genérico, sem distinção.
  const empresaQ = await clienteAdmin()
    .from("empresas")
    .select("id, nome, status_conta, bloqueado")
    .ilike("email", escaparParaIlike(empresaEmail))
    .maybeSingle();
  if (empresaQ.error) {
    log("error", "consulta_empresa_falhou", { code: empresaQ.error.code });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
  const empresa = empresaQ.data as { id: string; nome: string; status_conta: string; bloqueado: boolean } | null;
  if (!empresa) {
    log("warn", "login_falhou", { motivo: "empresa_nao_encontrada" });
    return erroCredenciais(ch);
  }
  // mesma regra de "empresa ativa" usada em private.empresa_id_ativa()/private.exigir_empresa_ativa(),
  // repetida aqui manualmente porque essas funções dependem de auth.uid() (indisponível antes do login).
  if (empresa.status_conta !== "aprovado" || empresa.bloqueado) {
    log("warn", "login_falhou", { motivo: "empresa_nao_ativa", empresa_id: empresa.id });
    return erroCredenciais(ch);
  }

  // 2) resolve o perfil dentro da empresa pelo "usuario" (case-insensitive, equivalente ao índice
  //    único perfis_usuario_empresa_ci_uk, que não é filtrado por ativo — então um "usuario" de um
  //    perfil desativado também é encontrado aqui, e barrado logo abaixo por perfis.ativo).
  const perfilQ = await clienteAdmin()
    .from("perfis")
    .select("id, nome, papel, ativo, tipo_acesso")
    .eq("empresa_id", empresa.id)
    .ilike("usuario", escaparParaIlike(usuario))
    .maybeSingle();
  if (perfilQ.error) {
    log("error", "consulta_perfil_falhou", { code: perfilQ.error.code });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
  const perfil = perfilQ.data as { id: string; nome: string; papel: string; ativo: boolean; tipo_acesso: string | null } | null;
  if (!perfil) {
    log("warn", "login_falhou", { motivo: "usuario_nao_encontrado", empresa_id: empresa.id });
    return erroCredenciais(ch);
  }
  if (!perfil.ativo) {
    log("warn", "login_falhou", { motivo: "perfil_inativo", empresa_id: empresa.id, perfil_id: perfil.id });
    return erroCredenciais(ch);
  }
  // Gate de superfície (Etapa 2, Opção A): só é aplicado quando quem chamou já foi atualizado para
  // informar "superficie" explicitamente. Hoje só o novo login do Florest ERP faz isso, enviando
  // "erp" — exige perfis.tipo_acesso = 'erp' (Migration 024). O Florest Garçom não envia este campo
  // (superficie === null aqui) e portanto não passa por esta checagem — comportamento inalterado.
  // Falha aqui devolve exatamente o mesmo 401 genérico, nunca revelando que o usuário existe mas
  // pertence à outra superfície (ex.: um garçom tentando entrar pelo ERP).
  if (superficie === "erp" && perfil.tipo_acesso !== "erp") {
    log("warn", "login_falhou", { motivo: "tipo_acesso_incompativel", empresa_id: empresa.id, perfil_id: perfil.id });
    return erroCredenciais(ch);
  }

  // 3) descobre o e-mail REAL do Auth para este perfil (pode ser o e-mail técnico de um garçom,
  //    <uuid>@garcons.florest.app — nunca aparece na resposta). perfis.id é sempre o mesmo uuid de
  //    auth.users.id, então getUserById(perfil.id) é direto, sem precisar de nenhuma tabela extra.
  const userQ = await clienteAdmin().auth.admin.getUserById(perfil.id);
  const emailReal = userQ.data?.user?.email;
  if (userQ.error || !emailReal) {
    // Isso indicaria um perfil "órfão" (sem login correspondente no Auth) — não deveria acontecer
    // em uso normal, mas não é um problema de credenciais do usuário, então é erro interno (500),
    // não a mensagem genérica de autenticação.
    log("error", "auth_user_nao_encontrado", { perfil_id: perfil.id, code: userQ.error?.code });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }

  // 4) valida a senha onde a senha de fato é validada: o próprio Supabase Auth. Usa o cliente com
  //    a chave anon (nunca a service_role) — o mesmo mecanismo de signInWithPassword usado hoje
  //    pelo login antigo (e-mail pessoal + senha), só que aqui com o e-mail resolvido no passo 3.
  const sessao = await clienteAuth().auth.signInWithPassword({ email: emailReal, password: senha });
  if (sessao.error || !sessao.data?.session) {
    const status = (sessao.error as { status?: number } | null)?.status;
    if (status === 429) {
      log("warn", "login_falhou", { motivo: "rate_limit", empresa_id: empresa.id, perfil_id: perfil.id });
      return erro(429, "muitas_tentativas", "Muitas tentativas. Tente novamente em instantes.", ch);
    }
    // qualquer outro motivo (senha errada é o caso normal aqui) cai na mesma mensagem genérica.
    log("warn", "login_falhou", { motivo: "senha_invalida", empresa_id: empresa.id, perfil_id: perfil.id });
    return erroCredenciais(ch);
  }

  const s = sessao.data.session;
  log("info", "login_sucesso", { empresa_id: empresa.id, perfil_id: perfil.id });
  return json(200, {
    ok: true,
    session: {
      access_token: s.access_token,
      refresh_token: s.refresh_token,
      expires_in: s.expires_in,
      expires_at: s.expires_at,
      token_type: s.token_type,
    },
    empresa: { id: empresa.id, nome: empresa.nome },
    perfil: { id: perfil.id, nome: perfil.nome, papel: perfil.papel },
  }, ch);
}

// ---------------------------------------------------------------------
const ORIGENS = (Deno.env.get("FLORESTLOGIN_ALLOWED_ORIGINS") ?? Deno.env.get("FLOREST_ALLOWED_ORIGINS") ?? "")
  .split(",").map((s) => s.trim()).filter((s) => s.length > 0);

async function handler(req: Request): Promise<Response> {
  const cors = decideCors(req, ORIGENS);
  if (cors.tipo === "negada") return erro(403, "origem_nao_permitida", "Origem não permitida.");
  const ch = cors.tipo === "permitida" ? cors.headers : {};
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: ch });
  if (req.method !== "POST") return erro(405, "metodo_nao_permitido", "Método não permitido.", { ...ch, allow: "POST, OPTIONS" });

  // Sem verificação de Authorization aqui de propósito: este é o endpoint de LOGIN — por
  // definição, ainda não existe nenhuma sessão/JWT antes dele. Ver nota de "Verify JWT" no topo
  // do arquivo.
  const corpo = await lerCorpo(req);
  if (!corpo.ok) return erro(corpo.status, corpo.erro, "Requisição inválida.", ch);

  try {
    return await login(corpo.obj, ch);
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
