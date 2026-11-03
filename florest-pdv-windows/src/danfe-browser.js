// Reutilizado do PDV main; apenas renderização de DANFE autorizado.
const escapeHtml = v => String(v ?? "").replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"})[c]);
function florestQrMatriz(texto){
  var ECC_POR_BLOCO = [-1,10,16,26,18,24,16,18,22,22,26,30,22,22,24,24,28,28,26,26,26,26,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28];
  var NUM_BLOCOS    = [-1,1,1,1,2,2,4,4,4,5,5,5,8,9,9,10,10,11,13,14,16,17,17,18,20,21,23,25,26,28,29,31,33,35,37,38,40,43,45,47,49];
  var dados = Array.prototype.slice.call(new TextEncoder().encode(String(texto)));

  function modulosBrutos(v){
    var r = (16*v + 128)*v + 64;
    if(v >= 2){ var n = Math.floor(v/7) + 2; r -= (25*n - 10)*n - 55; if(v >= 7) r -= 36; }
    return r;
  }
  function codewordsDeDados(v){ return Math.floor(modulosBrutos(v)/8) - ECC_POR_BLOCO[v]*NUM_BLOCOS[v]; }

  var ver = 1;
  for(;; ver++){
    if(ver > 40) throw new Error('Texto grande demais para QR Code.');
    var bitsCont = ver <= 9 ? 8 : 16;
    if(4 + bitsCont + 8*dados.length <= codewordsDeDados(ver)*8) break;
  }

  // ---- fluxo de bits
  var bits = [];
  function add(val, len){ for(var i = len-1; i >= 0; i--) bits.push((val >>> i) & 1); }
  add(4, 4); add(dados.length, ver <= 9 ? 8 : 16);
  dados.forEach(function(b){ add(b, 8); });
  var cap = codewordsDeDados(ver)*8;
  add(0, Math.min(4, cap - bits.length));
  add(0, (8 - bits.length % 8) % 8);
  for(var pad = 0xEC; bits.length < cap; pad ^= 0xEC ^ 0x11) add(pad, 8);
  var cw = [];
  for(var i = 0; i < bits.length; i += 8){ var by = 0; for(var k = 0; k < 8; k++) by = (by << 1) | bits[i+k]; cw.push(by); }

  // ---- Reed-Solomon
  function mul(x, y){ var z = 0; for(var i = 7; i >= 0; i--){ z = (z << 1) ^ ((z >>> 7) * 0x11D); z ^= ((y >>> i) & 1) * x; } return z & 255; }
  function divisor(grau){
    var r = []; for(var i = 0; i < grau; i++) r.push(0); r[grau-1] = 1; var raiz = 1;
    for(var i2 = 0; i2 < grau; i2++){ for(var j = 0; j < grau; j++){ r[j] = mul(r[j], raiz); if(j+1 < grau) r[j] ^= r[j+1]; } raiz = mul(raiz, 2); }
    return r;
  }
  function resto(bloco, div){
    var r = div.map(function(){ return 0; });
    bloco.forEach(function(b){ var f = b ^ r.shift(); r.push(0); div.forEach(function(c, i){ r[i] ^= mul(c, f); }); });
    return r;
  }
  var nBlocos = NUM_BLOCOS[ver], eccLen = ECC_POR_BLOCO[ver], bruto = Math.floor(modulosBrutos(ver)/8);
  var blocosCurtos = nBlocos - bruto % nBlocos, tamCurto = Math.floor(bruto / nBlocos);
  var blocos = [], div = divisor(eccLen);
  for(var b = 0, p = 0; b < nBlocos; b++){
    var d = cw.slice(p, p + tamCurto - eccLen + (b < blocosCurtos ? 0 : 1)); p += d.length;
    var e = resto(d, div);
    if(b < blocosCurtos) d.push(0);
    blocos.push(d.concat(e));
  }
  var final = [];
  for(var c = 0; c < blocos[0].length; c++){
    blocos.forEach(function(bl, idx){ if(c !== tamCurto - eccLen || idx >= blocosCurtos) final.push(bl[c]); });
  }

  // ---- matriz
  var N = ver*4 + 17, mod = [], fn = [];
  for(var y = 0; y < N; y++){ mod.push(new Array(N).fill(false)); fn.push(new Array(N).fill(false)); }
  function setF(x, y, v){ mod[y][x] = v; fn[y][x] = true; }
  function bit(x, i){ return ((x >>> i) & 1) !== 0; }

  for(var t = 0; t < N; t++){ setF(6, t, t % 2 === 0); setF(t, 6, t % 2 === 0); }
  function finder(cx, cy){
    for(var dy = -4; dy <= 4; dy++) for(var dx = -4; dx <= 4; dx++){
      var dist = Math.max(Math.abs(dx), Math.abs(dy)), xx = cx + dx, yy = cy + dy;
      if(xx >= 0 && xx < N && yy >= 0 && yy < N) setF(xx, yy, dist !== 2 && dist !== 4);
    }
  }
  finder(3, 3); finder(N-4, 3); finder(3, N-4);
  var pos = [];
  if(ver > 1){
    var nAl = Math.floor(ver/7) + 2, passo = ver === 32 ? 26 : Math.ceil((ver*4 + 4) / (nAl*2 - 2)) * 2;
    pos = [6]; for(var q = N - 7; pos.length < nAl; q -= passo) pos.splice(1, 0, q);
  }
  pos.forEach(function(ax, i){ pos.forEach(function(ay, j){
    if((i === 0 && j === 0) || (i === 0 && j === pos.length-1) || (i === pos.length-1 && j === 0)) return;
    for(var dy = -2; dy <= 2; dy++) for(var dx = -2; dx <= 2; dx++) setF(ax+dx, ay+dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }); });
  function formato(mask){
    var data = (0 << 3) | mask, rem = data;          // nível M = 00
    for(var i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
    var bs = ((data << 10) | rem) ^ 0x5412;
    for(var a = 0; a <= 5; a++) setF(8, a, bit(bs, a));
    setF(8, 7, bit(bs, 6)); setF(8, 8, bit(bs, 7)); setF(7, 8, bit(bs, 8));
    for(var c2 = 9; c2 < 15; c2++) setF(14 - c2, 8, bit(bs, c2));
    for(var d2 = 0; d2 < 8; d2++) setF(N-1-d2, 8, bit(bs, d2));
    for(var e2 = 8; e2 < 15; e2++) setF(8, N-15+e2, bit(bs, e2));
    setF(8, N-8, true);
  }
  formato(0);
  if(ver >= 7){
    var rem2 = ver; for(var i3 = 0; i3 < 12; i3++) rem2 = (rem2 << 1) ^ ((rem2 >>> 11) * 0x1F25);
    var vb = (ver << 12) | rem2;
    for(var i4 = 0; i4 < 18; i4++){ var cor = bit(vb, i4), aa = N - 11 + i4 % 3, bb = Math.floor(i4/3); setF(aa, bb, cor); setF(bb, aa, cor); }
  }
  var idx = 0;
  for(var dir = N - 1; dir >= 1; dir -= 2){
    if(dir === 6) dir = 5;
    for(var vert = 0; vert < N; vert++) for(var j2 = 0; j2 < 2; j2++){
      var x = dir - j2, up = ((dir + 1) & 2) === 0, y2 = up ? N - 1 - vert : vert;
      if(!fn[y2][x] && idx < final.length*8){ mod[y2][x] = bit(final[idx >>> 3], 7 - (idx & 7)); idx++; }
    }
  }
  function mascara(m){
    for(var y = 0; y < N; y++) for(var x = 0; x < N; x++){
      var inv;
      switch(m){
        case 0: inv = (x + y) % 2 === 0; break;
        case 1: inv = y % 2 === 0; break;
        case 2: inv = x % 3 === 0; break;
        case 3: inv = (x + y) % 3 === 0; break;
        case 4: inv = (Math.floor(x/3) + Math.floor(y/2)) % 2 === 0; break;
        case 5: inv = x*y % 2 + x*y % 3 === 0; break;
        case 6: inv = (x*y % 2 + x*y % 3) % 2 === 0; break;
        default: inv = ((x + y) % 2 + x*y % 3) % 2 === 0;
      }
      if(!fn[y][x] && inv) mod[y][x] = !mod[y][x];
    }
  }
  function penalidade(){
    var r = 0, x, y, k;
    function linha(get){
      var total = 0;
      for(var a = 0; a < N; a++){
        var corAtual = false, seq = 0, hist = '';
        for(var b = 0; b < N; b++){
          var v = get(a, b);
          hist += v ? '1' : '0';
          if(b > 0 && v === corAtual){ seq++; if(seq === 5) total += 3; else if(seq > 5) total++; }
          else { corAtual = v; seq = 1; }
        }
        var m1 = hist.match(/10111010000/g), m2 = hist.match(/00001011101/g);
        total += 40 * ((m1 ? m1.length : 0) + (m2 ? m2.length : 0));
      }
      return total;
    }
    r += linha(function(a, b){ return mod[a][b]; });
    r += linha(function(a, b){ return mod[b][a]; });
    for(y = 0; y < N-1; y++) for(x = 0; x < N-1; x++){ var c0 = mod[y][x]; if(c0 === mod[y][x+1] && c0 === mod[y+1][x] && c0 === mod[y+1][x+1]) r += 3; }
    var escuros = 0; for(y = 0; y < N; y++) for(x = 0; x < N; x++) if(mod[y][x]) escuros++;
    k = Math.ceil(Math.abs(escuros*20 - N*N*10) / (N*N)) - 1; r += k*10;
    return r;
  }
  var melhor = 0, menor = Infinity;
  for(var m = 0; m < 8; m++){
    mascara(m); formato(m);
    var pen = penalidade(); if(pen < menor){ menor = pen; melhor = m; }
    mascara(m);
  }
  mascara(melhor); formato(melhor);
  return mod;
}

// SVG do QR Code (módulos escuros em preto sobre fundo branco, com margem de silêncio).
function florestQrSvg(texto, borda){
  var m = florestQrMatriz(texto), b = borda == null ? 2 : borda, n = m.length, d = '';
  for(var y = 0; y < n; y++) for(var x = 0; x < n; x++) if(m[y][x]) d += 'M' + (x+b) + ',' + (y+b) + 'h1v1h-1z';
  var t = n + b*2;
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ' + t + ' ' + t + '" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#fff"/><path d="' + d + '" fill="#000"/></svg>';
}
// ---------- DANFE NFC-e (impressão a partir da NFC-e AUTORIZADA) ----------
// Fonte única de impressão da NFC-e, usada pelo PDV e pela tela Fiscal (mesmo documento nos dois lugares).
// 'xml_local'    -> monta o DANFE NFC-e (bobina 80 mm) SOMENTE com os dados reais da nota autorizada: o XML
//                   devolvido pela Dados Jah (emitente, itens, pagamentos, chave, QR Code fiscal da própria
//                   tag infNFeSupl/qrCode) + protocolo/data de autorização gravados na emissão. Nada é
//                   inventado: se faltar chave, protocolo ou QR Code no XML, NÃO monta e usa o PDF do provedor.
// 'pdf_provedor' -> abre sempre o PDF devolvido pela Dados Jah (comportamento anterior).
const DANFE_NFCE_FONTE = 'xml_local';
// Largura do cupom em colunas de texto (bobina de 80 mm, fonte monoespaçada de 10 px).
const DANFE_NFCE_COLS = 44;

const NFCE_TPAG = { '01':'Dinheiro','02':'Cheque','03':'Cartão de Crédito','04':'Cartão de Débito','05':'Crédito Loja','10':'Vale Alimentação','11':'Vale Refeição','12':'Vale Presente','13':'Vale Combustível','15':'Boleto Bancário','16':'Depósito Bancário','17':'PIX','18':'Transferência/Carteira Digital','19':'Programa de Fidelidade','20':'PIX','21':'Crédito em Loja','90':'Sem pagamento','99':'Outros' };

function nfceDecodificarXml(conteudo){
  if(!conteudo) return null;
  let s = String(conteudo).trim();
  if(s.charAt(0) !== '<'){
    try {
      const bin = atob(s.replace(/\s+/g, ''));
      const bytes = Uint8Array.from(bin, c => c.charCodeAt(0));
      s = new TextDecoder('utf-8').decode(bytes);
    } catch(e){ return null; }
  }
  return s.charAt(0) === '<' || s.charAt(0) === '﻿' ? s.replace(/^﻿/, '') : null;
}

// Lê só o que existe no XML autorizado. `doc` (linha de documentos_fiscais) completa apenas o que a
// emissão gravou separadamente (protocolo, data de autorização, número, série, chave).
function nfceLerDadosDanfe(doc){
  const xml = nfceDecodificarXml(doc && doc.xml_conteudo);
  if(!xml) return null;
  const dom = new DOMParser().parseFromString(xml, 'application/xml');
  if(dom.getElementsByTagName('parsererror').length) return null;
  const ns = (raiz, nome) => { const l = raiz ? raiz.getElementsByTagNameNS('*', nome) : []; return l.length ? l[0] : null; };
  const tx = (raiz, nome) => { const e = ns(raiz, nome); return e ? (e.textContent || '').trim() : ''; };
  const inf = ns(dom, 'infNFe');
  if(!inf) return null;
  const emit = ns(inf, 'emit'), ender = ns(emit, 'enderEmit'), ide = ns(inf, 'ide'), dest = ns(inf, 'dest');
  const tot = ns(ns(inf, 'total'), 'ICMSTot'), pag = ns(inf, 'pag'), supl = ns(dom, 'infNFeSupl'), prot = ns(dom, 'infProt');
  const itens = Array.from(inf.getElementsByTagNameNS('*', 'det')).map(det => {
    const p = ns(det, 'prod');
    return { n: det.getAttribute('nItem') || '', cod: tx(p, 'cProd'), desc: tx(p, 'xProd'), un: tx(p, 'uCom'), qtd: tx(p, 'qCom'),
             vun: tx(p, 'vUnCom'), vprod: tx(p, 'vProd'), vdesc: tx(p, 'vDesc'), voutro: tx(p, 'vOutro') };
  });
  const pagamentos = pag ? Array.from(pag.getElementsByTagNameNS('*', 'detPag')).map(d => ({ tPag: tx(d, 'tPag'), desc: tx(d, 'xPag'), v: tx(d, 'vPag') })) : [];
  const idAttr = (inf.getAttribute('Id') || '').replace(/^NFe/, '');
  return {
    emit: { cnpj: tx(emit, 'CNPJ'), ie: tx(emit, 'IE'), nome: tx(emit, 'xNome'), fantasia: tx(emit, 'xFant'),
            end: [tx(ender, 'xLgr'), tx(ender, 'nro'), tx(ender, 'xCpl'), tx(ender, 'xBairro')].filter(Boolean),
            cidade: tx(ender, 'xMun'), uf: tx(ender, 'UF'), cep: tx(ender, 'CEP'), fone: tx(ender, 'fone') },
    tpEmis: tx(ide, 'tpEmis'),
    numero: tx(ide, 'nNF') || (doc && doc.numero) || '',
    serie: tx(ide, 'serie') || (doc && doc.serie) || '',
    dhEmi: tx(ide, 'dhEmi') || (doc && doc.dh_emissao) || '',
    tpAmb: tx(prot, 'tpAmb') || tx(ide, 'tpAmb') || (doc && doc.tp_ambiente) || '',
    itens, pagamentos,
    vProd: tx(tot, 'vProd'), vDesc: tx(tot, 'vDesc'), vOutro: tx(tot, 'vOutro'), vNF: tx(tot, 'vNF') || (doc && doc.valor != null ? String(doc.valor) : ''),
    vTotTrib: tx(tot, 'vTotTrib'), vTroco: tx(pag, 'vTroco'),
    dest: { cpf: tx(dest, 'CPF'), cnpj: tx(dest, 'CNPJ'), nome: tx(dest, 'xNome') },
    infCpl: tx(ns(inf, 'infAdic'), 'infCpl'),
    chave: tx(prot, 'chNFe') || (doc && doc.chave_acesso) || idAttr,
    protocolo: tx(prot, 'nProt') || (doc && doc.protocolo) || '',
    dhAut: tx(prot, 'dhRecbto') || (doc && doc.dh_recebimento) || '',
    qrCode: tx(supl, 'qrCode'), urlChave: tx(supl, 'urlChave'),
    cancelada: !!(doc && doc.status === 'cancelada')
  };
}

function nfceNum(v){ const n = Number(String(v == null ? '' : v).replace(',', '.')); return Number.isFinite(n) ? n : 0; }
function nfceMoeda(v){ return nfceNum(v).toLocaleString('pt-BR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }); }
function nfceQtd(v){
  const n = nfceNum(v);
  if(Number.isInteger(n)) return String(n);
  const s = n.toLocaleString('pt-BR', { minimumFractionDigits: 3, maximumFractionDigits: 4 });
  return s;
}
function nfceDataHora(s){
  const m = /(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/.exec(String(s || ''));
  return m ? `${m[3]}/${m[2]}/${m[1]} ${m[4]}:${m[5]}:${m[6]}` : '';
}
function nfceCnpjFmt(c){ const d = String(c || '').replace(/\D/g, ''); return d.length === 14 ? d.replace(/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, '$1.$2.$3/$4-$5') : d; }
function nfceCpfFmt(c){ const d = String(c || '').replace(/\D/g, ''); return d.length === 11 ? d.replace(/(\d{3})(\d{3})(\d{3})(\d{2})/, '$1.$2.$3-$4') : d; }


// Texto ASCII puro: o cupom térmico não pode depender do code page do driver da impressora (acentos
// saem trocados quando o driver imprime só texto). Nada de dado fiscal muda: só a grafia do que é impresso.
function nfceAscii(s){
  return String(s == null ? '' : s).normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/º/g, 'o').replace(/ª/g, 'a').replace(/°/g, 'o').replace(/[–—]/g, '-').replace(/[‘’]/g, "'").replace(/[“”]/g, '"')
    .replace(/[^\x20-\x7E]/g, '?');
}
function nfceQuebrar(texto, n){
  const palavras = nfceAscii(texto).split(/\s+/).filter(Boolean), linhas = [];
  let atual = '';
  palavras.forEach(p => {
    while(p.length > n){ if(atual){ linhas.push(atual); atual = ''; } linhas.push(p.slice(0, n)); p = p.slice(n); }
    if(!atual) atual = p;
    else if((atual + ' ' + p).length <= n) atual += ' ' + p;
    else { linhas.push(atual); atual = p; }
  });
  if(atual) linhas.push(atual);
  return linhas;
}

// Quebra uma URL preferindo o fim de um segmento ("/"), para a linha não cortar uma palavra ao meio.
function nfceQuebrarUrl(url, n){
  const partes = nfceAscii(url).match(/[^/]*\/?/g).filter(Boolean), linhas = [];
  let atual = '';
  partes.forEach(p => {
    while(p.length > n){ if(atual){ linhas.push(atual); atual = ''; } linhas.push(p.slice(0, n)); p = p.slice(n); }
    if((atual + p).length <= n) atual += p; else { linhas.push(atual); atual = p; }
  });
  if(atual) linhas.push(atual);
  return linhas;
}

// Monta o HTML do DANFE NFC-e (bobina 80 mm, texto monoespaçado em colunas fixas, QR Code fiscal do XML).
// Retorna null se a nota não tem o mínimo real exigido (chave, protocolo e QR Code): nada é inventado.
function nfceMontarDanfeHtml(d, qrSvg){
  if(!d || !d.chave || !d.qrCode || !qrSvg) return null;
  // Migration 041: NFC-e emitida em CONTINGÊNCIA (tpEmis=9) ainda sem protocolo é impressa com a legenda "Emitida em Contingência -
  // Pendente de Autorização" e SEM protocolo. Sem protocolo e sem tpEmis=9, continua não montando (nada é inventado).
  const pendenteCtg = !d.protocolo && String(d.tpEmis) === '9';
  if(!d.protocolo && !pendenteCtg) return null;
  const N = DANFE_NFCE_COLS, e = escapeHtml;
  const blocos = [[]];                         // blocos de linhas; o QR Code fica entre o bloco 0 e o bloco 1
  const L = (t, b) => blocos[blocos.length - 1].push({ t: String(t), b: !!b });
  const centro = (t, b) => nfceQuebrar(t, N).forEach(l => L(' '.repeat(Math.floor((N - l.length) / 2)) + l, b));
  const esq = (t, b) => nfceQuebrar(t, N).forEach(l => L(l, b));
  const lr = (a, c, b) => { a = nfceAscii(a); c = nfceAscii(c); if(a.length + c.length + 1 > N) a = a.slice(0, Math.max(0, N - c.length - 1)); L(a + ' '.repeat(N - a.length - c.length) + c, b); };
  const sep = () => L('-'.repeat(N));

  const homolog = String(d.tpAmb) === '2';
  const nomeEmp = d.emit.fantasia && d.emit.fantasia !== d.emit.nome ? d.emit.fantasia : d.emit.nome;
  centro(nomeEmp, true);
  if(d.emit.fantasia && d.emit.fantasia !== d.emit.nome) centro(d.emit.nome);
  centro('CNPJ: ' + nfceCnpjFmt(d.emit.cnpj) + (d.emit.ie ? '  IE: ' + d.emit.ie : ''));
  centro([d.emit.end.join(', '), [d.emit.cidade, d.emit.uf].filter(Boolean).join(' - '), d.emit.cep ? 'CEP ' + d.emit.cep : ''].filter(Boolean).join(' - '));
  if(d.emit.fone) centro('Tel. ' + d.emit.fone);
  sep();
  centro('DANFE NFC-e', true);
  centro('Documento Auxiliar da Nota Fiscal de Consumidor Eletronica');
  if(pendenteCtg){ L(''); centro('Emitida em Contingencia - Pendente de Autorizacao', true); }
  if(d.cancelada){ L(''); centro('*** NFC-e CANCELADA ***', true); }
  if(homolog){ L(''); centro('EMITIDA EM AMBIENTE DE HOMOLOGACAO', true); centro('SEM VALOR FISCAL', true); }
  sep();
  d.itens.forEach(it => {
    esq(String(it.n).padStart(3, '0') + ' ' + [it.cod, it.desc].filter(Boolean).join(' '));
    const desconto = nfceNum(it.vdesc) > 0 ? ' (desc -' + nfceMoeda(it.vdesc) + ')' : '';
    lr('  ' + nfceQtd(it.qtd) + ' ' + it.un + ' x ' + nfceMoeda(it.vun) + desconto, nfceMoeda(it.vprod));
  });
  sep();
  lr('Qtd. total de itens', String(d.itens.length));
  lr('Valor total R$', nfceMoeda(d.vProd));
  if(nfceNum(d.vDesc) > 0) lr('Desconto R$', '-' + nfceMoeda(d.vDesc));
  if(nfceNum(d.vOutro) > 0) lr('Acrescimos R$', nfceMoeda(d.vOutro));
  lr('VALOR A PAGAR R$', nfceMoeda(d.vNF), true);
  sep();
  lr('Forma de pagamento', 'Valor pago R$', true);
  d.pagamentos.forEach(p => lr(NFCE_TPAG[p.tPag] || p.desc || 'Outros', nfceMoeda(p.v)));
  if(nfceNum(d.vTroco) > 0) lr('Troco R$', nfceMoeda(d.vTroco));
  if(nfceNum(d.vTotTrib) > 0){ sep(); esq('Tributos totais incidentes (Lei Federal 12.741/2012): R$ ' + nfceMoeda(d.vTotTrib)); }
  if(d.infCpl){ sep(); esq(d.infCpl); }
  sep();
  centro('NFC-e No ' + d.numero + ' Serie ' + d.serie, true);
  centro('Emissao: ' + nfceDataHora(d.dhEmi));
  centro('Via Consumidor');
  sep();
  if(d.urlChave){ centro('Consulte pela Chave de Acesso em:'); nfceQuebrarUrl(d.urlChave, N).forEach(l => centro(l)); }
  const grupos = String(d.chave).replace(/\D/g, '').match(/\d{1,4}/g) || [];
  for(let i = 0; i < grupos.length; i += 6) centro(grupos.slice(i, i + 6).join(' '), true);
  centro(d.dest.cpf ? 'CONSUMIDOR - CPF ' + nfceCpfFmt(d.dest.cpf) + (d.dest.nome ? ' - ' + d.dest.nome : '')
        : d.dest.cnpj ? 'CONSUMIDOR - CNPJ ' + nfceCnpjFmt(d.dest.cnpj) + (d.dest.nome ? ' - ' + d.dest.nome : '')
        : 'CONSUMIDOR NAO IDENTIFICADO');
  blocos.push([]);                              // ---- QR Code entre os dois blocos
  if(pendenteCtg){ centro('SEM PROTOCOLO DE AUTORIZACAO', true); centro('Emitida em Contingencia - Pendente de Autorizacao', true); centro('Guarde esta via ate a autorizacao pela SEFAZ'); }
  else {
    centro('Protocolo de autorizacao: ' + d.protocolo, true);
    if(d.dhAut) centro('Data de autorizacao: ' + nfceDataHora(d.dhAut));
  }
  const pre = b => '<pre>' + b.map(l => l.b ? '<b>' + e(l.t) + '</b>' : e(l.t)).join('\n') + '</pre>';
  return `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><title>DANFE NFC-e ${e(nfceAscii(d.numero))}</title><style>
    @page{ margin:0; }
    html,body{ margin:0; padding:0; background:#fff; color:#000; }
    body{ width:80mm; box-sizing:border-box; padding:2mm 4mm 3mm; }
    pre{ margin:0; font:10px/12px "Courier New",Courier,"Liberation Mono",monospace; white-space:pre; }
    b{ font-weight:700; }
    .qr{ text-align:center; margin:2mm 0; }
    .qr svg{ width:34mm; height:34mm; display:block; margin:0 auto; }
    @media print{ html,body{ height:auto !important; min-height:0 !important; overflow:visible !important; } }
  </style></head><body>${pre(blocos[0])}<div class="qr">${qrSvg}</div>${pre(blocos[1])}</body></html>`;
}

