const test=require('node:test'),assert=require('node:assert/strict'),path=require('node:path');const modulePath=path.resolve(__dirname,'../notas-entrada.js');
const item={descricao:'Areia 4 kg',gtin:null,codigo_fornecedor:'AREIA4',unidade_comercial:'PCT',quantidade:3,valor_unitario:39.9,valor_total:119.7};
test('vínculo do fornecedor é resolvido antes da conversão; quantidade fiscal não muda',async()=>{const {nePrepararVinculos,neDadosConversao}=await import(modulePath),calls=[];const p={id:'p1',nome:'Areia estoque',unidade_comercial:'KG',ativo:true};const r=await nePrepararVinculos({rpc:async(name,args)=>{calls.push({name,args});return {data:{versao:'ne_vinculos_20261119_v1',vinculos:[{codigo_fornecedor:'AREIA4',produto:p}]}}}},{fornecedor:{id:'forn'},itens:[{...item}]});assert.equal(r.itens[0].produto_id,'p1');assert.equal(r.itens[0].unidade_estoque,'KG');assert.equal(r.itens[0].vinculo_origem,'fornecedor');assert.equal(r.itens[0].quantidade,3);assert.equal(r.itens[0].valor_total,119.7);assert.equal(r.itens[0].fator_conversao,1,'não deduz peso do nome');assert.throws(()=>neDadosConversao(r.itens[0],p),/confirme/);r.itens[0].fator_conversao=4;r.itens[0].conversao_confirmada=true;assert.equal(neDadosConversao(r.itens[0],p).quantidade_estoque_entrada,'12');r.itens[0].produto_id=null;assert.throws(()=>neDadosConversao(r.itens[0],null),/já possui vínculo/);assert.equal(calls.length,1)});
test('GTIN tem prioridade sobre vínculo de fornecedor e cliente sem fornecedor não consulta códigos',async()=>{const {nePrepararVinculos}=await import(modulePath);const p={id:'gtin',gtin:'12345678',unidade_comercial:'UN'},q={id:'forn',unidade_comercial:'KG'};const rpc=async name=>({data:name==='notas_entrada_produtos_buscar'?{versao:'ne_20261026_v1',produtos:[p]}:{versao:'ne_vinculos_20261119_v1',vinculos:[{codigo_fornecedor:'AREIA4',produto:q}]}});const r=await nePrepararVinculos({rpc},{fornecedor:{id:'f'},itens:[{...item,gtin:'12345678'}]});assert.equal(r.itens[0].produto_id,'gtin');const calls=[];const n=await nePrepararVinculos({rpc:async name=>calls.push(name)},{fornecedor:{id:null},itens:[{...item}]});assert.equal(n.itens[0].produto_id,null);assert.equal(calls.length,0)});
test('falha na consulta de vínculos interrompe prévia e não confirma entrada',async()=>{const {nePrepararVinculos}=await import(modulePath);await assert.rejects(nePrepararVinculos({rpc:async()=>({error:{code:'42883'}})},{fornecedor:{id:'f'},itens:[{...item}]}),/atualização dos vínculos/)});

test('conflito exige confirmação e envia o vínculo a preservar',async()=>{
 const {neDadosConversao}=await import(modulePath);
 const line={...item,produto_id:'p2',vinculo_fornecedor_id:'p1'};
 const product={id:'p2',unidade_comercial:'PCT'};
 assert.throws(()=>neDadosConversao(line,product),/somente nesta nota/);
 line.confirmou_vinculo_apenas_nota=true;
 assert.equal(neDadosConversao(line,product).preservar_vinculo_fornecedor_id,'p1');
 line.produto_id='p1';
 assert.equal(neDadosConversao(line,{...product,id:'p1'}).preservar_vinculo_fornecedor_id,null);
});
