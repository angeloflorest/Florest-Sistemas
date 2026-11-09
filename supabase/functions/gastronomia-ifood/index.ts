// Preparação: não aceita eventos nem anuncia presença de lojas antes da homologação.
// O adaptador é testado separadamente; não há worker, credenciais ou cron ativo.
Deno.serve((req:Request)=>new Response(JSON.stringify({
 conectado:false,estado:'preparacao',mensagem:'Integração iFood desativada; cadastro e homologação pendentes.'
}),{status:req.method==='POST'?503:405,headers:{'Content-Type':'application/json','Cache-Control':'no-store','Retry-After':'300'}}));
