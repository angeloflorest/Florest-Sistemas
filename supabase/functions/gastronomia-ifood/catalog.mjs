// IDs estáveis e fila por empresa: nunca altera itens fora da integração.
export function catalogPayload(row,categoryId){
 const p=row.payload;if(!p?.id||!p.nome||!Number.isFinite(Number(p.preco))||Number(p.preco)<=0||p.nome.trim().length<1||p.nome.trim().length>100||(p.descricao||'').length>500)throw Error('Nome ou preço inválido para publicação.');
 const status=p.ativo?'AVAILABLE':'UNAVAILABLE',product={id:p.id,name:p.nome,externalCode:'GSP-'+p.id,optionGroups:[],...(p.descricao?{description:p.descricao}:{})},products=[product],optionGroups=[],options=[];
 for(const g of p.grupos||[]){const available=(g.opcoes||[]).filter(o=>o.ativo);if(g.minimo>available.length||g.minimo<0||g.maximo<g.minimo)throw Error('Grupo obrigatório sem opções suficientes: '+g.nome);product.optionGroups.push({id:g.id,min:g.minimo,max:g.maximo});optionGroups.push({id:g.id,name:g.nome,status:'AVAILABLE',optionGroupType:'OFFER_UNIT',optionIds:available.map(o=>o.id)});for(const o of available){if(!products.some(p=>p.id===o.produto_id))products.push({id:o.produto_id,name:o.nome,externalCode:'GSP-'+o.produto_id});options.push({id:o.id,productId:o.produto_id,externalCode:'GSO-'+o.id,status:'AVAILABLE',price:{value:0}})}}
 const contexts=(p.contextos||[]).map(c=>{if(!['DEFAULT','WHITELABEL','INDOOR'].includes(c.catalogContext)||!Number.isFinite(Number(c.price?.value))||Number(c.price?.value)<=0||!['AVAILABLE','UNAVAILABLE'].includes(c.status))throw Error('Contexto iFood inválido.');return {catalogContext:c.catalogContext,price:{value:Number(c.price.value)},status:p.ativo?c.status:'UNAVAILABLE'}});
 return {item:{id:row.item_id,productId:p.id,type:'DEFAULT',categoryId,status,price:{value:Number(p.preco)},externalCode:'GS-'+p.id,...(contexts.length?{contextModifiers:contexts}:{})},products,optionGroups,options};
}
export async function syncCatalog({empresa,merchant,api,rpc,deadline,bulk=false}){
 const retry=(e,row={})=>e.status===429?Math.max(30000,e.retryAfter||0):!e.status||e.status>=500?Math.min(300000,1000*2**Number(row.tentativas||0)):0;
 const pending=await rpc('catalogo_listar',empresa);if(!pending.length||Date.now()>deadline-5000)return;
 let catalogId,categories;
 try{const catalogs=await api.catalogs(merchant),catalog=catalogs.find(c=>c.status==='AVAILABLE'&&c.context?.includes('DEFAULT'));if(!catalog)throw Error('Catálogo Delivery não disponível na loja.');catalogId=catalog.catalogId;const data=await api.catalog(merchant,'categories',{catalogId});categories=Array.isArray(data)?data:data.categories||[];}catch(e){const row=await rpc('catalogo_reservar',empresa,pending[0]);if(row)await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,ok:false,retry_ms:retry(e,row),erro:'Consulta de catálogo: '+(e.message||'Falha de comunicação.')});return}
 const reserved=bulk?await rpc('catalogo_reservar_lote',empresa):[];if(!bulk)for(const next of pending.slice(0,100)){const row=await rpc('catalogo_reservar',empresa,next);if(row)reserved.push(row)}
 const reports=[];const report=async data=>{if(bulk)reports.push(data);else await rpc('catalogo_resultado',empresa,data)};
 const sameStructure=(a,b)=>{const clean=x=>{const {preco,ativo,...rest}=x;return rest};return JSON.stringify(clean(a))===JSON.stringify(clean(b))};
 const quick=reserved.filter(r=>r.remoto?.lotes?.length||!r.remoto?.verificar&&Number(r.payload.preco)>0&&r.remoto?.fonte&&(r.payload.preco!==r.remoto.fonte.preco||r.payload.ativo!==r.remoto.fonte.ativo)&&!(r.payload.ativo!==r.remoto.fonte.ativo&&r.payload.contextos?.length)&&sameStructure(r.payload,r.remoto.fonte));
 const handled=new Set(quick);
 const batches=new Map(),newRows=quick.filter(r=>!r.remoto?.lotes?.length);
 try{
  for(const [kind,field,action]of [['preco','price','prices'],['ativo','status','statuses']]){const rows=newRows.filter(r=>r.payload[kind]!==r.remoto.fonte[kind]);if(!rows.length)continue;
   const sent=await api.catalog(merchant,action,{payload:rows.map(r=>({externalCode:'GS-'+r.payload.id,[field]:kind==='preco'?{value:Number(r.payload.preco)}:r.payload.ativo?'AVAILABLE':'UNAVAILABLE',resources:['ITEM']}))});if(!sent?.batchId)throw Error('iFood não confirmou o lote de '+kind+'.');
   for(const row of rows){row.lotes??=[];row.lotes.push(sent.batchId)}
  }
 }catch(e){for(const row of quick)await report({produto_id:row.produto_id,hash:row.hash,ok:false,erro:e.message,retry_ms:retry(e,row)});quick.length=0;for(let i=reserved.length-1;i>=0;i--)if(newRows.includes(reserved[i]))reserved.splice(i,1)}
 if(newRows.some(r=>r.lotes?.length)&&Date.now()+5100<deadline)await new Promise(r=>setTimeout(r,5000));
 for(const row of quick){try{
  const lots=row.remoto?.lotes?.length?row.remoto.lotes:row.lotes||[];let waiting=false;
  for(const id of lots){if(!batches.has(id))batches.set(id,await api.catalog(merchant,'batch',{id}));const result=batches.get(id);if((result.batchStatus||result.status)!=='COMPLETED'){waiting=true;continue}const detail=(result.results||[]).find(r=>[row.produto_id,row.item_id,'GS-'+row.produto_id].includes(r.resourceId));if(!detail||detail.result!=='SUCCESS')throw Error('O iFood não confirmou este produto no lote.');}
  await report({produto_id:row.produto_id,hash:row.hash,...(waiting?{aguardar:true}:{ok:true}),remoto:{...row.remoto,lotes:waiting?lots:[],fonte:waiting?row.remoto?.fonte:row.payload,hash:row.hash}});
 }catch(e){await report({produto_id:row.produto_id,hash:row.hash,ok:false,erro:e.message,retry_ms:retry(e,row)})}}
 if(reports.length)await rpc('catalogo_resultados',empresa,{itens:reports});
 for(const row of reserved.filter(r=>!handled.has(r))){if(Date.now()>deadline-6000){await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,aguardar:true,remoto:row.remoto});continue;}
  try{
   const p=row.payload;let cat=categories.find(c=>c.id===row.remoto?.categoria_id&&row.remoto?.fonte?.categoria===p.categoria);if(cat&&cat.name?.trim().toLocaleLowerCase('pt-BR')!==p.categoria_nome.trim().toLocaleLowerCase('pt-BR')){await api.catalog(merchant,'updateCategory',{catalogId,id:cat.id,payload:{name:p.categoria_nome,status:'AVAILABLE'}});cat.name=p.categoria_nome}cat=cat||categories.find(c=>c.name?.trim().toLocaleLowerCase('pt-BR')===p.categoria_nome.trim().toLocaleLowerCase('pt-BR')&&c.status==='AVAILABLE');
   if(!cat){cat=await api.catalog(merchant,'createCategory',{catalogId,payload:{name:p.categoria_nome,status:'AVAILABLE',template:'DEFAULT'}});if(!cat?.id)throw Error('Categoria não confirmada pelo iFood.');categories.push(cat)}
   const payload=catalogPayload(row,cat.id);let aviso=null,imagePath=row.remoto?.image_url===p.foto?row.remoto?.image_path:null;
   const waiting=row.remoto?.verificar&&row.remoto?.hash===row.hash;
   if(p.foto&&!waiting){try{if(!imagePath){const {catalogImage}=await import('./image.mjs');const upload=await api.catalog(merchant,'image',{payload:{image:await catalogImage(p.foto,empresa,p.id)}});if(!upload?.imagePath)throw Error('iFood não confirmou o envio da foto.');imagePath=upload.imagePath}payload.products[0].imagePath=imagePath}catch(e){aviso='Foto: '+e.message}}

   if(!waiting)await api.catalog(merchant,'putItem',{payload});
   let actual;try{actual=await api.catalog(merchant,'item',{id:row.item_id})}catch(e){if(e.status===404&&Number(row.remoto?.verificacoes||0)<5){await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,aguardar:true,remoto:{verificar:true,hash:row.hash,verificacoes:Number(row.remoto?.verificacoes||0)+1,image_url:p.foto,image_path:imagePath,categoria_id:cat.id,fonte:p}});continue}throw e}const item=actual.item||actual;

   if(item.id!==row.item_id||item.status!==payload.item.status||(item.price&&Math.round(item.price.value*100)!==Math.round(payload.item.price.value*100))||payload.optionGroups.some(g=>!(actual.optionGroups||[]).some(r=>r.id===g.id))){if(Number(row.remoto?.verificacoes||0)<5){await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,aguardar:true,remoto:{verificar:true,hash:row.hash,verificacoes:Number(row.remoto?.verificacoes||0)+1,image_url:p.foto,image_path:imagePath,categoria_id:cat.id,fonte:p}});continue}throw Error('O iFood ainda não confirmou o produto, preço ou complementos.')}
   await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,ok:true,remoto:{id:row.item_id,status:item.status,aviso,image_url:p.foto,image_path:imagePath,categoria_id:cat.id,fonte:p}});
  }catch(e){await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,ok:false,retry_ms:retry(e,row),erro:e.message||'Falha ao publicar produto.'});if(e.status===429||e.status===401||e.status===403)break}
 }
}
