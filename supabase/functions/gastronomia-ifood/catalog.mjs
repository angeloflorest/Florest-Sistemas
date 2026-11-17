// IDs estáveis e fila por empresa: nunca altera itens fora da integração.
export function catalogPayload(row,categoryId){
 const p=row.payload;if(!p?.id||!p.nome||!Number.isFinite(Number(p.preco))||Number(p.preco)<0)throw Error('Nome ou preço inválido para publicação.');
 const status=p.ativo?'AVAILABLE':'UNAVAILABLE',product={id:p.id,name:p.nome,externalCode:'GSP-'+p.id,optionGroups:[]},products=[product],optionGroups=[],options=[];
 for(const g of p.grupos||[]){const available=(g.opcoes||[]).filter(o=>o.ativo);if(g.minimo>available.length||g.minimo<0||g.maximo<g.minimo)throw Error('Grupo obrigatório sem opções suficientes: '+g.nome);product.optionGroups.push({id:g.id,min:g.minimo,max:g.maximo});optionGroups.push({id:g.id,name:g.nome,status:'AVAILABLE',optionGroupType:'OFFER_UNIT',optionIds:available.map(o=>o.id)});for(const o of available){if(!products.some(p=>p.id===o.produto_id))products.push({id:o.produto_id,name:o.nome,externalCode:'GSP-'+o.produto_id});options.push({id:o.id,productId:o.produto_id,externalCode:'GSO-'+o.id,status:'AVAILABLE',price:{value:0}})}}
 return {item:{id:row.item_id,productId:p.id,type:'DEFAULT',categoryId,status,price:{value:Number(p.preco)},externalCode:'GS-'+p.id},products,optionGroups,options};
}
export async function syncCatalog({empresa,merchant,api,rpc,deadline}){
 const pending=await rpc('catalogo_listar',empresa);if(!pending.length||Date.now()>deadline-5000)return;
 let catalogId,categories;
 try{const catalogs=await api.catalogs(merchant),catalog=catalogs.find(c=>c.status==='AVAILABLE'&&c.context?.includes('DEFAULT'));if(!catalog)throw Error('Catálogo Delivery não disponível na loja.');catalogId=catalog.catalogId;const data=await api.catalog(merchant,'categories',{catalogId});categories=Array.isArray(data)?data:data.categories||[];}catch(e){const row=await rpc('catalogo_reservar',empresa,pending[0]);if(row)await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,ok:false,erro:'Consulta de catálogo: '+(e.message||'Falha de comunicação.')});return}
 for(const next of pending.slice(0,15)){if(Date.now()>deadline-6000)break;const row=await rpc('catalogo_reservar',empresa,next);if(!row)continue;
  try{
   const p=row.payload;let cat=categories.find(c=>c.name?.trim().toLocaleLowerCase('pt-BR')===p.categoria_nome.trim().toLocaleLowerCase('pt-BR')&&c.status==='AVAILABLE');
   if(!cat){cat=await api.catalog(merchant,'createCategory',{catalogId,payload:{name:p.categoria_nome,status:'AVAILABLE',template:'DEFAULT'}});if(!cat?.id)throw Error('Categoria não confirmada pelo iFood.');categories.push(cat)}
   const payload=catalogPayload(row,cat.id);let aviso=null,imagePath=row.remoto?.image_url===p.foto?row.remoto?.image_path:null;
   const waiting=row.remoto?.verificar&&row.remoto?.hash===row.hash;
   if(p.foto&&!waiting){try{if(!imagePath){const {catalogImage}=await import('./image.mjs');const upload=await api.catalog(merchant,'image',{payload:{image:await catalogImage(p.foto,empresa,p.id)}});if(!upload?.imagePath)throw Error('iFood não confirmou o envio da foto.');imagePath=upload.imagePath}payload.products[0].imagePath=imagePath}catch(e){aviso='Foto: '+e.message}}

   if(!waiting)await api.catalog(merchant,'putItem',{payload});
   let actual;try{actual=await api.catalog(merchant,'item',{id:row.item_id})}catch(e){if(e.status===404&&Number(row.remoto?.verificacoes||0)<5){await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,aguardar:true,remoto:{verificar:true,hash:row.hash,verificacoes:Number(row.remoto?.verificacoes||0)+1,image_url:p.foto,image_path:imagePath}});continue}throw e}const item=actual.item||actual;

   if(item.id!==row.item_id||item.status!==payload.item.status||(item.price&&Math.round(item.price.value*100)!==Math.round(payload.item.price.value*100))||payload.optionGroups.some(g=>!(actual.optionGroups||[]).some(r=>r.id===g.id))){if(Number(row.remoto?.verificacoes||0)<5){await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,aguardar:true,remoto:{verificar:true,hash:row.hash,verificacoes:Number(row.remoto?.verificacoes||0)+1,image_url:p.foto,image_path:imagePath}});continue}throw Error('O iFood ainda não confirmou o produto, preço ou complementos.')}
   await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,ok:true,remoto:{id:row.item_id,status:item.status,aviso,image_url:p.foto,image_path:imagePath}});
  }catch(e){await rpc('catalogo_resultado',empresa,{produto_id:row.produto_id,hash:row.hash,ok:false,erro:e.message||'Falha ao publicar produto.'});if(e.status===429||e.status===401||e.status===403)break}
 }
}
