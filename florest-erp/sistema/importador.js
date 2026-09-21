/* =====================================================================
   importador.js — Importador de planilhas (Excel .xlsx/.xls e CSV)
   Florest Sistemas

   Módulo GENÉRICO e reutilizável: não conhece "produtos", nem Supabase.
   Quem usa informa (1) quais campos existem, (2) como consultar registros
   já cadastrados e (3) como gravar um lote. O módulo cuida de:

     arquivo → leitura → mapeamento de colunas → prévia → validação →
     duplicidades → confirmação → importação em lotes

   Uso (resumo):

     import { abrirImportador } from './importador.js';
     abrirImportador({
       titulo: 'Importar produtos',
       nomeModelo: 'modelo-produtos.csv',
       campos: [ { chave, rotulo, tipo, obrigatorio, grupo, apelidos, ... } ],
       chavesDuplicidade: [ { campo, rotulo, normalizar, obrigatorioParaAviso } ],
       consultarExistentes: async (chaves, { aoProgredir }) => [ {id, nome, ...campos} ],
       gravarLote: async (linhas) => ({ criados, falhas: [{ indice, mensagem }] }),
       validarLinha: (dados) => ({ erros: [], avisos: [] }),      // opcional
       aoConcluir: (resumo) => {},                                 // opcional
     });

   Regras de segurança do módulo:
     - NUNCA sobrescreve registros existentes: quem já existe é apenas listado.
     - NUNCA inventa valores: campo não mapeado ou vazio vira null.
     - NUNCA carrega o cadastro inteiro no navegador para procurar
       duplicidades: envia apenas as chaves (em lotes) para o servidor.
     - empresa_id NÃO faz parte deste módulo: quem grava (gravarLote) é
       quem define a empresa, a partir da sessão do usuário — jamais do arquivo.
   ===================================================================== */

// Biblioteca de planilhas (carregada só quando o usuário escolhe um .xlsx/.xls).
// Versão fixa e mantida pelo próprio fabricante (SheetJS 0.20.x).
const SHEETJS_URL = 'https://cdn.sheetjs.com/xlsx-0.20.3/package/xlsx.mjs';

const LIMITE_LINHAS_PADRAO = 50000;
const TAMANHO_LOTE_PADRAO = 200;

// ---------------------------------------------------------------------
// Utilitários de GTIN / código de barras (também usados pelo PDV)
// ---------------------------------------------------------------------
export function somenteDigitos(v){ return String(v ?? '').replace(/\D/g, ''); }

/** Chave de comparação: só dígitos, sem zeros à esquerda (EAN-13 x GTIN-14 x UPC-A). */
export function chaveGtin(v){ return somenteDigitos(v).replace(/^0+/, ''); }

/** Confere tamanho (8, 12, 13 ou 14) e dígito verificador. */
export function gtinValido(v){
  const d = String(v ?? '');
  if(!/^\d+$/.test(d) || ![8, 12, 13, 14].includes(d.length)) return false;
  let soma = 0;
  for(let i = 0; i < d.length - 1; i++){
    soma += Number(d[d.length - 2 - i]) * (i % 2 === 0 ? 3 : 1);
  }
  return (10 - (soma % 10)) % 10 === Number(d[d.length - 1]);
}

/** Formas equivalentes do mesmo código (com/sem zeros à esquerda) para consultar no banco. */
export function variantesGtin(v){
  const d = somenteDigitos(v);
  const base = d.replace(/^0+/, '');
  if(!base) return [];
  const conjunto = new Set([d]);
  [8, 12, 13, 14].forEach(n => { if(base.length <= n) conjunto.add(base.padStart(n, '0')); });
  return [...conjunto];
}

// ---------------------------------------------------------------------
// Utilitários gerais
// ---------------------------------------------------------------------
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[m]));

function semAcento(s){
  return String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

const pausa = () => new Promise(r => setTimeout(r, 0));

function letraColuna(i){
  let n = i + 1, s = '';
  while(n > 0){ const r = (n - 1) % 26; s = String.fromCharCode(65 + r) + s; n = Math.floor((n - 1) / 26); }
  return s;
}

/** Converte "1.234,56", "1234.56", "R$ 10,5" ou número em { v, erro, ambiguo }. */
function lerNumero(bruto){
  if(typeof bruto === 'number') return Number.isFinite(bruto) ? { v: bruto } : { erro: true };
  let t = String(bruto ?? '').trim().replace(/\s/g, '').replace(/^R\$/i, '');
  if(t === '') return { v: null };
  if(/[eE]/.test(t) && /^[-+]?\d+([.,]\d+)?[eE][-+]?\d+$/.test(t)){
    const n = Number(t.replace(',', '.'));
    return Number.isFinite(n) ? { v: n } : { erro: true };
  }
  if(!/^[-+]?[\d.,]+$/.test(t)) return { erro: true };
  let neg = false;
  if(t[0] === '-' || t[0] === '+'){ neg = t[0] === '-'; t = t.slice(1); }
  if(!/\d/.test(t)) return { erro: true };
  let ambiguo = false;
  const virgulas = (t.match(/,/g) || []).length;
  const pontos = (t.match(/\./g) || []).length;
  if(virgulas && pontos){
    if(t.lastIndexOf(',') > t.lastIndexOf('.')) t = t.replace(/\./g, '').replace(',', '.');
    else t = t.replace(/,/g, '');
  } else if(virgulas){
    t = virgulas > 1 ? t.replace(/,/g, '') : t.replace(',', '.');
  } else if(pontos){
    if(pontos > 1) t = t.replace(/\./g, '');
    else if(/^[1-9]\d{0,2}\.\d{3}$/.test(t)){ t = t.replace('.', ''); ambiguo = true; }
  }
  const n = Number(t);
  if(!Number.isFinite(n)) return { erro: true };
  return { v: neg ? -n : n, ambiguo };
}

const arredondar = (n, casas) => { const f = 10 ** casas; return Math.round((n + Number.EPSILON) * f) / f; };

// ---------------------------------------------------------------------
// Tipos de campo: cada um recebe o valor bruto da célula (não vazio) e
// devolve { valor } ou { erro } ou { valor, aviso }.
// ---------------------------------------------------------------------
const SINONIMOS_UNIDADE = {
  UNID: 'UN', UNIDADE: 'UN', UND: 'UN', UNIDADES: 'UN',
  CAIXA: 'CX', CAIXAS: 'CX', CXA: 'CX',
  FARDO: 'FD', FARDOS: 'FD', FDO: 'FD',
  PACOTE: 'PCT', PACOTES: 'PCT',
  LITRO: 'L', LITROS: 'L',
  QUILO: 'KG', QUILOS: 'KG', KILO: 'KG',
};

const TIPOS = {
  texto(b, c){
    const s = String(b).replace(/\s+/g, ' ').trim();
    if(c.max && s.length > c.max) return { erro: `${c.rotulo}: excede ${c.max} caracteres` };
    return { valor: s };
  },

  gtin(b, c){
    let s = String(b).trim();
    if(/^[-+]?\d+([.,]\d+)?e[-+]?\d+$/i.test(s)){
      return { erro: `${c.rotulo}: o Excel converteu o número para notação científica (${s}). Formate a coluna como Texto e exporte de novo` };
    }
    if(['sem gtin', 'sem ean', 'sem codigo', 'n a', 'na', 'nao tem', 'nao possui'].includes(semAcento(s)) || /^-+$/.test(s)) return { valor: null };
    s = s.replace(/[\s.\-]/g, '');
    if(!/^\d+$/.test(s)) return { erro: `${c.rotulo}: contém caracteres que não são números (“${String(b).slice(0, 30)}”)` };
    if(/^0+$/.test(s)) return { valor: null };
    if(![8, 12, 13, 14].includes(s.length)){
      return { erro: `${c.rotulo}: tem ${s.length} dígitos (esperado 8, 12, 13 ou 14)${s.length < 12 ? ' — pode ter perdido zeros à esquerda' : ''}` };
    }
    if(!gtinValido(s)) return { erro: `${c.rotulo}: dígito verificador inválido (${s})` };
    return { valor: s };
  },

  moeda(b, c){
    const n = lerNumero(b);
    if(n.erro) return { erro: `${c.rotulo}: valor numérico inválido (“${String(b).slice(0, 30)}”)` };
    if(n.v === null) return { valor: null };
    if(n.v < 0) return { erro: `${c.rotulo}: não pode ser negativo` };
    const r = { valor: arredondar(n.v, c.casas ?? 2) };
    if(n.ambiguo) r.aviso = `${c.rotulo}: “${b}” foi lido como ${r.valor} (ponto tratado como separador de milhar)`;
    return r;
  },

  quantidade(b, c){
    const n = lerNumero(b);
    if(n.erro) return { erro: `${c.rotulo}: quantidade inválida (“${String(b).slice(0, 30)}”)` };
    if(n.v === null) return { valor: null };
    if(n.v < 0) return { erro: `${c.rotulo}: não pode ser negativo` };
    const r = { valor: arredondar(n.v, c.casas ?? 4) };
    if(n.ambiguo) r.aviso = `${c.rotulo}: “${b}” foi lido como ${r.valor} (ponto tratado como separador de milhar)`;
    return r;
  },

  percentual(b, c){
    const n = lerNumero(String(b).replace('%', ''));
    if(n.erro) return { erro: `${c.rotulo}: valor inválido (“${String(b).slice(0, 30)}”)` };
    if(n.v === null) return { valor: null };
    if(n.v < 0 || n.v > 100) return { erro: `${c.rotulo}: deve estar entre 0 e 100` };
    return { valor: arredondar(n.v, 4) };
  },

  /** Somente dígitos, com tamanho fixo (ex.: NCM 8, CEST 7, CFOP 4). Nunca completa zeros por conta própria. */
  digitos(b, c){
    let s = typeof b === 'number' ? String(Math.trunc(b)) : String(b).trim();
    s = s.replace(/[.\-\/\s]/g, '');
    if(!/^\d+$/.test(s)) return { erro: `${c.rotulo}: deve conter apenas números (“${String(b).slice(0, 20)}”)` };
    const tamanhos = [].concat(c.tam || []);
    if(c.preencherZeros && tamanhos.length && s.length < Math.min(...tamanhos)) s = s.padStart(Math.min(...tamanhos), '0');
    // Célula NUMÉRICA do Excel perde o zero à esquerda (ex.: NCM 02011000 vira 2011000). Só nesse caso restaura,
    // e apenas quando o código tem tamanho fixo único; célula de TEXTO nunca é completada.
    let aviso = null;
    if(c.zerosDeNumero && typeof b === 'number' && tamanhos.length === 1 && s.length < tamanhos[0]){
      s = s.padStart(tamanhos[0], '0');
      aviso = `${c.rotulo}: a célula era um número (o Excel remove o zero à esquerda) — restaurado para ${s}`;
    }
    if(tamanhos.length && !tamanhos.includes(s.length)){
      return { erro: `${c.rotulo}: deve ter ${tamanhos.join(' ou ')} dígitos (veio com ${s.length})` };
    }
    return aviso ? { valor: s, aviso } : { valor: s };
  },

  unidade(b, c){
    let s = semAcento(b).toUpperCase().replace(/\s+/g, '');
    s = SINONIMOS_UNIDADE[s] || s;
    if(!s) return { valor: null };
    if(s.length > (c.max || 6)) return { erro: `${c.rotulo}: “${String(b).slice(0, 20)}” tem mais de ${(c.max || 6)} caracteres` };
    if(c.validas && c.validas.length && !c.validas.includes(s)){
      return { valor: s, aviso: `${c.rotulo}: “${s}” não está na lista de unidades do sistema — será importada como está` };
    }
    return { valor: s };
  },
};

// ---------------------------------------------------------------------
// Leitura de arquivos
// ---------------------------------------------------------------------
async function lerArquivo(arquivo){
  const nome = arquivo.name.toLowerCase();
  const buf = await arquivo.arrayBuffer();

  if(nome.endsWith('.csv') || nome.endsWith('.txt') || arquivo.type === 'text/csv'){
    return [{ nome: 'CSV', linhas: parseCsv(decodificarTexto(buf)) }];
  }
  if(nome.endsWith('.xlsx') || nome.endsWith('.xls') || nome.endsWith('.xlsm')){
    let XLSX;
    try {
      XLSX = await import(/* @vite-ignore */ SHEETJS_URL);
    } catch(e){
      throw new Error('Não foi possível carregar o leitor de planilhas Excel (verifique a conexão com a internet). Como alternativa, salve o arquivo como CSV e tente novamente.');
    }
    let wb;
    try {
      wb = XLSX.read(new Uint8Array(buf), { type: 'array' });
    } catch(e){
      throw new Error('Não foi possível ler este arquivo Excel. Ele pode estar corrompido ou protegido por senha.');
    }
    return wb.SheetNames.map(n => ({
      nome: n,
      linhas: XLSX.utils.sheet_to_json(wb.Sheets[n], { header: 1, raw: true, defval: '', blankrows: true, range: 0 }),
    })).filter(p => p.linhas.length > 0);
  }
  throw new Error('Formato não suportado. Envie um arquivo .xlsx, .xls ou .csv.');
}

function decodificarTexto(buf){
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf).replace(/^﻿/, '');
  } catch(e){
    return new TextDecoder('windows-1252').decode(buf); // exportações antigas em ANSI
  }
}

function parseCsv(texto){
  // delimitador: o mais frequente na primeira linha "de verdade"
  const primeira = texto.split(/\r?\n/).find(l => l.trim() !== '') || '';
  const cont = (ch) => (primeira.match(new RegExp(ch === '\t' ? '\\t' : '\\' + ch, 'g')) || []).length;
  const cand = [[';', cont(';')], [',', cont(',')], ['\t', cont('\t')]].sort((a, b) => b[1] - a[1]);
  const delim = cand[0][1] > 0 ? cand[0][0] : ';';

  const linhas = [];
  let linha = [], campo = '', aspas = false;
  for(let i = 0; i < texto.length; i++){
    const ch = texto[i];
    if(aspas){
      if(ch === '"'){
        if(texto[i + 1] === '"'){ campo += '"'; i++; } else aspas = false;
      } else campo += ch;
    } else if(ch === '"' && campo === ''){
      aspas = true;
    } else if(ch === delim){
      linha.push(campo); campo = '';
    } else if(ch === '\n' || ch === '\r'){
      if(ch === '\r' && texto[i + 1] === '\n') i++;
      linha.push(campo); campo = '';
      linhas.push(linha); linha = [];
    } else campo += ch;
  }
  if(campo !== '' || linha.length){ linha.push(campo); linhas.push(linha); }
  return linhas;
}

function linhaVazia(l){ return !l || l.every(c => c === '' || c === null || c === undefined || (typeof c === 'string' && c.trim() === '')); }

/** Descobre a linha do cabeçalho: a primeira linha "cheia" entre as 20 primeiras. */
function detectarCabecalho(linhas){
  const amostra = linhas.slice(0, 20).map(l => (l || []).filter(c => String(c ?? '').trim() !== '').length);
  const max = Math.max(0, ...amostra);
  const alvo = Math.max(2, Math.ceil(max * 0.6));
  const idx = amostra.findIndex(n => n >= alvo);
  return idx >= 0 ? idx + 1 : 1; // 1-based
}

function csvEscapar(v){
  let s = String(v ?? '');
  if(/^[=+\-@\t\r]/.test(s)) s = "'" + s; // evita "injeção de fórmula" ao abrir no Excel
  return /[";\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

function baixarCsv(nome, linhas){
  const conteudo = '﻿' + linhas.map(l => l.map(csvEscapar).join(';')).join('\r\n');
  const url = URL.createObjectURL(new Blob([conteudo], { type: 'text/csv;charset=utf-8' }));
  const a = document.createElement('a');
  a.href = url; a.download = nome;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

// ---------------------------------------------------------------------
// Estilos (prefixo imp-; usam as variáveis de cor do sistema quando existem)
// ---------------------------------------------------------------------
function injetarEstilos(){
  if(document.getElementById('imp-estilos')) return;
  const st = document.createElement('style');
  st.id = 'imp-estilos';
  st.textContent = `
  .imp-overlay{ position:fixed; inset:0; z-index:9000; background:rgba(11,23,48,0.55); display:flex; align-items:center; justify-content:center; padding:18px; font-family: var(--font-body, system-ui, sans-serif); }
  .imp-card{ background: var(--card,#fff); color: var(--ink,#16233F); width:100%; max-width:1040px; max-height:calc(100vh - 36px); border-radius:14px; display:flex; flex-direction:column; box-shadow:0 20px 60px rgba(0,0,0,0.3); overflow:hidden; }
  .imp-head{ display:flex; align-items:center; justify-content:space-between; gap:12px; padding:16px 22px; border-bottom:1px solid var(--border,#DDE1EA); }
  .imp-head h3{ margin:0; font-size:18px; }
  .imp-x{ background:none; border:none; font-size:24px; line-height:1; cursor:pointer; color: var(--ink-soft,#4A5670); padding:4px 8px; }
  .imp-steps{ display:flex; gap:6px; padding:12px 22px 0; flex-wrap:wrap; }
  .imp-step{ font-size:12px; font-weight:700; padding:5px 12px; border-radius:999px; background:#EEF0F5; color: var(--ink-soft,#4A5670); }
  .imp-step.on{ background: var(--accent,#F3C623); color: var(--ink,#16233F); }
  .imp-step.ok{ background: var(--teal-soft,#DDEEE9); color: var(--teal,#2C6E60); }
  .imp-body{ padding:18px 22px; overflow:auto; flex:1; min-height:200px; }
  .imp-foot{ display:flex; align-items:center; justify-content:space-between; gap:10px; flex-wrap:wrap; padding:14px 22px; border-top:1px solid var(--border,#DDE1EA); background:#FAFBFC; }
  .imp-foot .imp-acoes{ display:flex; gap:10px; flex-wrap:wrap; margin-left:auto; }
  .imp-btn{ border:1px solid var(--border,#DDE1EA); background:#fff; color: var(--ink,#16233F); border-radius:8px; padding:9px 16px; font-size:14px; font-weight:600; cursor:pointer; font-family:inherit; }
  .imp-btn.pri{ background: var(--accent,#F3C623); border-color: var(--accent,#F3C623); }
  .imp-btn.perigo{ background: var(--danger,#B84B3C); border-color: var(--danger,#B84B3C); color:#fff; }
  .imp-btn:disabled{ opacity:0.5; cursor:not-allowed; }
  .imp-drop{ border:2px dashed var(--border,#DDE1EA); border-radius:12px; padding:38px 20px; text-align:center; cursor:pointer; background:#FAFBFC; }
  .imp-drop.sobre{ border-color: var(--accent,#F3C623); background: var(--accent-soft,#FDF3CF); }
  .imp-drop strong{ display:block; font-size:16px; margin-bottom:6px; }
  .imp-mut{ color: var(--ink-soft,#4A5670); font-size:13px; }
  .imp-msg{ padding:10px 14px; border-radius:8px; font-size:13px; margin:0 0 12px; }
  .imp-msg.erro{ background: var(--danger-soft,#F6DFDA); color: var(--danger,#B84B3C); }
  .imp-msg.info{ background:#EAF1FB; color:#2C4A66; }
  .imp-msg.aviso{ background: var(--accent-soft,#FDF3CF); }
  .imp-msg.ok{ background: var(--teal-soft,#DDEEE9); color: var(--teal,#2C6E60); }
  .imp-tabela{ width:100%; border-collapse:collapse; font-size:13px; }
  .imp-tabela th{ text-align:left; font-size:11px; text-transform:uppercase; letter-spacing:.03em; color: var(--ink-soft,#4A5670); padding:8px 10px; border-bottom:1px solid var(--border,#DDE1EA); background:#FAFBFC; position:sticky; top:0; }
  .imp-tabela td{ padding:8px 10px; border-bottom:1px solid #EEF0F5; vertical-align:top; }
  .imp-tabela select, .imp-linha-cab input{ width:100%; padding:7px 8px; border:1px solid var(--border,#DDE1EA); border-radius:7px; font-size:13px; font-family:inherit; background:#fff; }
  .imp-grupo td{ background:#F3F5F9; font-weight:700; font-size:12px; text-transform:uppercase; letter-spacing:.03em; color: var(--ink-soft,#4A5670); }
  .imp-req{ color: var(--danger,#B84B3C); font-weight:700; }
  .imp-tag{ display:inline-block; font-size:11px; font-weight:700; padding:2px 8px; border-radius:999px; background:#EEF0F5; color: var(--ink-soft,#4A5670); }
  .imp-tag.sug{ background:#EAF1FB; color:#2C4A66; }
  .imp-cards{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:10px; margin-bottom:14px; }
  .imp-cartao{ border:1px solid var(--border,#DDE1EA); border-radius:10px; padding:10px 12px; background:#fff; }
  .imp-cartao .n{ font-size:22px; font-weight:800; display:block; }
  .imp-cartao .r{ font-size:12px; color: var(--ink-soft,#4A5670); }
  .imp-cartao.novo .n{ color: var(--teal,#2C6E60); }
  .imp-cartao.erro .n{ color: var(--danger,#B84B3C); }
  .imp-cartao.dup .n{ color:#9A6B00; }
  .imp-filtros{ display:flex; gap:6px; flex-wrap:wrap; margin:10px 0; }
  .imp-chip{ border:1px solid var(--border,#DDE1EA); background:#fff; border-radius:999px; padding:5px 12px; font-size:12px; font-weight:600; cursor:pointer; font-family:inherit; }
  .imp-chip.on{ background: var(--ink,#16233F); color:#fff; border-color: var(--ink,#16233F); }
  .imp-scroll{ max-height:320px; overflow:auto; border:1px solid var(--border,#DDE1EA); border-radius:10px; }
  .imp-st{ font-size:11px; font-weight:700; padding:2px 8px; border-radius:999px; white-space:nowrap; }
  .imp-st.novo{ background: var(--teal-soft,#DDEEE9); color: var(--teal,#2C6E60); }
  .imp-st.aviso{ background: var(--accent-soft,#FDF3CF); color:#7A5A00; }
  .imp-st.erro{ background: var(--danger-soft,#F6DFDA); color: var(--danger,#B84B3C); }
  .imp-st.existente, .imp-st.repetido{ background:#EEF0F5; color: var(--ink-soft,#4A5670); }
  .imp-barra{ height:12px; background:#EEF0F5; border-radius:999px; overflow:hidden; margin:14px 0 6px; }
  .imp-barra > div{ height:100%; width:0; background: var(--teal,#2C6E60); transition:width .2s; }
  .imp-linha-cab{ display:flex; gap:14px; align-items:flex-end; flex-wrap:wrap; margin-bottom:14px; }
  .imp-linha-cab label{ font-size:12px; font-weight:700; display:block; margin-bottom:4px; }
  .imp-linha-cab select{ padding:7px 8px; border:1px solid var(--border,#DDE1EA); border-radius:7px; font-size:13px; }
  .imp-linha-cab input{ width:80px; }
  .imp-link{ background:none; border:none; padding:0; color:#2C4A9A; text-decoration:underline; cursor:pointer; font-size:13px; font-family:inherit; }
  @media (max-width:700px){ .imp-overlay{ padding:0; } .imp-card{ max-height:100vh; border-radius:0; } }
  `;
  document.head.appendChild(st);
}

// ---------------------------------------------------------------------
// Importador
// ---------------------------------------------------------------------
export function abrirImportador(config){
  const cfg = {
    titulo: 'Importar',
    nomeModelo: 'modelo-importacao.csv',
    tamanhoLote: TAMANHO_LOTE_PADRAO,
    limiteLinhas: LIMITE_LINHAS_PADRAO,
    chavesDuplicidade: [],
    ...config,
  };

  injetarEstilos();

  const est = {
    etapa: 1,            // 1 arquivo, 2 mapeamento, 3 conferência, 4 importação
    arquivo: null,
    planilhas: [],
    planilhaIdx: 0,
    linhaCab: 1,
    mapeamento: {},      // chave -> índice da coluna (-1 = não importar)
    sugeridos: new Set(),
    resultado: null,     // { linhas, resumo }
    filtro: 'todos',
    erroGlobal: '',
    carregando: '',
    confirmando: false,
    importando: false,
    cancelar: false,
    final: null,
    validacaoOk: false,
  };

  const overlay = document.createElement('div');
  overlay.className = 'imp-overlay';
  overlay.setAttribute('role', 'dialog');
  overlay.setAttribute('aria-modal', 'true');
  overlay.innerHTML = `
    <div class="imp-card">
      <div class="imp-head"><h3>${esc(cfg.titulo)}</h3><button type="button" class="imp-x" aria-label="Fechar">×</button></div>
      <div class="imp-steps"></div>
      <div class="imp-body"></div>
      <div class="imp-foot"></div>
    </div>`;
  document.body.appendChild(overlay);
  const elSteps = overlay.querySelector('.imp-steps');
  const elBody = overlay.querySelector('.imp-body');
  const elFoot = overlay.querySelector('.imp-foot');

  const fechar = (forcar) => {
    if(est.importando) return;
    const temProgresso = est.arquivo && est.etapa < 4 && !forcar;
    if(temProgresso && !window.confirm('Sair da importação? O que foi configurado até aqui será perdido (nada foi gravado).')) return;
    document.removeEventListener('keydown', aoTeclar);
    overlay.remove();
  };
  const aoTeclar = (e) => { if(e.key === 'Escape') fechar(); };
  document.addEventListener('keydown', aoTeclar);
  overlay.querySelector('.imp-x').addEventListener('click', () => fechar());

  // ---------- dados derivados ----------
  const planilha = () => est.planilhas[est.planilhaIdx];
  const cabecalhos = () => {
    const linha = (planilha()?.linhas[est.linhaCab - 1]) || [];
    const n = Math.max(linha.length, ...planilha().linhas.slice(est.linhaCab, est.linhaCab + 50).map(l => l.length), 0);
    return Array.from({ length: n }, (_, i) => {
      const t = String(linha[i] ?? '').trim();
      return t || `(coluna ${letraColuna(i)} sem título)`;
    });
  };
  const linhasDados = () => planilha().linhas.slice(est.linhaCab);       // índice 0 = linha (linhaCab + 1)
  const numeroLinha = (i) => est.linhaCab + 1 + i;                        // como aparece no Excel

  function sugerirMapeamento(){
    const cab = cabecalhos().map(semAcento);
    const pares = [];
    cfg.campos.forEach(c => {
      const nomes = [c.rotulo, c.chave, ...(c.apelidos || [])].map(semAcento).filter(Boolean);
      cab.forEach((h, idx) => {
        if(!h) return;
        let melhor = 0;
        nomes.forEach(n => {
          if(h === n) melhor = Math.max(melhor, 3);
          else if(n.length >= 6 && (h.includes(n) || n.includes(h) && h.length >= 6)) melhor = Math.max(melhor, 2);
        });
        if(melhor) pares.push({ chave: c.chave, idx, pontos: melhor });
      });
    });
    pares.sort((a, b) => b.pontos - a.pontos);
    const usadosCampos = new Set(), usadasCols = new Set();
    est.mapeamento = {}; est.sugeridos = new Set();
    cfg.campos.forEach(c => { est.mapeamento[c.chave] = -1; });
    pares.forEach(p => {
      if(usadosCampos.has(p.chave) || usadasCols.has(p.idx)) return;
      est.mapeamento[p.chave] = p.idx; est.sugeridos.add(p.chave);
      usadosCampos.add(p.chave); usadasCols.add(p.idx);
    });
  }

  function mapeamentoProblemas(){
    const problemas = [];
    const usos = {};
    cfg.campos.forEach(c => {
      const idx = est.mapeamento[c.chave];
      if(idx >= 0){ (usos[idx] = usos[idx] || []).push(c); }
      if(c.obrigatorio && (idx === undefined || idx < 0)) problemas.push(`Informe a coluna de “${c.rotulo}”.`);
    });
    Object.entries(usos).forEach(([idx, lista]) => {
      if(lista.length > 1) problemas.push(`A coluna “${cabecalhos()[idx]}” está sendo usada em mais de um campo (${lista.map(c => c.rotulo).join(', ')}).`);
    });
    return problemas;
  }

  // ---------- renderização ----------
  function render(){
    const nomes = ['Arquivo', 'Mapeamento', 'Conferência', 'Importação'];
    elSteps.innerHTML = nomes.map((n, i) => `<span class="imp-step ${est.etapa === i + 1 ? 'on' : (est.etapa > i + 1 ? 'ok' : '')}">${i + 1}. ${n}</span>`).join('');
    if(est.etapa === 1) renderArquivo();
    else if(est.etapa === 2) renderMapeamento();
    else if(est.etapa === 3) renderConferencia();
    else renderImportacao();
  }

  function rodape(esq, botoes){
    elFoot.innerHTML = `<div>${esq || ''}</div><div class="imp-acoes">${botoes || ''}</div>`;
  }

  // ----- etapa 1: arquivo -----
  function renderArquivo(){
    elBody.innerHTML = `
      ${est.erroGlobal ? `<div class="imp-msg erro">${esc(est.erroGlobal)}</div>` : ''}
      ${est.carregando ? `<div class="imp-msg info">${esc(est.carregando)}</div>` : ''}
      <div class="imp-drop" id="imp-drop" tabindex="0">
        <strong>Clique para escolher o arquivo ou arraste-o até aqui</strong>
        <span class="imp-mut">Excel (.xlsx, .xls) ou CSV — exportado do sistema antigo. Até ${cfg.limiteLinhas.toLocaleString('pt-BR')} linhas.</span>
        <input type="file" id="imp-arquivo" accept=".xlsx,.xls,.xlsm,.csv,.txt,text/csv" style="display:none;">
      </div>
      <p class="imp-mut" style="margin-top:14px;">Nas próximas etapas você vai indicar qual coluna do arquivo corresponde a cada campo — os nomes das colunas não precisam ser iguais aos do sistema.
      Nada é gravado até você confirmar, e registros já cadastrados nunca são alterados.</p>
      <p><button type="button" class="imp-link" id="imp-modelo">Baixar planilha modelo (CSV com os nomes dos campos)</button></p>`;
    rodape('', `<button type="button" class="imp-btn" id="imp-cancelar">Cancelar</button>`);
    const drop = elBody.querySelector('#imp-drop');
    const input = elBody.querySelector('#imp-arquivo');
    drop.addEventListener('click', () => input.click());
    drop.addEventListener('keydown', (e) => { if(e.key === 'Enter' || e.key === ' '){ e.preventDefault(); input.click(); } });
    drop.addEventListener('dragover', (e) => { e.preventDefault(); drop.classList.add('sobre'); });
    drop.addEventListener('dragleave', () => drop.classList.remove('sobre'));
    drop.addEventListener('drop', (e) => { e.preventDefault(); drop.classList.remove('sobre'); if(e.dataTransfer.files[0]) escolherArquivo(e.dataTransfer.files[0]); });
    input.addEventListener('change', () => { if(input.files[0]) escolherArquivo(input.files[0]); });
    elBody.querySelector('#imp-modelo').addEventListener('click', () => baixarCsv(cfg.nomeModelo, [cfg.campos.map(c => c.rotulo)]));
    elFoot.querySelector('#imp-cancelar').addEventListener('click', () => fechar());
  }

  async function escolherArquivo(arquivo){
    est.erroGlobal = ''; est.carregando = 'Lendo o arquivo…'; renderArquivo();
    try {
      const planilhas = await lerArquivo(arquivo);
      if(planilhas.length === 0 || planilhas.every(p => p.linhas.every(linhaVazia))) throw new Error('O arquivo está vazio.');
      const tot = Math.max(...planilhas.map(p => p.linhas.length));
      if(tot > cfg.limiteLinhas + 50) throw new Error(`O arquivo tem ${tot.toLocaleString('pt-BR')} linhas; o limite por importação é ${cfg.limiteLinhas.toLocaleString('pt-BR')}. Divida o arquivo em partes.`);
      est.arquivo = arquivo; est.planilhas = planilhas;
      est.planilhaIdx = planilhas.findIndex(p => p.linhas.length > 1) >= 0 ? planilhas.findIndex(p => p.linhas.length > 1) : 0;
      est.linhaCab = detectarCabecalho(planilha().linhas);
      sugerirMapeamento();
      est.carregando = ''; est.etapa = 2; render();
    } catch(e){
      est.carregando = ''; est.erroGlobal = e.message || String(e); renderArquivo();
    }
  }

  // ----- etapa 2: mapeamento -----
  function renderMapeamento(){
    const cab = cabecalhos();
    const dados = linhasDados();
    const totalLinhas = dados.filter(l => !linhaVazia(l)).length;
    const amostra = (idx) => {
      for(let i = 0; i < Math.min(dados.length, 200); i++){
        const v = dados[i]?.[idx];
        if(v !== '' && v !== undefined && v !== null && String(v).trim() !== '') return String(v).slice(0, 40);
      }
      return '';
    };
    const opcoes = (sel) => `<option value="-1">— não importar —</option>` + cab.map((h, i) => `<option value="${i}" ${sel === i ? 'selected' : ''}>${esc(h)} (${letraColuna(i)})</option>`).join('');
    let grupoAtual = null, linhasTab = '';
    cfg.campos.forEach(c => {
      if(c.grupo && c.grupo !== grupoAtual){ grupoAtual = c.grupo; linhasTab += `<tr class="imp-grupo"><td colspan="3">${esc(c.grupo)}</td></tr>`; }
      const idx = est.mapeamento[c.chave];
      linhasTab += `<tr>
        <td><strong>${esc(c.rotulo)}</strong>${c.obrigatorio ? ' <span class="imp-req">*</span>' : ''}${c.dica ? `<div class="imp-mut">${esc(c.dica)}</div>` : ''}</td>
        <td><select data-campo="${esc(c.chave)}">${opcoes(idx)}</select> ${est.sugeridos.has(c.chave) && idx >= 0 ? '<span class="imp-tag sug">sugerido</span>' : ''}</td>
        <td class="imp-mut" data-amostra="${esc(c.chave)}">${idx >= 0 ? esc(amostra(idx)) : ''}</td>
      </tr>`;
    });
    const planilhaSel = est.planilhas.length > 1
      ? `<div><label>Planilha (aba)</label><select id="imp-aba">${est.planilhas.map((p, i) => `<option value="${i}" ${i === est.planilhaIdx ? 'selected' : ''}>${esc(p.nome)}</option>`).join('')}</select></div>` : '';
    elBody.innerHTML = `
      <div class="imp-msg info"><strong>${esc(est.arquivo.name)}</strong> — ${totalLinhas.toLocaleString('pt-BR')} linha(s) de dados encontradas. Confira a linha do cabeçalho e indique a coluna de cada campo. Campos com * são obrigatórios; os demais podem ficar “não importar” e serão gravados vazios.</div>
      <div class="imp-linha-cab">
        ${planilhaSel}
        <div><label>Linha do cabeçalho</label><input type="number" id="imp-linha-cab" min="1" max="${Math.min(planilha().linhas.length, 500)}" value="${est.linhaCab}"></div>
      </div>
      <div id="imp-problemas"></div>
      <div class="imp-scroll" style="max-height:none;"><table class="imp-tabela"><thead><tr><th style="width:32%">Campo do sistema</th><th style="width:40%">Coluna do arquivo</th><th>Exemplo (1º valor preenchido)</th></tr></thead><tbody>${linhasTab}</tbody></table></div>`;
    atualizarProblemasMapeamento();
    rodape('', `<button type="button" class="imp-btn" id="imp-voltar">← Trocar arquivo</button><button type="button" class="imp-btn pri" id="imp-validar">Validar e ver prévia →</button>`);

    elBody.querySelectorAll('select[data-campo]').forEach(sel => sel.addEventListener('change', () => {
      const chave = sel.dataset.campo;
      est.mapeamento[chave] = Number(sel.value); est.sugeridos.delete(chave);
      const cel = elBody.querySelector(`[data-amostra="${chave}"]`);
      cel.textContent = Number(sel.value) >= 0 ? amostra(Number(sel.value)) : '';
      sel.parentElement.querySelector('.imp-tag')?.remove();
      atualizarProblemasMapeamento();
    }));
    elBody.querySelector('#imp-linha-cab').addEventListener('change', (e) => {
      const n = Math.max(1, Math.min(parseInt(e.target.value, 10) || 1, planilha().linhas.length));
      est.linhaCab = n; sugerirMapeamento(); renderMapeamento();
    });
    elBody.querySelector('#imp-aba')?.addEventListener('change', (e) => {
      est.planilhaIdx = Number(e.target.value); est.linhaCab = detectarCabecalho(planilha().linhas); sugerirMapeamento(); renderMapeamento();
    });
    elFoot.querySelector('#imp-voltar').addEventListener('click', () => { est.etapa = 1; est.arquivo = null; render(); });
    elFoot.querySelector('#imp-validar').addEventListener('click', () => { if(mapeamentoProblemas().length === 0) validar(); });
  }

  function atualizarProblemasMapeamento(){
    const p = mapeamentoProblemas();
    const el = elBody.querySelector('#imp-problemas');
    if(el) el.innerHTML = p.length ? `<div class="imp-msg aviso">${p.map(esc).join('<br>')}</div>` : '';
    const btn = elFoot.querySelector('#imp-validar');
    if(btn) btn.disabled = p.length > 0;
  }

  // ----- validação -----
  async function validar(){
    est.etapa = 3; est.resultado = null; est.erroGlobal = ''; est.confirmando = false; est.filtro = 'todos'; est.validacaoOk = false;
    elSteps.querySelectorAll('.imp-step').forEach((s, i) => { s.className = 'imp-step ' + (i + 1 === 3 ? 'on' : (i + 1 < 3 ? 'ok' : '')); });
    elBody.innerHTML = `<div class="imp-msg info" id="imp-progresso-txt">Validando as linhas…</div><div class="imp-barra"><div id="imp-progresso"></div></div>`;
    rodape('', '');
    const setProg = (txt, pct) => {
      const t = elBody.querySelector('#imp-progresso-txt'); if(t) t.textContent = txt;
      const b = elBody.querySelector('#imp-progresso'); if(b) b.style.width = Math.round(pct) + '%';
    };

    const dados = linhasDados();
    const linhas = [];
    let vazias = 0;
    const camposMapeados = cfg.campos.filter(c => est.mapeamento[c.chave] >= 0);

    // 1) conversão e validação linha a linha (local)
    for(let i = 0; i < dados.length; i++){
      const bruta = dados[i];
      if(linhaVazia(bruta)){ vazias++; continue; }
      const reg = { n: numeroLinha(i), bruta, dados: {}, erros: [], avisos: [], status: 'novo', existentes: [], repetidaDe: null };
      camposMapeados.forEach(c => {
        const b = bruta[est.mapeamento[c.chave]];
        const r = validarCampo(c, b);
        if(r.vazio){ reg.dados[c.chave] = null; if(c.obrigatorio) reg.erros.push(`${c.rotulo}: vazio (obrigatório)`); return; }
        reg.dados[c.chave] = r.valor ?? null;
        if(r.erro) reg.erros.push(r.erro);
        if(r.aviso) reg.avisos.push(r.aviso);
      });
      cfg.campos.forEach(c => { if(!(c.chave in reg.dados)) reg.dados[c.chave] = null; });
      if(reg.erros.length === 0){
        const semChaves = cfg.chavesDuplicidade.length > 0 && cfg.chavesDuplicidade.every(k => !chaveDe(k, reg.dados[k.campo]));
        if(semChaves) reg.avisos.push(`Sem ${cfg.chavesDuplicidade.map(k => k.rotulo).join(' nem ')} — não será possível detectar duplicidade desta linha no futuro`);
        if(cfg.validarLinha){
          const extra = cfg.validarLinha(reg.dados) || {};
          (extra.erros || []).forEach(m => reg.erros.push(m));
          (extra.avisos || []).forEach(m => reg.avisos.push(m));
        }
      }
      if(reg.erros.length) reg.status = 'erro';
      else if(reg.avisos.length) reg.status = 'aviso';
      linhas.push(reg);
      if(i % 4000 === 3999){ setProg(`Validando as linhas… ${i + 1} de ${dados.length}`, (i / dados.length) * 40); await pausa(); }
    }

    // 2) repetidas dentro do próprio arquivo
    setProg('Procurando repetições dentro do arquivo…', 45);
    const vistos = cfg.chavesDuplicidade.map(() => new Map());
    linhas.forEach(reg => {
      if(reg.status === 'erro') return;
      for(let k = 0; k < cfg.chavesDuplicidade.length; k++){
        const def = cfg.chavesDuplicidade[k];
        const ch = chaveDe(def, reg.dados[def.campo]);
        if(!ch) continue;
        if(vistos[k].has(ch)){
          reg.status = 'repetido'; reg.repetidaDe = vistos[k].get(ch);
          reg.erros = []; reg.avisos = [];
          reg.msgRepetido = `Repetido no arquivo (mesmo ${def.rotulo}: ${reg.dados[def.campo]}) — igual à linha ${reg.repetidaDe}`;
          return;
        }
      }
      cfg.chavesDuplicidade.forEach((def, k) => {
        const ch = chaveDe(def, reg.dados[def.campo]);
        if(ch) vistos[k].set(ch, reg.n);
      });
    });

    // 3) consulta no servidor: quais já existem (só chaves, em lotes)
    const candidatos = linhas.filter(r => r.status === 'novo' || r.status === 'aviso');
    const chaves = {};
    cfg.chavesDuplicidade.forEach(def => {
      chaves[def.campo] = [...new Set(candidatos.map(r => chaveDe(def, r.dados[def.campo])).filter(Boolean))];
    });
    const totalChaves = Object.values(chaves).reduce((s, l) => s + l.length, 0);
    let existentes = [];
    if(totalChaves > 0 && cfg.consultarExistentes){
      setProg(`Verificando ${totalChaves.toLocaleString('pt-BR')} código(s) já cadastrados…`, 50);
      try {
        existentes = await cfg.consultarExistentes(chaves, {
          aoProgredir: (feito, total) => setProg(`Verificando duplicidades no cadastro… ${feito} de ${total}`, 50 + (feito / Math.max(total, 1)) * 48),
        }) || [];
      } catch(e){
        est.erroGlobal = 'Não foi possível verificar os cadastros existentes: ' + (e.message || e) + ' — por segurança a importação foi bloqueada para não gerar duplicidades.';
        est.resultado = null; est.validacaoOk = false;
        return renderConferencia();
      }
    }
    const indices = cfg.chavesDuplicidade.map(def => {
      const m = new Map();
      existentes.forEach(ex => { const ch = chaveDe(def, ex[def.campo]); if(ch){ (m.get(ch) || m.set(ch, []).get(ch)).push(ex); } });
      return m;
    });
    candidatos.forEach(reg => {
      const achados = new Map();
      cfg.chavesDuplicidade.forEach((def, k) => {
        const ch = chaveDe(def, reg.dados[def.campo]);
        (indices[k].get(ch) || []).forEach(ex => { if(!achados.has(ex.id ?? ex)) achados.set(ex.id ?? ex, { ex, por: def.rotulo }); });
      });
      if(achados.size){
        reg.status = 'existente';
        reg.existentes = [...achados.values()];
      }
    });

    est.validacaoOk = true;
    est.resultado = { linhas, vazias };
    renderConferencia();
  }

  function chaveDe(def, valor){
    if(valor === null || valor === undefined || valor === '') return '';
    return def.normalizar ? String(def.normalizar(valor) ?? '') : String(valor).trim();
  }

  function validarCampo(campo, bruto){
    const vazio = bruto === '' || bruto === null || bruto === undefined || (typeof bruto === 'string' && bruto.trim() === '');
    if(vazio) return { vazio: true };
    const fn = TIPOS[campo.tipo] || TIPOS.texto;
    return fn(bruto, campo);
  }

  // ----- etapa 3: conferência -----
  const ROTULO_STATUS = { novo: 'Novo', aviso: 'Novo (com aviso)', erro: 'Erro', existente: 'Já cadastrado', repetido: 'Repetido no arquivo' };
  const CLASSE_STATUS = { novo: 'novo', aviso: 'aviso', erro: 'erro', existente: 'existente', repetido: 'repetido' };

  function contar(){
    const c = { novo: 0, aviso: 0, erro: 0, existente: 0, repetido: 0 };
    est.resultado.linhas.forEach(r => { c[r.status]++; });
    return c;
  }

  function mensagemDaLinha(r){
    if(r.status === 'repetido') return r.msgRepetido;
    if(r.status === 'existente'){
      return r.existentes.map(({ ex, por }) => `Mesmo ${por} de “${ex.nome ?? ex.descricao ?? '—'}”${ex.codigo ? ` (cód. ${ex.codigo})` : ''}`).join(' | ');
    }
    return [...r.erros, ...r.avisos].join(' | ');
  }

  function renderConferencia(){
    if(!est.resultado){
      elBody.innerHTML = `<div class="imp-msg erro">${esc(est.erroGlobal || 'Erro na validação.')}</div>`;
      rodape('', `<button type="button" class="imp-btn" id="imp-ajustar">← Ajustar mapeamento</button><button type="button" class="imp-btn pri" id="imp-tentar">Tentar novamente</button>`);
      elFoot.querySelector('#imp-ajustar').addEventListener('click', () => { est.etapa = 2; est.erroGlobal = ''; render(); });
      elFoot.querySelector('#imp-tentar').addEventListener('click', () => { est.erroGlobal = ''; validar(); });
      return;
    }
    const c = contar();
    const aImportar = c.novo + c.aviso;
    const filtros = [['todos', 'Todas'], ['novo', 'Novas'], ['aviso', 'Com aviso'], ['erro', 'Com erro'], ['existente', 'Já cadastradas'], ['repetido', 'Repetidas no arquivo']];
    const lista = est.resultado.linhas.filter(r => est.filtro === 'todos' || r.status === est.filtro);
    const visiveis = lista.slice(0, 200);
    const camposTabela = cfg.campos.filter(cp => est.mapeamento[cp.chave] >= 0 && cp.exibirNaPrevia !== false).slice(0, 6);
    const naoMapeadosFiscais = cfg.campos.filter(cp => cp.grupo && /fisca/i.test(cp.grupo) && !(est.mapeamento[cp.chave] >= 0));
    const fmt = (cp, v) => v === null || v === undefined ? '<span class="imp-mut">—</span>' : esc(cp.tipo === 'moeda' ? Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' }) : v);

    elBody.innerHTML = `
      ${est.erroGlobal ? `<div class="imp-msg erro">${esc(est.erroGlobal)}</div>` : ''}
      <div class="imp-cards">
        <div class="imp-cartao"><span class="n">${(c.novo + c.aviso + c.erro + c.existente + c.repetido).toLocaleString('pt-BR')}</span><span class="r">linhas lidas${est.resultado.vazias ? ` (+${est.resultado.vazias} vazias ignoradas)` : ''}</span></div>
        <div class="imp-cartao novo"><span class="n">${aImportar.toLocaleString('pt-BR')}</span><span class="r">serão criadas${c.aviso ? ` (${c.aviso} com aviso)` : ''}</span></div>
        <div class="imp-cartao erro"><span class="n">${c.erro.toLocaleString('pt-BR')}</span><span class="r">com erro (não serão importadas)</span></div>
        <div class="imp-cartao dup"><span class="n">${c.existente.toLocaleString('pt-BR')}</span><span class="r">já cadastradas (não serão alteradas)</span></div>
        <div class="imp-cartao dup"><span class="n">${c.repetido.toLocaleString('pt-BR')}</span><span class="r">repetidas no arquivo (ignoradas)</span></div>
      </div>
      ${naoMapeadosFiscais.length ? `<div class="imp-msg info">Campos não mapeados que ficarão <strong>vazios</strong> para conferência posterior: ${naoMapeadosFiscais.map(cp => esc(cp.rotulo)).join(', ')}. Nada é preenchido automaticamente.</div>` : ''}
      <div class="imp-filtros">${filtros.map(([k, r]) => `<button type="button" class="imp-chip ${est.filtro === k ? 'on' : ''}" data-filtro="${k}">${r}${k !== 'todos' ? ` (${(k === 'novo' ? c.novo : c[k]).toLocaleString('pt-BR')})` : ''}</button>`).join('')}</div>
      <div class="imp-scroll"><table class="imp-tabela">
        <thead><tr><th>Linha</th><th>Situação</th>${camposTabela.map(cp => `<th>${esc(cp.rotulo)}</th>`).join('')}<th>Detalhe</th></tr></thead>
        <tbody>${visiveis.map(r => `<tr>
          <td>${r.n}</td>
          <td><span class="imp-st ${CLASSE_STATUS[r.status]}">${ROTULO_STATUS[r.status]}</span></td>
          ${camposTabela.map(cp => `<td>${fmt(cp, r.dados[cp.chave])}</td>`).join('')}
          <td class="imp-mut">${esc(mensagemDaLinha(r))}</td>
        </tr>`).join('') || `<tr><td colspan="${camposTabela.length + 3}" class="imp-mut" style="padding:18px;">Nenhuma linha neste filtro.</td></tr>`}</tbody>
      </table></div>
      ${lista.length > visiveis.length ? `<p class="imp-mut">Mostrando as primeiras ${visiveis.length} de ${lista.length.toLocaleString('pt-BR')} linhas. Use “Baixar problemas” para ver tudo.</p>` : ''}
      ${est.confirmando ? `<div class="imp-msg aviso" style="margin-top:12px;"><strong>Confirmar importação?</strong> Serão criados <strong>${aImportar.toLocaleString('pt-BR')}</strong> registro(s) novo(s). ${c.erro + c.existente + c.repetido > 0 ? `${(c.erro + c.existente + c.repetido).toLocaleString('pt-BR')} linha(s) serão ignoradas. ` : ''}Nenhum registro existente será alterado.</div>` : ''}`;

    const temProblemas = c.erro + c.existente + c.repetido + c.aviso > 0;
    let botoes = `<button type="button" class="imp-btn" id="imp-ajustar">← Ajustar mapeamento</button>`;
    if(temProblemas) botoes += `<button type="button" class="imp-btn" id="imp-baixar">Baixar problemas (CSV)</button>`;
    if(est.confirmando){
      botoes += `<button type="button" class="imp-btn" id="imp-voltar-conf">Voltar</button><button type="button" class="imp-btn pri" id="imp-confirmar">Sim, importar ${aImportar.toLocaleString('pt-BR')}</button>`;
    } else {
      botoes += `<button type="button" class="imp-btn pri" id="imp-importar" ${aImportar === 0 || !est.validacaoOk ? 'disabled' : ''}>Importar ${aImportar.toLocaleString('pt-BR')} novo(s) →</button>`;
    }
    rodape(c.erro ? `<span class="imp-mut">Corrija os erros no arquivo e importe de novo, ou siga só com as linhas válidas.</span>` : '', botoes);

    elBody.querySelectorAll('[data-filtro]').forEach(b => b.addEventListener('click', () => { est.filtro = b.dataset.filtro; renderConferencia(); }));
    elFoot.querySelector('#imp-ajustar').addEventListener('click', () => { est.etapa = 2; est.resultado = null; est.confirmando = false; render(); });
    elFoot.querySelector('#imp-baixar')?.addEventListener('click', baixarProblemas);
    elFoot.querySelector('#imp-importar')?.addEventListener('click', () => { est.confirmando = true; renderConferencia(); elBody.scrollTop = elBody.scrollHeight; });
    elFoot.querySelector('#imp-voltar-conf')?.addEventListener('click', () => { est.confirmando = false; renderConferencia(); });
    elFoot.querySelector('#imp-confirmar')?.addEventListener('click', importar);
  }

  function baixarProblemas(){
    const cab = cabecalhos();
    const linhas = [['Linha', 'Situação', 'Detalhe', ...cab]];
    est.resultado.linhas.filter(r => r.status !== 'novo').forEach(r => {
      linhas.push([r.n, ROTULO_STATUS[r.status], mensagemDaLinha(r), ...cab.map((_, i) => r.bruta[i] ?? '')]);
    });
    baixarCsv('importacao-problemas.csv', linhas);
  }

  // ----- etapa 4: importação -----
  async function importar(){
    const alvo = est.resultado.linhas.filter(r => r.status === 'novo' || r.status === 'aviso');
    est.etapa = 4; est.importando = true; est.cancelar = false; est.final = null;
    render();
    const falhas = [];
    let criados = 0, processadas = 0, interrompido = false;
    for(let i = 0; i < alvo.length; i += cfg.tamanhoLote){
      if(est.cancelar){ interrompido = true; break; }
      const lote = alvo.slice(i, i + cfg.tamanhoLote);
      try {
        const r = await cfg.gravarLote(lote.map(l => ({ indice: l.n, dados: l.dados })));
        criados += r.criados || 0;
        (r.falhas || []).forEach(f => falhas.push(f));
      } catch(e){
        lote.forEach(l => falhas.push({ indice: l.n, mensagem: e.message || String(e) }));
      }
      processadas += lote.length;
      atualizarBarra(processadas, alvo.length);
    }
    est.importando = false;
    est.final = { criados, falhas, total: alvo.length, interrompido, restantes: alvo.length - processadas };
    render();
    try { cfg.aoConcluir && cfg.aoConcluir(est.final); } catch(e){ console.error(e); }
  }

  function atualizarBarra(feito, total){
    const b = elBody.querySelector('#imp-progresso'); if(b) b.style.width = (total ? (feito / total) * 100 : 100) + '%';
    const t = elBody.querySelector('#imp-progresso-txt'); if(t) t.textContent = `Importando… ${feito.toLocaleString('pt-BR')} de ${total.toLocaleString('pt-BR')}`;
  }

  function renderImportacao(){
    if(est.importando){
      elBody.innerHTML = `<div class="imp-msg info" id="imp-progresso-txt">Importando…</div><div class="imp-barra"><div id="imp-progresso"></div></div><p class="imp-mut">Não feche esta janela. Os registros são gravados em lotes de ${cfg.tamanhoLote}.</p>`;
      rodape('', `<button type="button" class="imp-btn perigo" id="imp-parar">Parar após o lote atual</button>`);
      elFoot.querySelector('#imp-parar').addEventListener('click', (e) => { est.cancelar = true; e.target.disabled = true; e.target.textContent = 'Parando…'; });
      return;
    }
    const f = est.final;
    elBody.innerHTML = `
      <div class="imp-msg ${f.falhas.length || f.interrompido ? 'aviso' : 'ok'}">
        <strong>${f.interrompido ? 'Importação interrompida.' : 'Importação concluída.'}</strong><br>
        ${f.criados.toLocaleString('pt-BR')} registro(s) criado(s)
        ${f.falhas.length ? ` · ${f.falhas.length.toLocaleString('pt-BR')} falha(s) na gravação` : ''}
        ${f.interrompido ? ` · ${f.restantes.toLocaleString('pt-BR')} linha(s) não processadas` : ''}
      </div>
      ${f.falhas.length ? `<div class="imp-scroll"><table class="imp-tabela"><thead><tr><th>Linha</th><th>Motivo</th></tr></thead><tbody>${f.falhas.slice(0, 100).map(x => `<tr><td>${esc(x.indice)}</td><td>${esc(x.mensagem)}</td></tr>`).join('')}</tbody></table></div>` : ''}
      <p class="imp-mut" style="margin-top:12px;">Linhas com erro, já cadastradas ou repetidas no arquivo não foram gravadas. Você pode rodar a importação de novo com o mesmo arquivo: o que já foi criado será reconhecido como “já cadastrado”.</p>`;
    rodape('', `${f.falhas.length ? '<button type="button" class="imp-btn" id="imp-baixar-falhas">Baixar falhas (CSV)</button>' : ''}<button type="button" class="imp-btn pri" id="imp-fim">Fechar</button>`);
    elFoot.querySelector('#imp-fim').addEventListener('click', () => fechar(true));
    elFoot.querySelector('#imp-baixar-falhas')?.addEventListener('click', () => baixarCsv('importacao-falhas.csv', [['Linha', 'Motivo'], ...f.falhas.map(x => [x.indice, x.mensagem])]));
  }

  render();
  return { fechar: () => fechar(true) };
}