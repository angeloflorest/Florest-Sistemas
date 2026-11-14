// =====================================================================
// TESTE DE HOMOLOGAÇÃO da emissão em contingência (tpEmis=9) pela API da Dados Jah — Migration 42 (teste controlado, sem alterar o banco).
// Arquivo só é usado quando o corpo da chamada traz "teste_contingencia_homologacao": true E o secret FISCAL_CTG_TESTE_HOMOLOG
// está ligado ("sim") E a empresa está em HOMOLOGAÇÃO (tpAmb=2 E configuracoes_fiscais.nfce_ambiente = 'homologacao') E o usuário é
// proprietário ou tem o módulo Fiscal. Em produção, sem o secret ou sem permissão, a Edge RECUSA a chamada antes de reservar número
// ou enviar qualquer coisa.
//
// O que ele faz: a mesma emissão de sempre, com ide.tpEmis="9", ide.dhCont e ide.xJust; e devolve um DIAGNÓSTICO do que a API
// respondeu (campos, cStat, chave, XML: tpEmis/dhCont/xJust/assinatura/QR Code; DANFE presente?). NÃO decide nada fiscal:
// a classificação (autorizada/rejeitada/desconhecida) continua sendo a do ERP — HTTP 200/201 ou "processed" nunca é autorização.
// Nunca devolve token, senha nem o conteúdo do XML.
// =====================================================================
import { chaveValida } from "./chave.ts";

export const XJUST_TESTE_CTG = "TESTE DE HOMOLOGACAO DA CONTINGENCIA OFFLINE NFC-E TPEMIS 9";   // 15..256, sem símbolos XML, sem espaço duplo
export const MODO_ENVIO_TESTE_CTG = "teste_contingencia_homologacao";
/** dhCont é gravado alguns segundos ANTES do dhEmi: a SEFAZ exige dhCont <= dhEmi e o provedor pode arredondar horários. */
export const SEGUNDOS_DHCONT_ANTES_DHEMI = 60;

export type PedidoTesteCtg =
  | { ativo: true }
  | { ativo: false; codigo: "teste_desabilitado" | "teste_somente_homologacao" | "teste_sem_permissao"; mensagem: string };

/**
 * Só homologação: o ambiente efetivo (tpAmb) precisa ser "2" E a configuração fiscal precisa dizer EXPLICITAMENTE "homologacao"
 * (ambiente ausente ou desconhecido NÃO libera o teste). `nfceAmbiente` vem sempre do banco, nunca do corpo da requisição.
 */
export function avaliarPedidoTesteCtg(secretHabilitacao: string | undefined | null, tpAmb: string, nfceAmbiente: string | null): PedidoTesteCtg {
  if ((secretHabilitacao ?? "").trim().toLowerCase() !== "sim") {
    return { ativo: false, codigo: "teste_desabilitado", mensagem: "O teste de contingência em homologação está desligado (secret FISCAL_CTG_TESTE_HOMOLOG). Nada foi enviado e nenhum número foi consumido." };
  }
  if (tpAmb !== "2" || nfceAmbiente !== "homologacao") {
    return { ativo: false, codigo: "teste_somente_homologacao", mensagem: "O teste de contingência só roda em HOMOLOGAÇÃO (tpAmb=2). Nada foi enviado e nenhum número foi consumido." };
  }
  return { ativo: true };
}

/** Quem pode pedir o teste: proprietário ou usuário ativo com o módulo Fiscal. Só o PDV, sozinho, NÃO basta. */
export function avaliarPermissaoTesteCtg(perfil: { papel?: unknown; permissoes?: unknown; ativo?: unknown } | null | undefined): PedidoTesteCtg {
  const permissoes = Array.isArray(perfil?.permissoes) ? (perfil?.permissoes as unknown[]) : [];
  const autorizado = perfil?.ativo === true && (perfil?.papel === "proprietario" || permissoes.includes("fiscal"));
  if (!autorizado) {
    return { ativo: false, codigo: "teste_sem_permissao", mensagem: "Somente o proprietário ou usuários com o módulo Fiscal podem executar o teste de contingência. Nada foi enviado e nenhum número foi consumido." };
  }
  return { ativo: true };
}

const RE_ISO_BRASILIA = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})([+-]\d{2}:\d{2})$/;

/** dhEmi (AAAA-MM-DDThh:mm:ss-03:00) menos SEGUNDOS_DHCONT_ANTES_DHEMI, no mesmo fuso. Lança erro se o formato não for o esperado. */
export function dhContParaTeste(dhEmi: string): string {
  const m = RE_ISO_BRASILIA.exec(String(dhEmi ?? ""));
  if (!m) throw new Error("dhEmi_formato_invalido");
  const parede = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6])) - SEGUNDOS_DHCONT_ANTES_DHEMI * 1000;
  const iso = new Date(parede).toISOString();                 // AAAA-MM-DDThh:mm:ss.sssZ (relógio de parede, sem mudar de fuso)
  return iso.slice(0, 19) + m[7];
}

const instante = (s: unknown): number | null => {
  const t = typeof s === "string" && RE_ISO_BRASILIA.test(s) ? Date.parse(s) : NaN;
  return Number.isFinite(t) ? t : null;
};

/** Confere o grupo ide ANTES do envio: se algo faltar, a Edge aborta sem enviar. Devolve a lista de problemas (vazia = ok). */
export function validarIdeTesteCtg(ide: Record<string, unknown> | null | undefined): string[] {
  const p: string[] = [];
  const i = ide ?? {};
  if (i.tpEmis !== "9") p.push("tpEmis_diferente_de_9");
  if (i.tpAmb !== "2") p.push("tpAmb_diferente_de_2");
  const eEmi = instante(i.dhEmi), eCont = instante(i.dhCont);
  if (eEmi === null) p.push("dhEmi_ausente_ou_invalido");
  if (eCont === null) p.push("dhCont_ausente_ou_invalido");
  if (eEmi !== null && eCont !== null && eCont > eEmi) p.push("dhCont_posterior_ao_dhEmi");
  const x = typeof i.xJust === "string" ? i.xJust : "";
  if (x.length < 15 || x.length > 256) p.push("xJust_tamanho_invalido");
  if (/[<>&"']/.test(x) || /\s{2,}/.test(x) || x !== x.trim()) p.push("xJust_caracteres_invalidos");
  return p;
}

export interface IdeEnviadoTesteCtg {
  tpEmis: string | null; tpAmb: string | null; dhEmi: string | null; dhCont: string | null; xJust: string | null;
  serie: string | null; nNF: string | null; cNF: string | null;
}
function ideEnviado(ide: Record<string, unknown> | null | undefined): IdeEnviadoTesteCtg {
  const s = (v: unknown): string | null => (typeof v === "string" || typeof v === "number") && String(v).length > 0 ? String(v) : null;
  const i = ide ?? {};
  return { tpEmis: s(i.tpEmis), tpAmb: s(i.tpAmb), dhEmi: s(i.dhEmi), dhCont: s(i.dhCont), xJust: s(i.xJust), serie: s(i.serie), nNF: s(i.nNF), cNF: s(i.cNF) };
}

export interface DiagnosticoTesteCtg {
  aviso: string;
  /** false enquanto a requisição à Dados Jah ainda não teve resposta (ex.: falha de rede depois do envio). */
  resposta_recebida: boolean;
  /** O que o ERP ENVIOU no grupo ide (confere tpEmis=9, dhCont e xJust no payload). */
  payload_ide_enviado: IdeEnviadoTesteCtg;
  payload_tem_tpEmis_dhCont_xJust: boolean;
  chave_prevista: string | null;
  chave_prevista_valida: boolean | null;
  chave_prevista_tpEmis: string | null;
  http_status: number | null;
  corpo_http_erro: string | null;
  campos_do_item: string[];
  cStat: string | null;
  xMotivo: string | null;
  situation: string | null;
  situationDfe: string | null;
  tem_protocolo: boolean;
  chDfe: string | null;
  chDfe_valida: boolean;
  chDfe_dv_valido: boolean | null;
  chDfe_tpEmis: string | null;
  chDfe_igual_a_prevista: boolean | null;
  classificacao_do_erp: string;
  leitura: string;
  xml: {
    presente: boolean; via_link: boolean; tamanho: number | null;
    tem_tpEmis_9: boolean | null; tem_dhCont: boolean | null; dhCont_igual_ao_enviado: boolean | null; tem_xJust: boolean | null; xJust_igual_ao_enviado: boolean | null;
    tem_assinatura: boolean | null; tem_infNFeSupl: boolean | null; tem_qrCode: boolean | null; tem_protNFe: boolean | null;
  };
  danfe: { pdf_presente: boolean; pdf_link_presente: boolean };
  conferir_manualmente: string[];
}

const AVISO = "HTTP 200/201 e 'processed' NÃO são autorização. Só vale cStat 100/150 + protocolo + chave (a SEFAZ). Confirme a situação real da chave na SEFAZ antes de concluir.";

function texto(v: unknown): string | null { return typeof v === "string" && v.length > 0 ? v : null; }

/** Anexo gravado ANTES do envio: mostra o que foi enviado mesmo que a resposta nunca chegue (timeout/queda de rede). */
export function anexoPreliminarTesteCtg(e: { ide: Record<string, unknown>; chavePrevista: string | null }): Record<string, unknown> {
  const ide = ideEnviado(e.ide);
  return {
    aviso: AVISO,
    resposta_recebida: false,
    payload_ide_enviado: ide,
    payload_tem_tpEmis_dhCont_xJust: ide.tpEmis === "9" && !!ide.dhCont && !!ide.xJust,
    chave_prevista: e.chavePrevista,
    chave_prevista_valida: e.chavePrevista ? chaveValida(e.chavePrevista) : null,
    chave_prevista_tpEmis: e.chavePrevista ? e.chavePrevista.slice(34, 35) : null,
    http_status: null,
  };
}

function leituraDoResultado(classe: string, d: { cStat: string | null; temProtocolo: boolean; xmlPresente: boolean; xmlTem9: boolean | null; xmlTemAssinatura: boolean | null; httpStatus: number | null }): string {
  if (classe === "autorizada") {
    return "A SEFAZ (homologação) AUTORIZOU esta NFC-e (cStat " + (d.cStat ?? "?") + " com protocolo). Isto indica que a API se comunicou com a SEFAZ: NÃO prova que ela gere e assine tpEmis=9 sem conexão, nem que transmita depois. Confira o XML e o DANFE abaixo e responda à Dados Jah.";
  }
  if (classe === "rejeitada") {
    return "A SEFAZ REJEITOU a nota (cStat " + (d.cStat ?? "?") + "): nada foi autorizado e a nota não existe na SEFAZ. Leia o motivo, corrija a causa e repita o teste se for o caso.";
  }
  if (classe === "denegada") {
    return "A SEFAZ DENEGOU o documento. Não repita o teste neste documento; acione o suporte fiscal.";
  }
  if (d.xmlPresente && !d.temProtocolo) {
    return "A API devolveu um documento SEM cStat/protocolo de autorização" + (d.xmlTem9 === true ? " e com tpEmis=9" : "") + (d.xmlTemAssinatura === true ? " assinado" : "") + ": possivelmente gerado e assinado SEM transmissão. NÃO é autorização. O documento ficou BLOQUEADO em 'processando' com os dados preservados; não reenvie. Consulte a chave na SEFAZ e pergunte à Dados Jah como transmitir depois.";
  }
  return "Resposta SEM prova fiscal (HTTP " + (d.httpStatus ?? "?") + "). NÃO é autorização. O documento ficou BLOQUEADO em 'processando': não reenvie; consulte a situação antes de qualquer nova ação.";
}

export function diagnosticarRespostaTesteCtg(e: {
  httpStatus: number | null;
  item: Record<string, unknown> | null;
  chavePrevista: string | null;
  xJustEnviado: string;
  classificacaoErp: string;
  ide?: Record<string, unknown> | null;
  /** corpo de erro HTTP JÁ sanitizado (sem token) e truncado pelo chamador */
  corpoErro?: string | null;
}): DiagnosticoTesteCtg {
  const item = e.item ?? {};
  const ide = ideEnviado(e.ide ?? null);
  const chRaw = texto(item.chDfe)?.replace(/\D/g, "") ?? null;
  const chaveFormato = !!chRaw && /^\d{44}$/.test(chRaw);
  const xml = texto(item.xml);
  const temXml = !!xml;
  const marca = (re: RegExp): boolean | null => (temXml ? re.test(xml as string) : null);
  const xjustNoXml = temXml ? (xml as string).match(/<xJust>([^<]*)<\/xJust>/)?.[1] ?? null : null;
  const dhContNoXml = temXml ? (xml as string).match(/<dhCont>([^<]*)<\/dhCont>/)?.[1] ?? null : null;
  const cStat = texto(item.cStat) ?? (typeof item.cStat === "number" ? String(item.cStat) : null);
  const temProtocolo = !!texto(item.nProt);
  const xmlTem9 = marca(/<tpEmis>\s*9\s*<\/tpEmis>/);
  const xmlTemAss = marca(/<Signature[\s>]/);
  return {
    aviso: AVISO,
    resposta_recebida: true,
    payload_ide_enviado: ide,
    payload_tem_tpEmis_dhCont_xJust: ide.tpEmis === "9" && !!ide.dhCont && !!ide.xJust,
    chave_prevista: e.chavePrevista,
    chave_prevista_valida: e.chavePrevista ? chaveValida(e.chavePrevista) : null,
    chave_prevista_tpEmis: e.chavePrevista ? e.chavePrevista.slice(34, 35) : null,
    http_status: e.httpStatus,
    corpo_http_erro: e.corpoErro ? e.corpoErro.slice(0, 600) : null,
    campos_do_item: Object.keys(item).slice(0, 80),
    cStat,
    xMotivo: texto(item.xMotivo)?.slice(0, 300) ?? null,
    situation: texto(item.situation),
    situationDfe: texto(item.situationDfe),
    tem_protocolo: temProtocolo,
    chDfe: chaveFormato ? chRaw : null,
    chDfe_valida: chaveFormato,
    chDfe_dv_valido: chaveFormato ? chaveValida(chRaw) : null,
    chDfe_tpEmis: chaveFormato ? (chRaw as string).slice(34, 35) : null,
    chDfe_igual_a_prevista: chaveFormato && e.chavePrevista ? chRaw === e.chavePrevista : null,
    classificacao_do_erp: e.classificacaoErp,
    leitura: leituraDoResultado(e.classificacaoErp, { cStat, temProtocolo, xmlPresente: temXml, xmlTem9, xmlTemAssinatura: xmlTemAss, httpStatus: e.httpStatus }),
    xml: {
      presente: temXml, via_link: !!texto(item.xmlLink), tamanho: temXml ? (xml as string).length : null,
      tem_tpEmis_9: xmlTem9, tem_dhCont: marca(/<dhCont>[^<]+<\/dhCont>/), dhCont_igual_ao_enviado: temXml && ide.dhCont ? dhContNoXml === ide.dhCont : null,
      tem_xJust: marca(/<xJust>[^<]+<\/xJust>/), xJust_igual_ao_enviado: temXml ? xjustNoXml === e.xJustEnviado : null,
      tem_assinatura: xmlTemAss, tem_infNFeSupl: marca(/<infNFeSupl>/), tem_qrCode: marca(/<qrCode>[\s\S]+<\/qrCode>/), tem_protNFe: marca(/<protNFe[\s>]/),
    },
    danfe: { pdf_presente: !!texto(item.pdf), pdf_link_presente: !!texto(item.pdfLink) },
    conferir_manualmente: [
      "Abrir o XML (xmlLink) e conferir tpEmis=9, dhCont, xJust, a assinatura (Signature) e o QR Code (infNFeSupl).",
      "Abrir o DANFE (pdfLink/pdf) e conferir a identificação de 'EMITIDA EM CONTINGÊNCIA' e o QR Code.",
      "Consultar a chave na SEFAZ (portal ou fiscal-consultar-documento) e registrar a situação real: autorizada, rejeitada ou inexistente.",
      "Perguntar à Dados Jah (Patrick): a API gera/assina o XML tpEmis=9 SEM conexão com a SEFAZ e permite transmitir depois o MESMO documento? Em homologação a resposta autorizada indica que houve conexão.",
    ],
  };
}

