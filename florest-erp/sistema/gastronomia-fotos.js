/* Fotos exclusivas do Módulo Gastronomia. Não altera cadastros de produtos. */
(function(){
'use strict';
const bucket='gastronomia-fotos';
const cache=new Map();
function urlFor(productId){return cache.get(String(productId))||''}
function setPhotos(products){cache.clear();for(const p of products||[])if(p?.id)cache.set(String(p.id),p.foto||'')}
function image(productId,size=44){const url=urlFor(productId);if(!url)return null;const img=document.createElement('img');img.src=url;img.alt='';img.loading='lazy';img.decoding='async';img.referrerPolicy='no-referrer';img.style.cssText='width:'+size+'px;height:'+size+'px;object-fit:cover;border-radius:7px;flex:none;vertical-align:middle;margin-right:8px;background:#f1f5f9';img.onerror=()=>{img.hidden=true};return img}
function addImage(parent,id,size){const img=image(id,size);if(img)parent.prepend(img)}
async function optimize(file){
 if(!/^image\/(jpeg|png|webp)$/.test(file.type))throw Error('Escolha uma foto JPG, PNG ou WebP.');
 if(file.size>15*1024*1024)throw Error('A imagem deve ter no máximo 15 MB.');
 const bitmap=await createImageBitmap(file);const max=800,ratio=Math.min(1,max/Math.max(bitmap.width,bitmap.height));
 const canvas=document.createElement('canvas');canvas.width=Math.max(1,Math.round(bitmap.width*ratio));canvas.height=Math.max(1,Math.round(bitmap.height*ratio));
 canvas.getContext('2d').drawImage(bitmap,0,0,canvas.width,canvas.height);bitmap.close?.();
 const blob=await new Promise((resolve,reject)=>canvas.toBlob(b=>b?resolve(b):reject(Error('Não foi possível preparar a imagem.')),'image/webp',0.78));
 if(blob.size>2*1024*1024)throw Error('A imagem otimizada excede 2 MB. Escolha outra foto.');
 return blob;
}
async function upload(supabase,empresaId,produtoId,file){
 if(!empresaId||!produtoId)throw Error('Empresa ou produto não identificado.');
 const blob=await optimize(file);
 const path=empresaId+'/'+produtoId+'/'+crypto.randomUUID()+'.webp';
 const {error}=await supabase.storage.from(bucket).upload(path,blob,{contentType:'image/webp',upsert:false,cacheControl:'31536000'});
 if(error)throw error;
 const {data}=supabase.storage.from(bucket).getPublicUrl(path);
 if(!data?.publicUrl)throw Error('Não foi possível obter o endereço da foto.');
 return data.publicUrl;
}
function picker(row,initial){
 const container=document.createElement('div');container.className='gs-foto-controle';
 const preview=document.createElement('img');preview.alt='Foto do produto';preview.loading='lazy';preview.style.cssText='width:90px;height:90px;object-fit:contain;border-radius:8px;background:#f1f5f9';
 const input=document.createElement('input');input.type='file';input.accept='image/jpeg,image/png,image/webp';input.style.display='none';
 const button=document.createElement('button');button.type='button';button.className='gs-button';button.textContent='Escolher foto do computador';
 const remove=document.createElement('button');remove.type='button';remove.className='gs-button';remove.textContent='Remover foto';
 const state={url:initial||'',file:null,previewUrl:null};
 function refresh(){preview.style.visibility=state.url||state.file?'visible':'hidden';preview.src=state.previewUrl||state.url||''}
 button.onclick=()=>input.click();
 input.onchange=()=>{const file=input.files?.[0];if(!file)return;if(!/^image\/(jpeg|png|webp)$/.test(file.type)){alert('Escolha JPG, PNG ou WebP.');return}if(file.size>15*1024*1024){alert('Imagem acima de 15 MB.');return}if(state.previewUrl)URL.revokeObjectURL(state.previewUrl);state.file=file;state.previewUrl=URL.createObjectURL(file);refresh()};
 remove.onclick=()=>{if(state.previewUrl)URL.revokeObjectURL(state.previewUrl);state.file=null;state.url='';state.previewUrl=null;input.value='';refresh()};
 container.append(preview,button,remove,input);row.append(container);refresh();return state;
}
window.GSFotos={setPhotos,urlFor,image,addImage,upload,picker};
})();
