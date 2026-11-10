// Conferência visual: o recebimento enviado ao caixa continua sendo apenas a parcela devida.
export function confirmCash({amount,money,current=()=>true}){
 const due=Math.round(Number(amount)*100);
 if(!Number.isSafeInteger(due)||due<=0)throw Error('Informe um valor válido para receber em dinheiro.');
 const el=(tag,text)=>{const e=document.createElement(tag);if(text!==undefined)e.textContent=text;return e};
 return new Promise(resolve=>{
  const dialog=el('dialog');dialog.className='gs-modal gs-cash-change';dialog.style.width='min(520px,94vw)';dialog.setAttribute('aria-label','Conferir dinheiro e troco');
  const title=el('h2','Dinheiro e troco'),form=el('form'),label=el('label','Valor entregue pelo cliente (R$)'),input=el('input'),total=el('p','Valor a cobrar em dinheiro: '+money(due/100)),change=el('p','Troco: —'),status=el('p'),actions=el('div'),cancel=el('button','Voltar'),confirm=el('button','Confirmar recebimento em dinheiro');
  input.type='number';input.id='gs-troco-'+crypto.randomUUID();label.htmlFor=input.id;input.min=(due/100).toFixed(2);input.max='99999999999.99';input.step='.01';input.required=true;input.inputMode='decimal';input.autocomplete='off';
  change.setAttribute('aria-live','polite');change.style.cssText='font-size:24px;font-weight:700';status.setAttribute('role','status');actions.className='gs-actions';cancel.type='button';confirm.type='submit';cancel.className='gs-button';confirm.className='gs-button gs-primary';
  total.append(el('small',' · Somente a parcela deste recebimento.'));form.append(total,label,input,change,status,actions);actions.append(cancel,confirm);dialog.append(title,form);document.body.append(dialog);
  const style=el('style');style.textContent=`
dialog.gs-cash-change{box-sizing:border-box;padding:24px;border:1px solid #dce4ed;border-radius:18px;color:#0b2a4d;background:#fff;box-shadow:0 20px 70px #0b2a4d40;max-height:90dvh;overflow:auto}
dialog.gs-cash-change h2{font-size:24px;line-height:1.3;margin:0 0 18px}
dialog.gs-cash-change form>p:first-child{padding:14px 16px;margin:0 0 18px;border-radius:12px;background:#f0f5fa;line-height:1.6;font-weight:600}
dialog.gs-cash-change small{display:block;color:#718096;font-size:12px;font-weight:400}
dialog.gs-cash-change label{font-size:14px;font-weight:600;margin:0 0 8px}
dialog.gs-cash-change input{box-sizing:border-box;min-height:52px;font-size:20px;border:1px solid #bdccdc;border-radius:10px;padding:12px}
dialog.gs-cash-change input:focus{outline:2px solid #1565c0;outline-offset:2px}
dialog.gs-cash-change p[aria-live]{margin:18px 0 10px;padding:16px;border:1px solid #f5dfa0;border-radius:12px;background:#fff9e5;line-height:1.4}
dialog.gs-cash-change p[role=status]{color:#b42318;font-size:14px;line-height:1.5}
dialog.gs-cash-change p[role=status]:empty{display:none}
dialog.gs-cash-change .gs-actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}
dialog.gs-cash-change .gs-actions button{box-sizing:border-box;min-height:48px;padding:12px 16px;border:1px solid #e9b900;border-radius:10px;background:#facc15;color:#0b2a4d;font:700 14px/1.4 Arial,sans-serif;cursor:pointer;transition:background .15s,box-shadow .15s}
dialog.gs-cash-change .gs-actions button[type=submit]{flex:1}
dialog.gs-cash-change .gs-actions button:hover:not(:disabled){background:#f4bd00;box-shadow:0 3px 10px #b58a0026}
dialog.gs-cash-change .gs-actions button:focus-visible{outline:3px solid #1565c0;outline-offset:3px}
dialog.gs-cash-change .gs-actions button:disabled{opacity:.5;cursor:default}
@media(max-width:480px){dialog.gs-cash-change{padding:20px}dialog.gs-cash-change .gs-actions{flex-direction:column}dialog.gs-cash-change .gs-actions button{width:100%}}
`;dialog.prepend(style);
  let finished=false;
  function finish(ok){if(finished)return;finished=true;dialog.close();dialog.remove();resolve(ok)}
  function update(){const value=Number(input.value),cents=Math.round(value*100),valid=input.value!==''&&input.validity.valid&&Number.isSafeInteger(cents)&&cents>=due;confirm.disabled=!valid;change.textContent=valid?'Troco: '+money((cents-due)/100):'Troco: —';status.textContent=input.value!==''&&Number.isFinite(value)&&cents<due?'O valor entregue é menor que o valor a cobrar.':'';return valid}
  input.oninput=update;cancel.onclick=()=>finish(false);dialog.addEventListener('cancel',e=>{e.preventDefault();finish(false)});dialog.addEventListener('close',()=>finish(false));form.onsubmit=e=>{e.preventDefault();if(!update()||!form.reportValidity())return;if(!current()){finish(false);return}finish(true)};
  update();dialog.showModal();input.focus();
 });
}
