// =====================================================================
// Florest ERP (DistGestor) — Edge Function "fiscal-emitir-documento"
// Projeto: Supabase ERP DISTGESTOR. Configurar: Verify JWT = LIGADO.
// Precisa do arquivo "dadosjah.ts" (idêntico) na mesma pasta — ver nota de proveniência nele.
//
// (Histórico — esta função JÁ ESTÁ IMPLANTADA e em uso; o texto abaixo é da época da escrita.)
// Escrita para a Etapa 7 (Diagnóstico Fiscal): fiscal-configurar-emitente
// e fiscal-upload-certificado já estão implantadas e corretas (confirmado por você no painel do
// Supabase); esta era a única peça que faltava, e a única versão que existia no workspace
// (fiscal_emitir_documento_dashboard/index.ts) era código de referência do PetGestor — chama
// usuario_tem_modulo, a tabela dadosjah_credenciais, dadosjah_obter_credenciais e
// fiscal_proximo_numero, nenhum dos quais existe no banco do DistGestor (ver
// etapa7_diagnostico_fiscal_dadosjah.md). Esta função foi reescrita do zero para o schema REAL
// do DistGestor, usando aquela referência SOMENTE para a regra fiscal (payload da NFC-e,
// interpretação do retorno) e para o desenho geral do fluxo — nunca para nomes de RPC/tabela.
//
// Depende da Migration 10 (distgestor_migration_010_fiscal_reservar_numero.sql, entregue junto)
// já aplicada — cria public.fiscal_reservar_numero, usada no passo 10 abaixo.
//
// REVISÃO FISCAL 2 (Módulo Bar, ÚLTIMA revisão antes da instalação — nenhuma mudança de
// arquitetura, nenhuma Migration 017; ver relatório correspondente para o detalhamento completo).
// Três correções, todas isoladas neste arquivo (nenhuma alteração em distgestor_migration_016_
// modulo_bar.sql nem em fiscal_emitir_nota/fiscal_reservar_numero — núcleo, compartilhado com
// PDV/Pet, deliberadamente intocado):
//   PONTO 1 (desconto/acréscimo/taxa de serviço): para uma venda do Bar (vendas.tipo='bar'),
//     public.vendas.total já é o total NET correto (bruto - desconto + acréscimo + taxa_servico,
//     somado por pagamento não estornado — ver bar_comanda_pagar), mas o valor bruto de
//     itens_venda (e de documentos_fiscais.valor, gravado por fiscal_emitir_nota) NUNCA reflete
//     esses ajustes — sem correção, a NFC-e sairia com o total bruto (ex. R$500) mesmo quando o
//     cliente pagou R$450 (desconto) ou R$550 (taxa de serviço). Corrigido preenchendo
//     total.ICMSTot.vDesc/vOutro (campos padrão do layout 4.00, já existentes neste payload, só
//     hardcoded em "0.00" antes) a partir da soma de bar_pagamentos.desconto/acrescimo/
//     taxa_servico dos pagamentos NÃO estornados da venda — nenhum campo novo foi inventado.
//   PONTO 2 (formas de pagamento divididas): para uma venda do Bar, pag.detPag deixa de usar
//     vendas.forma_pagamento (que pode ser só o resumo "dividido") e passa a reconstruir as
//     formas reais a partir de bar_pagamentos_formas dos pagamentos NÃO estornados — reaproveita
//     a mesma codigoFormaPagamento já usada por PDV/Pet, sem um segundo padrão fiscal.
//   PONTO 3 (bloqueio de comanda não quitada, OBRIGATÓRIO NO BACKEND): para uma venda do Bar,
//     antes de qualquer outra coisa (mesma seção da trava de vendas.cancelada_em, ainda antes da
//     trava atômica), confirma em public.bar_pedidos_itens que não restam itens da comanda ainda
//     em aberto (estornado=false e pagamento_id IS NULL); se restar algum, RECUSA a emissão.
// PDV e Pet (vendas.tipo <> 'bar') continuam com o comportamento exato de antes desta revisão em
// todos os três pontos.
//
// REVISÃO FISCAL 3 (PDV MISTO — depende da Migration 028, public.vendas_pagamentos). Só o ramo
// "não é Bar" do bloco de pag.detPag mudou; o ramo do Bar (REVISÃO FISCAL 2) ficou intacto:
//   - Venda COM linhas em vendas_pagamentos (feita por public.registrar_venda_mista): detPag é
//     montado a partir delas (uma linha por forma, somando formas repetidas em centavos), com a
//     mesma codigoFormaPagamento/montarGrupoCard de sempre (card {tpIntegra:"2"} em 03/04/17).
//     A soma em centavos tem de ser IGUAL ao valor fiscal da NFC-e (vNF); senão a emissão é
//     recusada ANTES de reservar numeração e de chamar a Dados Jah (422, nenhuma nota sai).
//   - Venda SEM linhas (todas as vendas antigas e as feitas por registrar_venda): comportamento
//     idêntico ao anterior, usando vendas.forma_pagamento.
// Uma venda continua gerando no máximo UMA NFC-e (índice parcial documentos_fiscais_venda_tipo_uk).
//
// AMBIENTE FISCAL POR EMPRESA (correção): o tpAmb deixou de ser fixo em "2". Vem de
// configuracoes_fiscais.nfce_ambiente (homologacao -> "2", producao -> "1"). Em PRODUÇÃO a emissão é
// recusada (422, antes de travar o documento e de reservar numeração) se faltarem os pré-requisitos
// fiscais (validarProducao, a mesma lista de fiscal-definir-ambiente). CSC, idCSC, série e numeração
// NÃO são alterados por esta função.
//
// Fluxo (tpAmb conforme o ambiente da empresa; async false, tpDanfe Cupom):
//   1. Autentica o usuário (JWT) e obtém a empresa dele via perfis (RLS) — nunca do corpo.
//   2. Confirma, com uma leitura via RLS em documentos_fiscais (tenant + módulo fiscal/pdw),
//      que o documento pedido existe, pertence à empresa do usuário, e que ele tem permissão.
//   3. Só emite NFC-e nesta etapa (nfse/nfe ficam para depois).
//   4. REVISÃO FISCAL (Módulo Bar): confirma vendas.cancelada_em IS NULL — uma venda
//      cancelada/estornada (ex.: bar_pagamento_estornar) nunca pode virar documento fiscal — e,
//      só para vendas do Bar (tipo='bar'), confirma que a comanda está totalmente quitada (PONTO
//      3 da REVISÃO FISCAL 2: nenhum item não estornado com pagamento_id nulo). Ambas as travas no
//      BACKEND (não só no index.html), antes de qualquer outro passo.
//   5. Confirma configuracoes_fiscais.emitente_registrado = true.
//   6. Confirma os Secrets RESPTEC_* (obrigatórios no bloco infRespTec de toda NFC-e).
//   7. Trava atômica: UPDATE condicional (status IN nao_emitida/rejeitada) evita duas emissões
//      simultâneas do mesmo documento e nunca reprocessa um já autorizado.
//   8. A partir daqui, qualquer exceção não tratada reverte o documento para "rejeitada" (nunca
//      fica preso em "processando" indefinidamente).
//   9. Busca os itens de mercadoria da venda (produtos.tipo_fiscal = 'produto'); sem isso, volta
//      o documento para "nao_emitida" (não é falha, só não há o que emitir).
//   10. Obtém/renova o token de USUÁRIO da empresa na Dados Jah via fiscal_credenciais (nunca o
//       token de Sistema).
//   11. Reserva o número fiscal atomicamente via public.fiscal_reservar_numero (RPC nova,
//       Migration 10) — chamada com o cliente de RLS, nunca com service_role.
//   12. Monta o payload da NFC-e, incluindo infNF.emit com os dados atuais de
//       configuracoes_fiscais (o emitente também é pré-cadastrado à parte, via
//       fiscal-configurar-emitente, mas o diagnóstico mostrou que esta chamada
//       específica exige o bloco emit no próprio payload — sem ele a Dados Jah
//       rejeitava com "IE do emitente não cadastrada").
//   13. Chama POST /nfce?tpDanfe=Cupom (timeout ~60s).
//   14. Interpreta o retorno com interpretarRetornoFiscal (dadosjah.ts) — nunca conclui
//       "autorizada" sem cStat/situação de sucesso + protocolo + chave de acesso.
//   15. Grava o resultado em documentos_fiscais + evento de auditoria em
//       documentos_fiscais_eventos, e responde ao frontend sem nenhum dado sensível.
//
// P1 — SEGURANÇA FISCAL (Migration 036 obrigatória, aplicada ANTES desta função) — revisão 2:
//   (1) Número, série e cNF são persistidos NO DOCUMENTO, numa única transação, ANTES de chamar a
//       Dados Jah (RPC public.fiscal_reservar_numero_documento). Imediatamente antes do envio a Edge
//       grava a situação "enviando" (se não conseguir gravar, NÃO envia). Reaproveitar nNF/série/cNF
//       só é permitido para tentativa que nunca foi enviada (em_curso) ou cuja consulta foi
//       confirmada por um usuário Fiscal (liberada_para_reenvio) — nunca automaticamente.
//   (2) Só viram "rejeitada" os cStat de rejeição CONFIRMADA (lista explícita em dadosjah.ts) e só
//       viram "autorizada" cStat 100 + protocolo + chave. Denegação, cancelamento, inutilização,
//       duplicidade, processamento pendente, cStat não catalogado, falha de rede/timeout/HTTP (inclusive
//       HTTP 400 com texto de validação ou de rede do ACBr — não há garantia documentada de que a Dados Jah
//       não transmitiu), corpo ilegível e retorno sem cStat => "situação desconhecida"/denegada: o documento
//       permanece em "processando" (bloqueado), com a orientação de consulta em mensagem_rejeicao e o
//       marcador retorno_provedor->emissao_tentativa->situacao. Se gravar esse estado falhar, o documento
//       continua "processando"/"enviando" (nunca é desbloqueado); um trigger do banco também impede
//       qualquer UPDATE processando -> rejeitada/nao_emitida enquanto a tentativa estiver pendente.
//   Resposta HTTP da API (Dados Jah) NÃO é cStat da SEFAZ — ver comentário em dadosjah.ts.
//
// CORS: chamada direto do navegador (JWT do usuário) — mesmo secret DISTGESTOR_ALLOWED_ORIGINS
// (ou FLOREST_ALLOWED_ORIGINS) já configurado para as demais funções fiscais.
// =====================================================================

import {
  DADOSJAH_BASE_URL,
  CODIGO_UF,
  criarClienteAdmin,
  criarClienteUsuario,
  obterSegredoVault,
  jsonResponse,
  decideCors,
  origensPermitidasEnv,
  sanitizarCorpoDiagnostico,
  somenteDigitos,
  logFiscal,
  interpretarRetornoFiscal,
  classificarFalhaTransporte,
  classificarFalhaHttp,
  classificarRetornoDadosJah,
  mensagemSituacaoDesconhecida,
  type DesfechoEmissao,
  agoraISOComOffsetBrasilia,
  codigoFormaPagamento,
  formatarValorMonetario,
  montarGrupoCard,
} from "./dadosjah.ts";
import { montarChave } from "./chave.ts";
import { validarSaldoBar, conferirTotaisBar, ratearAjustesBar } from "./bar-financeiro.mjs";
// Migration 42: teste de homologação da contingência (tpEmis=9). Inerte sem o secret FISCAL_CTG_TESTE_HOMOLOG e fora de tpAmb=2.
import {
  anexoPreliminarTesteCtg,
  avaliarPedidoTesteCtg,
  avaliarPermissaoTesteCtg,
  dhContParaTeste,
  diagnosticarRespostaTesteCtg,
  MODO_ENVIO_TESTE_CTG,
  validarIdeTesteCtg,
  XJUST_TESTE_CTG,
} from "./teste_ctg.ts";

type ClienteAdmin = ReturnType<typeof criarClienteAdmin>;

// Ambiente da emissão: vem de configuracoes_fiscais.nfce_ambiente da EMPRESA (definido pela Edge
// fiscal-definir-ambiente — o navegador não consegue gravar esse campo). homologacao -> tpAmb "2",
// producao -> tpAmb "1". Qualquer outro valor/ausência = HOMOLOGAÇÃO (nunca produção por omissão).
const TP_AMB_HOMOLOGACAO = "2";
const TP_AMB_PRODUCAO = "1";
const TIPO_EVENTO = "emissao_nfce";

// Idêntica à de fiscal-upload-certificado.index.ts (já correta/implantada): usa
// public.fiscal_credenciais (não dadosjah_credenciais, que não existe neste banco) e o token de
// USUÁRIO da empresa (nunca o de Sistema).
async function obterTokenUsuario(admin: ClienteAdmin, empresaId: string): Promise<string | null> {
  const { data: cred, error } = await admin
    .from("fiscal_credenciais")
    .select("dadosjah_email, dadosjah_password_secret_id, dadosjah_token, dadosjah_token_expires_at")
    .eq("empresa_id", empresaId)
    .maybeSingle();

  if (error || !cred?.dadosjah_email || !cred?.dadosjah_password_secret_id) return null;

  const margemSegundos = 60;
  const aindaValido =
    cred.dadosjah_token &&
    cred.dadosjah_token_expires_at &&
    new Date(cred.dadosjah_token_expires_at).getTime() - margemSegundos * 1000 > Date.now();

  if (aindaValido) return cred.dadosjah_token as string;

  const senha = await obterSegredoVault(admin, cred.dadosjah_password_secret_id as string);
  if (!senha) return null;

  const resp = await fetch(`${DADOSJAH_BASE_URL}/auth/user/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ email: cred.dadosjah_email, password: senha }),
  });
  if (!resp.ok) return null;

  const json = await resp.json().catch(() => null);
  const token = json?.data?.accessToken;
  const expiresAt = json?.data?.expiresAt ?? null;
  if (!token) return null;

  await admin
    .from("fiscal_credenciais")
    .update({ dadosjah_token: token, dadosjah_token_expires_at: expiresAt })
    .eq("empresa_id", empresaId);

  return token as string;
}

// ---------------------------------------------------------------------
// VALIDAÇÃO FISCAL PARA PRODUÇÃO — idêntica à de fiscal-definir-ambiente (mantenha as duas cópias
// iguais). Devolve a lista de pendências em português; lista vazia = pode emitir em produção.
// ---------------------------------------------------------------------
function hojeSaoPaulo(agora = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Sao_Paulo", year: "numeric", month: "2-digit", day: "2-digit" }).format(agora);
}

// deno-lint-ignore no-explicit-any
function validarProducao(config: Record<string, any>, respTecOk: boolean, hoje: string): string[] {
  const p: string[] = [];
  const falta = (nome: string, ok: boolean) => { if (!ok) p.push(nome); };

  const dados: string[] = [];
  const preenchido = (v: unknown) => typeof v === "string" ? v.trim() !== "" : v !== null && v !== undefined;
  if (!preenchido(config.razao_social)) dados.push("razão social");
  if (somenteDigitos(config.cnpj).length !== 14) dados.push("CNPJ (14 dígitos)");
  if (!preenchido(config.inscricao_estadual)) dados.push("inscrição estadual");
  if (!["1", "2", "3"].includes(String(config.crt ?? ""))) dados.push("regime tributário (CRT)");
  if (somenteDigitos(config.cep).length !== 8) dados.push("CEP");
  for (const [campo, rotulo] of [["endereco", "endereço"], ["numero", "número"], ["bairro", "bairro"], ["municipio", "município"]] as const) {
    if (!preenchido(config[campo])) dados.push(rotulo);
  }
  if (!/^[A-Za-z]{2}$/.test(String(config.uf ?? "").trim())) dados.push("UF");
  if (somenteDigitos(config.codigo_ibge).length !== 7) dados.push("código IBGE do município (7 dígitos)");
  if (dados.length > 0) p.push(`Dados da empresa incompletos ou inválidos: ${dados.join(", ")}.`);

  const serie = String(config.nfce_serie ?? "").trim();
  falta("Informe a série da NFC-e.", /^\d+$/.test(serie) && Number(serie) > 0);

  const csc = String(config.nfce_csc ?? "").trim();
  const idCsc = String(config.nfce_id_csc ?? "").trim();
  falta("Informe o CSC de PRODUÇÃO (o CSC de homologação não vale em produção).", csc !== "");
  falta("Informe o idCSC de PRODUÇÃO.", /^\d+$/.test(idCsc));
  // Versão do QR Code: NUNCA presumida (sem default "2"). A Dados Jah a recebe em POST/PATCH /user
  // (nfceVersaoQRCode, opcional na doc oficial) e o ERP a exige explicitamente em produção.
  const versaoQr = String(config.nfce_versao_qrcode ?? "").trim();
  falta("Informe a versão do QR Code da NFC-e (conforme o cadastro do CSC na SEFAZ). O sistema não assume uma versão.", /^\d+$/.test(versaoQr));

  const certAtivo = config.certificado_status === "ativo";
  falta("Instale o certificado digital A1 da empresa.", certAtivo);
  if (certAtivo) {
    const validade = typeof config.certificado_validade === "string" ? config.certificado_validade.slice(0, 10) : "";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(validade)) p.push("Não foi possível confirmar a validade do certificado digital. Reenvie o certificado.");
    else if (validade < hoje) p.push(`O certificado digital está vencido (validade ${validade.split("-").reverse().join("/")}). Instale um certificado válido.`);
    const cnpjCert = somenteDigitos(config.certificado_cnpj);
    const cnpjEmp = somenteDigitos(config.cnpj);
    if (cnpjCert.length >= 8 && cnpjEmp.length >= 8 && cnpjCert.slice(0, 8) !== cnpjEmp.slice(0, 8)) {
      p.push("O certificado digital pertence a outro CNPJ (a raiz do CNPJ do certificado é diferente da empresa).");
    }
  }

  falta("A empresa ainda não foi criada na Dados Jah (use \"Registrar empresa na Dados Jah\").", config.dadosjah_usuario_criado === true);
  falta("O emitente ainda não foi registrado na Dados Jah (use \"Registrar empresa na Dados Jah\").", config.emitente_registrado === true);
  falta("Os dados do responsável técnico não estão configurados no servidor (RESPTEC_*). Contate o suporte.", respTecOk);
  return p;
}

// Reverte o documento para "rejeitada" com uma mensagem, e registra o evento correspondente.
// Chamada em TODO caminho de falha depois da trava atômica (item 17 do pedido: nunca deixar um
// documento preso em "processando" indefinidamente) — inclusive dentro do catch mais externo,
// para qualquer exceção não prevista (a referência do PetGestor não fazia isso no catch externo;
// aqui fazemos, por segurança).
async function reverterParaRejeitada(
  admin: ClienteAdmin,
  documentoFiscalId: string,
  empresaId: string,
  motivo: string,
): Promise<void> {
  try {
    const { error: erroReversao } = await admin
      .from("documentos_fiscais")
      .update({ status: "rejeitada", mensagem_rejeicao: motivo, atualizado_em: new Date().toISOString() })
      .eq("id", documentoFiscalId)
      .eq("empresa_id", empresaId);
    if (erroReversao) {
      // P1: o banco pode recusar (trigger da Migration 036: tentativa enviando/desconhecida/denegada não
      // volta a rejeitada). Nesse caso o documento permanece bloqueado e NÃO se grava evento "rejeitada".
      logFiscal("reversao_para_rejeitada_recusada", { documentoFiscalId, codigo: erroReversao.code ?? null });
      return;
    }
    await admin.from("documentos_fiscais_eventos").insert({
      documento_fiscal_id: documentoFiscalId,
      empresa_id: empresaId,
      tipo_evento: TIPO_EVENTO,
      status: "rejeitada",
      mensagem: motivo,
    });
  } catch (e) {
    logFiscal("falha_ao_reverter_documento", { documentoFiscalId, erro: e instanceof Error ? e.name : "desconhecido" });
  }
}

// ---------------------------------------------------------------------
// P1 — marcador da tentativa de emissão (documentos_fiscais.retorno_provedor->'emissao_tentativa').
// situacao: em_curso (reservado, NUNCA enviado) | enviando (envio iniciado, sem desfecho gravado) |
//           desconhecida | denegada | liberada_para_reenvio (consulta confirmada) | finalizada.
// A RPC fiscal_reservar_numero_documento (Migration 036) cria o marcador em 'em_curso'.
// ---------------------------------------------------------------------
const SITUACOES_BLOQUEADAS = new Set(["enviando", "desconhecida", "denegada"]);
// Marcador em_curso parado há mais que isto com o documento ainda "processando": a Edge foi interrompida
// ANTES de gravar "enviando" (nenhuma requisição saiu) — precisa de liberação pelo suporte.
const LIMITE_EM_CURSO_MS = 5 * 60_000;

// deno-lint-ignore no-explicit-any
function tentativaDe(retornoProvedor: any): Record<string, unknown> {
  const t = retornoProvedor?.emissao_tentativa;
  return t && typeof t === "object" ? (t as Record<string, unknown>) : {};
}

// Devolve o retorno_provedor atual do documento com o marcador mesclado (ou undefined se não deu
// para ler — nesse caso o chamador NÃO altera o marcador).
async function mesclarTentativa(
  admin: ClienteAdmin,
  documentoFiscalId: string,
  empresaId: string,
  patch: Record<string, unknown> | ((tentativaAtual: Record<string, unknown>) => Record<string, unknown>),
  // deno-lint-ignore no-explicit-any
): Promise<Record<string, any> | undefined> {
  try {
    const { data, error } = await admin
      .from("documentos_fiscais")
      .select("retorno_provedor")
      .eq("id", documentoFiscalId)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (error || !data) return undefined;
    const atual = (data.retorno_provedor && typeof data.retorno_provedor === "object") ? data.retorno_provedor : {};
    const t = tentativaDe(atual);
    const p = typeof patch === "function" ? patch(t) : patch;
    return { ...atual, emissao_tentativa: { ...t, ...p } };
  } catch {
    return undefined;
  }
}

// Grava "enviando" ANTES de chamar a Dados Jah. Só devolve true se a gravação foi CONFIRMADA (linha
// atualizada, sem erro). Qualquer dúvida => false => a Edge NÃO envia.
// Dados de cada ENVIO gravados ANTES de a requisição sair (Migration 37): o dhEmi enviado, a chave de acesso PREVISTA
// (cálculo do ERP — ver chave.ts) e o idExternal. Servem para consultar a SEFAZ diretamente depois de uma falha de
// comunicação. A lista "envios" só cresce (cada reenvio liberado acrescenta um item); nada é sobrescrito.
interface DadosEnvio { dhEmi: string; chavePrevista: string | null; idExternal: string; modo?: string; extra?: Record<string, unknown> }
const MAX_ENVIOS_REGISTRADOS = 20;

async function marcarEnvioIniciado(admin: ClienteAdmin, documentoFiscalId: string, empresaId: string, envio: DadosEnvio): Promise<boolean> {
  try {
    const agora = new Date().toISOString();
    const rp = await mesclarTentativa(admin, documentoFiscalId, empresaId, (t) => {
      const anteriores = Array.isArray(t.envios) ? (t.envios as unknown[]) : [];
      const item = {
        n: anteriores.length + 1,
        dhEmi: envio.dhEmi,
        chave_prevista: envio.chavePrevista,
        id_externo: envio.idExternal,
        envio_iniciado_em: agora,
        ...(envio.modo ? { modo: envio.modo } : {}),
        ...(envio.extra ?? {}),
      };
      return {
        situacao: "enviando",
        envio_iniciado_em: agora,
        dh_emi: envio.dhEmi,
        chave_prevista: envio.chavePrevista,
        id_externo: envio.idExternal,
        ...(envio.extra ?? {}),
        envios: [...anteriores, item].slice(-MAX_ENVIOS_REGISTRADOS),
      };
    });
    if (!rp) return false;
    const { data, error } = await admin
      .from("documentos_fiscais")
      .update({ retorno_provedor: rp, atualizado_em: new Date().toISOString() })
      .eq("id", documentoFiscalId)
      .eq("empresa_id", empresaId)
      .eq("status", "processando")
      .select("id")
      .maybeSingle();
    return !error && !!data;
  } catch {
    return false;
  }
}

// TESTE de contingência em homologação: quando a API responde com um documento mas SEM prova de autorização, o documento fica
// bloqueado em "processando" e aqui se PRESERVAM os dados necessários para uma transmissão posterior e para a consulta: tpEmis, dhCont,
// xJust, chave prevista, idDfe/chDfe devolvidos, hash/tamanho do XML e (só se trouxer tpEmis=9) o próprio XML. Não altera status,
// numeração nem contador. Falha aqui nunca muda o resultado (só deixa de guardar a evidência extra).
async function sha256Hex(texto: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(texto));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
async function preservarDadosTesteCtg(
  admin: ClienteAdmin,
  documentoFiscalId: string,
  empresaId: string,
  d: { ide: Record<string, unknown>; item: Record<string, unknown>; chavePrevista: string | null },
): Promise<void> {
  try {
    const xml = typeof d.item.xml === "string" && d.item.xml.length > 0 && d.item.xml.length <= 2_000_000 ? d.item.xml : null;
    const xmlComTpEmis9 = !!xml && /<tpEmis>\s*9\s*<\/tpEmis>/.test(xml);
    const agora = new Date().toISOString();
    const rp = await mesclarTentativa(admin, documentoFiscalId, empresaId, {
      contingencia_teste: {
        tpEmis: "9", dhCont: d.ide.dhCont ?? null, xJust: d.ide.xJust ?? null, chave_prevista: d.chavePrevista,
        id_dfe: typeof d.item.idDfe === "string" ? d.item.idDfe : null, ch_dfe: typeof d.item.chDfe === "string" ? d.item.chDfe : null,
        xml_presente: !!xml, xml_tpEmis_9: xmlComTpEmis9, xml_tamanho: xml ? xml.length : null, xml_sha256: xml ? await sha256Hex(xml) : null,
        xml_link: typeof d.item.xmlLink === "string" ? d.item.xmlLink.slice(0, 500) : null, pdf_link: typeof d.item.pdfLink === "string" ? d.item.pdfLink.slice(0, 500) : null,
        preservado_em: agora,
      },
    });
    if (!rp) return;
    const campos: Record<string, unknown> = { retorno_provedor: rp, atualizado_em: agora };
    if (xml && xmlComTpEmis9) campos.xml_conteudo = xml;
    await admin.from("documentos_fiscais").update(campos)
      .eq("id", documentoFiscalId).eq("empresa_id", empresaId).eq("status", "processando");
  } catch (e) {
    logFiscal("falha_preservar_dados_teste_ctg", { documentoFiscalId, erro: e instanceof Error ? e.name : "desconhecido" });
  }
}

// Documento fica em "processando" (BLOQUEADO para reemissão) com a orientação de consulta. NUNCA vira
// "rejeitada"/"nao_emitida". Se não conseguir gravar o estado, o documento continua "processando" com o
// marcador "enviando" já gravado antes do envio (e o trigger do banco impede qualquer desbloqueio).
// Devolve o corpo da resposta ao frontend.
async function registrarSituacaoDesconhecida(
  admin: ClienteAdmin,
  documentoFiscalId: string,
  empresaId: string,
  desfecho: Pick<DesfechoEmissao, "classe" | "categoria" | "codigo" | "cStat" | "xMotivo" | "httpStatus" | "detalhe" | "indicio">,
  numero: string | number | null,
  serie: string | null,
  dadosProvedor: { idDfe?: string | null; chDfe?: string | null } = {},
  // Migration 44: abertura AUTOMÁTICA da contingência quando a PRÓPRIA SEFAZ informou serviço indisponível. Opcional e best-effort:
  // quem decide é a RPC do banco (ativação automática desligada por padrão); qualquer falha aqui é ignorada e o fluxo segue como antes.
  abrirContingencia?: () => Promise<Record<string, unknown> | null>,
): Promise<Record<string, unknown>> {
  const mensagem = mensagemSituacaoDesconhecida(numero, serie, desfecho.categoria, desfecho.cStat);
  logFiscal("emissao_situacao_desconhecida", {
    empresaId, documentoFiscalId, classe: desfecho.classe, categoria: desfecho.categoria, codigo: desfecho.codigo,
    httpStatus: desfecho.httpStatus, cStat: desfecho.cStat, indicio: desfecho.indicio, numero, serie,
  });
  let registrado = false;
  try {
    const rp = await mesclarTentativa(admin, documentoFiscalId, empresaId, {
      situacao: desfecho.classe === "denegada" ? "denegada" : "desconhecida",
      categoria: desfecho.categoria,
      desfecho_codigo: desfecho.codigo,
      http_status: desfecho.httpStatus,
      c_stat: desfecho.cStat,
      indicio: desfecho.indicio,
      detalhe: desfecho.detalhe,
      desconhecida_em: new Date().toISOString(),
    });
    const campos: Record<string, unknown> = { mensagem_rejeicao: mensagem, atualizado_em: new Date().toISOString() };
    if (rp) campos.retorno_provedor = rp;
    if (desfecho.cStat) campos.c_stat = desfecho.cStat;
    if (dadosProvedor.idDfe) campos.id_dfe = dadosProvedor.idDfe;
    if (dadosProvedor.chDfe) campos.chave_acesso = dadosProvedor.chDfe;
    // .eq("status","processando"): nunca sobrescreve um documento que, por outro caminho, já foi finalizado.
    const { data: atualizado, error } = await admin.from("documentos_fiscais").update(campos)
      .eq("id", documentoFiscalId).eq("empresa_id", empresaId).eq("status", "processando")
      .select("id").maybeSingle();
    registrado = !!rp && !error && !!atualizado;
    if (!registrado) {
      logFiscal("falha_persistir_situacao_desconhecida", { empresaId, documentoFiscalId, codigo: error?.code ?? null, leuMarcador: !!rp });
      // Plano B mínimo: só a orientação (não mexe em status nem no marcador). O documento segue "processando".
      await admin.from("documentos_fiscais").update({ mensagem_rejeicao: mensagem })
        .eq("id", documentoFiscalId).eq("empresa_id", empresaId).eq("status", "processando");
    }
    const { error: erroEvento } = await admin.from("documentos_fiscais_eventos").insert({
      documento_fiscal_id: documentoFiscalId,
      empresa_id: empresaId,
      tipo_evento: TIPO_EVENTO,
      status: "processando",
      c_stat: desfecho.cStat,
      mensagem,
      payload: { situacao: desfecho.classe === "denegada" ? "denegada" : "desconhecida", categoria: desfecho.categoria, codigo: desfecho.codigo, http_status: desfecho.httpStatus, numero, serie },
    });
    if (erroEvento) logFiscal("falha_evento_situacao_desconhecida", { documentoFiscalId, codigo: erroEvento.code ?? null });
  } catch (e) {
    logFiscal("falha_ao_registrar_situacao_desconhecida", { documentoFiscalId, erro: e instanceof Error ? e.name : "desconhecido" });
  }
  let contingencia: Record<string, unknown> | null = null;
  if (abrirContingencia && registrado && desfecho.classe === "desconhecida" && desfecho.categoria === "servico") {
    try { contingencia = await abrirContingencia(); } catch { contingencia = null; }
  }
  return {
    status: "situacao_desconhecida",
    categoria: desfecho.categoria,
    codigo: desfecho.codigo,
    numero: numero ?? null,
    serie: serie ?? null,
    mensagem,
    // false = não foi possível gravar o desfecho; o documento continua bloqueado ("processando"/"enviando").
    estadoRegistrado: registrado,
    // Só presente quando o banco abriu a contingência (SEFAZ informou serviço indisponível). A NFC-e NÃO está autorizada.
    ...(contingencia ? { contingencia } : {}),
  };
}

Deno.serve(async (req: Request) => {
  const cors = decideCors(req, origensPermitidasEnv());
  if (cors.tipo === "negada") {
    return jsonResponse({ error: "Origem não permitida." }, 403);
  }
  const corsHeaders = cors.tipo === "permitida" ? cors.headers : {};
  // Migration 42: no teste de homologação da contingência o diagnóstico da resposta da API acompanha QUALQUER resposta desta chamada.
  let anexoTesteCtg: Record<string, unknown> | null = null;
  const responder = (body: unknown, status = 200) =>
    jsonResponse(anexoTesteCtg && body && typeof body === "object" ? { ...(body as Record<string, unknown>), teste_contingencia: anexoTesteCtg } : body, status, corsHeaders);

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return responder({ error: "Método não permitido." }, 405);
  }

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return responder({ error: "Não autenticado." }, 401);

  const supabaseUser = criarClienteUsuario(authHeader);
  const { data: userData, error: userError } = await supabaseUser.auth.getUser();
  if (userError || !userData?.user) {
    return responder({ error: "Sessão inválida." }, 401);
  }

  // ---------------------------------------------------------
  // empresa_id: sempre do perfil do usuário autenticado (RLS), nunca do corpo.
  // ---------------------------------------------------------
  const { data: perfil, error: perfilError } = await supabaseUser
    .from("perfis")
    .select("empresa_id")
    .single();
  if (perfilError || !perfil?.empresa_id) {
    return responder({ error: "Usuário sem empresa vinculada." }, 403);
  }
  const empresaId = perfil.empresa_id as string;

  const body = await req.json().catch(() => null);
  const documentoFiscalId: string | undefined = typeof body?.documento_fiscal_id === "string" ? body.documento_fiscal_id : undefined;
  if (!documentoFiscalId) {
    return responder({ error: "Informe documento_fiscal_id." }, 400);
  }

  // ---------------------------------------------------------
  // Controle de acesso (tenant + permissão fiscal/pdv): leitura real via RLS, não reimplementada.
  // documentos_fiscais tem duas políticas de SELECT: a PERMISSIVE de empresa_id_ativa() e a
  // RESTRICTIVE rbac_documentos_fiscais_select (perm_alguma(['fiscal','pdv'])). Se o documento
  // não existir, não for desta empresa, OU o usuário não tiver o módulo, esta leitura devolve
  // null — sem distinguir o motivo exato ao chamador (mesma resposta genérica da referência).
  // ---------------------------------------------------------
  const { data: gateDoc, error: gateError } = await supabaseUser
    .from("documentos_fiscais")
    .select("id, venda_id, tipo_documento, status")
    .eq("id", documentoFiscalId)
    .maybeSingle();
  if (gateError) {
    logFiscal("erro_checar_documento", { empresaId, codigo: gateError.code });
    return responder({ error: "Não foi possível verificar o documento fiscal. Tente novamente." }, 500);
  }
  if (!gateDoc) {
    return responder({ error: "Documento fiscal não encontrado para esta empresa." }, 404);
  }
  if (gateDoc.tipo_documento !== "nfce") {
    return responder({ error: "Esta função emite apenas NFC-e nesta etapa." }, 400);
  }

  // ---------------------------------------------------------
  // REVISÃO FISCAL (Módulo Bar, public.vendas.cancelada_em/cancelada_por/motivo_cancelamento —
  // núcleo, seção 1.0 da distgestor_migration_016_modulo_bar.sql): uma venda cancelada/estornada
  // (hoje só possível via public.bar_pagamento_estornar, mas a coluna é genérica do núcleo e vale
  // para qualquer módulo futuro) NUNCA pode virar documento fiscal. O index.html já esconde o
  // botão "Emitir nota" para uma venda cancelada (renderVendaFiscal), mas isso NÃO é suficiente —
  // esta é a única trava que importa de verdade, porque é a única que roda no backend e vale para
  // QUALQUER chamador desta função (frontend, retry manual, futura integração), não só o botão.
  // Lida por RLS (supabaseUser): o tenant já foi confirmado pela leitura de documentos_fiscais
  // acima (RESTRICTIVE de módulo fiscal/pdv), então esta leitura de vendas só precisa confirmar
  // cancelada_em/tipo — nunca decide permissão nem tenant por conta própria. "tipo" foi incluído
  // nesta MESMA leitura (sem round-trip extra) para a nova trava do Ponto 3, logo abaixo.
  // ---------------------------------------------------------
  const { data: vendaGate, error: vendaGateError } = await supabaseUser
    .from("vendas")
    .select("cancelada_em, tipo")
    .eq("id", gateDoc.venda_id)
    .maybeSingle();
  if (vendaGateError) {
    logFiscal("erro_checar_venda_cancelada", { empresaId, documentoFiscalId, codigo: vendaGateError.code });
    return responder({ error: "Não foi possível verificar a venda associada a este documento. Tente novamente." }, 500);
  }
  if (vendaGate?.cancelada_em) {
    return responder({ error: "Esta venda foi cancelada/estornada e não pode emitir documento fiscal." }, 422);
  }

  const admin = criarClienteAdmin();
  // Gastronomia: trava de quitação, com leitura administrativa sempre restrita à empresa confirmada.
  let gastronomiaFiscal: {desconto:number;outros:number;total:number}|null=null;
  if(vendaGate?.tipo==='gastronomia'){
    const ga=await admin.from('gastronomia_atendimentos').select('id,desconto,acrescimo,taxa_servico,taxa_entrega,estado').eq('empresa_id',empresaId).eq('venda_id',gateDoc.venda_id).maybeSingle();
    if(ga.error||!ga.data||ga.data.estado==='cancelado')return responder({error:'Atendimento da Gastronomia indisponível para emissão.'},422);
    const gi=await admin.from('gastronomia_itens').select('quantidade,preco_unitario').eq('empresa_id',empresaId).eq('atendimento_id',ga.data.id).eq('cancelado',false);
    const gp=await admin.from('gastronomia_pagamentos').select('valor').eq('empresa_id',empresaId).eq('atendimento_id',ga.data.id).eq('estornado',false);
    const gv=await admin.from('vendas').select('total').eq('empresa_id',empresaId).eq('id',gateDoc.venda_id).single();
    if(gi.error||gp.error||gv.error)return responder({error:'Não foi possível conferir o atendimento da Gastronomia.'},500);
    const bruto=(gi.data??[]).reduce((n:number,i:any)=>n+Number(i.quantidade)*Number(i.preco_unitario),0);
    const desconto=Number(ga.data.desconto),outros=Number(ga.data.acrescimo)+Number(ga.data.taxa_servico)+Number(ga.data.taxa_entrega),total=Math.round((bruto-desconto+outros)*100)/100;
    const pago=(gp.data??[]).reduce((n:number,p:any)=>n+Number(p.valor),0);
    if(!Number.isFinite(total)||Math.round(pago*100)!==Math.round(total*100)||Math.round(Number(gv.data.total)*100)!==Math.round(total*100))return responder({error:'Quite todo o atendimento antes de emitir o documento fiscal.'},422);
    gastronomiaFiscal={desconto,outros,total};
  }

  // ---------------------------------------------------------
  // Bar: a emissão exige mesa fechada, saldo financeiro zero e recebimentos conferidos.
  // O contexto usa o cálculo oficial da comanda, incluindo pagamentos por valor e ajustes.
  // Leitura exclusiva do service_role, filtrada pela empresa já validada acima.
  // ---------------------------------------------------------
  let barFiscal: Record<string, unknown> | null = null;
  if (vendaGate?.tipo === "bar") {
    const { data: contexto, error: erroContexto } = await admin.rpc("bar_fiscal_saldo", {p_venda_id:gateDoc.venda_id,p_empresa_id:empresaId});
    if(erroContexto || !contexto){
      logFiscal("erro_checar_saldo_bar", {empresaId,documentoFiscalId,codigo:erroContexto?.code});
      return responder({error:"Não foi possível conferir o saldo financeiro da comanda. Tente novamente."},500);
    }
    const motivo=validarSaldoBar(contexto);
    if(motivo)return responder({error:motivo},422);
    barFiscal=contexto;
  }

  // ---------------------------------------------------------
  // Configuração fiscal + emitente registrado (leitura por admin, filtro explícito de empresa_id
  // como defesa em profundidade — o tenant já foi confirmado acima pela RLS).
  // ---------------------------------------------------------
  const { data: config, error: configError } = await admin
    .from("configuracoes_fiscais")
    .select("*")
    .eq("empresa_id", empresaId)
    .maybeSingle();
  if (configError) {
    logFiscal("erro_ler_config", { empresaId, codigo: configError.code });
    return responder({ error: "Não foi possível ler as Configurações Fiscais. Tente novamente." }, 500);
  }
  if (!config) {
    return responder({ error: "Configurações fiscais não encontradas para esta empresa." }, 422);
  }
  if (!config.emitente_registrado) {
    return responder(
      { error: "O emitente ainda não foi registrado na Dados Jah. Conclua a configuração fiscal primeiro." },
      422
    );
  }

  const respTecCnpj = Deno.env.get("RESPTEC_CNPJ");
  const respTecContato = Deno.env.get("RESPTEC_CONTATO");
  const respTecEmail = Deno.env.get("RESPTEC_EMAIL");
  const respTecFone = Deno.env.get("RESPTEC_FONE");
  if (!respTecCnpj || !respTecContato || !respTecEmail || !respTecFone) {
    return responder(
      { error: "Dados do responsável técnico não configurados (Secrets RESPTEC_CNPJ / RESPTEC_CONTATO / RESPTEC_EMAIL / RESPTEC_FONE)." },
      500
    );
  }

  // ---------------------------------------------------------
  // AMBIENTE FISCAL DA EMPRESA + pré-requisitos de PRODUÇÃO. Roda ANTES da trava atômica e da
  // reserva de numeração: se algo faltar, o documento fica como estava e nenhum número é gasto.
  // ---------------------------------------------------------
  const emProducao = config.nfce_ambiente === "producao";
  const tpAmb = emProducao ? TP_AMB_PRODUCAO : TP_AMB_HOMOLOGACAO;
  // Migration 42: pedido de TESTE de contingência em homologação. Recusado ANTES de qualquer número, trava ou envio.
  const pedidoTesteCtg = body?.teste_contingencia_homologacao === true;
  if (pedidoTesteCtg) {
    const av = avaliarPedidoTesteCtg(Deno.env.get("FISCAL_CTG_TESTE_HOMOLOG"), tpAmb, typeof config.nfce_ambiente === "string" ? config.nfce_ambiente : null);
    if (!av.ativo) {
      logFiscal("teste_ctg_recusado", { empresaId, documentoFiscalId, codigo: av.codigo });
      return responder({ status: "teste_contingencia_recusado", codigo: av.codigo, mensagem: av.mensagem }, 403);
    }
    // Só proprietário ou módulo Fiscal (o PDV sozinho não testa contingência). Perfil lido pelo cliente do USUÁRIO (RLS).
    const { data: perfilTeste } = await supabaseUser.from("perfis").select("papel, permissoes, ativo").single();
    const perm = avaliarPermissaoTesteCtg(perfilTeste as { papel?: unknown; permissoes?: unknown; ativo?: unknown } | null);
    if (!perm.ativo) {
      logFiscal("teste_ctg_recusado", { empresaId, documentoFiscalId, codigo: perm.codigo });
      return responder({ status: "teste_contingencia_recusado", codigo: perm.codigo, mensagem: perm.mensagem }, 403);
    }
  }
  if (emProducao) {
    const pendenciasProducao = validarProducao(config, true, hojeSaoPaulo());
    if (pendenciasProducao.length > 0) {
      logFiscal("emissao_producao_bloqueada", { empresaId, documentoFiscalId, pendencias: pendenciasProducao.length });
      return responder(
        {
          error: `Emissão em PRODUÇÃO bloqueada: ${pendenciasProducao.join(" ")}`,
          codigo: "pendencias_producao",
          pendencias: pendenciasProducao,
        },
        422
      );
    }
  }

  // ---------------------------------------------------------
  // Trava atômica: só avança se conseguir passar o status para "processando" partindo de
  // "nao_emitida" ou "rejeitada". Impede duas requisições simultâneas emitirem o mesmo documento.
  // ---------------------------------------------------------
  const { data: travado, error: travaError } = await admin
    .from("documentos_fiscais")
    .update({ status: "processando", atualizado_em: new Date().toISOString() })
    .eq("id", documentoFiscalId)
    .eq("empresa_id", empresaId)
    .in("status", ["nao_emitida", "rejeitada"])
    .select()
    .maybeSingle();

  if (travaError) {
    logFiscal("erro_travar_documento", { empresaId, documentoFiscalId, codigo: travaError.code });
    return responder({ error: "Erro interno ao iniciar a emissão." }, 500);
  }

  if (!travado) {
    const { data: atual } = await admin
      .from("documentos_fiscais")
      .select("status, numero, serie, chave_acesso, protocolo, retorno_provedor, atualizado_em")
      .eq("id", documentoFiscalId)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (atual?.status === "processando") {
      // P1: "processando" com tentativa enviando/desconhecida/denegada NÃO é "aguarde": a nota pode já ter
      // sido autorizada (ou denegada). Orienta a consulta e mantém a reemissão bloqueada.
      const t = tentativaDe(atual.retorno_provedor);
      const situacao = String(t.situacao ?? "");
      if (t.modo === "contingencia") {   // Migration 041: este documento está em contingência offline; a emissão normal não o toca
        return responder({
          status: "contingencia_ativa", codigo: "documento_em_contingencia", numero: atual.numero ?? null, serie: atual.serie ?? null,
          mensagem: "Esta NFC-e está em contingência offline (tpEmis=9) e segue o fluxo de Fiscal > Notas em contingência. Ela não pode ser emitida pelo caminho normal.",
        });
      }
      const idadeMs = atual.atualizado_em ? Date.now() - new Date(atual.atualizado_em as string).getTime() : 0;
      if (SITUACOES_BLOQUEADAS.has(situacao)) {
        return responder({
          status: "situacao_desconhecida",
          categoria: situacao === "denegada" ? "denegacao" : (t.categoria ?? null),
          codigo: "situacao_desconhecida_bloqueada",
          numero: atual.numero ?? null,
          serie: atual.serie ?? null,
          mensagem: mensagemSituacaoDesconhecida(atual.numero ?? null, atual.serie ?? null, situacao === "denegada" ? "denegacao" : (t.categoria as string | undefined) ?? null, (t.c_stat as string | undefined) ?? null),
        });
      }
      if (situacao === "em_curso" && idadeMs > LIMITE_EM_CURSO_MS) {
        // Interrompida ANTES de gravar "enviando": nenhuma requisição saiu. Só o suporte libera (não é automático).
        return responder({
          status: "situacao_desconhecida",
          codigo: "interrompida_antes_do_envio",
          numero: atual.numero ?? null,
          serie: atual.serie ?? null,
          mensagem: `A emissão da NFC-e nº ${atual.numero ?? "?"} foi interrompida antes do envio à Dados Jah (nenhuma requisição foi enviada). Peça ao suporte do Florest ERP para liberar o documento; não crie outra nota para esta venda.`,
        });
      }
    }
    if (atual?.status === "autorizada") {
      return responder({
        status: "autorizada",
        jaAutorizada: true,
        numero: atual.numero,
        chaveAcesso: atual.chave_acesso,
        protocolo: atual.protocolo,
      });
    }
    return responder({ error: "Esta emissão já está em processamento. Aguarde." }, 409);
  }

  // ---------------------------------------------------------------------
  // A partir daqui o documento está travado em "processando". Qualquer exceção não prevista a
  // partir deste ponto é capturada e reverte o documento para "rejeitada" (nunca fica preso).
  // ---------------------------------------------------------------------
  // P1: fase da tentativa. Exceção ANTES do envio => a Dados Jah nunca recebeu nada (rejeitada, sem
  // risco); exceção a partir do envio => situação desconhecida. "tentativa" guarda nNF/série/cNF já
  // persistidos no documento.
  let fase: "pre_envio" | "envio" = "pre_envio";
  let tentativa: { numero: string; serie: string; cNF: string } | null = null;
  try {
    const vendaId = travado.venda_id as string;

    // Itens de mercadoria (só tipo_fiscal = 'produto' entram na NFC-e; serviço fica para NFS-e,
    // fora do escopo desta etapa). Verificado ANTES de reservar o número fiscal — diferente da
    // referência do PetGestor, que reservava o número antes de checar isto e desperdiçava uma
    // numeração sempre que a venda não tinha item de mercadoria.
    const { data: itens, error: itensError } = await admin
      .from("itens_venda")
      .select("quantidade, preco_unitario, subtotal, produtos ( nome, codigo, gtin, ncm, cest, cfop, unidade_comercial, origem_mercadoria, cst_csosn, cst_pis, cst_cofins, tipo_fiscal )")
      .eq("venda_id", vendaId)
      .eq("empresa_id", empresaId);

    if (itensError) {
      await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Erro ao ler os itens da venda.");
      return responder({ error: "Não foi possível concluir a emissão. Tente novamente." }, 500);
    }

    const itensProduto = (itens ?? []).filter((i: any) => (i.produtos?.tipo_fiscal ?? "produto") === "produto");
    if (itensProduto.length === 0) {
      // Não é uma falha: a venda não tem mercadoria a declarar (só serviço, por exemplo). Volta
      // para "nao_emitida" (não "rejeitada") para não sugerir um erro que não houve.
      await admin
        .from("documentos_fiscais")
        .update({ status: "nao_emitida", mensagem_rejeicao: null, atualizado_em: new Date().toISOString() })
        .eq("id", documentoFiscalId)
        .eq("empresa_id", empresaId);
      return responder({ error: "Esta venda não possui itens de mercadoria para gerar NFC-e." }, 422);
    }

    // ---------------------------------------------------------------------
    // VALIDAÇÃO FISCAL PRÉVIA (pré-voo) — antes de reservar numeração ou chamar a Dados Jah.
    // Bloqueia aqui exatamente os campos que a montagem do "det"/"imposto" logo abaixo realmente
    // usa: NCM e CFOP (sempre, sem fallback) e cst_csosn (sem ele, imposto.ICMS nem é montado —
    // ver "imposto.ICMS = ... if (p.cst_csosn)" mais abaixo). produtos.cst_csosn é a MESMA coluna
    // tanto para CRT 1/2 (Simples Nacional, vira CSOSN no payload) quanto para CRT 3 (Regime
    // Normal, vira CST) — por isso a checagem independe do config.crt: o que falta é o dado no
    // cadastro do produto, não a interpretação por regime. Nenhum valor é inventado para destravar
    // a emissão — só impede o envio e relata, produto a produto, o que está faltando.
    const CAMPOS_FISCAIS_OBRIGATORIOS: Array<{ campo: "ncm" | "cfop" | "cst_csosn"; rotulo: string }> = [
      { campo: "ncm", rotulo: "NCM" },
      { campo: "cfop", rotulo: "CFOP" },
      { campo: "cst_csosn", rotulo: "CSOSN" },
    ];
    const produtosPendentes: Array<{ nome: string; campos: string[] }> = [];
    for (const item of itensProduto as any[]) {
      const p = item.produtos ?? {};
      const camposFaltando = CAMPOS_FISCAIS_OBRIGATORIOS
        .filter(({ campo }) => !p[campo] || String(p[campo]).trim() === "")
        .map(({ rotulo }) => rotulo);
      if (camposFaltando.length > 0) {
        produtosPendentes.push({ nome: p.nome || "(produto sem nome)", campos: camposFaltando });
      }
    }
    if (produtosPendentes.length > 0) {
      const linhasProdutos = produtosPendentes.map((p) => `${p.nome} — ${p.campos.join(", ")}`);
      const mensagemUsuario = [
        "Não foi possível emitir a NFC-e.",
        "Existem produtos com dados fiscais pendentes:",
        ...linhasProdutos,
      ].join("\n");
      const motivoInterno =
        `Dados fiscais pendentes em ${produtosPendentes.length} produto(s): ` +
        produtosPendentes.map((p) => `${p.nome} (${p.campos.join(", ")})`).join("; ");
      await reverterParaRejeitada(admin, documentoFiscalId, empresaId, motivoInterno);
      return responder({ error: mensagemUsuario }, 422);
    }

    // Venda + cliente (para o bloco "dest" — omitido se não houver CPF, do cliente ou da própria
    // venda). Inclui "tipo": a REVISÃO FISCAL 2 abaixo (desconto/acréscimo/taxa de serviço e formas
    // de pagamento) só se aplica quando tipo='bar' — PDV/Pet continuam exatamente como antes.
    //
    // "cpf_nota" (Migration 025): CPF informado pelo operador no PDV no momento da venda, fixado na
    // própria venda — não depende do cadastro do cliente permanecer com aquele CPF depois. É isto
    // que corrige a Venda #26: lá, o cliente "Angelo" estava vinculado (cliente_id preenchido), mas
    // o "dest" sempre foi remontado a partir do CPF ATUAL em public.clientes (join em tempo de
    // emissão) — nunca de um valor gravado na venda — então um cadastro sem CPF (ou alterado depois)
    // gerava "consumidor não identificado" mesmo com cliente identificado na venda.
    const { data: venda, error: vendaError } = await admin
      .from("vendas")
      .select("id, numero_venda, cliente_id, forma_pagamento, total, tipo, cpf_nota, clientes ( nome, cpf, cep, logradouro, numero, bairro, cidade, uf )")
      .eq("id", vendaId)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (vendaError || !venda) {
      await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Venda associada ao documento fiscal não encontrada.");
      return responder({ error: "Não foi possível concluir a emissão. Tente novamente." }, 500);
    }
    const cliente = (venda as any).clientes as Record<string, unknown> | null;
    const vendaEhDoBar = (venda as any).tipo === "bar";

    // Valor bruto dos produtos (soma de itens_venda.subtotal desta venda). Para PDV/Pet este valor
    // SEMPRE bate com vendas.total (o núcleo não tem nenhum conceito de desconto/acréscimo/taxa de
    // serviço — public.vendas não tem essas colunas, e itens_venda.subtotal é uma coluna gerada só
    // de quantidade*preco_unitario), então nada muda para eles a partir daqui.
    const vProdTotal = itensProduto.reduce((soma: number, i: any) => soma + Number(i.subtotal), 0);

    // Valor total do documento (produtos), lido do próprio documento (fiscal_emitir_nota já gravou
    // a soma BRUTA dos itens de mercadoria em documentos_fiscais.valor — mesmo cálculo de
    // vProdTotal acima, feito de novo aqui a partir de itens_venda). Usado, sem nenhuma mudança,
    // para vendas que NÃO são do Bar — comportamento idêntico ao anterior a esta revisão.
    const { data: documentoAtual } = await admin
      .from("documentos_fiscais")
      .select("valor")
      .eq("id", documentoFiscalId)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    const valorDocumento = Number(documentoAtual?.valor ?? 0);

    // ---------------------------------------------------------
    // REVISÃO FISCAL 2 (Módulo Bar) — PONTO 1 (desconto/acréscimo/taxa de serviço) e PONTO 2
    // (formas de pagamento divididas). Ver nota completa no cabeçalho do arquivo. Resultado deste
    // bloco: vDescTotal/vOutroTotal (para total.ICMSTot), valorFiscalTotal (para total.ICMSTot.vNF
    // e para a soma de pag.detPag) e detPag (o array final de formas de pagamento do payload).
    // ---------------------------------------------------------
    let vDescTotal = 0;
    let vOutroTotal = 0;
    let valorFiscalTotal: number;
    // CORREÇÃO (Rejeição 391 — regra YA04-10): "card" é opcional (Object) e só vai no detPag
    // quando montarGrupoCard devolve algo (tPag 03/04/17) — dinheiro e as demais formas continuam
    // exatamente como antes, sem o campo.
    let detPag: Array<{ tPag: string; xPag: string; vPag: string; card?: { tpIntegra: string } }>;

    if (!vendaEhDoBar) {
      // PDV/Pet: mesmo cálculo/formato de antes desta revisão, só acrescentando "card" quando a
      // forma de pagamento exigir (ver montarGrupoCard em dadosjah.ts).
      if(gastronomiaFiscal){vDescTotal=gastronomiaFiscal.desconto;vOutroTotal=gastronomiaFiscal.outros;valorFiscalTotal=gastronomiaFiscal.total;}else{valorFiscalTotal = valorDocumento || vProdTotal;}

      // PDV MISTO (Migration 028): se a venda tem linhas em public.vendas_pagamentos (gravadas só
      // por public.registrar_venda_mista), elas são a fonte das formas de pagamento reais da
      // NFC-e. Sem NENHUMA linha (todas as vendas antigas, e as feitas direto por registrar_venda),
      // vale vendas.forma_pagamento exatamente como sempre foi (ramo "else" abaixo, inalterado).
      // Lido com o cliente admin e com empresa_id + venda_id explícitos (mesmo padrão do resto
      // desta função): quem emite fiscal pode ter só permissão fiscal, e uma falha de leitura NUNCA
      // cai silenciosamente no ramo antigo (uma venda mista sairia com forma errada) — vira erro.
      const { data: pagamentosPdv, error: pagamentosPdvError } = await admin
        .from("vendas_pagamentos")
        .select("ordem, forma_pagamento, valor")
        .eq("venda_id", vendaId)
        .eq("empresa_id", empresaId)
        .order("ordem", { ascending: true });
      if (pagamentosPdvError) {
        logFiscal("erro_ler_pagamentos_pdv", { empresaId, documentoFiscalId, vendaId, codigo: pagamentosPdvError.code });
        await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Erro ao ler os pagamentos da venda.");
        return responder({ error: "Não foi possível concluir a emissão. Tente novamente." }, 500);
      }

      if ((pagamentosPdv ?? []).length > 0) {
        // Soma por forma, em CENTAVOS inteiros (sem erro de ponto flutuante), preservando a ordem
        // da primeira aparição de cada forma. Duas linhas da mesma forma (ex.: dois Pix) viram um
        // único detPag com a soma — mesmo tratamento já dado às formas do Bar.
        const centavosPorForma = new Map<string, number>();
        let somaCentavos = 0;
        let linhaInvalida = false;
        for (const p of pagamentosPdv ?? []) {
          const forma = String((p as any).forma_pagamento ?? "").trim();
          const centavos = Math.round(Number((p as any).valor) * 100);
          if (!forma || !Number.isFinite(centavos) || centavos <= 0) {
            linhaInvalida = true;
            break;
          }
          centavosPorForma.set(forma, (centavosPorForma.get(forma) ?? 0) + centavos);
          somaCentavos += centavos;
        }

        // Validação em centavos (igualdade EXATA, sem tolerância) contra o valor fiscal da NFC-e
        // (o mesmo valorFiscalTotal que vai em total.ICMSTot.vNF). Se não bater, NÃO emite: a
        // verificação acontece antes de reservar a numeração fiscal e antes de qualquer chamada à
        // Dados Jah, então nenhum número é consumido e nenhuma nota sai.
        const fiscalCentavos = Math.round(valorFiscalTotal * 100);
        if (linhaInvalida || somaCentavos !== fiscalCentavos) {
          const emReais = (c: number) => (c / 100).toFixed(2).replace(".", ",");
          const mensagem = linhaInvalida
            ? "Não foi possível emitir a NFC-e: há uma forma de pagamento inválida registrada nesta venda. Nenhuma nota foi emitida."
            : `Não foi possível emitir a NFC-e: a soma das formas de pagamento (R$ ${emReais(somaCentavos)}) é diferente do valor da NFC-e (R$ ${emReais(fiscalCentavos)}). Nenhuma nota foi emitida.`;
          logFiscal("inconsistencia_pagamentos_pdv", {
            empresaId, documentoFiscalId, vendaId, linhaInvalida, somaCentavos, fiscalCentavos,
            formas: Array.from(centavosPorForma.keys()),
          });
          await reverterParaRejeitada(admin, documentoFiscalId, empresaId, mensagem);
          return responder({ error: mensagem }, 422);
        }

        // Mesma codigoFormaPagamento e mesmo montarGrupoCard do ramo antigo e do Bar — nenhum
        // código novo: Pix -> 17, Cartão de Débito -> 04, Cartão de Crédito -> 03, Dinheiro -> 01,
        // Outros -> 99 (xPag = o próprio nome da forma). card {tpIntegra:"2"} só em 03/04/17.
        detPag = Array.from(centavosPorForma.entries()).map(([forma, centavos]) => {
          const tPag = codigoFormaPagamento(forma);
          const linha: { tPag: string; xPag: string; vPag: string; card?: { tpIntegra: string } } = {
            tPag,
            xPag: forma,
            vPag: formatarValorMonetario(centavos / 100),
          };
          const card = montarGrupoCard(tPag);
          if (card) linha.card = card;
          return linha;
        });
      } else {
        // Venda SEM linhas em vendas_pagamentos (vendas antigas e vendas feitas por registrar_venda):
        // comportamento exatamente igual ao de antes da Migration 028.
        //
        // Única trava nova neste ramo: 'dividido' em vendas.forma_pagamento só pode existir com
        // detalhamento (Bar: bar_pagamentos_formas; PDV: vendas_pagamentos). Uma venda NÃO-Bar
        // marcada 'dividido' e SEM nenhuma linha em vendas_pagamentos é um estado inconsistente
        // (nunca criado pelo sistema) — emitir como forma única/"99" seria fiscalmente errado,
        // então a emissão é recusada. Nenhuma venda existente é afetada (confirmado no banco: o
        // valor 'dividido' só aparece em vendas do Bar).
        if (String((venda as any).forma_pagamento ?? "").trim() === "dividido") {
          logFiscal("inconsistencia_dividido_sem_pagamentos_pdv", { empresaId, documentoFiscalId, vendaId });
          const mensagem = "Esta venda está marcada como paga em mais de uma forma, mas não há pagamentos detalhados registrados. Emissão bloqueada por segurança.";
          await reverterParaRejeitada(admin, documentoFiscalId, empresaId, mensagem);
          return responder({ error: mensagem }, 422);
        }

        const tPagUnico = codigoFormaPagamento((venda as any).forma_pagamento || "");
        const linhaUnica: { tPag: string; xPag: string; vPag: string; card?: { tpIntegra: string } } = {
          tPag: tPagUnico,
          xPag: (venda as any).forma_pagamento || "",
          vPag: formatarValorMonetario(valorFiscalTotal),
        };
        const cardUnico = montarGrupoCard(tPagUnico);
        if (cardUnico) linhaUnica.card = cardUnico;
        detPag = [linhaUnica];
      }
    } else {
      // Bar: a fonte real dos ajustes e das formas de pagamento é bar_pagamentos/
      // bar_pagamentos_formas, filtrando SOMENTE pagamentos NÃO estornados desta venda —
      // pagamentos estornados nunca podem aparecer no documento fiscal (Ponto 2). Lido com o
      // cliente admin (mesmo padrão do resto desta função): bar_pagamentos/bar_pagamentos_formas
      // são SELECT-only por RLS condicionada a permissão do módulo bar, e quem emite fiscal pode
      // ter só permissão fiscal/pdv — usar RLS aqui daria falso-negativo (0 linhas) em vez de
      // refletir o estado real dos pagamentos.
      const { data: pagamentosAtivos, error: pagamentosAtivosError } = await admin
        .from("bar_pagamentos")
        .select("desconto, acrescimo, taxa_servico, total, bar_pagamentos_formas ( forma_pagamento, valor )")
        .eq("venda_id", vendaId)
        .eq("empresa_id", empresaId)
        .eq("estornado", false);

      if (pagamentosAtivosError) {
        await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Erro ao ler os pagamentos da comanda.");
        return responder({ error: "Não foi possível concluir a emissão. Tente novamente." }, 500);
      }

      const formasSoma = new Map<string, number>();
      let somaTotalPagamentosAtivos = 0;
      for (const p of pagamentosAtivos ?? []) {
        vDescTotal += Number((p as any).desconto ?? 0);
        vOutroTotal += Number((p as any).acrescimo ?? 0) + Number((p as any).taxa_servico ?? 0);
        somaTotalPagamentosAtivos += Number((p as any).total ?? 0);
        for (const f of (p as any).bar_pagamentos_formas ?? []) {
          const chave = String(f.forma_pagamento || "").trim();
          formasSoma.set(chave, (formasSoma.get(chave) ?? 0) + Number(f.valor ?? 0));
        }
      }
      // Os ajustes pertencem à comanda; o saldo oficial inclui pagamentos antigos e fracionados.
      try {
        const totais=conferirTotaisBar(barFiscal,vProdTotal,Number((venda as any).total),somaTotalPagamentosAtivos);
        vDescTotal=totais.desconto;vOutroTotal=totais.outros;valorFiscalTotal=totais.total;
      } catch(e) {
        const mensagem=e instanceof Error?e.message:"Totais da comanda inconsistentes.";
        await reverterParaRejeitada(admin,documentoFiscalId,empresaId,mensagem);
        return responder({error:mensagem},422);
      }

      // Garantia matemática (Ponto 1): TOTAL FISCAL = TOTAL COMERCIAL DA VENDA. Confere contra
      // vendas.total (fonte de verdade do total comercial, mantida por bar_comanda_pagar/
      // bar_pagamento_estornar) e contra a soma dos pagamentos ativos — se algo não reconciliar
      // (só possível por um bug em outro lugar; nunca esperado), a emissão é RECUSADA em vez de
      // sair com um total fiscal errado.
      const totalComercial = Number((venda as any).total ?? 0);
      if (
        Math.abs(valorFiscalTotal - totalComercial) > 0.01 ||
        Math.abs(valorFiscalTotal - somaTotalPagamentosAtivos) > 0.01
      ) {
        logFiscal("inconsistencia_total_fiscal_bar", {
          empresaId, documentoFiscalId, vendaId, vProdTotal, vDescTotal, vOutroTotal,
          valorFiscalTotal, totalComercial, somaTotalPagamentosAtivos,
        });
        await reverterParaRejeitada(
          admin, documentoFiscalId, empresaId,
          "Inconsistência entre o total da venda e os pagamentos registrados. Emissão bloqueada por segurança.",
        );
        return responder({ error: "Não foi possível concluir a emissão: inconsistência no total da venda. Contate o suporte." }, 500);
      }

      if (formasSoma.size === 0) {
        await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Nenhuma forma de pagamento ativa encontrada para esta comanda.");
        return responder({ error: "Não foi possível concluir a emissão: nenhum pagamento ativo encontrado para esta comanda." }, 422);
      }

      // Reaproveita a MESMA codigoFormaPagamento e o MESMO montarGrupoCard já usados por PDV/Pet
      // acima — nenhum segundo padrão fiscal exclusivo do Bar. Numa comanda dividida (ex.: metade
      // dinheiro, metade PIX), cada forma vira sua própria linha de detPag, e só a(s) linha(s)
      // cujo tPag exigir (03/04/17) ganha(m) "card" — dinheiro na mesma comanda continua sem.
      detPag = Array.from(formasSoma.entries()).map(([forma, valor]) => {
        const tPag = codigoFormaPagamento(forma);
        const linha: { tPag: string; xPag: string; vPag: string; card?: { tpIntegra: string } } = {
          tPag,
          xPag: forma,
          vPag: formatarValorMonetario(valor),
        };
        const card = montarGrupoCard(tPag);
        if (card) linha.card = card;
        return linha;
      });
    }

    // ---------------------------------------------------------
    // Token de USUÁRIO da empresa (nunca o de Sistema) — igual a fiscal-upload-certificado.
    // ---------------------------------------------------------
    const tokenUsuario = await obterTokenUsuario(admin, empresaId);
    if (!tokenUsuario) {
      await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Falha de autenticação com a Dados Jah.");
      return responder({ error: "Não foi possível autenticar a empresa na Dados Jah." }, 502);
    }

    // ---------------------------------------------------------
    // Numeração fiscal atômica (Migration 10) — chamada pelo cliente de RLS (supabaseUser), não
    // pelo admin: a permissão é a mesma checada por RLS/perm_alguma, não uma regra à parte.
    // ---------------------------------------------------------
    // P1: número + série + cNF são gravados NO DOCUMENTO, numa única transação, ANTES de chamar a
    // Dados Jah (Migration 036: public.fiscal_reservar_numero_documento). Se este documento já tem uma
    // tentativa em_curso/desconhecida no mesmo ambiente, a RPC devolve os MESMOS nNF/série/cNF (nenhum
    // número novo é consumido). Chamada com o cliente de RLS: a permissão fiscal/pdv é checada no banco.
    const serie = config.nfce_serie || "1";
    const cNFNovo = String(Math.floor(Math.random() * 99999999)).padStart(8, "0");
    const { data: reservaRows, error: numeroError } = await supabaseUser.rpc("fiscal_reservar_numero_documento", {
      p_documento_fiscal_id: documentoFiscalId,
      p_serie: serie,
      p_c_nf: cNFNovo,
      p_tp_amb: tpAmb,
    });
    const reserva = Array.isArray(reservaRows) ? reservaRows[0] : reservaRows;
    if (numeroError && String(numeroError.message ?? "").includes("FISCAL_TENTATIVA_PENDENTE")) {
      // O banco recusou: este documento tem tentativa enviando/desconhecida/denegada sem confirmação de
      // consulta. NÃO reverte para "rejeitada" (reabriria a venda para um documento novo): fica bloqueado.
      logFiscal("reserva_recusada_tentativa_pendente", { empresaId, documentoFiscalId });
      return responder({
        status: "situacao_desconhecida",
        codigo: "tentativa_pendente_de_consulta",
        numero: (travado as { numero?: string | null }).numero ?? null,
        serie: (travado as { serie?: string | null }).serie ?? null,
        mensagem: mensagemSituacaoDesconhecida((travado as { numero?: string | null }).numero ?? null, (travado as { serie?: string | null }).serie ?? null),
      });
    }
    // CONTINGÊNCIA OFFLINE (Migration 041): se há contingência ATIVA no ambiente, ou o documento já está em contingência, o banco
    // recusa a emissão NORMAL. Isto NÃO é falha da nota: nada foi enviado e nenhum número foi consumido. O documento volta a
    // "nao_emitida" (nunca "rejeitada") e o usuário é orientado a usar Fiscal > Notas em contingência. Só este desvio foi acrescentado.
    const msgReservaCtg = String(numeroError?.message ?? "");
    if (numeroError && (msgReservaCtg.includes("FISCAL_CONTINGENCIA_ATIVA") || msgReservaCtg.includes("FISCAL_DOC_EM_CONTINGENCIA"))) {
      logFiscal("emissao_normal_suspensa_contingencia", { empresaId, documentoFiscalId });
      if (!msgReservaCtg.includes("FISCAL_DOC_EM_CONTINGENCIA")) {   // documento que JÁ está em contingência nunca é mexido aqui
        try {
          await admin.from("documentos_fiscais")
            .update({ status: "nao_emitida", atualizado_em: new Date().toISOString() })
            .eq("id", documentoFiscalId).eq("empresa_id", empresaId).eq("status", "processando");
        } catch { /* o documento fica "processando" sem número: o suporte fiscal libera; nada foi enviado */ }
      }
      return responder({
        status: "contingencia_ativa",
        codigo: msgReservaCtg.includes("FISCAL_DOC_EM_CONTINGENCIA") ? "documento_em_contingencia" : "contingencia_ativa",
        mensagem: msgReservaCtg.includes("FISCAL_DOC_EM_CONTINGENCIA")
          ? "Esta NFC-e está em contingência offline e não pode ser emitida pelo caminho normal. Use Fiscal > Notas em contingência."
          : "Há contingência offline de NFC-e ATIVA: a emissão normal está suspensa. Nada foi enviado à SEFAZ e nenhum número foi consumido. Emita em contingência pelo PDV ou peça a um usuário do módulo Fiscal para encerrar a contingência (Fiscal > Notas em contingência).",
      });
    }
    if (numeroError || !reserva || reserva.o_numero === null || reserva.o_numero === undefined || !reserva.o_c_nf) {
      logFiscal("erro_reservar_numero_documento", { empresaId, documentoFiscalId, codigo: numeroError?.code ?? null });
      await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Erro ao gerar numeração fiscal.");
      return responder({ error: "Erro ao gerar o número fiscal." }, 500);
    }
    const proximoNumero = String(reserva.o_numero);
    const serieEmitida = String(reserva.o_serie ?? serie);
    const cNF = String(reserva.o_c_nf);
    tentativa = { numero: proximoNumero, serie: serieEmitida, cNF };
    if (reserva.o_reaproveitado) {
      logFiscal("tentativa_emissao_reaproveitada", { empresaId, documentoFiscalId, numero: proximoNumero, serie: serieEmitida });
    }

    // ---------------------------------------------------------
    // Payload da NFC-e (inclui infNF.emit — ver comentário mais abaixo, logo
    // antes da montagem de infNF).
    // ---------------------------------------------------------
    const ajustesBar=barFiscal?ratearAjustesBar(itensProduto,vDescTotal,vOutroTotal):null;
    const det = itensProduto.map((item: any, index: number) => {
      const p = item.produtos;
      const qtd = Number(item.quantidade);
      const prod: Record<string, unknown> = {
        cProd: p.codigo || p.nome,
        cEAN: p.gtin || "SEM GTIN",
        xProd: p.nome,
        NCM: p.ncm,
        CFOP: p.cfop,
        uCom: p.unidade_comercial || "UN",
        qCom: qtd.toFixed(4),
        vUnCom: Number(item.preco_unitario).toFixed(2),
        vProd: Number(item.subtotal).toFixed(2),
        cEANTrib: p.gtin || "SEM GTIN",
        uTrib: p.unidade_comercial || "UN",
        qTrib: qtd.toFixed(4),
        vUnTrib: Number(item.preco_unitario).toFixed(2),
        indTot: "1",
      };
      if(ajustesBar){
        if(ajustesBar[index].desconto)prod.vDesc=formatarValorMonetario(ajustesBar[index].desconto);
        if(ajustesBar[index].outros)prod.vOutro=formatarValorMonetario(ajustesBar[index].outros);
      }
      if (p.cest) prod.CEST = p.cest;

      const imposto: Record<string, unknown> = {};
      if (p.cst_csosn) {
        // configuracoes_fiscais.crt é texto ("1"/"2"/"3", só essas 3 opções no front — Etapa 9).
        // CRT 1 (Simples Nacional) e 2 (Simples Nacional c/ excesso de sublimite) usam CSOSN;
        // CRT 3 (Regime Normal) usa CST. produtos.cst_csosn guarda o código correspondente ao
        // regime da empresa — antes ia sempre como "CST", mesmo para Simples Nacional (causa do
        // erro "ID:N12a/CSOSN - Nenhum valor informado" da Dados Jah).
        imposto.ICMS = (config.crt === "1" || config.crt === "2")
          ? { orig: p.origem_mercadoria || "0", CSOSN: p.cst_csosn }
          : { orig: p.origem_mercadoria || "0", CST: p.cst_csosn };
      }
      if (p.cst_pis) imposto.PIS = { CST: p.cst_pis };
      if (p.cst_cofins) imposto.COFINS = { CST: p.cst_cofins };

      return { nItem: String(index + 1), prod, imposto };
    });

    // Montagem do "dest" (Migration 025 — "CPF na nota" no PDV):
    //   1) venda.cpf_nota (fixado no momento da venda) tem PRIORIDADE sobre o CPF atual do cadastro
    //      do cliente. Se houver cliente selecionado na venda, mantém nome/endereço do cadastro dele
    //      (apenas o CNPJCPF vem de cpf_nota). Se NÃO houver cliente selecionado, identifica somente
    //      pelo CPF — SEM inventar xNome (ver diagnostico_cpf_na_nota_pdv.md: xNome é opcional no
    //      leiaute NFe/NFCe 4.00 e no dicionário de dados da NFC-e quando o destinatário é
    //      identificado só por CPF/indIEDest; decisão do usuário foi validar isso empiricamente em
    //      homologação, TP_AMB=2, em vez de inventar um nome placeholder).
    //   2) Sem cpf_nota na venda: comportamento ANTERIOR à Migration 025, inalterado — usa o CPF
    //      atual de public.clientes via join (cliente?.cpf).
    //   3) Sem nenhum CPF (nem cpf_nota, nem cliente.cpf): dest fica undefined — "consumidor não
    //      identificado", exatamente como antes. Esta é a causa raiz da Venda #26: o "dest" sempre
    //      foi remontado a partir do CPF ATUAL do cliente (join em tempo de emissão), nunca de um
    //      valor gravado na própria venda — um cadastro sem CPF (ou alterado depois da venda) gerava
    //      "consumidor não identificado" mesmo com cliente_id preenchido.
    let dest: Record<string, unknown> | undefined;
    const cpfNotaDigits = (venda as any).cpf_nota ? somenteDigitos((venda as any).cpf_nota) : "";
    if (cpfNotaDigits) {
      if (cliente?.nome) {
        dest = { CNPJCPF: cpfNotaDigits, xNome: cliente.nome, indIEDest: "9" };
        if (cliente.logradouro) {
          dest.enderDest = {
            xLgr: cliente.logradouro,
            nro: cliente.numero || "S/N",
            xBairro: cliente.bairro || "",
            cMun: config.codigo_ibge,
            xMun: cliente.cidade || config.municipio,
            UF: cliente.uf || config.uf,
            CEP: somenteDigitos(cliente.cep) || undefined,
            cPais: "1058",
            xPais: "BRASIL",
          };
        }
      } else {
        // Nenhum cliente selecionado na venda: identifica somente pelo CPF informado no PDV.
        dest = { CNPJCPF: cpfNotaDigits, indIEDest: "9" };
      }
    } else if (cliente?.cpf) {
      const cpfDigits = somenteDigitos(cliente.cpf);
      dest = { CNPJCPF: cpfDigits, xNome: cliente.nome, indIEDest: "9" };
      if (cliente.logradouro) {
        dest.enderDest = {
          xLgr: cliente.logradouro,
          nro: cliente.numero || "S/N",
          xBairro: cliente.bairro || "",
          cMun: config.codigo_ibge,
          xMun: cliente.cidade || config.municipio,
          UF: cliente.uf || config.uf,
          CEP: somenteDigitos(cliente.cep) || undefined,
          cPais: "1058",
          xPais: "BRASIL",
        };
      }
    }

    const ufFiscal = String(config.uf ?? "").trim().toUpperCase();
    const cUF = CODIGO_UF[ufFiscal];
    if (!cUF) {
      await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "UF do emitente inválida. Nenhum documento foi enviado.");
      return responder({ error: "UF do emitente inválida. Confira o cadastro fiscal antes de emitir." }, 400);
    }

    // ---------------------------------------------------------
    // ÚNICA correção desta entrega: infNF.emit, com os dados ATUAIS de
    // configuracoes_fiscais — mesmas colunas já usadas no restante do
    // arquivo (config.codigo_ibge/municipio/uf logo abaixo) e no mesmo
    // padrão do bloco "emit" já usado em fiscal-configurar-emitente
    // (POST /emit). O diagnóstico já confirmou emit: null neste payload
    // e configuracoes_fiscais com CNPJ/IE/CRT corretos — daí a rejeição
    // "IE do emitente não cadastrada".
    // ---------------------------------------------------------
    const enderEmit: Record<string, unknown> = {
      xLgr: config.endereco,
      nro: config.numero,
      xBairro: config.bairro,
      cMun: config.codigo_ibge,
      xMun: config.municipio,
      UF: ufFiscal,
      CEP: somenteDigitos(config.cep),
      cPais: "1058",
      xPais: "BRASIL",
    };
    if (config.telefone) enderEmit.fone = somenteDigitos(config.telefone);

    // Anti-duplicidade (Migration 37): o dhEmi é gerado UMA vez, usado no payload e gravado no documento antes do
    // envio, junto com a chave de acesso PREVISTA (cálculo do ERP). Se a Dados Jah mudar algum desses campos antes de
    // transmitir, a chave real será outra: ao receber a autorização o ERP compara (chave_prevista_confere).
    const dhEmiEnvio = agoraISOComOffsetBrasilia();
    // Teste de contingência: dhCont fica 60 s antes do dhEmi (SEFAZ exige dhCont <= dhEmi).
    let dhContTeste = "";
    if (pedidoTesteCtg) {
      try { dhContTeste = dhContParaTeste(dhEmiEnvio); }
      catch {
        await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Teste de contingência abortado antes do envio (horário inválido). Nada foi enviado.");
        return responder({ status: "teste_contingencia_abortado", codigo: "dhcont_invalido", mensagem: "Teste abortado antes do envio: não foi possível calcular dhCont. Nada foi enviado." }, 500);
      }
    }
    let chavePrevista: string | null = null;
    try {
      chavePrevista = montarChave({
        cUF, dhEmi: dhEmiEnvio, cnpj: somenteDigitos(config.cnpj), mod: "65", serie: serieEmitida, nNF: proximoNumero, tpEmis: pedidoTesteCtg ? "9" : "1", cNF,
      });
    } catch (e) {
      chavePrevista = null;
      logFiscal("chave_prevista_nao_calculada", { empresaId, documentoFiscalId, motivo: e instanceof Error ? e.message : "desconhecido" });
    }

    const infNF: Record<string, unknown> = {
      versao: "4.00",
      emit: {
        CNPJCPF: somenteDigitos(config.cnpj),
        xNome: config.razao_social,
        xFant: config.nome_fantasia || config.razao_social,
        IE: config.inscricao_estadual,
        CRT: config.crt,
        enderEmit,
      },
      ide: {
        cUF,
        cNF,
        natOp: "Venda ao consumidor",
        serie: serieEmitida,
        nNF: proximoNumero,
        dhEmi: dhEmiEnvio,
        tpNF: "1",
        idDest: "1",
        cMunFG: config.codigo_ibge,
        tpImp: "4",
        tpEmis: pedidoTesteCtg ? "9" : "1",
        // Teste de homologação da contingência (Migration 42): dhCont/xJust só existem quando tpEmis=9.
        ...(pedidoTesteCtg ? { dhCont: dhContTeste, xJust: XJUST_TESTE_CTG } : {}),
        tpAmb,
        finNFe: "1",
        indFinal: "1",
        indPres: "1",
        procEmi: "0",
        verProc: "Florest ERP 1.0",
      },
      det,
      total: {
        ICMSTot: {
          vBC: "0.00",
          vICMS: "0.00",
          vICMSDeson: "0.00",
          vFCP: "0.00",
          vBCST: "0.00",
          vFCPST: "0.00",
          vFCPSTRet: "0.00",
          vProd: formatarValorMonetario(vProdTotal),
          vFrete: "0.00",
          vSeg: "0.00",
          vDesc: formatarValorMonetario(vDescTotal),
          vII: "0.00",
          vIPI: "0.00",
          vIPIDevol: "0.00",
          vPIS: "0.00",
          vCOFINS: "0.00",
          vOutro: formatarValorMonetario(vOutroTotal),
          vNF: formatarValorMonetario(valorFiscalTotal),
        },
      },
      // CORREÇÃO (Rejeição 753 — NT X02-10): faltava o grupo transp/modFrete no payload (nenhuma
      // versão anterior deste arquivo o enviava — nem esta integração, nem a referência do
      // PetGestor). Pela regra X02-10, para tpImp=6 (DANFE Simplificado Tipo 2) a SEFAZ exige
      // modFrete=9 OU indPres=4; como esta é uma venda presencial de balcão sem frete/entrega
      // (indPres continua "1", de propósito — não é alterado para 4), o correto é declarar
      // modFrete=9 ("Sem Ocorrência de Transporte"). Nomeado "transp"/"modFrete" seguindo a MESMA
      // convenção já usada em 100% dos outros grupos deste payload (ide, det/prod/imposto, total/
      // ICMSTot, pag/detPag, infRespTec, dest/enderDest): o nome do campo JSON é sempre idêntico
      // ao nome da tag do leiaute 4.00 da NFe/NFC-e. Nenhum dado de transportador, veículo,
      // reboque, vagão, balsa ou retenção de ICMS de transporte é enviado — para modFrete=9 esse
      // sub-grupo não existe no leiaute e não deve ser preenchido com dado fictício.
      transp: {
        modFrete: "9",
      },
      pag: {
        detPag,
      },
      infRespTec: {
        CNPJ: somenteDigitos(respTecCnpj),
        xContato: respTecContato,
        email: respTecEmail,
        fone: somenteDigitos(respTecFone),
      },
    };
    if (dest) infNF.dest = dest;

    const payload = { async: false, NFCe: [{ idExternal: documentoFiscalId, infNF }] };

    // TESTE de contingência: confere o payload ANTES de qualquer envio (tpEmis=9, dhCont, xJust, chave prevista com tpEmis=9).
    // Se algo faltar, aborta sem enviar; o número reservado fica no marcador "em_curso" e é reaproveitado na próxima tentativa.
    if (pedidoTesteCtg) {
      const problemas = validarIdeTesteCtg(infNF.ide as Record<string, unknown>);
      if (!chavePrevista) problemas.push("chave_prevista_nao_calculada");
      else if (chavePrevista.slice(34, 35) !== "9") problemas.push("chave_prevista_sem_tpEmis_9");
      anexoTesteCtg = anexoPreliminarTesteCtg({ ide: infNF.ide as Record<string, unknown>, chavePrevista });
      if (problemas.length > 0) {
        logFiscal("teste_ctg_payload_invalido", { empresaId, documentoFiscalId, problemas });
        await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Teste de contingência abortado antes do envio: payload inválido. Nada foi enviado.");
        return responder({ status: "teste_contingencia_abortado", codigo: "payload_invalido", mensagem: "Teste abortado ANTES do envio: o payload não tem tpEmis=9, dhCont e xJust válidos. Nada foi enviado.", problemas }, 422);
      }
    }

    // Migration 44: preserva a REQUISIÇÃO ORIGINAL (o que será enviado) para uma eventual retransmissão da MESMA nota em contingência.
    // Best-effort: se o banco não aceitar (ou a Migration 44 não estiver aplicada), a emissão normal segue exatamente como antes.
    if (!pedidoTesteCtg) {
      try {
        const { error: erroReq } = await admin.rpc("fiscal_requisicao_original_salvar", {
          p_empresa_id: empresaId, p_documento_fiscal_id: documentoFiscalId, p_numero: Number(proximoNumero), p_serie: String(serieEmitida),
          p_tp_amb: String(tpAmb), p_chave_prevista: chavePrevista, p_requisicao: payload,
        });
        if (erroReq) logFiscal("requisicao_original_nao_salva", { empresaId, documentoFiscalId, codigo: erroReq.code ?? null });
      } catch (e) {
        logFiscal("requisicao_original_nao_salva", { empresaId, documentoFiscalId, erro: e instanceof Error ? e.name : "desconhecido" });
      }
    }

    // ---------------------------------------------------------
    // DIAGNÓSTICO TEMPORÁRIO (investigação da rejeição "IE do emitente não
    // cadastrada", mesmo com GET /emit confirmando CNPJCPF/IE/CRT corretos no
    // emitente já registrado na Dados Jah). Mostra o payload fiscal
    // EFETIVAMENTE enviado nesta chamada — nunca token/senha/accessToken/
    // segredos/certificado.
    // Nota: infNF.emit é omitido por desenho neste payload (o emitente já foi
    // pré-cadastrado via fiscal-configurar-emitente — ver comentário no topo
    // do arquivo), por isso "emit" abaixo tende a aparecer null; os campos
    // CNPJCPF/IE/CRT logo abaixo vêm de configuracoes_fiscais (o que foi
    // usado para registrar o emitente), não do corpo desta chamada.
    // ---------------------------------------------------------
    logFiscal("diagnostico_payload_nfce", {
      empresaId,
      documentoFiscalId,
      emit: (infNF as Record<string, unknown>).emit ?? null,
      emitente_configurado: {
        CNPJCPF: somenteDigitos(config.cnpj),
        IE: config.inscricao_estadual ?? null,
        CRT: config.crt ?? null,
      },
      ide: infNF.ide,
      transp: infNF.transp,
      pag: infNF.pag,
      det,
    });

    // ---------------------------------------------------------
    // Transmissão (timeout de 60s).
    // ---------------------------------------------------------
    // P1: ANTES de qualquer byte sair, grava no documento que o envio vai começar ("enviando"). Se a gravação
    // não for CONFIRMADA, a Edge NÃO envia (nada saiu: o documento volta a rejeitada/em_curso e a próxima
    // tentativa reaproveita o mesmo número). Se o marcador chegou a ser gravado e só a confirmação se perdeu,
    // o trigger do banco impede o retorno a "rejeitada" e o documento fica bloqueado — lado seguro.
    if (!(await marcarEnvioIniciado(admin, documentoFiscalId, empresaId, { dhEmi: dhEmiEnvio, chavePrevista, idExternal: documentoFiscalId, ...(pedidoTesteCtg ? { modo: MODO_ENVIO_TESTE_CTG, extra: { tpEmis: "9", dhCont: dhContTeste, xJust: XJUST_TESTE_CTG } } : {}) }))) {
      logFiscal("falha_marcar_envio_iniciado", { empresaId, documentoFiscalId });
      await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Não foi possível registrar o início do envio. Nada foi enviado à Dados Jah.");
      return responder({ error: "Não foi possível iniciar o envio da NFC-e. Nada foi enviado. Tente novamente." }, 500);
    }

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 60_000);

    // A partir daqui a requisição PODE chegar à Dados Jah/SEFAZ: qualquer falha sem resposta
    // conclusiva é "situação desconhecida", nunca rejeição.
    fase = "envio";
    let respostaFetch: Response;
    try {
      respostaFetch = await fetch(`${DADOSJAH_BASE_URL}/nfce?tpDanfe=Cupom`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", Authorization: `Bearer ${tokenUsuario}` },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
    } catch (fetchErr) {
      clearTimeout(timeoutId);
      const desfecho = classificarFalhaTransporte(fetchErr);
      return responder(await registrarSituacaoDesconhecida(admin, documentoFiscalId, empresaId, desfecho, proximoNumero, serieEmitida));
    }
    clearTimeout(timeoutId);

    // deno-lint-ignore no-explicit-any
    let itemResposta: any = null;
    let desfecho: DesfechoEmissao;
    let corpoErroTeste: string | null = null;

    if (!respostaFetch.ok) {
      const corpoErro = await respostaFetch.text().catch(() => "");
      if (pedidoTesteCtg) corpoErroTeste = sanitizarCorpoDiagnostico(corpoErro, [tokenUsuario]);
      logFiscal("falha_emitir_nfce", {
        empresaId,
        documentoFiscalId,
        status: respostaFetch.status,
        corpo: sanitizarCorpoDiagnostico(corpoErro, [tokenUsuario]),
      });
      // Sem cStat estruturado da SEFAZ no corpo, QUALQUER falha HTTP é "desconhecida" (não há garantia
      // documentada de que a Dados Jah não transmitiu). Com cStat estruturado, o cStat decide.
      desfecho = classificarFalhaHttp(respostaFetch.status, corpoErro, [tokenUsuario]);
      if (desfecho.cStat !== null) {
        try { const j = JSON.parse(corpoErro); itemResposta = j?.data?.NFCe?.[0] ?? j?.NFCe?.[0] ?? null; } catch { itemResposta = null; }
      }
    } else {
      const respostaJson = await respostaFetch.json().catch(() => null);
      itemResposta = respostaJson?.data?.NFCe?.[0] ?? null;
      desfecho = classificarRetornoDadosJah(itemResposta);
    }

    if (pedidoTesteCtg) {
      // Migration 42: diagnóstico do teste (nunca token/XML). Anexado a todas as respostas seguintes e registrado como evento.
      anexoTesteCtg = diagnosticarRespostaTesteCtg({
        httpStatus: respostaFetch.status, item: itemResposta, chavePrevista, xJustEnviado: XJUST_TESTE_CTG, classificacaoErp: desfecho.classe,
        ide: infNF.ide as Record<string, unknown>, corpoErro: corpoErroTeste,
      }) as unknown as Record<string, unknown>;
      try {
        await admin.from("documentos_fiscais_eventos").insert({
          documento_fiscal_id: documentoFiscalId, empresa_id: empresaId, tipo_evento: "teste_contingencia_homologacao", status: "processando",
          c_stat: (anexoTesteCtg.cStat as string | null) ?? null, mensagem: "Teste de homologação da contingência (tpEmis=9): diagnóstico da resposta da API.", payload: anexoTesteCtg,
        });
      } catch { /* o diagnóstico também segue na resposta */ }
    }

    // Teste de contingência sem prova de autorização: preserva tpEmis/dhCont/xJust/chave/XML para consulta e transmissão posterior.
    if (pedidoTesteCtg && itemResposta && desfecho.classe !== "autorizada" && desfecho.classe !== "rejeitada") {
      await preservarDadosTesteCtg(admin, documentoFiscalId, empresaId, { ide: infNF.ide as Record<string, unknown>, item: itemResposta as Record<string, unknown>, chavePrevista });
    }

    // Só "autorizada" e "rejeitada" (cStat de rejeição CONFIRMADO) seguem para a gravação definitiva.
    // Todo o resto (desconhecida, denegada) fica BLOQUEADO em "processando" com a orientação de consulta.
    if (!itemResposta || (desfecho.classe !== "autorizada" && desfecho.classe !== "rejeitada")) {
      return responder(await registrarSituacaoDesconhecida(
        admin, documentoFiscalId, empresaId, desfecho, proximoNumero, serieEmitida,
        { idDfe: itemResposta?.idDfe ?? null, chDfe: itemResposta?.chDfe ?? null },
        pedidoTesteCtg ? undefined : async () => {
          const { data, error } = await supabaseUser.rpc("fiscal_contingencia_ativar_por_falha", { p_documento_fiscal_id: documentoFiscalId });
          if (error) {
            logFiscal("ctg_auto_nao_ativada", { empresaId, documentoFiscalId, codigo: error.code ?? null, regra: String(error.message ?? "").match(/FISCAL_[A-Z_]+/)?.[0] ?? null });
            return null;
          }
          const r = (data ?? {}) as Record<string, unknown>;
          if (r.resultado !== "contingencia") return null;
          return { ativada: true, ctg_documento_id: r.ctg_documento_id ?? null, contingencia_id: r.contingencia_id ?? null, status: r.status ?? null,
                   nNF: r.nNF ?? null, serie: r.serie ?? null, chave_acesso: r.chave_acesso ?? null,
                   aviso: "NFC-e em contingência: ainda NÃO autorizada. Será retransmitida automaticamente com o mesmo número." };
        },
      ));
    }

    // ---------------------------------------------------------
    // DIAGNÓSTICO TEMPORÁRIO: registra a resposta completa da Dados Jah para
    // o POST /nfce?tpDanfe=Cupom (payload já confirmado correto pelo log
    // diagnostico_payload_nfce), antes de interpretarRetornoFiscal — nunca
    // token/senha/accessToken/segredos/certificado (não há nada disso em
    // itemResposta).
    // ---------------------------------------------------------
    logFiscal("diagnostico_resposta_nfce", {
      empresaId,
      documentoFiscalId,
      statusHttp: respostaFetch.status,
      itemResposta,
      cStat: itemResposta.cStat ?? null,
      xMotivo: itemResposta.xMotivo ?? null,
      situation: itemResposta.situation ?? null,
      situationDfe: itemResposta.situationDfe ?? null,
      idDfe: itemResposta.idDfe ?? null,
      chDfe: itemResposta.chDfe ?? null,
      nProt: itemResposta.nProt ?? null,
    });

    if (itemResposta.tpAmb !== undefined && itemResposta.tpAmb !== null && String(itemResposta.tpAmb) !== tpAmb) {
      // A Dados Jah devolveu um ambiente diferente do pedido: grava o que ela devolveu (a verdade do
      // documento) e deixa o rastro no log.
      logFiscal("divergencia_ambiente_emissao", { empresaId, documentoFiscalId, pedido: tpAmb, retornado: String(itemResposta.tpAmb) });
    }
    const resultado = interpretarRetornoFiscal(itemResposta);

    // P1: o desfecho é conclusivo (autorizada ou rejeitada pela SEFAZ) — marca a tentativa como
    // finalizada na MESMA gravação do resultado (uma nova tentativa, se houver, usará novo número).
    // chave_prevista_confere: true/false só quando há chave prevista E chave devolvida; senão null. É a evidência
    // que permitirá (um dia) ligar fiscal_parametros_consulta.chave_prevista_validada. Nunca altera o resultado.
    const chaveDevolvida = typeof itemResposta.chDfe === "string" ? itemResposta.chDfe.replace(/\D/g, "") : null;
    const chavePrevistaConfere = chavePrevista && chaveDevolvida ? chavePrevista === chaveDevolvida : null;
    if (chavePrevistaConfere === false) {
      logFiscal("chave_prevista_divergente", { empresaId, documentoFiscalId, numero: proximoNumero, serie: serieEmitida });
    }
    const retornoProvedorFinal = await mesclarTentativa(admin, documentoFiscalId, empresaId, {
      situacao: "finalizada",
      desfecho_codigo: desfecho.codigo,
      c_stat: resultado.cStat,
      finalizada_em: new Date().toISOString(),
      chave_prevista_confere: chavePrevistaConfere,
    });

    const { error: updateFinalError } = await admin
      .from("documentos_fiscais")
      .update({
        status: resultado.status,
        // REVISÃO FISCAL 2 (Ponto 1): grava aqui o total FISCAL correto (valorFiscalTotal — já
        // net de desconto/acréscimo/taxa de serviço para o Bar; idêntico ao valor bruto de antes
        // para PDV/Pet). documentos_fiscais.valor tinha ficado com o valor BRUTO gravado por
        // fiscal_emitir_nota (núcleo, não alterado) — sem esta atualização, a lista de documentos
        // do index.html (renderDocumentosDaVenda, que exibe doc.valor) continuaria mostrando o
        // valor bruto mesmo depois de uma emissão correta, mesmo com a NFC-e real já saindo certa.
        valor: valorFiscalTotal,
        ...(retornoProvedorFinal ? { retorno_provedor: retornoProvedorFinal } : {}),
        id_dfe: itemResposta.idDfe ?? null,
        tp_ambiente: itemResposta.tpAmb ?? tpAmb,
        numero: itemResposta.nNF ?? proximoNumero,
        serie: itemResposta.serie ?? serieEmitida,
        chave_acesso: itemResposta.chDfe ?? null,
        protocolo: itemResposta.nProt ?? null,
        c_stat: resultado.cStat,
        mensagem_rejeicao: resultado.status === "rejeitada" ? resultado.xMotivo : null,
        dh_emissao: itemResposta.dhEmi ?? null,
        dh_recebimento: itemResposta.dhRecbto ?? null,
        situation: itemResposta.situation ?? null,
        situation_dfe: itemResposta.situationDfe ?? null,
        xml_conteudo: itemResposta.xml ?? null,
        pdf_conteudo: itemResposta.pdf ?? null,
        xml_url: itemResposta.xmlLink || null,
        pdf_url: itemResposta.pdfLink || null,
        atualizado_em: new Date().toISOString(),
      })
      .eq("id", documentoFiscalId)
      .eq("empresa_id", empresaId);

    if (updateFinalError) {
      logFiscal("falha_salvar_resultado_emissao", { empresaId, documentoFiscalId, codigo: updateFinalError.code });
      // A Dados Jah já processou a nota — não revertemos para "rejeitada" aqui (seria falso). P1: o
      // documento fica em "processando" com situação desconhecida (bloqueado para reemissão) e a
      // orientação de consulta; guardamos o que a Dados Jah informou (cStat/chave) para a consulta.
      return responder(await registrarSituacaoDesconhecida(
        admin, documentoFiscalId, empresaId,
        { classe: "desconhecida", categoria: "retorno_inesperado", codigo: "resultado_nao_salvo", cStat: resultado.cStat, xMotivo: resultado.xMotivo, httpStatus: respostaFetch.status, indicio: null, detalhe: "Resultado recebido da Dados Jah, mas não foi possível gravá-lo." },
        proximoNumero, serieEmitida,
        { idDfe: itemResposta.idDfe ?? null, chDfe: itemResposta.chDfe ?? null },
      ));
    }

    await admin.from("documentos_fiscais_eventos").insert({
      documento_fiscal_id: documentoFiscalId,
      empresa_id: empresaId,
      tipo_evento: TIPO_EVENTO,
      status: resultado.status,
      c_stat: resultado.cStat,
      mensagem: resultado.xMotivo,
    });

    return responder({
      status: resultado.status,
      cStat: resultado.cStat,
      xMotivo: resultado.xMotivo,
      numero: itemResposta.nNF ?? null,
      chaveAcesso: itemResposta.chDfe ?? null,
      temXml: !!(itemResposta.xml || itemResposta.xmlLink),
      temPdf: !!(itemResposta.pdf || itemResposta.pdfLink),
    });
  } catch (erroInterno) {
    logFiscal("excecao_apos_trava", { empresaId, documentoFiscalId, fase, erro: erroInterno instanceof Error ? erroInterno.name : "desconhecido" });
    if (fase === "envio") {
      // P1: a exceção ocorreu depois de a requisição poder ter chegado à Dados Jah — não sabemos o
      // desfecho. NÃO volta para "rejeitada": fica bloqueado com a orientação de consulta.
      return responder(await registrarSituacaoDesconhecida(
        admin, documentoFiscalId, empresaId,
        { classe: "desconhecida", categoria: "retorno_inesperado", codigo: "excecao_apos_envio", cStat: null, xMotivo: null, httpStatus: null, indicio: null, detalhe: "Exceção interna após o envio à Dados Jah." },
        tentativa?.numero ?? null, tentativa?.serie ?? null,
      ));
    }
    await reverterParaRejeitada(admin, documentoFiscalId, empresaId, "Erro interno inesperado durante a emissão.");
    return responder({ error: "Não foi possível concluir a emissão. Tente novamente ou verifique a configuração fiscal." }, 500);
  }
});

