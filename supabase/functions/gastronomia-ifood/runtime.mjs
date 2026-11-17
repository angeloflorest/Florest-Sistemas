import {createIFoodClient,IFoodError} from './adapter.mjs';
export function serverClient({cfg,empresa,rpc,fetchImpl=fetch}){
 return createIFoodClient({enabled:true,...cfg.credenciais,merchants:[cfg.merchant_id],fetchImpl,
  tokenStore:{get:()=>rpc('h_token_obter',empresa),acquire:()=>rpc('h_token_reservar',empresa),save:data=>rpc('h_token_salvar',empresa,data),invalidate:accessToken=>rpc('h_token_invalidar',empresa,{accessToken}),release:()=>rpc('h_token_liberar',empresa)},
  beforePoll:async()=>{const limit=Date.now()+5500;let wait=Number(await rpc('h_marcar_poll',empresa));while(wait>0){if(Date.now()+wait>limit)throw new IFoodError('Aguarde o intervalo de consulta iFood.',{retryAfter:wait});await new Promise(r=>setTimeout(r,wait+5));wait=Number(await rpc('h_marcar_poll',empresa))}}
 });
}
