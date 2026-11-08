
// Adaptação exclusiva do contêiner Windows; os controles operacionais acima são os do ERP.
let desktopPolling=false,desktopStatus=null;
window.florestBar.onStatus(s=>{desktopStatus=s;});
window.florestBarHasWork=()=>barMesaCarrinho.length>0||barMesaRecebendo||barTransferindoMesa;
setInterval(async()=>{
 if(desktopPolling||viewAtual!=='bar'||document.hidden||barMesaRecebendo||barTransferindoMesa)return;
 const focus=document.activeElement;if(focus?.matches('input,textarea,select')&&focus.closest('.modal-overlay:not(.hidden)'))return;
 desktopPolling=true;
 try{
  if(barSubViewAtual==='mesas'){
   const selected=barComandaAtualId,table=barMesaAtual?.id;
   await carregarBarMesas();
   if(selected&&table&&barMesaAtual?.id===table&&!$('modal-bar-mesa').classList.contains('hidden')){
    const {data:current,error}=await supabase.from('bar_mesas').select('*').eq('id',table).single();
    if(!error&&current?.comanda_atual_id===selected)await atualizarSaldoEItensMesa();
    else if(!error&&current?.comanda_atual_id!==selected)$('bar-mesa-msg').textContent='Esta mesa foi alterada em outro terminal. Preserve o pedido em preparação e reabra a mesa antes de confirmar.';
   }
  }else if(barSubViewAtual==='caixa')await cxBarAbrirSub();
 }catch{}finally{desktopPolling=false;}
},5000);
window.florestBar.onCommand(async command=>{
 if(command==='pending'){
  const s=await window.florestBar.status();const esc=escapeHtml;
  await florestDialog('Operações locais',`<p>${s.online?'Conectado':'Sem conexão'} · Terminal ${esc(s.terminal)}</p><p>Consultas usam a última cópia autenticada. Pedidos em preparação ficam guardados neste terminal.</p><p>Sem conexão, pagamento, fechamento, transferência, junção e alterações compartilhadas ficam bloqueados para evitar conflitos. Recuperações automáticas usam somente a chave original em RPCs idempotentes.</p>`+s.pending.map(p=>`<p>${esc(p.action)} · ${esc(p.state)}<br>${esc(p.error||'Aguardando confirmação')}<br>Identificador: ${esc(p.id)}</p>`).join(''),'Fechar');
 }
});
