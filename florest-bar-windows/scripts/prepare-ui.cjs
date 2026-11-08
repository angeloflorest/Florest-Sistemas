'use strict';
const fs=require('fs'),path=require('path'),crypto=require('crypto'),cp=require('child_process');
const root=path.resolve(__dirname,'../..'),out=path.resolve(__dirname,'../src/renderer');
const raw=fs.readFileSync(path.join(root,'florest-erp/sistema/index.html'),'utf8');
// A main inclui um script da Gastronomia dentro do template DANFE; seu fechamento encerra o módulo HTML prematuramente. Não pertence ao Bar.
let html=raw.replace(/\r\n/g,'\n').replace('<script src="./gastronomia-fotos.js" defer></script>','');const m=html.match(/<script type="module">([\s\S]*?)<\/script>/);if(!m)throw Error('Módulo original não localizado');let code=m[1];
function patch(a,b){if(!code.includes(a))throw Error('Referência mudou: '+a.slice(0,80));code=code.replace(a,b);}
patch("import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';","import { createClient } from './vendor/supabase.js';");
patch('createClient(SUPABASE_URL, SUPABASE_ANON_KEY) : null;', 'createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {auth:{storage:window.florestBar.storage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:false},global:{fetch:window.florestBarFetch}}) : null;');
code=code.replace(/function primeiroModuloPermitido\(exceto\)\{[\s\S]*?\n\}/, "function primeiroModuloPermitido(){ return podeAcessar('bar_visualizar') ? 'bar' : null; }");
patch('instalarTaxasPagamento(supabase);', `const desktopGetSession=supabase.auth.getSession.bind(supabase.auth);
supabase.auth.getSession=async(...args)=>{
 const result=await desktopGetSession(...args);
 if(result.error){const saved=await window.florestBar.offlineSession();if(saved)return {data:{session:saved},error:null};}
 return result;
};
instalarTaxasPagamento(supabase);`);
patch('function abrirView(view){',"function abrirView(view){ if(view !== 'bar') return;");
// Mantém o carrinho original; somente persiste o rascunho por operador e mesa.
patch('function renderCarrinhoMesa(){',"function renderCarrinhoMesa(){\n if(barMesaAtual?.id) window.florestBar.saveDraft({table:barMesaAtual.id,data:{cart:barMesaCarrinho,comanda:barComandaAtualId}}).catch(()=>{});");
patch('  barMesaCarrinho = [];\n  barMesaQtdItensValidos = 0;',"  const localDraft = await window.florestBar.loadDraft(mesa.id);\n  barMesaCarrinho = localDraft?.data?.cart || [];\n  barMesaQtdItensValidos = 0;");
const orderStart=code.indexOf("$('btn-bar-mesa-lancar').addEventListener");const resultAt=code.indexOf('  if(resultado){',orderStart);if(resultAt<0)throw Error('Fluxo original de pedido alterado');code=code.slice(0,resultAt)+"  if(resultado?.recuperado_windows){barMesaCarrinho=[];renderCarrinhoMesa();$('modal-bar-mesa').classList.add('hidden');barMesaAtual=null;barComandaAtualId=null;await carregarBarMesas();$('bar-mesas-msg').textContent='Pedido anterior confirmado no ERP sem novo lançamento nem reimpressão. Confira a mesa atual antes de atender.';return;}\n"+code.slice(resultAt);
code += fs.readFileSync(path.join(__dirname,'desktop-module.js'),'utf8');
html=html.replace(m[0],'<script src="desktop-adapter.js"></script>\n<script type="module" src="erp-bar.js"></script>');
html=html.replace(/<link rel="preconnect"[^>]+>/g,'').replace(/<link href="https:\/\/fonts.googleapis.com[^>]+>/g,'<link rel="stylesheet" href="fonts/fonts.css">');
html=html.replace('<head>','<head>\n<meta http-equiv="Content-Security-Policy" content="default-src \'self\' blob: data:; script-src \'self\' \'unsafe-inline\' blob:; style-src \'self\' \'unsafe-inline\'; img-src \'self\' data: blob: https://etulhyboogqhyyevpnlo.supabase.co; connect-src https://etulhyboogqhyyevpnlo.supabase.co wss://etulhyboogqhyyevpnlo.supabase.co; frame-src \'self\' data: blob:; object-src \'none\'; base-uri \'self\'">');
html=html.replace('</head>','<style>.nav-item:not([data-view="bar"]),#tab-cadastro,#maria-flutuante,.sidebar-section-title:not(:has(+ #nav-bar)){display:none!important}</style>\n</head>');
html=html.replace(/<title>[^<]*<\/title>/,'<title>Florest Bar</title>');
fs.mkdirSync(out,{recursive:true});fs.writeFileSync(path.join(out,'index.html'),html);fs.writeFileSync(path.join(out,'erp-bar.js'),code);for(const f of ['taxas-pagamento.js','taxas-core.js'])fs.copyFileSync(path.join(root,'florest-erp/sistema',f),path.join(out,f));fs.cpSync(path.join(root,'florest-erp/sistema/assets'),path.join(out,'assets'),{recursive:true});
const git=cp.execFileSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).trim();fs.writeFileSync(path.join(out,'reference.json'),JSON.stringify({commit:git,source:'florest-erp/sistema/index.html',sha256:crypto.createHash('sha256').update(raw).digest('hex'),mode:'original HTML, CSS e funções; adaptação de transporte, armazenamento, entrada exclusiva Bar e polling'},null,2));
require('./vendor.cjs').prepareVendor(path.join(out,'vendor'));
console.log('Interface original preparada, SHA256: '+JSON.parse(fs.readFileSync(path.join(out,'reference.json'))).sha256);
