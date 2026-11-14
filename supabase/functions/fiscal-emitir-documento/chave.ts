// =====================================================================
// Florest ERP — chave de acesso da NFC-e (modelo 65): cálculo, validação e decomposição.
// CÓPIA IDÊNTICA em fiscal-emitir-documento/chave.ts e fiscal-consultar-documento/chave.ts (o Supabase não
// compartilha arquivos entre pastas; o teste de contrato confere os hashes). Sem dependências, sem I/O.
//
// Composição (leiaute 4.00 da NF-e/NFC-e, 44 posições):
//   cUF(2) AAMM(4) CNPJ(14) mod(2) serie(3) nNF(9) tpEmis(1) cNF(8) cDV(1)
// cDV = módulo 11, pesos 2..9 da direita para a esquerda sobre as 43 primeiras posições;
//       resto 0 ou 1 => DV 0; senão DV = 11 - resto.
//
// IMPORTANTE (honestidade): a chave aqui é PREVISTA — calculada pelo ERP a partir do que ele mesmo envia
// (UF, CNPJ, série, nNF, cNF, tpEmis e o AAMM do dhEmi). Se a Dados Jah/ACBr alterar qualquer um desses
// campos antes de transmitir (por exemplo gerar outro cNF ou outro dhEmi), a chave real será outra. Isso
// ainda NÃO foi confirmado com a Dados Jah; por isso a chave prevista só vale como EVIDÊNCIA NEGATIVA depois
// que o parâmetro fiscal_parametros_consulta.chave_prevista_validada for ligado (ver Migration 037).
// Ela vale como evidência POSITIVA sempre: se a SEFAZ confirma autorização dessa chave, a nota existe.
// =====================================================================

export interface PartesChave {
  cUF: string;
  aamm: string;
  cnpj: string;
  mod: string;
  serie: string;
  nNF: string;
  tpEmis: string;
  cNF: string;
  dv: string;
}

export function calcularDV(base43: string): string {
  if (!/^[0-9]{43}$/.test(base43)) throw new Error("chave_base_invalida");
  let soma = 0;
  let peso = 2;
  for (let i = base43.length - 1; i >= 0; i--) {
    soma += Number(base43[i]) * peso;
    peso = peso === 9 ? 2 : peso + 1;
  }
  const resto = soma % 11;
  return String(resto === 0 || resto === 1 ? 0 : 11 - resto);
}

const so = (v: unknown): string => String(v ?? "").replace(/\D/g, "");

export interface EntradaChave {
  cUF: string | number;
  /** dhEmi no formato ISO do payload (AAAA-MM-DDThh:mm:ss-03:00); só AAAA-MM é usado. */
  dhEmi: string;
  cnpj: string;
  mod?: string;
  serie: string | number;
  nNF: string | number;
  tpEmis?: string | number;
  cNF: string | number;
}

/** Monta a chave de 44 dígitos. Lança erro (nunca devolve chave "aproximada") se algum campo for inválido. */
export function montarChave(e: EntradaChave): string {
  const m = /^(\d{4})-(\d{2})-\d{2}T/.exec(String(e.dhEmi ?? ""));
  if (!m) throw new Error("dhEmi_invalido");
  const mes = Number(m[2]);
  if (mes < 1 || mes > 12) throw new Error("dhEmi_invalido");
  const cUF = so(e.cUF);
  const cnpj = so(e.cnpj);
  const mod = so(e.mod ?? "65");
  const serie = so(e.serie);
  const nNF = so(e.nNF);
  const tpEmis = so(e.tpEmis ?? "1");
  const cNF = so(e.cNF);
  if (!/^[0-9]{2}$/.test(cUF)) throw new Error("cUF_invalido");
  if (!/^[0-9]{14}$/.test(cnpj)) throw new Error("cnpj_invalido");
  if (mod !== "65") throw new Error("modelo_invalido");
  if (serie === "" || serie.length > 3) throw new Error("serie_invalida");
  if (nNF === "" || nNF.length > 9 || Number(nNF) < 1) throw new Error("nNF_invalido");
  if (!/^[0-9]$/.test(tpEmis)) throw new Error("tpEmis_invalido");
  if (!/^[0-9]{8}$/.test(cNF)) throw new Error("cNF_invalido");
  const base = cUF + m[1].slice(2) + m[2] + cnpj + mod + serie.padStart(3, "0") + nNF.padStart(9, "0") + tpEmis + cNF;
  return base + calcularDV(base);
}

/** Decompõe uma chave de 44 dígitos (sem validar o DV). Devolve null se não tiver 44 dígitos. */
export function decomporChave(chave: unknown): PartesChave | null {
  const c = String(chave ?? "").replace(/\D/g, "");
  if (!/^[0-9]{44}$/.test(c) || String(chave ?? "").replace(/\s/g, "").length !== 44) return null;
  return {
    cUF: c.slice(0, 2), aamm: c.slice(2, 6), cnpj: c.slice(6, 20), mod: c.slice(20, 22), serie: c.slice(22, 25),
    nNF: c.slice(25, 34), tpEmis: c.slice(34, 35), cNF: c.slice(35, 43), dv: c.slice(43, 44),
  };
}

export function chaveValida(chave: unknown): boolean {
  const p = decomporChave(chave);
  if (!p) return false;
  return calcularDV(String(chave).slice(0, 43)) === p.dv;
}

export interface IdentidadeEsperada {
  cUF?: string | null;
  cnpj?: string | null;
  serie?: string | number | null;
  nNF?: string | number | null;
  cNF?: string | null;
  tpEmis?: string | null;
}

/** Compara a chave com a identidade esperada do documento. Devolve a lista de divergências (vazia = confere). */
export function divergenciasDaChave(chave: unknown, esperado: IdentidadeEsperada): string[] {
  const p = decomporChave(chave);
  if (!p) return ["chave_formato_invalido"];
  const d: string[] = [];
  if (calcularDV(String(chave).replace(/\D/g, "").slice(0, 43)) !== p.dv) d.push("chave_dv_invalido");
  if (p.mod !== "65") d.push("modelo_diferente_de_65");
  if (esperado.cUF != null && so(esperado.cUF) !== p.cUF) d.push("uf_diferente");
  if (esperado.cnpj != null && so(esperado.cnpj) !== p.cnpj) d.push("cnpj_emitente_diferente");
  if (esperado.serie != null && Number(so(esperado.serie)) !== Number(p.serie)) d.push("serie_diferente");
  if (esperado.nNF != null && Number(so(esperado.nNF)) !== Number(p.nNF)) d.push("numero_diferente");
  if (esperado.cNF != null && so(esperado.cNF) !== p.cNF) d.push("cNF_diferente");
  if (esperado.tpEmis != null && so(esperado.tpEmis) !== p.tpEmis) d.push("tpEmis_diferente");
  return d;
}

