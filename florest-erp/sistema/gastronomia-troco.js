// Conferência visual: o recebimento enviado ao caixa continua sendo apenas a parcela devida.
export function confirmCash({amount,money,current=()=>true}){
 const due=Math.round(Number(amount)*100);
 if(!Number.isSafeInteger(due)||due<=0)throw Error('Informe um valor válido para receber em dinheiro.');
 const el=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e};
 return new Promise(resolve=>{
  const dialog=el('dialog');dialog.className='gs-modal';dialog.style.width='min(440px,94vw)';dialog.setAttribute('aria-label','Conferir dinheiro e troco');
  const title=el('h2','Dinheiro e troco'),form=el('form'),label=el('label','Valor entregue pelo cliente (R$)'),input=el('input'),total=el('p','Valor a cobrar em dinheiro: '+money(due/100)),change=el('p','Troco: —'),status=el('p'),actions=el('div'),cancel=el('button','Voltar'),confirm=el('button','Confirmar recebimento em dinheiro');
  input.type='number';input.id='gs-troco-'+crypto.randomUUID();label.htmlFor=input.id;input.min=(due/100).toFixed(2);input.max='99999999999.99';input.step='.01';input.required=true;input.inputMode='decimal';input.autocomplete='off';
  change.setAttribute('aria-live','polite');change.style.cssText='font-size:24px;font-weight:700';status.setAttribute('role','status');actions.className='gs-actions';cancel.type='button';confirm.type='submit';cancel.className='gs-button';confirm.className='gs-button gs-primary';
  total.append(el('small',' · Somente a parcela deste recebimento.'));form.append(total,label,input,change,status,actions);actions.append(cancel,confirm);dialog.append(title,form);document.body.append(dialog);
  let finished=false;
  function finish(ok){if(finished)return;finished=true;dialog.close();dialog.remove();resolve(ok)}
  function update(){const value=Number(input.value),cents=Math.round(value*100),valid=input.value!==''&&input.validity.valid&&Number.isSafeInteger(cents)&&cents>=due;confirm.disabled=!valid;change.textContent=valid?'Troco: '+money((cents-due)/100):'Troco: —';status.textContent=input.value!==''&&Number.isFinite(value)&&cents<due?'O valor entregue é menor que o valor a cobrar.':'';return valid}
  input.oninput=update;cancel.onclick=()=>finish(false);dialog.addEventListener('cancel',e=>{e.preventDefault();finish(false)});dialog.addEventListener('close',()=>finish(false));form.onsubmit=e=>{e.preventDefault();if(!update()||!form.reportValidity())return;if(!current()){finish(false);return}finish(true)};
  update();dialog.showModal();input.focus();
 });
}
