// =====================================================================
// Florest ERP (DistGestor) — helper "dadosjah.ts" da Edge Function fiscal-emitir-documento
//
// IMPORTANTE (deploy): o Supabase não compartilha arquivos entre pastas de Edge Functions
// diferentes — este arquivo precisa existir, IDÊNTICO, dentro desta pasta (junto do index.ts).
// Ele é uma pasta própria, separada do dadosjah.ts usado por fiscal-configurar-emitente e
// fiscal-upload-certificado (que NÃO foi alterado por esta entrega).
//
// PROVENIÊNCIA (para revisão sua antes do deploy):
//   - As seções 1 e 2 abaixo (clientes Supabase, Vault, utilidades de CORS/log/formatação) são
//     CÓPIA das mesmas funções já corretas e implantadas em
//     florest_erp_senha/dadosjah.ts (usado por fiscal-configurar-emitente e
//     fiscal-upload-certificado) — nada foi inventado nelas, só trazidas as que esta função
//     realmente usa (sem gerarSenhaForte/limparSegredo/normalizarExtensaoCertificado/
//     criarSegredoVault, que só fazem sentido nas outras duas funções).
//   - A seção 3 (CODIGO_UF, agoraISOComOffsetBrasilia, codigoFormaPagamento,
//     formatarValorMonetario, interpretarRetornoFiscal) é CÓDIGO NOVO, escrito para esta
//     entrega. A referência do PetGestor (fiscal_emitir_documento_dashboard/index.ts) IMPORTA
//     estas mesmas funções de um "./dadosjah.ts" que documentamos na Etapa 7 como INEXISTENTE em
//     todo o workspace — só o index.ts que depende dele foi encontrado. Não havia, portanto,
//     nenhuma implementação real para copiar; cada uma é comentada abaixo com a fonte usada
//     (tabela padrão SEFAZ para UF, regras conhecidas de tPag, e a única evidência real que
//     tínhamos: os nomes de campo que o index.ts do PetGestor lê da resposta da Dados Jah).
//     REVISE estas quatro/cinco antes do primeiro teste real — em especial codigoFormaPagamento
//     (não sabemos os valores exatos que o PDV grava em vendas.forma_pagamento) e
//     interpretarRetornoFiscal (a lógica de "o que conta como autorizada" é nossa reconstrução
//     conservadora, não algo confirmado com a Dados Jah).
//   - exigeGrupoCard/montarGrupoCard (correção da Rejeição 391, regra YA04-10 do leiaute 4.00):
//     ver nota de proveniência na própria função, logo abaixo de codigoFormaPagamento.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

export const DADOSJAH_BASE_URL = "https://api-dfe.dadosjah.com.br/v1";

// ---------------------------------------------------------------------
// 1. Clientes Supabase (cópia de florest_erp_senha/dadosjah.ts)
// ---------------------------------------------------------------------

// Cliente com a service_role: só para o que REALMENTE precisa ignorar RLS (ler
// fiscal_credenciais/documentos_fiscais/vendas/itens_venda/produtos com filtro explícito de
// empresa_id, e gravar o resultado da emissão). Nunca usar este cliente para decidir permissão.
export function criarClienteAdmin() {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) {
    throw new Error("Configuração do Supabase ausente (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY).");
  }
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}

// Cliente com a chave anônima + o JWT do usuário logado: usado SOMENTE para autenticar o usuário,
// obter empresa_id via perfis, e confirmar (via RLS real) que o documento fiscal pedido pertence
// à empresa dele e que ele tem o módulo fiscal/pdv — nunca para decidir isso "na mão".
export function criarClienteUsuario(authHeader: string) {
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anon) {
    throw new Error("Configuração do Supabase ausente (SUPABASE_URL / SUPABASE_ANON_KEY).");
  }
  return createClient(url, anon, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { headers: { Authorization: authHeader } },
  });
}

type ClienteAdmin = ReturnType<typeof criarClienteAdmin>;

// Lê de volta, em texto puro, a senha da empresa na Dados Jah guardada no Vault — pelo id
// referenciado em fiscal_credenciais.dadosjah_password_secret_id. Mesma função
// public.dadosjah_vault_obter_segredo (Migration 007), só EXECUTE para service_role.
export async function obterSegredoVault(admin: ClienteAdmin, secretId: string): Promise<string | null> {
  const { data, error } = await admin.rpc("dadosjah_vault_obter_segredo", { p_secret_id: secretId });
  if (error || !data) return null;
  return data as string;
}

// ---------------------------------------------------------------------
// 2. Utilidades (cópia de florest_erp_senha/dadosjah.ts)
// ---------------------------------------------------------------------

export function jsonResponse(body: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...extraHeaders,
    },
  });
}

export type CorsDecision =
  | { tipo: "sem_origem" }
  | { tipo: "permitida"; headers: Record<string, string> }
  | { tipo: "negada" };

// Mesma convenção das demais funções fiscais: DISTGESTOR_ALLOWED_ORIGINS, com fallback para
// FLOREST_ALLOWED_ORIGINS (já configurada para florest-notificar/florest-admin-usuarios).
export function origensPermitidasEnv(): string[] {
  return (Deno.env.get("DISTGESTOR_ALLOWED_ORIGINS") ?? Deno.env.get("FLOREST_ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

export function decideCors(req: Request, permitidas: string[]): CorsDecision {
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

// Diagnóstico seguro do corpo de erro devolvido pela Dados Jah: qualquer segredo passado em
// `segredos` é removido do texto antes de logar (nunca token, senha, payload completo).
export function sanitizarCorpoDiagnostico(texto: string, segredos: Array<string | undefined>): string {
  let limpo = texto;
  for (const s of segredos) {
    if (s && s.length > 0) limpo = limpo.split(s).join("[removido]");
  }
  return limpo.length > 500 ? limpo.slice(0, 500) + "…" : limpo;
}

export function somenteDigitos(v: unknown): string {
  return typeof v === "string" ? v.replace(/\D+/g, "") : "";
}

// Log seguro: nunca token, senha, XML/PDF ou o corpo completo da resposta da Dados Jah.
export function logFiscal(evento: string, campos: Record<string, unknown> = {}) {
  console.error(JSON.stringify({ evento, ...campos }));
}

// ---------------------------------------------------------------------
// 3. Código NOVO desta entrega — ver nota de proveniência no topo do arquivo.
// ---------------------------------------------------------------------

// Tabela padrão do IBGE/SEFAZ de código de UF (campo cUF do NFe/NFC-e, layout 4.00). Dado
// técnico público e fixo (não muda por empresa/ambiente) — não depende de nenhuma fonte do
// workspace, é a tabela oficial usada em qualquer integração fiscal brasileira.
export const CODIGO_UF: Record<string, string> = {
  RO: "11", AC: "12", AM: "13", RR: "14", PA: "15", AP: "16", TO: "17",
  MA: "21", PI: "22", CE: "23", RN: "24", PB: "25", PE: "26", AL: "27", SE: "28", BA: "29",
  MG: "31", ES: "32", RJ: "33", SP: "35",
  PR: "41", SC: "42", RS: "43",
  MS: "50", MT: "51", GO: "52", DF: "53",
};

// dhEmi (e demais campos de data/hora) do NFe/NFC-e exige ISO 8601 COM offset (não "Z") — layout
// 4.00, campo TDateTimeUTC. O Brasil não usa mais horário de verão desde 2019, então o horário de
// Brasília é sempre UTC-03:00; não há necessidade de calcular DST.
export function agoraISOComOffsetBrasilia(): string {
  const agora = new Date();
  const local = new Date(agora.getTime() - 3 * 60 * 60 * 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  return (
    `${local.getUTCFullYear()}-${pad(local.getUTCMonth() + 1)}-${pad(local.getUTCDate())}` +
    `T${pad(local.getUTCHours())}:${pad(local.getUTCMinutes())}:${pad(local.getUTCSeconds())}-03:00`
  );
}

// Mapeia public.vendas.forma_pagamento (texto livre digitado/selecionado no PDV — não é um enum
// no banco) para o código tPag exigido em pag.detPag do NFC-e (tabela padrão SEFAZ, layout 4.00).
// ATENÇÃO: como forma_pagamento é texto livre, esta função só reconhece os termos mais comuns em
// português (normalizados: minúsculo, sem acento). Precisa ser CONFERIDA contra os valores reais
// que o PDV grava (tela de fechamento de venda) antes do primeiro teste — qualquer valor não
// reconhecido cai em "99" (Outros), que é aceito pela SEFAZ mas não deveria ser o caminho comum.
const TPAG_MAPA: Record<string, string> = {
  dinheiro: "01",
  cheque: "02",
  "cartao de credito": "03",
  "cartao credito": "03",
  credito: "03",
  "cartao de debito": "04",
  "cartao debito": "04",
  debito: "04",
  "credito loja": "05",
  "vale alimentacao": "10",
  "vale refeicao": "11",
  "vale presente": "12",
  "vale combustivel": "13",
  boleto: "15",
  "deposito bancario": "16",
  pix: "17",
  "transferencia bancaria": "18",
  transferencia: "18",
  "sem pagamento": "90",
};

function normalizarTexto(v: string): string {
  return v
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "") // remove acentos
    .trim()
    .toLowerCase();
}

export function codigoFormaPagamento(formaPagamento: string): string {
  const chave = normalizarTexto(formaPagamento || "");
  return TPAG_MAPA[chave] ?? "99"; // "99" = Outros (SEFAZ) — usado quando não reconhecemos o texto
}

// ---------------------------------------------------------------------
// CORREÇÃO (Rejeição 391 — regra YA04-10 do leiaute 4.00 da NFe/NFC-e): quando tPag é 03 (Cartão
// de Crédito), 04 (Cartão de Débito) ou 17 (PIX), o grupo "card" dentro de cada detPag é exigido
// pela SEFAZ. Os nomes "card"/"tpIntegra" são os nomes REAIS do grupo/campo do leiaute 4.00 (Nota
// Técnica que estendeu a exigência também a PIX) — não inventados; seguem a mesma convenção já
// usada em 100% dos outros campos deste payload (nome do campo JSON = nome da tag/atributo XML).
//
// tpIntegra = "2" ("Pagamento NÃO integrado com o sistema de automação da empresa") é o único
// valor correto aqui: o Florest ERP não tem integração TEF/POS com maquininha nem captura
// automática de PIX — o operador só marca manualmente a forma de pagamento (ver
// public.vendas.forma_pagamento / bar_pagamentos_formas, ambos texto livre escolhido na tela,
// nunca um retorno de equipamento). tpIntegra = "1" ("Pagamento integrado") exigiria um TEF/POS
// real informando os dados da transação — não é o caso.
//
// Os demais campos do grupo card no leiaute (CNPJ da credenciadora, bandeira/tBand, código de
// autorização/cAut, CNPJ do recebedor/CNPJReceb, terminal/idTermPag) só existem para descrever
// UMA transação de TEF/POS real (tpIntegra=1) — não fazem sentido e não são exigidos quando
// tpIntegra=2, e o Florest ERP não tem nenhum desses dados para preencher de verdade. Por isso
// NENHUM deles é enviado aqui: incluir um CNPJ/cAut/bandeira fictício seria pior do que omiti-los
// (dado fiscal fabricado), e o leiaute não exige isso para pagamento não integrado.
const TPAG_EXIGE_GRUPO_CARD = new Set(["03", "04", "17"]);

export interface GrupoCard {
  tpIntegra: string;
}

// Decide (por tPag) se este detPag precisa do grupo card, e já devolve o grupo pronto — ou
// undefined quando não se aplica (ex.: dinheiro, "01"). Reaproveitada tanto pelo payload de
// PDV/Pet quanto pelo do Módulo Bar (ver index.ts), para não duplicar esta regra em dois lugares.
export function montarGrupoCard(tPag: string): GrupoCard | undefined {
  return TPAG_EXIGE_GRUPO_CARD.has(tPag) ? { tpIntegra: "2" } : undefined;
}

// NFe/NFC-e layout 4.00 exige valores monetários como string com 2 casas decimais (ex.: "10.50").
export function formatarValorMonetario(valor: number): string {
  const seguro = Number.isFinite(valor) ? valor : 0;
  return seguro.toFixed(2);
}

// ---------------------------------------------------------------------
// Interpretação do retorno da Dados Jah (POST /nfce). Os NOMES de campo abaixo (cStat, xMotivo,
// nProt, chDfe, situation, situationDfe) são os mesmos lidos pela referência do PetGestor — essa
// parte é evidência real, não inventada. A LÓGICA de quando considerar "autorizada" é a nossa
// reconstrução conservadora (cStat "100" é o código padrão SEFAZ para "Autorizado o uso da
// NF-e/NFC-e"; exigimos também protocolo + chave de acesso antes de declarar sucesso — nunca
// concluímos autorizada só por ausência de erro). REVISE contra a documentação/Postman real da
// Dados Jah antes do primeiro teste; se ela usar outro campo/valor para sucesso, ajuste aqui.
// ---------------------------------------------------------------------
export interface ResultadoInterpretacaoFiscal {
  status: "autorizada" | "rejeitada";
  cStat: string | null;
  xMotivo: string | null;
}

export function interpretarRetornoFiscal(item: Record<string, unknown>): ResultadoInterpretacaoFiscal {
  const cStat = item?.cStat !== undefined && item?.cStat !== null ? String(item.cStat) : null;
  const xMotivo = typeof item?.xMotivo === "string" ? item.xMotivo : null;
  const nProt = typeof item?.nProt === "string" && item.nProt.length > 0 ? item.nProt : null;
  const chDfe = typeof item?.chDfe === "string" && item.chDfe.length > 0 ? item.chDfe : null;
  const situation = typeof item?.situation === "string" ? normalizarTexto(item.situation) : null;
  const situationDfe = typeof item?.situationDfe === "string" ? normalizarTexto(item.situationDfe) : null;

  const cStatIndicaAutorizada = cStat === "100";
  const situacaoIndicaAutorizada =
    situation === "autorizada" || situation === "autorizado" ||
    situationDfe === "autorizada" || situationDfe === "autorizado";

  // Só "autorizada" com evidência completa: (cStat 100 OU texto de situação equivalente) E
  // protocolo E chave de acesso presentes. Qualquer coisa fora disso é tratada como rejeitada.
  if ((cStatIndicaAutorizada || situacaoIndicaAutorizada) && nProt && chDfe) {
    return { status: "autorizada", cStat, xMotivo };
  }

  return {
    status: "rejeitada",
    cStat,
    xMotivo: xMotivo ?? "Retorno da Dados Jah não confirma autorização (sem cStat 100/situação equivalente e/ou sem protocolo ou chave de acesso).",
  };
}

// =====================================================================
// P1 — SEGURANÇA FISCAL: classificação do DESFECHO de uma tentativa de emissão (revisão 2).
//
// PRINCÍPIO: só há três desfechos que liberam ou encerram o documento sozinhos:
//   - "autorizada": cStat 100 + protocolo + chave de acesso (decisão de interpretarRetornoFiscal, inalterada);
//   - "rejeitada": a SEFAZ respondeu com um cStat de REJEIÇÃO CONFIRMADO (lista explícita abaixo);
//   - "denegada": a SEFAZ denegou (110/205/301/302/303) — a nota existe e consumiu a numeração; NUNCA reemitir.
// QUALQUER outra coisa é "desconhecida": o documento fica bloqueado até consulta + confirmação.
//
// NÃO existe regra "primeiro dígito do cStat" para rejeição. Cada cStat cai numa CATEGORIA explícita
// (autorização, rejeição confirmada, denegação, cancelamento, inutilização, duplicidade, processamento
// pendente, serviço, evento); cStat fora das tabelas = "cstat_nao_catalogado" => desconhecida.
//
// FALHA HTTP (não-2xx) da Dados Jah NÃO é evidência de que a nota não foi transmitida: não há garantia
// documentada da Dados Jah de que um HTTP 400/401/403/422 aconteça antes da transmissão à SEFAZ. Então,
// SEM cStat estruturado da SEFAZ no corpo, toda falha HTTP é "desconhecida" — inclusive HTTP 400 com texto
// de validação ("IE do emitente…", "campo obrigatório", "schema"…) ou com falha de rede do ACBr. Textos só
// servem de INDÍCIO informativo (campo "indicio"), nunca para liberar reenvio.
//
// FONTES das tabelas de cStat (consultadas em 14/10/2026; o MOC 7.0 oficial no Confaz/Portal NF-e NÃO pôde
// ser lido por esta ferramenta — acesso bloqueado — então confira com o MOC/NT vigentes antes de ampliar):
//   páginas por código de buscadorncm.com.br (203, 204, 206, 209, 213, 215, 218, 225, 228, 252, 301, 391, 610,
//   753, 999, 105, 108, 110, 150), docs de resiliência da nfe.io e fórum do Projeto ACBr (103-105, 110).
// Só 100 (autorizada), a lista de rejeições confirmadas e as denegações influenciam decisões; as demais
// categorias levam todas a "desconhecida" (só mudam a mensagem), então um erro de categoria nelas é inofensivo.
// =====================================================================
export type ClasseDesfecho = "autorizada" | "rejeitada" | "denegada" | "desconhecida";

export type CategoriaCStat =
  | "autorizacao" | "autorizacao_fora_prazo" | "rejeicao" | "denegacao" | "cancelamento" | "inutilizacao"
  | "duplicidade" | "processamento_pendente" | "servico" | "evento" | "nao_catalogado";

// Rejeições CONFIRMADAS: a SEFAZ não autorizou e NÃO registra a nota (numeração reaproveitável após corrigir).
// Lista deliberadamente curta e explícita; ampliar só após conferir o código no MOC/NT vigentes.
const CSTAT_REJEICAO_CONFIRMADA: ReadonlySet<string> = new Set([
  "203", // Emissor não habilitado para emissão da NF-e
  "209", // IE do emitente inválida
  "213", // CNPJ-Base do Emitente difere do CNPJ-Base do Certificado Digital
  "215", // Falha no schema XML
  "225", // Falha no Schema XML do lote de NFe
  "228", // Data de Emissão muito atrasada
  "252", // Ambiente informado diverge do Ambiente de recebimento
  "391", // Não informados os dados do cartão de crédito / débito nas Formas de Pagamento
  "441", // xPag obrigatório para tPag 99 (verificado em fonte secundária na auditoria tPag)
  "442", // xPag informado indevidamente (idem)
  "444", // QR Code v2 para emitente pessoa física (idem)
  "610", // Total da NF difere do somatório dos valores que compõem o total
  "753", // NFC-e com Frete
]);

const CSTAT_OUTRAS_CATEGORIAS: Readonly<Record<string, CategoriaCStat>> = {
  "100": "autorizacao",
  "150": "autorizacao_fora_prazo", // autorizada FORA DE PRAZO: o ERP não finaliza sozinho — exige consulta
  "101": "cancelamento", "151": "cancelamento", "155": "cancelamento", "218": "cancelamento",
  "102": "inutilizacao", "206": "inutilizacao", "563": "inutilizacao",
  "103": "processamento_pendente", "104": "processamento_pendente", "105": "processamento_pendente", "106": "processamento_pendente",
  "107": "servico", "108": "servico", "109": "servico",
  "110": "denegacao", "205": "denegacao", "301": "denegacao", "302": "denegacao", "303": "denegacao",
  "204": "duplicidade", "539": "duplicidade",
  "128": "evento", "135": "evento", "136": "evento", "573": "evento",
};

// ---------------------------------------------------------------------
// NÍVEL DE EVIDÊNCIA de cada cStat catalogado. NENHUM código foi validado no MOC/NT oficial (o portal não
// pôde ser lido): CSTAT_VALIDADO_NO_MOC está VAZIO de propósito. Quem validar um código no MOC vigente
// deve movê-lo para esse conjunto (e só então considerar a lista "conferida").
//   N1 = página específica do código (ou da regra do campo, ex.: tPag/xPag p/ 441-442) em fonte secundária (buscadorncm.com.br), 14/10/2026
//   N2 = citado em documentação de resiliência (nfe.io) / fórum do Projeto ACBr
//   N3 = conhecimento geral do leiaute/MOC; NÃO consultado individualmente nesta revisão
// Se um código de N3 estiver errado, o efeito é só a MENSAGEM (todas as categorias não-rejeição/denegação
// bloqueiam do mesmo jeito); um erro em REJEIÇÃO ou DENEGAÇÃO é o que importa — todas N1 exceto 205/302/303 (N3).
// ---------------------------------------------------------------------
export const CSTAT_EVIDENCIA: Readonly<Record<string, "N1" | "N2" | "N3">> = {
  "100": "N3", "150": "N1",
  "203": "N1", "209": "N1", "213": "N1", "215": "N1", "225": "N1", "228": "N1", "252": "N1", "391": "N1",
  "441": "N1", "442": "N1", "444": "N1", "610": "N1", "753": "N1",
  "110": "N1", "205": "N3", "301": "N1", "302": "N3", "303": "N3",
  "101": "N3", "151": "N3", "155": "N3", "218": "N1",
  "102": "N3", "206": "N1", "563": "N3",
  "204": "N1", "539": "N3",
  "103": "N2", "104": "N2", "105": "N1", "106": "N3",
  "107": "N3", "108": "N1", "109": "N3",
  "128": "N3", "135": "N3", "136": "N3", "573": "N3",
};
export const CSTAT_VALIDADO_NO_MOC: ReadonlySet<string> = new Set<string>([]);

export function categoriaDoCStat(cStat: string | null | undefined): CategoriaCStat {
  const c = cStat === null || cStat === undefined ? "" : String(cStat).trim();
  if (CSTAT_REJEICAO_CONFIRMADA.has(c)) return "rejeicao";
  return CSTAT_OUTRAS_CATEGORIAS[c] ?? "nao_catalogado";
}

export interface DesfechoEmissao {
  classe: ClasseDesfecho;
  // Detalha o motivo (também usado para a mensagem ao usuário).
  categoria: CategoriaCStat | "falha_transporte" | "falha_http" | "retorno_inesperado" | "retorno_sem_cstat" | "retorno_contraditorio" | "autorizacao_incompleta" | "autorizada";
  // Código estável para log/evento/suporte (ex.: rede_timeout, http_5xx, http_400, cstat_duplicidade…).
  codigo: string;
  cStat: string | null;
  xMotivo: string | null;
  httpStatus: number | null;
  // Texto curto e SEGURO (sem token/segredo/corpo completo).
  detalhe: string | null;
  // Pista informativa extraída do texto (NUNCA usada para decidir): rede | validacao_local | autenticacao.
  indicio: "rede" | "validacao_local" | "autenticacao" | null;
}

// Indícios de falha de rede/transporte (texto normalizado: minúsculo, sem acento) — informativo.
const PADROES_FALHA_REDE: RegExp[] = [
  /network subsystem/, /subsistema de rede/, /\bsocket\b/, /winsock/, /\b100(53|54|60|61|93)\b/,
  /time-?out|timed out|tempo (esgotado|limite)/, /connection (reset|refused|closed|aborted|lost)/,
  /\beconn\w*|\betimedout\b|\benotfound\b|\behostunreach\b|\benetunreach\b/,
  /\bssl\b|\btls\b|handshake/, /(falha|erro) (de|na|no) (comunicacao|conexao|rede|transmissao)/,
  /nao (foi possivel|conseguiu) (se )?(conectar|comunicar)/, /sem (resposta|conexao)/,
  /servico (indisponivel|paralisado|em manutencao)|service unavailable|bad gateway|gateway time/,
  /unreachable|host not found|name resolution|\bdns\b/,
];
// Indícios de validação local — INFORMATIVO. Não prova que a Dados Jah não transmitiu o documento.
const PADROES_VALIDACAO_LOCAL: RegExp[] = [
  /\bid\s*:\s*[a-z]{1,3}\d{1,3}[a-z]?\s*[\/\-:]/, /nenhum valor informado/, /emitente nao cadastrad/,
  /ie do emitente/, /obrigatori[oa]/, /valor invalido|formato invalido|tamanho (invalido|maximo|minimo)/,
  /schema|xsd|\bvalidation\b|validacao/,
];

export function textoIndicaFalhaRede(texto: string | null | undefined): boolean {
  if (!texto) return false;
  const t = normalizarTexto(String(texto));
  return PADROES_FALHA_REDE.some((r) => r.test(t));
}
export function textoIndicaValidacaoLocal(texto: string | null | undefined): boolean {
  if (!texto) return false;
  const t = normalizarTexto(String(texto));
  return PADROES_VALIDACAO_LOCAL.some((r) => r.test(t));
}

function recortar(v: string | null | undefined, max = 300): string | null {
  if (!v) return null;
  const s = String(v).replace(/\s+/g, " ").trim();
  return s.length > max ? s.slice(0, max) + "…" : s;
}

// Falha ANTES de haver resposta HTTP (fetch lançou exceção): a requisição pode ter chegado — desconhecida.
export function classificarFalhaTransporte(erro: unknown): DesfechoEmissao {
  const nome = (erro as Error | null)?.name ?? "";
  const timeout = nome === "AbortError" || nome === "TimeoutError";
  return {
    classe: "desconhecida", categoria: "falha_transporte", codigo: timeout ? "rede_timeout" : "rede_falha",
    cStat: null, xMotivo: null, httpStatus: null, indicio: "rede",
    detalhe: timeout ? "Tempo esgotado aguardando a resposta da Dados Jah (60 s)." : "Falha de comunicação com a Dados Jah (sem resposta HTTP).",
  };
}

function extrairItemNFCe(json: unknown): Record<string, unknown> | null {
  // deno-lint-ignore no-explicit-any
  const j = json as any;
  const cand = j?.data?.NFCe?.[0] ?? j?.NFCe?.[0] ?? null;
  return cand && typeof cand === "object" ? cand : null;
}

// Resposta HTTP NÃO-2xx da Dados Jah. Só um cStat ESTRUTURADO (NFCe[0].cStat com 3 dígitos) conta como
// resposta da SEFAZ; sem ele, NENHUM status HTTP produz rejeição, liberação ou autorização.
export function classificarFalhaHttp(status: number, corpo: string, segredos: Array<string | undefined> = []): DesfechoEmissao {
  const corpoSeguro = sanitizarCorpoDiagnostico(corpo ?? "", segredos);
  let json: unknown = null;
  try { json = corpo ? JSON.parse(corpo) : null; } catch { /* corpo não-JSON */ }

  const item = extrairItemNFCe(json);
  const cStatCorpo = item?.cStat !== undefined && item?.cStat !== null ? String(item.cStat) : null;
  if (item && cStatCorpo && /^\d{3}$/.test(cStatCorpo)) {
    const r = classificarRetornoDadosJah(item);
    return { ...r, httpStatus: status, detalhe: recortar(`HTTP ${status}; ${r.detalhe ?? ""}`) };
  }

  // deno-lint-ignore no-explicit-any
  const j = json as any;
  const msgJson = [j?.message, j?.error, j?.data?.message, j?.errors && JSON.stringify(j.errors)].filter((x) => typeof x === "string").join(" | ");
  const textoAnalise = [msgJson, corpoSeguro].filter(Boolean).join(" | ");
  const indicio: DesfechoEmissao["indicio"] = textoIndicaFalhaRede(textoAnalise) ? "rede"
    : (status === 401 || status === 403) ? "autenticacao"
    : textoIndicaValidacaoLocal(textoAnalise) ? "validacao_local" : null;

  return {
    classe: "desconhecida", categoria: "falha_http",
    codigo: status >= 500 ? "http_5xx" : status === 400 ? "http_400" : status >= 400 ? `http_${status}` : "http_outro",
    cStat: null, xMotivo: null, httpStatus: status, indicio,
    detalhe: recortar(`HTTP ${status}${indicio ? ` [indício: ${indicio}]` : ""}: ${textoAnalise}`),
  };
}

// Retorno HTTP 2xx da Dados Jah (item NFCe[0], ou null quando o corpo veio vazio/ilegível/sem NFCe).
// A decisão de "autorizada" é EXATAMENTE a de interpretarRetornoFiscal (inalterada).
export function classificarRetornoDadosJah(item: Record<string, unknown> | null | undefined): DesfechoEmissao {
  const vazio = { cStat: null as string | null, xMotivo: null as string | null, httpStatus: 200 as number | null, indicio: null as DesfechoEmissao["indicio"] };
  if (!item || typeof item !== "object") {
    return { classe: "desconhecida", categoria: "retorno_inesperado", codigo: "retorno_inesperado", ...vazio, detalhe: "Resposta da Dados Jah sem o item da NFC-e." };
  }
  const base = interpretarRetornoFiscal(item);
  const cStat = base.cStat !== null && /^\d{3}$/.test(base.cStat) ? base.cStat : null;
  const xMotivo = typeof item.xMotivo === "string" ? item.xMotivo : null;
  const comEvidencia = { cStat: base.cStat, xMotivo, httpStatus: 200 as number | null, indicio: null as DesfechoEmissao["indicio"] };
  const nProt = typeof item.nProt === "string" && item.nProt.length > 0;
  const chDfe = typeof item.chDfe === "string" && item.chDfe.length > 0;

  if (base.status === "autorizada") {
    if (base.cStat !== null && base.cStat !== "100") {
      return { classe: "desconhecida", categoria: "retorno_contraditorio", codigo: "retorno_contraditorio", ...comEvidencia, detalhe: recortar(`Situação autorizada mas cStat ${base.cStat}.`) };
    }
    return { classe: "autorizada", categoria: "autorizada", codigo: "autorizada", ...comEvidencia, detalhe: null };
  }

  if (cStat !== null) {
    const cat = categoriaDoCStat(cStat);
    if (cat === "autorizacao") { // cStat 100 sem protocolo e/ou chave
      return { classe: "desconhecida", categoria: "autorizacao_incompleta", codigo: "autorizacao_incompleta", ...comEvidencia, detalhe: recortar(`cStat 100 sem ${!nProt ? "protocolo" : ""}${!nProt && !chDfe ? " e " : ""}${!chDfe ? "chave de acesso" : ""}.`) };
    }
    if (cat === "rejeicao") {
      if (nProt && chDfe) { // rejeição não gera protocolo: contraditório
        return { classe: "desconhecida", categoria: "retorno_contraditorio", codigo: "retorno_contraditorio", ...comEvidencia, detalhe: recortar(`cStat ${cStat} com protocolo e chave de acesso presentes.`) };
      }
      return { classe: "rejeitada", categoria: "rejeicao", codigo: "cstat_rejeicao", ...comEvidencia, detalhe: recortar(xMotivo) };
    }
    if (cat === "denegacao") {
      return { classe: "denegada", categoria: "denegacao", codigo: "cstat_denegacao", ...comEvidencia, detalhe: recortar(`cStat ${cStat}${xMotivo ? ": " + xMotivo : ""}`) };
    }
    return { classe: "desconhecida", categoria: cat, codigo: `cstat_${cat}`, ...comEvidencia, detalhe: recortar(`cStat ${cStat}${xMotivo ? ": " + xMotivo : ""}`) };
  }

  // Sem cStat utilizável: NUNCA é rejeição confirmada (nem pelo texto de "situation").
  const textoSituacao = [item.situation, item.situationDfe, xMotivo].filter((x) => typeof x === "string").join(" | ");
  return {
    classe: "desconhecida", categoria: "retorno_sem_cstat",
    codigo: textoIndicaFalhaRede(textoSituacao) ? "retorno_falha_rede" : "retorno_sem_cstat",
    ...comEvidencia, indicio: textoIndicaFalhaRede(textoSituacao) ? "rede" : null,
    detalhe: recortar(`Retorno sem cStat utilizável. ${textoSituacao}`),
  };
}

// ---------------------------------------------------------------------
// Orientação ao usuário (API, documento e evento). Nunca contém token, segredo nem corpo da resposta.
// Em TODAS: não emitir de novo; consultar a SEFAZ; reenvio só depois da confirmação registrada no ERP.
// ---------------------------------------------------------------------
export function mensagemSituacaoDesconhecida(
  numero: string | number | null,
  serie: string | null,
  categoria?: string | null,
  cStat?: string | null,
): string {
  const ref = numero ? ` (NFC-e nº ${numero}${serie ? `, série ${serie}` : ""})` : "";
  const cs = cStat ? ` (cStat ${cStat})` : "";
  const fecho =
    " NÃO emita novamente. Consulte a situação da NFC-e pelo número/série no painel da Dados Jah ou pela chave de acesso no portal da SEFAZ;" +
    " o reenvio só é liberado depois que um usuário do módulo Fiscal registrar no ERP o resultado da consulta.";
  switch (categoria) {
    case "denegacao":
      return `A SEFAZ DENEGOU o uso da NFC-e${ref}${cs}: a numeração foi consumida e esta nota não pode ser reemitida com o mesmo número. NÃO emita novamente; procure seu contador (irregularidade fiscal) e o suporte do Florest ERP.`;
    case "duplicidade":
      return `A SEFAZ informou duplicidade${ref}${cs}: já existe NFC-e com esta numeração e ela pode estar AUTORIZADA.${fecho}`;
    case "cancelamento":
      return `A SEFAZ informou que há NFC-e CANCELADA com esta numeração${ref}${cs}.${fecho}`;
    case "inutilizacao":
      return `A SEFAZ informou que a numeração${ref}${cs} consta como INUTILIZADA.${fecho}`;
    case "processamento_pendente":
      return `A SEFAZ ainda não concluiu o processamento da NFC-e${ref}${cs}; ela pode vir a ser autorizada.${fecho}`;
    case "servico":
      return `A SEFAZ informou indisponibilidade/paralisação do serviço${ref}${cs}; não é possível saber se a nota foi processada.${fecho}`;
    case "autorizacao_fora_prazo":
      return `A SEFAZ indicou autorização fora de prazo${ref}${cs}: a nota provavelmente está AUTORIZADA.${fecho}`;
    default:
      return `Não foi possível confirmar o resultado da emissão${ref}${cs}: a nota pode ter sido autorizada pela SEFAZ.${fecho}`;
  }
}

