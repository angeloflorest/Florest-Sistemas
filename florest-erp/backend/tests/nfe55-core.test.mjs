import {test} from 'node:test';
import assert from 'node:assert/strict';
import {preparar,payload,resultado,executar,documentoValido} from '../../funcoes-supabase/fiscal-nfe55/core.mjs';
import {fixture} from './nfe55-fixture.mjs';
function chave(){let base='3126111122233300018155001000000123112345678',sum=0,w=2;for(let i=42;i>=0;i--){sum+=Number(base[i])*w;w=w===9?2:w+1;}let d=11-sum%11;return base+(d>=10?0:d);}
function autorizado(registro){return {data:{NFe:[{idExternal:registro.id,nNF:'123',serie:'1',tpAmb:'1',chDfe:chave(),nProt:'131260000000001',cStat:'100',situationDfe:'Autorizado',idDfe:'provider-id',xMotivo:'Autorizado o uso da NFe'}]}};}
test('payload específico NF-e, produção e série 1; valores originam na venda',()=>{
 const f=fixture(),inf=preparar(f.snapshot,f.revisao,f.tecnico),p=payload(inf,f.registro);
 assert.equal(p.async,false);assert.equal(p.NFe.length,1);assert.equal(p.NFCe,undefined);assert.equal(p.NFe[0].infNF.ide.serie,'1');assert.equal(p.NFe[0].infNF.ide.tpAmb,'1');assert.equal(p.NFe[0].infNF.det[0].prod.vProd,'20.00');assert.equal(p.NFe[0].infNF.dest.CNPJCPF,'52998224725');assert.equal(p.NFe[0].infNF.emit.CNPJCPF,'11222333000181');
});
test('valida CPF/CNPJ e impede enquadramento desconhecido, campos ausentes e valores divergentes antes de POST',()=>{
 assert.ok(documentoValido('52998224725'));assert.ok(!documentoValido('00000000000'));
 for(const mutate of [f=>f.snapshot.venda.cancelada_em='2026-11-01',f=>f.snapshot.venda.total=19,f=>f.revisao.dest.CNPJCPF='123',f=>f.revisao.dest.enderDest.cMun='',f=>f.revisao.itens[0].cfop='6102',f=>f.snapshot.emitente.crt='1',f=>f.snapshot.emitente.nfe_numeracao_confirmada_em=null,f=>f.snapshot.emitente.nfe_serie='',f=>f.revisao.dest.indIEDest='1',f=>delete f.revisao.totais.vFrete,f=>f.revisao.itens[0].imposto.ICMS.CST='qualquer',f=>f.revisao.pagamentos[0].vPag='19',f=>f.snapshot.itens[0].produto.tipo_fiscal='servico',f=>f.revisao.itens[0].id=2]){const f=fixture();mutate(f);assert.throws(()=>preparar(f.snapshot,f.revisao,f.tecnico));}
});
test('HTTP 201 não é autorização; exige chave modelo 55, empresa, série, número, ambiente e protocolo',()=>{
 const f=fixture(),r={...f.registro,payload:payload(preparar(f.snapshot,f.revisao,f.tecnico),f.registro)};
 assert.equal(resultado(autorizado(r),r).status,'autorizada');
 for(const mutate of [n=>n.tpAmb='2',n=>n.idExternal='outro',n=>n.nNF='124',n=>n.nProt='',n=>n.chDfe='0'.repeat(44)]){const b=autorizado(r);mutate(b.data.NFe[0]);assert.equal(resultado(b,r).status,'pendente');}
 assert.equal(resultado({statusCode:201,data:{idBatch:'lote'}},r).status,'pendente');
 const b=autorizado(r);Object.assign(b.data.NFe[0],{cStat:'271',situationDfe:'Rejeitado'});assert.equal(resultado(b,r).status,'rejeitada');b.data.NFe[0].cStat='204';assert.equal(resultado(b,r).status,'pendente');
});
test('emissão persiste claim antes de único POST /nfe; timeout só permite GET de consulta',async()=>{
 const f=fixture(),infNF=preparar(f.snapshot,f.revisao,f.tecnico),calls=[],saved=[];
 const fetcher=async(url,opts)=>{calls.push([url,opts.method]);if(opts.method==='POST')throw Error('timeout');return new Response(JSON.stringify(autorizado(f.registro)));};
 let r=await executar({acao:'emitir',registro:f.registro,infNF,token:'token-falso',fetcher,salvar:async(p,claim)=>saved.push({p,claim})});
 assert.equal(saved[0].claim,true);assert.equal(r.status,'pendente');assert.equal(calls.length,1);assert.match(calls[0][0],/\/v1\/nfe\?tpDanfe=Retrato$/);
 r=await executar({acao:'consultar',registro:r,token:'token-falso',fetcher,salvar:async()=>{}});assert.equal(r.status,'autorizada');assert.equal(calls.filter(c=>c[1]==='POST').length,1);assert.match(calls[1][0],/idExternal=nota-teste/);
});
test('claim concorrente recusado não transmite; autorização não é rebaixada por resposta incompleta',async()=>{
 const f=fixture();let calls=0;await assert.rejects(executar({acao:'emitir',registro:f.registro,infNF:preparar(f.snapshot,f.revisao,f.tecnico),token:'fake',fetcher:async()=>{calls++;},salvar:async()=>{throw Error('claim já usado');}}));assert.equal(calls,0);
 const registro={...f.registro,status:'autorizada'};const r=await executar({acao:'consultar',registro,token:'fake',fetcher:async()=>new Response('{}'),salvar:async()=>assert.fail('Não rebaixar autorização')});assert.equal(r.status,'autorizada');
});

test('série configurada é usada no payload e na validação da resposta, sem fixar série 1',()=>{
 const f=fixture();f.snapshot.emitente.nfe_serie='12';f.registro.serie='12';
 const p=payload(preparar(f.snapshot,f.revisao,f.tecnico),f.registro);assert.equal(p.NFe[0].infNF.ide.serie,'12');
 const r={...f.registro,payload:p},body=autorizado(r);assert.equal(resultado(body,r).status,'pendente');
 let base=body.data.NFe[0].chDfe.slice(0,22)+'012'+body.data.NFe[0].chDfe.slice(25,43),sum=0,w=2;
 for(let i=42;i>=0;i--){sum+=Number(base[i])*w;w=w===9?2:w+1;}const d=11-sum%11;
 body.data.NFe[0].serie='12';body.data.NFe[0].chDfe=base+(d>=10?0:d);assert.equal(resultado(body,r).status,'autorizada');
});
test('CRT 1 / CSOSN 102 usa o campo confirmado CSOSN, sem CST normal e sem cálculo externo',()=>{
 const f=fixture();f.snapshot.emitente.crt='1';f.snapshot.emitente.uf='mg';f.revisao.dest.enderDest.UF='mg';f.revisao.itens[0].csosn='102';f.revisao.sem_acessorios=true;f.revisao.totais={};
 const n=preparar(f.snapshot,f.revisao,f.tecnico);assert.deepEqual(n.det[0].imposto.ICMS,{orig:'0',CSOSN:'102'});assert.equal(n.emit.CRT,'1');assert.equal(n.total.ICMSTot.vNF,'20.00');assert.equal(n.total.ICMSTot.vPIS,'0.00');
 f.revisao.itens[0].csosn='500';assert.throws(()=>preparar(f.snapshot,f.revisao,f.tecnico),/500/);
});
test('PIS/COFINS ausentes não recebem CST padrão; 49/99 exigem confirmação de ausência de destaque',()=>{
 const f=fixture();f.snapshot.emitente.crt='1';f.revisao.itens[0].csosn='102';f.revisao.sem_acessorios=true;f.revisao.totais={};
 const x=f.revisao.itens[0].imposto;x.PIS={CST:''};x.COFINS={CST:''};
 assert.throws(()=>preparar(f.snapshot,f.revisao,f.tecnico),/CST de PIS ausente/);assert.equal(x.PIS.CST,'');
 x.PIS={CST:'49'};x.COFINS={CST:'99'};assert.throws(()=>preparar(f.snapshot,f.revisao,f.tecnico),/confirme.*PIS CST 49/);
 x.PIS.sem_destaque=true;x.COFINS.sem_destaque=true;
 const n=preparar(f.snapshot,f.revisao,f.tecnico);assert.deepEqual(n.det[0].imposto.PIS,{CST:'49'});assert.deepEqual(n.det[0].imposto.COFINS,{CST:'99'});assert.equal(n.det[0].imposto.PIS.pPIS,undefined);
 x.PIS.pPIS='1.65';assert.throws(()=>preparar(f.snapshot,f.revisao,f.tecnico),/não corresponde/);
});
