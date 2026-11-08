import asyncio,json,uuid,sys
from pathlib import Path
from playwright.async_api import async_playwright
ROOT=Path(__file__).resolve().parents[1];BASE='https://florest-reserva.77-112-23-104.sslip.io';A='florest_backend_teste_20261108';B='florest_retorno_teste_20261108'
async def main():
 actor=json.loads((ROOT/'.runtime/browser-actor.json').read_text());code=(ROOT/'.runtime/lab-control-code').read_text().strip();markers=ROOT/('.runtime/full-cycle-tax-markers.json'if '--tax'in sys.argv else '.runtime/full-cycle-markers.json')
 if markers.exists():raise RuntimeError('Ciclo já iniciado; conferir comprovantes antes de repetir vendas')
 records={};checks=[];primary=[]
 def check(name,ok):
  checks.append({'test':name,'passed':bool(ok)})
  if not ok:raise RuntimeError('Falha no ciclo: '+name)
 async with async_playwright()as p:
  browser=await p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox']);context=await browser.new_context(viewport={'width':1440,'height':1050});page=await context.new_page();lab=await context.new_page()
  context.on('request',lambda r:primary.append(r.url.split('?')[0])if 'etulhyboogqhyyevpnlo.supabase.co'in r.url else None)
  await lab.goto(BASE+'/simulador/',wait_until='networkidle',timeout=45000);await lab.locator('#code').fill(code)
  denied=await lab.evaluate("async()=>{const r=await fetch('/lab-control/v1/action',{method:'POST',headers:{'content-type':'application/json','x-florest-test-control':'incorrect-test-code'},body:JSON.stringify({action:'activate_reserve'})});return r.status;}")
  check('Troca recusada sem código válido',denied in [401,429])
  async def action(name,expected,available):
   await lab.locator('[data-action="'+name+'"]').click()
   await lab.wait_for_function("document.querySelector('#message').textContent.includes('Ação concluída')",timeout=120000)
   s=await lab.evaluate("async()=>{const r=await fetch('/lab-control/v1/state');return r.json();}");check('Estado após '+name,s['active_database']==expected and s['primary_available']==available and s['production_changed']is False)
  await action('return_primary',B,True)
  await page.goto(BASE+'/erp/',wait_until='networkidle',timeout=60000)
  for field,value in [('empresa',actor['company_email']),('usuario',actor['username']),('senha',actor['password'])]:await page.locator('#login-erp-'+field).fill(value)
  await page.locator('#login-erp-senha').press('Enter');await page.wait_for_function("!document.querySelector('#app-screen').classList.contains('hidden')",timeout=45000)
  await page.wait_for_timeout(1500)
  if not await page.locator('#view-pdv').is_visible():await page.locator('#nav-pdv').click()
  async def sale(phase):
   product=await page.evaluate('''async()=>{const{createClient}=await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm');const c=createClient(FLOREST_PREVIEW.url,FLOREST_PREVIEW.anonKey,{auth:{storageKey:'florest-aws-teste-session'}});const{data,error}=await c.from('produtos').select('id,codigo,preco_venda').gt('quantidade_estoque',1).gt('preco_venda',0).eq('venda_granel',false).eq('ativo',true).not('codigo','is',null).limit(1);if(error)throw Error(error.message);if(!data.length)throw Error('Produto de teste indisponível');return data[0];}''')
   await page.locator('#pdv-busca-produto').fill(product['codigo']);await page.locator('#pdv-busca-produto').press('Enter');await page.wait_for_timeout(1500)
   positive=await page.locator('#pdv-total').evaluate("e=>Number(e.innerText.replace(/[^0-9]/g,''))>0")
   if not positive:await page.locator('#btn-adicionar-pdv').click()
   await page.wait_for_function("Number(document.querySelector('#pdv-total').innerText.replace(/[^0-9]/g,''))>0",timeout=15000)
   await page.locator('.pdx-pg[data-forma="Dinheiro"]').click();await page.wait_for_function("!document.querySelector('#btn-finalizar-venda').disabled",timeout=15000)
   records[phase]={'status':'started','product_id':product['id']};markers.write_text(json.dumps(records));markers.chmod(0o600)
   async with page.expect_response(lambda r:'/rpc/florest_sandbox_registrar_venda_mista'in r.url,timeout=50000)as future:await page.locator('#btn-finalizar-venda').click()
   response=await future.value;data=await response.json()
   if response.status!=200:raise RuntimeError('Venda do ensaio não confirmada: HTTP '+str(response.status)+' código '+str(data.get('code')if isinstance(data,dict)else''))
   request=response.request.post_data_json;s=data[0]
   records[phase].update(status='saved',sale_id=s['venda_id'],number=s['numero_venda'],operation=request['p_operacao'],receipt=response.headers.get('x-florest-test-receipt'),request=request)
   markers.write_text(json.dumps(records));check('Venda '+phase+' confirmada',bool(s['venda_id']))
   if '--tax'in sys.argv:check('Preparação original das taxas preservada em '+phase,all('taxas'in item for item in request['p_args']['p_pagamentos']))
   # Evita um diálogo fiscal opcional cobrir o próximo ensaio; nenhuma emissão é clicada.
   await page.evaluate("document.querySelectorAll('dialog[open]').forEach(d=>d.close())")
   await page.reload(wait_until='networkidle');await page.wait_for_function("!document.querySelector('#app-screen').classList.contains('hidden')",timeout=30000);
   if not await page.locator('#view-pdv').is_visible():await page.locator('#nav-pdv').click()
   await page.wait_for_timeout(800)
   return records[phase]
  first=await sale('principal')
  check('Venda do principal aceita somente com espelho confirmado',first['receipt']=='shadow-confirmed')
  await action('simulate_primary_failure',None,False)
  down=await page.evaluate("async()=>{const token=JSON.parse(localStorage.getItem('florest-aws-teste-session')).access_token;const r=await fetch('/rest/v1/vendas?select=id&limit=1',{headers:{apikey:FLOREST_PREVIEW.anonKey,authorization:'Bearer '+token}});return r.status;}")
  check('Principal indisponível não recebe nova operação',down==503)
  await action('activate_reserve',A,False)
  # O pedido em tela continua no mesmo endereço, agora gravando na reserva.
  await page.reload(wait_until='networkidle');await page.wait_for_function("!document.querySelector('#app-screen').classList.contains('hidden')",timeout=30000);
  if not await page.locator('#view-pdv').is_visible():await page.locator('#nav-pdv').click()
  await page.wait_for_timeout(800)
  second=await sale('reserva')
  check('Venda durante queda fica durável na AWS e pendente de retorno',second['receipt']=='durable-reserve-pending-return')
  async def find_sale(path,number):
   return await page.evaluate("""async({path,number})=>{const token=JSON.parse(localStorage.getItem('florest-aws-teste-session')).access_token;const q=new URLSearchParams({select:'id,numero_venda,total',numero_venda:'eq.'+number});const r=await fetch(path+'vendas?'+q,{headers:{apikey:FLOREST_PREVIEW.anonKey,authorization:'Bearer '+token}});if(!r.ok)throw Error('Consulta recusada');return r.json();}""",{'path':path,'number':number})
  reserve=await find_sale('/reserva/rest/v1/',second['number']);returned=await find_sale('/retorno/rest/v1/',second['number'])
  check('Venda da queda existe na reserva',len(reserve)==1 and reserve[0]['id']==second['sale_id'])
  check('Venda da queda não foi transmitida ao principal indisponível',not returned)
  await action('return_primary',B,True)
  for item in [first,second]:
   x=await find_sale('/reserva/rest/v1/',item['number']);y=await find_sale('/retorno/rest/v1/',item['number'])
   check('Venda '+str(item['number'])+' presente uma vez nos dois bancos',len(x)==len(y)==1 and x==y)
  duplicate=await page.evaluate("""async request=>{const token=JSON.parse(localStorage.getItem('florest-aws-teste-session')).access_token;const r=await fetch('/rest/v1/rpc/florest_sandbox_registrar_venda_mista',{method:'POST',headers:{apikey:FLOREST_PREVIEW.anonKey,authorization:'Bearer '+token,'content-type':'application/json'},body:JSON.stringify(request)});return{status:r.status,data:await r.json()};}""",second['request'])
  check('Mesma tentativa após retorno devolve a mesma venda',duplicate['status']==200 and duplicate['data'][0]['venda_id']==second['sale_id'])
  check('Nenhuma chamada do navegador ao Supabase real',not primary)
  await lab.screenshot(path=str(ROOT/('lab-full-cycle-tax.png'if '--tax'in sys.argv else 'lab-full-cycle.png')),full_page=True)
  proof={'all_passed':all(x['passed']for x in checks),'tests':checks,'sales':[{k:v for k,v in item.items()if k not in ['request']}for item in [first,second]],'primary_requests':len(primary),'production_changed':False,'actual_supabase_failover_ready':False}
  (ROOT/('lab-full-cycle-tax-proof.json'if '--tax'in sys.argv else 'lab-full-cycle-proof.json')).write_text(json.dumps(proof,indent=2));print(json.dumps(proof));await browser.close()
asyncio.run(main())
