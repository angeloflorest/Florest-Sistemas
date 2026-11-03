"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const {createUpdater}=require('../src/update.cjs');
function fixture(){const a=new EventEmitter();let sale=false,backups=0,installed=0;
a.checkForUpdates=async()=>a.emit('update-available',{version:'0.4.0'});
a.downloadUpdate=async()=>a.emit('update-downloaded');a.quitAndInstall=()=>installed++;
const u=createUpdater({autoUpdater:a,hasSale:async()=>sale,prepare:async()=>backups++,install:()=>{},onChange:()=>{}});
return {a,u,setSale:v=>sale=v,counts:()=>({backups,installed})};}
test('atualizador não baixa nem instala durante venda',async()=>{const f=fixture();await f.u.check();f.setSale(true);await assert.rejects(f.u.install(),/venda/);assert.deepEqual(f.counts(),{backups:0,installed:0});assert.equal(f.a.autoInstallOnAppQuit,false);});
test('confere novamente venda após download e mantém atualização pronta',async()=>{const f=fixture();await f.u.check();f.a.downloadUpdate=async()=>{f.setSale(true);f.a.emit('update-downloaded');};await assert.rejects(f.u.install(),/Venda em andamento/);assert.equal(f.u.state().status,'ready');assert.equal(f.counts().installed,0);f.setSale(false);await f.u.install();assert.deepEqual(f.counts(),{backups:1,installed:1});});
test('download inválido nunca instala',async()=>{const f=fixture();await f.u.check();f.a.downloadUpdate=async()=>{throw Error('checksum SHA512 inválido');};await assert.rejects(f.u.install(),/checksum/);assert.equal(f.counts().installed,0);});
const {createFiscal}=require('../src/fiscal.cjs');
function fiscalFixture(){let enabled=true,connected=true,pending=false,calls=[];const row={id_local:'l',id_remoto:'r',estado_sync:'sincronizada'};
const rpc=async(name,args)=>{calls.push({name,args});if(!connected)throw Error('offline');if(name==='fiscal_emissao_caixa_obter')return {empresa_id:'e',emite_nota_fiscal:enabled};if(name==='fiscal_contingencia_status')return {ativa:false};return [{id:'doc',tipo_documento:'nfce',status:'rascunho'}];};
const fiscal=createFiscal({rpc,client:{functions:{invoke:async(name,args)=>{calls.push({name,args});return {data:{status:'autorizada'}};}}},getContext:()=>({empresaId:'e'}),storage:{db:{prepare:()=>({get:()=>pending?{...row,id_remoto:null,estado_sync:'pendente'}:row})}},sync:async()=>{}});
return {fiscal,calls,enable:v=>enabled=v,online:v=>connected=v,pending:v=>pending=v};}
test('configuração fiscal desabilitada ou sem conexão nunca chama emissor',async()=>{const f=fiscalFixture();f.enable(false);await assert.rejects(f.fiscal.emit('l'),/habilitada/);f.enable(true);f.online(false);await assert.rejects(f.fiscal.emit('l'),/offline/);assert.equal(f.calls.filter(c=>c.name==='fiscal-emitir-documento').length,0);});
test('venda pendente não emite NFC-e',async()=>{const f=fiscalFixture();f.pending(true);await assert.rejects(f.fiscal.emit('l'),/sincronização/);assert.equal(f.calls.filter(c=>c.name==='fiscal_emitir_nota').length,0);});
test('duplo clique compartilha emissão e usa serviço fiscal existente',async()=>{const f=fiscalFixture();const a=f.fiscal.emit('l'),b=f.fiscal.emit('l');assert.equal(a,b);assert.equal((await a).status,'autorizada');assert.equal(f.calls.filter(c=>c.name==='fiscal-emitir-documento').length,1);assert.deepEqual(f.calls.find(c=>c.name==='fiscal_emitir_nota').args,{p_venda_id:'r'});});
