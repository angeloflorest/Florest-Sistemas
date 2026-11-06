import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fixture} from './nfe55-fixture.mjs';
import {preparar} from '../../funcoes-supabase/fiscal-nfe55/core.mjs';
import {revisaoDoCadastro,pendenciasContrato,destinoDoCliente} from '../../sistema/fiscal-nfe55-modelo.js';
import {montarCalculo,aplicarCalculo,consultarLista} from '../../funcoes-supabase/fiscal-nfe55/automacao.mjs';
function dados(){const f=fixture();f.revisao.sem_acessorios=true;f.snapshot.venda.forma_pagamento='Pix';Object.assign(f.snapshot.itens[0].produto,{ncm:'12345678',cfop:'5102',gtin:'SEM GTIN',unidade_comercial:'UN',origem_mercadoria:'0',cst_csosn:'90',cst_pis:'07',cst_cofins:'07',aliquota_icms:0});return f;}
function resposta(f){const req=montarCalculo(f.snapshot,f.revisao);return {data:{...req,det:req.det.map(d=>({...d,imposto:{...d.imposto,ICMS:{...d.imposto.ICMS,vBC:'0.00',vICMS:'0.00',vBCSTRet:'0.00',pST:'0.00',vICMSSTRet:'0.00'}}})),total:{ICMSTot:{...f.revisao.totais,vProd:'20.00',vNF:'20.00'}}}};}
test('cadastro preenche produtos, origem zero e pagamento sem escolher alíquota ou CST ausentes',()=>{
 const f=dados(),r=revisaoDoCadastro(f.snapshot);assert.equal(r.itens[0].ncm,'12345678');assert.equal(r.itens[0].imposto.ICMS.orig,'0');assert.equal(r.itens[0].imposto.ICMS.CST,'cst90');assert.equal(r.pagamentos[0].tPag,'17');assert.equal(r.totais.vPIS,undefined);
 delete f.snapshot.itens[0].produto.cst_pis;delete f.snapshot.itens[0].produto.gtin;
 const missing=revisaoDoCadastro(f.snapshot);assert.equal(missing.itens[0].imposto.PIS.CST,'');assert.equal(missing.itens[0].gtin,'SEM GTIN');
});
test('CPF e CNPJ podem ser carregados; indicador de contribuinte CNPJ não é presumido',()=>{
 assert.equal(destinoDoCliente({cpf:'529.982.247-25'}).indIEDest,'9');const c=destinoDoCliente({nome:'Empresa',cpf:'11.222.333/0001-81'});assert.equal(c.CNPJCPF,'11222333000181');assert.equal(c.indIEDest,'');const f=dados();f.revisao.dest={...c,indIEDest:'9',enderDest:f.revisao.dest.enderDest};assert.equal(preparar(f.snapshot,f.revisao,f.tecnico).dest.CNPJCPF,'11222333000181');
});
test('pendência é por item/formato: CRT 2 e 3 usam CST confirmado; CRT 1 e 4 mantêm CSOSN sem fallback',()=>{
 for(const crt of ['2','3']){const f=dados();f.snapshot.emitente.crt=crt;const r=revisaoDoCadastro(f.snapshot,f.revisao);assert.deepEqual(pendenciasContrato(f.snapshot,r),[]);assert.equal(preparar(f.snapshot,r,f.tecnico).emit.CRT,crt);}
 for(const crt of ['1','4']){const f=dados();f.snapshot.emitente.crt=crt;f.snapshot.itens[0].produto.cst_csosn='102';const r=revisaoDoCadastro(f.snapshot);assert.equal(r.itens[0].csosn,'102');assert.equal(r.itens[0].imposto.ICMS.CST,undefined);assert.equal(r.itens[0].imposto.ICMS.CSOSN,'102');if(crt==='1')assert.deepEqual(pendenciasContrato(f.snapshot,r),[]);else assert.match(pendenciasContrato(f.snapshot,r).join(' '),/CRT 4/);assert.throws(()=>montarCalculo(f.snapshot,{...r,sem_acessorios:true}),/representação do CSOSN/);}
 const f=dados();f.snapshot.itens.push({...structuredClone(f.snapshot.itens[0]),id:2});f.snapshot.itens[1].produto.cst_csosn='00';const p=pendenciasContrato(f.snapshot,revisaoDoCadastro(f.snapshot));assert.equal(p.length,1);assert.match(p[0],/Item 2/);
});
test('cálculo usa só valores canônicos da venda e campos oficiais; ausência não vira alíquota escolhida',()=>{
 const f=dados(),r=montarCalculo(f.snapshot,f.revisao);assert.equal(r.UFEmitente,'MG');assert.equal(r.det[0].prod.vProd,'20');assert.equal(r.det[0].imposto.ICMS.pICMS,'0');assert.equal(r.det[0].imposto.PIS.pPIS,undefined);
 const changed=structuredClone(f.revisao);changed.itens[0].quantidade=99;assert.equal(montarCalculo(f.snapshot,changed).det[0].prod.qCom,'2');
 changed.itens[0].calculo={ICMS:{CST:'csosn102'}};assert.throws(()=>montarCalculo(f.snapshot,changed),/CST do cálculo diverge/);
 assert.throws(()=>montarCalculo(f.snapshot,{...f.revisao,sem_acessorios:false}),/Confirme a operação/);
});
test('retorno calculado preenche totais e preserva venda; não duplica nenhuma operação',()=>{
 const f=dados(),r=aplicarCalculo(f.snapshot,f.revisao,resposta(f));assert.equal(r.revisao.totais.vICMS,'0');assert.equal(preparar(f.snapshot,r.revisao,f.tecnico).total.ICMSTot.vNF,'20.00');assert.equal(f.snapshot.venda.total,20);
});
test('cálculo com item, CST, origem, despesas, total ou tributo não suportado é recusado',()=>{
 for(const mutate of [b=>b.data.det[0].prod.vProd='21',b=>b.data.det[0].prod.vFrete='1',b=>b.data.det[0].imposto.PIS.CST='49',b=>b.data.det[0].imposto.ICMS.orig='1',b=>b.data.det[0].imposto.ICMS.vICMS='2',b=>b.data.total.ICMSTot.vNF='21',b=>b.data.total.ICMSTot.vST='1',b=>b.data.det[0].nItem='2']){const f=dados(),b=resposta(f);mutate(b);assert.throws(()=>aplicarCalculo(f.snapshot,f.revisao,b));}
});
test('listas não selecionam códigos; preservam paginação parcial e não expõem campos extras',async()=>{
 const calls=[],r=await consultarLista({tipo:'icms',busca:'90',token:'token-teste',fetcher:async(url,options)=>{calls.push([url,options]);return new Response(JSON.stringify({data:{fiscoDetails:[{codeCST:'90',CRT:[2,3],description:'Outros',xmlFields:['orig'],segredo:'não retornar'}],currentPage:1,totalPages:2}}));}});
 assert.equal(calls[0][1].method,'GET');assert.equal(calls[0][1].body,undefined);assert.equal(r.parcial,true);assert.equal(r.total_paginas,2);assert.equal(r.itens[0].segredo,undefined);assert.equal(r.itens[0].codeCST,'90');
});
test('COFINS usa somente aliases documentados e não troca rota em falha de autenticação',async()=>{
 const calls=[];await consultarLista({tipo:'cofins',token:'fake',fetcher:async url=>{calls.push(url);return calls.length===1?new Response('{}',{status:404}):new Response(JSON.stringify({data:{fiscoDetails:[]}}));}});assert.ok(calls[0].endsWith('/lists/cofins'));assert.ok(calls[1].endsWith('/lists/confins'));
 let n=0;await assert.rejects(consultarLista({tipo:'cofins',token:'fake',fetcher:async()=>{n++;return new Response('{}',{status:401});}}));assert.equal(n,1);
 await assert.rejects(consultarLista({tipo:'https://outro.invalid',token:'fake',fetcher:async()=>assert.fail('Rota arbitrária')}));
});
