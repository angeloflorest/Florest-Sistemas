async function florestSandboxVendaMista(args){
 const {data:{session}}=await supabase.auth.getSession();
 if(!session?.user?.id)return{data:null,error:{code:'LAB_SESSION',message:'Entre novamente no ERP de teste.'}};
 const key='florest.lab.sale.operation.'+session.user.id,signature=JSON.stringify(args);let operation,hadPending=false,sendArgs;
 try{
  let raw=localStorage.getItem(key),pending=raw?JSON.parse(raw):null;hadPending=!!pending;
  if(pending&&pending.signature!==signature)return{data:null,error:{code:'LAB_PENDING_CART',message:'Há uma tentativa anterior com outros dados. Confira o histórico antes de iniciar outra venda.'}};
  if(pending){operation=pending.id;sendArgs=pending.args||args;}
  else{
   // Usa a mesma preparação de taxas e bandeiras do fluxo original do ERP.
   try{sendArgs={...args,p_pagamentos:await prepararTaxasRecebimentoMesa(supabase,args.p_pagamentos)};}
   catch(error){return{data:null,error:{code:'TAXA_PAGAMENTO',message:error.message||'Não foi possível preparar as formas de pagamento.'}};}
   raw=localStorage.getItem(key);pending=raw?JSON.parse(raw):null;
   if(pending){
    hadPending=true;
    if(pending.signature!==signature)return{data:null,error:{code:'LAB_PENDING_CART',message:'Outra tentativa está pendente neste navegador. Confira o histórico.'}};
    operation=pending.id;sendArgs=pending.args||args;
   }else{operation=crypto.randomUUID();localStorage.setItem(key,JSON.stringify({id:operation,signature,args:sendArgs}));}
  }
 }catch{return{data:null,error:{code:'LAB_STORAGE',message:'Não foi possível preservar a tentativa neste navegador. Nenhuma venda foi enviada.'}};}
 const result=await supabase.rpc('florest_sandbox_registrar_venda_mista',{p_operacao:operation,p_args:sendArgs});
 const knownRollback=!hadPending&&result.error&&/^[A-Z0-9]{5}$/.test(result.error.code||'');
 if((!result.error&&result.data?.[0]?.venda_id)||knownRollback){
  try{const current=JSON.parse(localStorage.getItem(key)||'null');if(current?.id===operation)localStorage.removeItem(key);}catch{}
 }
 return result;
}
