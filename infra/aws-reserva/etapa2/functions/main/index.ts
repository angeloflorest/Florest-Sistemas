// Executa somente o login original nesta primeira etapa.
Deno.serve(async (req: Request) => {
  const path = new URL(req.url).pathname;
  if (path !== '/functions/v1/florest-login') {
    return new Response(JSON.stringify({erro:'funcao_ainda_nao_implantada'}), {status:503,headers:{'content-type':'application/json'}});
  }
  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath: '/home/deno/functions/florest-login',
      memoryLimitMb: 128,
      workerTimeoutMs: 15000,
      noModuleCache: false,
      envVars: Object.entries(Deno.env.toObject()),
    });
    return await worker.fetch(req);
  } catch {
    return new Response(JSON.stringify({ok:false,erro:'login_indisponivel',mensagem:'Não foi possível concluir o acesso no ambiente de teste.'}),{status:503,headers:{'content-type':'application/json'}});
  }
});
