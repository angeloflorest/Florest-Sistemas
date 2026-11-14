// Apenas apresentação pós-venda. Recebimentos, estoque e autorização fiscal continuam no ERP.
export function criarPerguntaCupom({escopo,permitido,preparar,selecionar,emitir,mensagem,imprimir,contingencia,falhaTecnica,tentarContingencia}){
 const apresentados=new Set(),fila=[];
 let atual=null;
 const el=(tag,text)=>{const node=document.createElement(tag);if(text!==undefined)node.textContent=text;return node;};
 function proximo(){
  if(atual||!fila.length)return;
  const item=fila.shift(),dialog=el('dialog'),card=el('div'),titulo=el('h3',item.numeroVenda?`Venda #${item.numeroVenda} concluída`:'Venda concluída'),pergunta=el('p','Deseja emitir cupom fiscal?'),feedback=el('div'),sim=el('button','Sim, emitir cupom fiscal'),sair=el('button','Não, sair'),print=el('button','Imprimir cupom fiscal'),recibo=item.imprimirComprovante?el('button','Imprimir comprovante (não fiscal)'):null;
  if(item.escopo!==JSON.stringify(escopo())){proximo();return;}
  atual={item,dialog};dialog.id='dialog-cupom-pos-venda';dialog.setAttribute('aria-labelledby','cupom-pos-venda-titulo');titulo.id='cupom-pos-venda-titulo';
  dialog.style.cssText='border:1px solid var(--border,#bbb);border-radius:12px;padding:24px;max-width:440px;max-height:90vh;overflow:auto;width:calc(100% - 40px);box-sizing:border-box;background:var(--card,#fff);color:var(--ink,#172536);font:inherit;';
  card.style.cssText='display:flex;flex-direction:column;gap:12px;text-align:center';feedback.setAttribute('role','status');feedback.setAttribute('aria-live','polite');
  for(const button of [sim,sair,print,recibo].filter(Boolean)){button.type='button';button.className=button===sim?'btn-accent':'btn-secondary';button.style.width='100%';}
  print.hidden=true;card.append(titulo);if(item.detalhe)card.append(el('p',item.detalhe));card.append(pergunta,feedback,sim,print);if(recibo)card.append(recibo);card.append(sair);dialog.append(card);document.body.append(dialog);
  let ocupado=false,documento=null,vendaId=item.vendaId;
  const erro=e=>{feedback.textContent=e?.message||String(e);};
  const executar=async fn=>{if(ocupado)return;ocupado=true;for(const b of [sim,sair,print,recibo].filter(Boolean))b.disabled=true;try{if(item.escopo!==JSON.stringify(escopo()))throw Error('A sessão mudou. Consulte a venda na empresa original pela tela Fiscal.');await fn();}catch(e){erro(e);}finally{ocupado=false;for(const b of [sim,sair,print,recibo].filter(Boolean))b.disabled=false;}};
  // A contingência já tem sua própria janela; não cobri-la com um dialog modal nativo.
  const suspender=async fn=>{dialog.close();try{return await fn();}finally{if(dialog.isConnected)dialog.showModal();}};
  const fechar=()=>{if(ocupado)return;dialog.close();dialog.remove();atual=null;if(item.aoFechar)item.aoFechar();proximo();};
  sair.onclick=fechar;dialog.addEventListener('cancel',event=>{event.preventDefault();fechar();});
  print.onclick=()=>executar(async()=>{await imprimir(documento);feedback.textContent='Impressão do cupom fiscal solicitada.';});
  if(recibo)recibo.onclick=()=>executar(async()=>{await item.imprimirComprovante();feedback.textContent='Comprovante não fiscal enviado para impressão.';});
  sim.onclick=()=>executar(async()=>{
   // A configuração controla a emissão, nunca esconde a pergunta de uma venda concluída.
   feedback.textContent='Conferindo emissão fiscal…';
   if(!await permitido())throw Error('A emissão pelo caixa está desativada nas configurações fiscais da empresa. A venda está registrada.');
   if(!vendaId)vendaId=await item.resolverVenda?.();
   if(!vendaId)throw Error('Não foi possível localizar a venda para emitir o cupom. Tente novamente ou consulte a tela Fiscal.');
   if(await contingencia(vendaId,feedback,suspender))return;
   const doc=selecionar(await preparar(vendaId));
   if(!doc)throw Error('Esta venda não tem item de mercadoria para gerar NFC-e.');
   const resultado=doc.status==='autorizada'?{status:'autorizada',numero:doc.numero}:await emitir(doc.id);
   feedback.innerHTML=mensagem(resultado);
   if(resultado?.status==='autorizada'){
    documento=doc.id;sim.hidden=true;print.hidden=false;sair.textContent='Sair';
    try{await imprimir(documento);}catch(e){feedback.append(el('p','Cupom autorizado. '+(e?.message||'Não foi possível abrir a impressão. Use Imprimir cupom fiscal.')));}
   }else if(falhaTecnica(resultado))await suspender(()=>tentarContingencia(doc.id,vendaId,feedback));
  });
  dialog.showModal();sim.focus();
 }
 return function perguntar(item){
  const chave=JSON.stringify([escopo(),item.chave||item.vendaId]);
  if(!item.vendaId&&!item.resolverVenda)return;
  if(apresentados.has(chave))return;
  apresentados.add(chave);fila.push({...item,escopo:JSON.stringify(escopo())});proximo();
 };
}
