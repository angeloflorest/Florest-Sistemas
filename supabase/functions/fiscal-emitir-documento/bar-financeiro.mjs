// Conferência financeira do Bar. Nenhum recebimento é alterado por estas funções.
const centavos=v=>{const n=Number(v);if(v===null||v===undefined||!Number.isFinite(n)||Math.abs(n*100-Math.round(n*100))>1e-6)throw Error('Valor monetário inválido no fechamento do Bar.');return Math.round(n*100);};
export function validarSaldoBar(ctx){
 if(!ctx||ctx.status!=='fechada'||ctx.em_edicao!==false)return 'Conclua a edição e feche a mesa antes de emitir o cupom fiscal.';
 try{const saldo=centavos(ctx.saldo);if(saldo!==0)return `A comanda possui saldo de R$ ${(saldo/100).toFixed(2).replace('.',',')}. Quite ou ajuste a conta antes de emitir o cupom fiscal.`;
 if(centavos(ctx.total_final)!==centavos(ctx.total_pago))return 'O total da comanda não confere com os recebimentos. Confira a conta antes de emitir.';}catch(e){return e.message;}
 return null;
}
export function conferirTotaisBar(ctx,bruto,totalComercial,totalRecebido){
 const motivo=validarSaldoBar(ctx);if(motivo)throw Error(motivo);
 const final=centavos(bruto)-centavos(ctx.desconto)+centavos(ctx.outros);
 if(final!==centavos(ctx.total_final)||final!==centavos(totalComercial)||final!==centavos(totalRecebido))throw Error('Inconsistência entre produtos, ajustes, total da venda e recebimentos do Bar.');
 return {desconto:centavos(ctx.desconto)/100,outros:centavos(ctx.outros)/100,total:final/100};
}
export function ratearAjustesBar(itens,desconto,outros){
 const pesos=itens.map(i=>centavos(i.subtotal)),soma=pesos.reduce((s,n)=>s+n,0),d=centavos(desconto),o=centavos(outros);
 if(pesos.some(n=>n<0)||soma<=0||d<0||o<0||d>soma)throw Error('Ajustes fiscais do Bar incompatíveis com os produtos.');
 const ratear=total=>{const linhas=pesos.map((p,i)=>{const n=BigInt(p)*BigInt(total),base=Number(n/BigInt(soma));return {i,base,resto:n%BigInt(soma)}});let falta=total-linhas.reduce((s,x)=>s+x.base,0);for(const x of [...linhas].sort((a,b)=>a.resto===b.resto?a.i-b.i:a.resto>b.resto?-1:1)){if(falta--<=0)break;x.base++;}return linhas.map(x=>x.base/100);};
 const descontos=ratear(d),acrescimos=ratear(o);return pesos.map((_,i)=>({desconto:descontos[i],outros:acrescimos[i]}));
}
