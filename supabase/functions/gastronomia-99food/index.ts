// Preparação: não acusa recebimento de pedidos enquanto não existir processamento homologado.
// Não publicar como webhook operacional nem cadastrar na plataforma nesta etapa.
Deno.serve((req:Request)=>new Response(JSON.stringify({conectado:false,estado:'preparacao',mensagem:'Integração 99Food desativada; credenciais, testes e autorização pendentes.'}),{status:req.method==='POST'?503:405,headers:{'Content-Type':'application/json','Cache-Control':'no-store','Retry-After':'300'}}));
