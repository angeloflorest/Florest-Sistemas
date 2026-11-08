(()=>{
 const bar=document.createElement('aside');bar.id='aws-preview-banner';bar.innerHTML='<strong>TESTE AWS</strong> · Vendas salvas somente na cópia de teste. Sem nota fiscal e sem envio ao Supabase. Dados iniciais de 07/11/2026. <a href="/conferir/" target="_blank" rel="noopener">Conferir venda salva</a> · <a href="/simulador/" target="_blank" rel="noopener">Simular queda e retorno</a>';
 document.body.prepend(bar);
 const state=document.createElement('span');state.style.fontWeight='bold';bar.append(' · ',state);
 async function update(){try{const r=await fetch('/lab-control/v1/state',{cache:'no-store'});if(r.ok){const s=await r.json();state.textContent=s.status==='ready'?s.active_label:(s.status==='primary_down'?'Principal de teste indisponível': 'Troca em andamento');}}catch{}}update();setInterval(update,5000);
 const style=document.createElement('style');style.textContent='#aws-preview-banner{position:fixed;top:0;left:0;right:0;z-index:2147483647;padding:10px 16px;background:#fff0b3;color:#432e00;font:13px/1.45 Arial;text-align:center;box-shadow:0 1px 5px #0003}#aws-preview-banner a{color:#123c80;font-weight:bold;white-space:nowrap}#view-pdv{top:58px!important;height:calc(100dvh - 58px)!important}body{padding-top:58px!important}#auth-screen{padding-top:58px!important}';document.head.append(style);
})();
