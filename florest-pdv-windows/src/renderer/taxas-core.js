(function(root,factory){
"use strict";
const api=factory();
if(typeof module==="object"&&module.exports)module.exports=api;
else root.FlorestTaxas=api;
})(typeof globalThis!=="undefined"?globalThis:this,function(){
"use strict";
const bandeiras=Object.freeze(["Visa","Mastercard","Elo","American Express","Hipercard","Diners"]);
const formasCartao=Object.freeze(["Cartão de Débito","Cartão de Crédito"]);
async function preparar(config,forma,perguntar){
 const meta={config_id:config?.id||null,bandeira:null};
 if(!config?.ativo||!formasCartao.includes(forma))return meta;
 const regras=(config.regras||[]).filter(r=>r.forma===forma&&bandeiras.includes(r.bandeira));
 if(!regras.length)return meta;
 const escolhida=await perguntar(regras.map(r=>r.bandeira),forma);
 if(!regras.some(r=>r.bandeira===escolhida))throw new Error("Selecione uma bandeira cadastrada.");
 meta.bandeira=escolhida;
 return meta;
}
function agruparDespesas(lista){
 const taxas=lista.filter(d=>d.taxas_automaticas);
 if(!taxas.length)return lista;
 return [...lista.filter(d=>!d.taxas_automaticas),{...taxas[0],id:null,
 descricao:"Despesa administrativa de cartões",categoria:"",
 valor:taxas.reduce((s,d)=>s+Math.round(Number(d.valor)*100),0)/100,taxas_automaticas:true}];
}
return Object.freeze({bandeiras,formasCartao,preparar,agruparDespesas});
});
