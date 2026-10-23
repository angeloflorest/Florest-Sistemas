import './taxas-core.js';
const Core=globalThis.FlorestTaxas;
export const agruparDespesasTaxas=Core.agruparDespesas;
const escapeHtml=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function dialogo(titulo,html){
 const d=document.createElement('dialog');
 d.className='taxas-dialog';
 d.innerHTML='<h2>'+escapeHtml(titulo)+'</h2>'+html;
 d.addEventListener('keydown',e=>e.stopPropagation());
 document.body.appendChild(d);
 return d;
}
function escolher(bandeiras,forma){
 return new Promise((resolve,reject)=>{
  const d=dialogo('Bandeira — '+forma,'<p>Selecione a bandeira utilizada neste pagamento.</p><div class="taxas-bandeiras">'+bandeiras.map((b,i)=>'<button type="button" data-brand="'+i+'">'+escapeHtml(b)+'</button>').join('')+'</div><button type="button" data-cancel>Cancelar</button>');
  let concluido=false;
  const cancelar=()=>{if(concluido)return;concluido=true;d.remove();reject(new Error('Pagamento cancelado: nenhuma bandeira selecionada.'));};
  d.addEventListener('cancel',e=>{e.preventDefault();cancelar();});
  d.querySelector('[data-cancel]').onclick=cancelar;
  const buttons=[...d.querySelectorAll('[data-brand]')];
  buttons.forEach((b,i)=>b.onclick=()=>{concluido=true;d.close();d.remove();resolve(bandeiras[i]);});
  d.addEventListener('keydown',e=>{
   const i=buttons.indexOf(document.activeElement);
   if(['ArrowDown','ArrowRight','ArrowUp','ArrowLeft'].includes(e.key)){e.preventDefault();buttons[(Math.max(i,0)+(e.key==='ArrowDown'||e.key==='ArrowRight'?1:buttons.length-1))%buttons.length].focus();}
  });
  d.showModal();buttons[0].focus();
 });
}
export function instalarTaxasPagamento(client){
 if(!client)return;
 const rpc=client.rpc.bind(client);
 const pagamentos={registrar_venda_mista:'p_pagamentos',pdv_comanda_finalizar:'p_pagamentos',bar_comanda_pagar:'p_formas',bar_comanda_pagar_valor:'p_formas'};
 client.rpc=async(name,args,options)=>{
  const chave=pagamentos[name];
  if(!chave||!Array.isArray(args?.[chave])||!args[chave].length)return rpc(name,args,options);
  try{
   const {data:config,error}=await rpc('taxas_pagamento_obter');
   if(error)throw error;
   const lista=[];
   for(const p of args[chave])lista.push({...p,taxas:p.taxas||await Core.preparar(config,p.forma_pagamento,escolher)});
   return rpc(name,{...args,[chave]:lista},options);
  }catch(error){return {data:null,error:{message:error.message||String(error),code:'TAXA_PAGAMENTO'}};}
 };
 const style=document.createElement('style');
 style.textContent='.taxas-dialog{border:1px solid #dce4ed;border-radius:12px;padding:24px;max-width:650px;width:calc(100% - 40px);max-height:85vh;color:#0b2a4d;background:white;font-family:inherit}.taxas-dialog::backdrop{background:#0b2a4d99}.taxas-dialog h2{margin-top:0}.taxas-dialog p{line-height:1.5}.taxas-dialog button{background:#f8c820;color:#0b2a4d;border:0;border-radius:6px;padding:10px 14px;margin:6px;cursor:pointer;font-weight:700}.taxas-dialog input[type=number]{width:110px;padding:8px;border:1px solid #cbd5e1;border-radius:5px}.taxas-dialog table{width:100%;border-collapse:collapse}.taxas-dialog td,.taxas-dialog th{padding:6px;text-align:left;border-bottom:1px solid #e2e8f0}.taxas-dialog .taxas-scroll{max-height:45vh;overflow:auto}.taxas-dialog .taxas-error{color:#b42318}.taxas-dialog label{display:block;line-height:1.6}.taxas-bandeiras{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:5px}';
 document.head.appendChild(style);
 const menu=document.querySelector('#view-financeiro .fin-abas');
 if(!menu)return;
 const b=document.createElement('button');b.type='button';b.className='fin-aba';b.id='fin-formas-pagamento';b.textContent='Formas de pagamento';
 b.onclick=async()=>{
  b.disabled=true;
  try{
   const {data:config,error}=await rpc('taxas_pagamento_obter');if(error)throw error;
   const linhas=[{forma:'Pix',bandeira:null},...Core.formasCartao.flatMap(forma=>Core.bandeiras.map(bandeira=>({forma,bandeira})))];
   const d=dialogo('Cadastro de formas de pagamento','<label><input type="checkbox" id="taxas-ativo"> Controlar taxas de pagamento e solicitar bandeira no caixa</label><p>Configuração somente desta empresa. Válida no PDV, no módulo Bar e no executável atualizado. Crédito e débito à vista.</p><p>O caixa registra o valor integral. A taxa será uma <b>Despesa administrativa de cartões</b> no Financeiro. Deixe em branco as bandeiras que não deseja solicitar. A taxa 0% também conta como cadastrada.</p><form><div class="taxas-scroll"><table><thead><tr><th>Forma</th><th>Bandeira</th><th>Taxa (%)</th></tr></thead><tbody>'+linhas.map((r,i)=>'<tr><td>'+escapeHtml(r.forma)+'</td><td>'+escapeHtml(r.bandeira||'—')+'</td><td><input aria-label="'+escapeHtml(r.forma+' '+(r.bandeira||'')+' taxa percentual')+'" type="number" min="0" max="100" step="0.0001" data-rate="'+i+'"></td></tr>').join('')+'</tbody></table></div><p class="taxas-error" role="alert"></p><button type="submit">Salvar configuração</button><button type="button" data-close>Fechar</button></form>');
   d.querySelector('#taxas-ativo').checked=config.ativo;
   linhas.forEach((r,i)=>{const regra=config.regras.find(x=>x.forma===r.forma&&(x.bandeira||null)===r.bandeira);if(regra)d.querySelector('[data-rate="'+i+'"]').value=regra.percentual;});
   const fechar=()=>{d.close();d.remove();};
   d.querySelector('[data-close]').onclick=fechar;
   d.addEventListener('cancel',e=>{e.preventDefault();fechar();});
   d.querySelector('form').onsubmit=async e=>{
    e.preventDefault();
    const salvar=d.querySelector('[type=submit]'),msg=d.querySelector('.taxas-error');
    salvar.disabled=true;msg.textContent='';
    try{
     const regras=linhas.flatMap((r,i)=>{const value=d.querySelector('[data-rate="'+i+'"]').value;return value===''?[]:[{...r,percentual:Number(value)}];});
     const {error}=await rpc('taxas_pagamento_salvar',{p_ativo:d.querySelector('#taxas-ativo').checked,p_regras:regras});if(error)throw error;
     msg.style.color='#18794e';msg.textContent='Configuração salva. No executável atualizado, use Receber atualizações para aplicar agora.';
    }catch(error){msg.style.color='#b42318';msg.textContent=error.message||String(error);}finally{salvar.disabled=false;}
   };
   d.showModal();
  }catch(error){alert('Não foi possível abrir as formas de pagamento: '+(error.message||error));}finally{b.disabled=false;}
 };
 menu.appendChild(b);
}
