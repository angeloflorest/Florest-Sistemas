// =====================================================================
// DistGestor — Edge Function "distgestor-usuarios"  (ARQUIVO ÚNICO para colar no editor do Dashboard)
// Só no Supabase "ERP FLOREST". Configurar: Verify JWT = LIGADO.
//
// Para que serve: o proprietário (ou um usuário com o módulo "Usuários e Acessos") cria o LOGIN de um
// funcionário e redefine a senha dele. Criar usuário no Supabase Auth exige a service_role, que NUNCA pode
// ficar no navegador — por isso esta função existe. Todo o resto (listar, editar permissões, ativar/desativar)
// é feito direto pelo navegador, por RPCs protegidas no banco.
//
// FASE 6 (Migration 026, já aplicada) — "criar" (funcionário do ERP) deixa de receber e-mail do
// cliente: passa a receber "usuario" (mesmo formato/normalização de "usuario" em criar_garcom —
// USUARIO_RE, trim + minúsculas) e esta função gera sozinha um e-mail técnico interno
// (crypto.randomUUID()@FUNCIONARIOS_EMAIL_DOMINIO), nunca visto pelo proprietário nem pelo
// funcionário — mesmo mecanismo já usado para garçons (GARCOM_EMAIL_DOMINIO), com um domínio
// PRÓPRIO e distinto só para nunca confundir auditoria/e-mails entre os dois tipos de login
// técnico. O login público do funcionário do ERP continua sendo e-mail da empresa + usuário +
// senha, resolvido pela Edge Function florest-login — nunca o e-mail técnico gerado aqui.
// "usuarios_vincular" (Migration 026) já aceita "p_usuario" (opcional) — esta função passa a
// sempre enviá-lo. Esta fase também sincroniza a lista MODULOS abaixo com a lista real e atual de
// private.usuarios_modulos() (Migrations 006 e 016) — a lista anterior, da era PetGestor, estava
// desatualizada e era a causa raiz do erro "Permissões inválidas." para qualquer permissão criada
// depois dela (pets/agenda/pacotes e as 9 permissões do Módulo Bar).
//
// FASE 4 (Migration 020) acrescentou as ações "criar_garcom"/"redefinir_senha_garcom": o mesmo mecanismo
// acima, só que para o cadastro simplificado de garçons dentro do Módulo Bar (aba Bar → Garçons). A tela ali
// só pede Nome + Senha — nunca e-mail — então esta função gera sozinha um e-mail técnico aleatório
// (crypto.randomUUID()@GARCOM_EMAIL_DOMINIO), que o proprietário nunca vê nem digita; "Pedro" continua
// existindo só como perfis.nome, exatamente como qualquer outro funcionário. As permissões do garçom são
// sempre as 3 fixas decididas pelo banco (bar_garcom_vincular) — esta função nunca recebe nem envia uma
// lista de permissões para um garçom.
//
// FASE 5 (Migration 021/022) acrescentou "usuario" ao cadastro de garçom: é o login dele no novo
// florest-login (e-mail da empresa + usuário + senha). "criar_garcom" agora recebe também "usuario",
// valida o formato (sem espaços, 2 a 60 caracteres — mesma regra da constraint
// perfis_usuario_formato_ck da Migration 021) e normaliza (trim + minúsculas) antes de repassar ao
// banco; quem decide se há conflito dentro da empresa e grava perfis.usuario continua sendo o banco
// (bar_garcom_vincular, Migration 022), nunca esta função sozinha. A edição de nome/usuario de um
// garçom já existente NÃO passa por aqui — continua sendo a RPC direta bar_garcom_atualizar, chamada
// pelo navegador; esta função só participa da edição para trocar a senha (ação já existente
// "redefinir_senha_garcom", inalterada).
//
// Segurança:
//   - o ator vem SEMPRE do JWT (validado pelo servidor de autenticação); a empresa vem do banco (perfis) — nunca do corpo;
//   - antes de criar qualquer coisa, o banco confirma: ator ativo, empresa aprovada, ator pode administrar usuários
//     (ou, para garçom, É o proprietário da empresa — bar_configurar e qualquer outra permissão de
//     funcionário NÃO autorizam administrar garçom), permissões pedidas são válidas e não passam das
//     que o próprio ator possui (só o proprietário libera "usuarios"; garçom nunca recebe permissão
//     além do trio fixo do Bar);
//   - se o vínculo ao perfil falhar depois do login criado, o login recém-criado é APAGADO (nada fica órfão) —
//     isso agora também cobre o caso de "usuario" já estar em uso na empresa (o banco recusa o vínculo
//     e esta função desfaz o login recém-criado, sem deixar login órfão nem usuario duplicado);
//   - a senha inicial é enviada uma única vez, nunca é gravada em log nem devolvida;
//   - mensagens de erro do banco só sobem quando são as mensagens próprias das regras (SQLSTATE P0001/42501/28000).
//
// Ações (POST, JSON):
//   { "acao": "criar", "nome": "...", "usuario": "...", "senha": "...", "permissoes": ["pdv", ...] }   -- "usuario" na Fase 6; antes era "email"
//   { "acao": "redefinir_senha", "usuario_id": "<uuid>", "senha": "..." }
//   { "acao": "criar_garcom", "nome": "...", "usuario": "...", "senha": "..." }   -- Fase 4; "usuario" na Fase 5
//   { "acao": "redefinir_senha_garcom", "usuario_id": "<uuid>", "senha": "..." }  -- Fase 4
//
// Secrets (somente NOMES) — SUPABASE_URL e a chave de servidor são injetadas pela própria Supabase:
//   DISTGESTOR_ALLOWED_ORIGINS   origem(ns) exata(s) do navegador (sem barra final), separadas por vírgula.
//                                Se não existir, usa FLOREST_ALLOWED_ORIGINS (a mesma já usada por florest-notificar).
// Depende da Migration 004 (RPCs usuarios_preparar_criacao, usuarios_vincular, usuarios_autorizar_alvo), da
// Migration 020 (bar_garcons_preparar_criacao, bar_garcom_autorizar_alvo) e da Migration 022 — AINDA NÃO
// GERADA/APLICADA — que precisa alterar bar_garcom_vincular(p_ator, p_user_id, p_nome) para também receber
// e gravar p_usuario (ver resumo de alterações). Sem a Migration 022, a chamada a bar_garcom_vincular feita
// por esta função falhará (parâmetro p_usuario inexistente no banco).
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const MAX_BODY_BYTES = 4096;
const SENHA_MIN = 6;
const SENHA_MAX = 18;   // regra única: de 6 a 18 caracteres, sem exigir maiúscula/minúscula/número/símbolo
// Lista EXATA e atual de private.usuarios_modulos() (Migrations 006 e 016) — toda permissão que o
// banco aceita em perfis.permissoes (perfis_permissoes_ck) precisa estar aqui, e só o que está
// aqui. Nunca inventar uma chave nova aqui sem primeiro ela existir no banco (e vice-versa): esta
// lista é só um filtro defensivo ANTES de chamar o banco — a validação real e definitiva é sempre
// private.usuarios_normalizar_permissoes(), dentro de usuarios_preparar_criacao/usuarios_vincular.
const MODULOS = new Set([
  "maria",
  "dashboard", "clientes", "produtos", "estoque", "pdv", "fornecedores",
  "notas_entrada", "financeiro", "fiscal", "relatorios", "configuracoes", "usuarios",
  "pets", "agenda", "pacotes",
  "bar_visualizar", "bar_mesas", "bar_pedidos", "bar_caixa", "bar_portaria",
  "bar_configurar", "bar_cancelar_pedido", "bar_corrigir_pessoas", "bar_estornar_pagamento",
]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Mesmo formato exigido pela constraint perfis_usuario_formato_ck da Migration 021: sem espaços,
// de 2 a 60 caracteres. É só validação de formato — a unicidade dentro da empresa é sempre
// decidida pelo banco (usuarios_vincular/bar_garcom_vincular), nunca por esta função.
const USUARIO_RE = /^\S{2,60}$/;
// Domínio técnico do e-mail gerado para o login de um garçom (Fase 4). Nunca é enviado a lugar
// nenhum (email_confirm:true dispensa confirmação) e nunca é mostrado ao proprietário ou ao
// garçom — existe só para satisfazer a exigência de e-mail único do Supabase Auth.
const GARCOM_EMAIL_DOMINIO = "garcons.florest.app";
// Domínio técnico do e-mail gerado para o login de um funcionário do ERP (Fase 6). Deliberadamente
// DIFERENTE de GARCOM_EMAIL_DOMINIO (garçom e funcionário do ERP são tipos de login distintos —
// perfis.tipo_acesso 'garcom' vs 'erp' — nunca devem compartilhar o mesmo domínio técnico, para não
// confundir auditoria/logs). Nunca enviado a lugar nenhum nem mostrado ao proprietário ou ao
// funcionário — existe só para satisfazer a exigência de e-mail único do Supabase Auth; o login
// público do funcionário é sempre e-mail da empresa + usuário + senha (florest-login).
const FUNCIONARIOS_EMAIL_DOMINIO = "funcionarios.florest.app";
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
  if (s.length < SENHA_MIN || s.length > SENHA_MAX) return "Use uma senha de 6 a 18 caracteres.";
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
  if(o["papel"] === "proprietario"){
    const permitido=await client().rpc("florest_senha_preparar",{p_ator:ator,p_alvo:ator});
    if(permitido.error)return erro(403,"nao_autorizado","Somente proprietário pode criar outro proprietário.",ch);
  }
  const nome = typeof o["nome"] === "string" ? o["nome"].trim() : "";
  // Fase 6: "usuario", não "email" — o funcionário nunca informa nem precisa saber de um e-mail
  // técnico. Normalizado aqui (trim + minúsculas) antes de ir para o banco — mesma normalização já
  // usada em criarGarcom() e exigida pelos índices únicos lower(usuario) (Migration 021). O banco
  // (usuarios_vincular, Migration 026) é quem decide, de fato, se há conflito dentro da empresa.
  const usuario = typeof o["usuario"] === "string" ? o["usuario"].trim().toLowerCase() : "";
  const permissoes = validarPermissoes(o["permissoes"]);
  const senha = o["senha"];
  if (nome.length < 2 || nome.length > 200) return erro(400, "nome_invalido", "Informe o nome do funcionário (2 a 200 caracteres).", ch);
  if (!USUARIO_RE.test(usuario)) return erro(400, "usuario_invalido", "Informe um usuário sem espaços, de 2 a 60 caracteres.", ch);
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

  // 2) cria o login com um e-mail técnico interno, gerado aqui, nunca visto pelo proprietário nem
  // pelo funcionário (mesmo mecanismo já usado para garçons — ver GARCOM_EMAIL_DOMINIO —, com um
  // domínio PRÓPRIO e distinto). O login público do funcionário continua sendo e-mail da empresa +
  // usuário + senha, resolvido pela Edge Function florest-login; este e-mail técnico só existe
  // para satisfazer a exigência de e-mail único do Supabase Auth.
  const email = `${crypto.randomUUID()}@${FUNCIONARIOS_EMAIL_DOMINIO}`;
  const novo = await client().auth.admin.createUser({ email, password: senha as string, email_confirm: true });
  if (novo.error || !novo.data?.user?.id) {
    const msg = (novo.error?.message ?? "").toLowerCase();
    if (msg.includes("password")) return erro(400, "senha_invalida", "A senha não foi aceita. Use uma senha mais forte.", ch);
    log("error", "criar_login_falhou", { status: novo.error?.status });
    return erro(500, "erro_interno", "Não foi possível criar o login. Tente novamente.", ch);
  }
  const novoId = novo.data.user.id;

  // 3) vincula à empresa do ator (o banco revalida tudo) e grava perfis.usuario (Migration 026).
  // Se falhar — inclusive por "usuario" já em uso nesta empresa — apaga o login recém-criado: nada
  // fica órfão, e nenhum usuario duplicado chega a existir.
  const vinc = await client().rpc("usuarios_vincular", {
    p_ator: ator, p_user_id: novoId, p_nome: nome, p_permissoes: permissoes, p_usuario: usuario,
  });
  if (vinc.error) {
    const del = await client().auth.admin.deleteUser(novoId);
    if (del.error) log("error", "rollback_falhou", { usuario_id: novoId });
    const m = mensagemDoBanco(vinc.error);
    log("warn", "vincular_falhou", { code: vinc.error.code });
    return m ? erro(400, "nao_vinculado", m, ch) : erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
  if(o["papel"] === "proprietario"){
    const promocao=await client().rpc("florest_usuario_promover_novo",{p_ator:ator,p_alvo:novoId});
    if(promocao.error){await client().auth.admin.deleteUser(novoId);return erro(500,"promocao_falhou","Não foi possível concluir o cadastro do proprietário.",ch);}
  }
  log("info", "funcionario_criado", { ator, usuario_id: novoId });
  return json(200, { ok: true, usuario_id: novoId }, ch);
}

async function redefinirSenha(ator: string, o: Record<string, unknown>, ch: Record<string, string>): Promise<Response> {
  const alvo = typeof o["usuario_id"] === "string" ? o["usuario_id"] : "";
  if (!UUID_RE.test(alvo)) return erro(400, "usuario_invalido", "Usuário inválido.", ch);
  const msgSenha = validarSenha(o["senha"]);
  if (msgSenha) return erro(400, "senha_invalida", msgSenha, ch);

  const aut = await client().rpc("florest_senha_preparar", { p_ator: ator, p_alvo: alvo });
  if (aut.error) {
    const m = mensagemDoBanco(aut.error);
    if (m) return erro(403, "nao_autorizado", m, ch);
    log("error", "autorizar_falhou", { code: aut.error.code });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
  const audit = await client().rpc("florest_auditar_senha", {p_ator:ator,p_alvo:alvo,p_resultado:"iniciada"});
  if(audit.error)return erro(500,"auditoria_indisponivel","Não foi possível registrar a operação. A senha não foi alterada.",ch);
  const r = await client().auth.admin.updateUserById(alvo, { password: o["senha"] as string });
  const fim = await client().rpc("florest_auditar_senha", {p_ator:ator,p_alvo:alvo,p_resultado:r.error?"falha_auth":"sucesso"});
  if(!r.error && fim.error)return erro(500,"auditoria_pendente","A senha foi alterada, mas o registro final da auditoria precisa ser conferido.",ch);
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
// Fase 4 — Garçons do Módulo Bar (Migration 020). Mesmo molde de criar()/redefinirSenha() acima,
// só que: (1) nunca recebe nem valida e-mail/permissões — o e-mail é gerado aqui, as permissões
// são decididas pelo banco (bar_garcom_vincular); (2) a autorização do ator é ser o PROPRIETÁRIO
// da empresa (verificada dentro de bar_garcons_preparar_criacao/bar_garcom_autorizar_alvo, via
// private.bar_garcons_ator) — bar_configurar e qualquer outra permissão de funcionário não
// autorizam administrar garçom, e não é a mesma checagem de "usuarios" usada em criar()/redefinirSenha().
// ---------------------------------------------------------------------
async function criarGarcom(ator: string, o: Record<string, unknown>, ch: Record<string, string>): Promise<Response> {
  const nome = typeof o["nome"] === "string" ? o["nome"].trim() : "";
  // Normalizado aqui (trim + minúsculas) antes de ir para o banco — mesma normalização que a
  // Migration 021 usa nos índices únicos lower(usuario). O banco é quem decide, de fato, se há
  // conflito dentro da empresa (bar_garcom_vincular); esta função só garante o formato.
  const usuario = typeof o["usuario"] === "string" ? o["usuario"].trim().toLowerCase() : "";
  const senha = o["senha"];
  if (nome.length < 2 || nome.length > 200) return erro(400, "nome_invalido", "Informe o nome do garçom (2 a 200 caracteres).", ch);
  if (!USUARIO_RE.test(usuario)) return erro(400, "usuario_invalido", "Informe um usuário sem espaços, de 2 a 60 caracteres.", ch);
  const msgSenha = validarSenha(senha);
  if (msgSenha) return erro(400, "senha_invalida", msgSenha, ch);

  // 1) o banco decide se o ator pode cadastrar um garçom (é o proprietário da empresa) antes de criar qualquer login
  const pre = await client().rpc("bar_garcons_preparar_criacao", { p_ator: ator });
  if (pre.error) {
    const m = mensagemDoBanco(pre.error);
    if (m) return erro(403, "nao_autorizado", m, ch);
    log("error", "preparar_garcom_falhou", { code: pre.error.code });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }

  // 2) cria o login com um e-mail técnico aleatório (nunca o nome do garçom, nunca visível a ele
  // ou ao proprietário) e já confirmado (o proprietário responde por essa pessoa, como no fluxo
  // geral de funcionários).
  const email = `${crypto.randomUUID()}@${GARCOM_EMAIL_DOMINIO}`;
  const novo = await client().auth.admin.createUser({ email, password: senha as string, email_confirm: true });
  if (novo.error || !novo.data?.user?.id) {
    const msg = (novo.error?.message ?? "").toLowerCase();
    if (msg.includes("password")) return erro(400, "senha_invalida", "A senha não foi aceita. Use uma senha mais forte.", ch);
    log("error", "criar_login_garcom_falhou", { status: novo.error?.status });
    return erro(500, "erro_interno", "Não foi possível criar o login. Tente novamente.", ch);
  }
  const novoId = novo.data.user.id;

  // 3) vincula à empresa do ator como garçom — permissões fixas, decididas só pelo banco — e grava
  // perfis.usuario (Fase 5 / Migration 022). Se falhar (inclusive por "usuario" já em uso nesta
  // empresa), apaga o login recém-criado: nada fica órfão, e nenhum usuario duplicado chega a existir.
  const vinc = await client().rpc("bar_garcom_vincular", { p_ator: ator, p_user_id: novoId, p_nome: nome, p_usuario: usuario });
  if (vinc.error) {
    const del = await client().auth.admin.deleteUser(novoId);
    if (del.error) log("error", "rollback_garcom_falhou", { usuario_id: novoId });
    const m = mensagemDoBanco(vinc.error);
    log("warn", "vincular_garcom_falhou", { code: vinc.error.code });
    return m ? erro(400, "nao_vinculado", m, ch) : erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
  log("info", "garcom_criado", { ator, usuario_id: novoId });
  return json(200, { ok: true, usuario_id: novoId }, ch);
}

async function redefinirSenhaGarcom(ator: string, o: Record<string, unknown>, ch: Record<string, string>): Promise<Response> {
  const alvo = typeof o["usuario_id"] === "string" ? o["usuario_id"] : "";
  if (!UUID_RE.test(alvo)) return erro(400, "usuario_invalido", "Garçom inválido.", ch);
  const msgSenha = validarSenha(o["senha"]);
  if (msgSenha) return erro(400, "senha_invalida", msgSenha, ch);

  const aut = await client().rpc("florest_senha_preparar", { p_ator: ator, p_alvo: alvo });
  if (aut.error) {
    const m = mensagemDoBanco(aut.error);
    if (m) return erro(403, "nao_autorizado", m, ch);
    log("error", "autorizar_garcom_falhou", { code: aut.error.code });
    return erro(500, "erro_interno", "Não foi possível concluir. Tente novamente.", ch);
  }
  const audit = await client().rpc("florest_auditar_senha", {p_ator:ator,p_alvo:alvo,p_resultado:"iniciada"});
  if(audit.error)return erro(500,"auditoria_indisponivel","Não foi possível registrar a operação. A senha não foi alterada.",ch);
  const r = await client().auth.admin.updateUserById(alvo, { password: o["senha"] as string });
  const fim = await client().rpc("florest_auditar_senha", {p_ator:ator,p_alvo:alvo,p_resultado:r.error?"falha_auth":"sucesso"});
  if(!r.error && fim.error)return erro(500,"auditoria_pendente","A senha foi alterada, mas o registro final da auditoria precisa ser conferido.",ch);
  if (r.error) {
    const msg = (r.error.message ?? "").toLowerCase();
    if (msg.includes("password")) return erro(400, "senha_invalida", "A senha não foi aceita. Use uma senha mais forte.", ch);
    log("error", "trocar_senha_garcom_falhou", { status: r.error.status });
    return erro(500, "erro_interno", "Não foi possível trocar a senha. Tente novamente.", ch);
  }
  log("info", "senha_garcom_redefinida", { ator, usuario_id: alvo });
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
      case "criar_garcom": return await criarGarcom(ator, corpo.obj, ch);
      case "redefinir_senha_garcom": return await redefinirSenhaGarcom(ator, corpo.obj, ch);
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
