import asyncio,json,sys
from pathlib import Path
from playwright.async_api import async_playwright
ROOT=Path(__file__).resolve().parents[1]
async def main():
 actor=json.loads((ROOT/'.runtime/browser-actor.json').read_text());base='https://florest-reserva.77-112-23-104.sslip.io'
 async with async_playwright()as p:
  browser=await p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox'])
  context=await browser.new_context(viewport={'width':1440,'height':1000});page=await context.new_page();errors=[];failed=[];primary=[]
  async def detail(response):
   if response.url.startswith(base)and response.status>=400:
    try:
     data=await response.json()
     if isinstance(data,dict):failed.append({'status':response.status,'message':data.get('message'),'code':data.get('code')})
    except Exception:pass
  page.on('response',detail)
  page.on('pageerror',lambda e:errors.append(str(e)[:300]))
  page.on('response',lambda r:failed.append({'status':r.status,'path':r.url.split(base)[-1].split('?')[0]})if r.url.startswith(base)and r.status>=400 else None)
  page.on('request',lambda r:primary.append(r.url.split('?')[0])if 'etulhyboogqhyyevpnlo.supabase.co' in r.url else None)
  await page.goto(base+'/erp/',wait_until='networkidle',timeout=60000)
  await page.locator('#login-erp-empresa').fill(actor['company_email'])
  await page.locator('#login-erp-usuario').fill(actor['username'])
  await page.locator('#login-erp-senha').fill(actor['password'])
  await page.locator('#login-erp-senha').press('Enter')
  try:await page.wait_for_function("!document.querySelector('#app-screen').classList.contains('hidden')",timeout=45000);logged=True
  except Exception:logged=False
  if logged:
   await page.locator('#nav-pdv').click()
   await page.wait_for_timeout(3500)
   if '--sale' in sys.argv:
    marker=ROOT/('.runtime/browser-roundtrip-marker.json'if '--roundtrip'in sys.argv else '.runtime/browser-sale-marker.json')
    if marker.exists():raise RuntimeError('Uma tentativa de venda já está registrada; não repetir automaticamente.')
    product=await page.evaluate('''async()=>{const{createClient}=await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm');const c=createClient(FLOREST_PREVIEW.url,FLOREST_PREVIEW.anonKey,{auth:{storageKey:'florest-aws-teste-session'}});const{data,error}=await c.from('produtos').select('id,codigo,gtin,nome,preco_venda,quantidade_estoque,venda_granel').gt('quantidade_estoque',1).gt('preco_venda',0).eq('venda_granel',false).eq('ativo',true).not('codigo','is',null).limit(1);if(error)throw Error(error.message);if(!data.length)throw Error('Não há produto para teste.');return data[0];}''')
    await page.locator('#pdv-busca-produto').fill(product['codigo'])
    await page.locator('#pdv-busca-produto').press('Enter')
    await page.wait_for_timeout(2000)
    await page.screenshot(path=str(ROOT/'browser-cart-stage.png'))
    if await page.locator('#pdv-carrinho').inner_text()== 'Nenhum item no cupom ainda.':
     await page.locator('#btn-adicionar-pdv').click()
    await page.wait_for_function("document.querySelector('#pdv-total').innerText !== 'R$ 0,00'",timeout=15000)
    await page.locator('.pdx-pg[data-forma="Dinheiro"]').click()
    await page.wait_for_function("!document.querySelector('#btn-finalizar-venda').disabled",timeout=10000)
    marker.write_text(json.dumps({'status':'attempt_started','product_id':product['id']}));marker.chmod(0o600)
    async with page.expect_response(lambda r:'/rest/v1/rpc/registrar_venda_mista' in r.url,timeout=30000)as future:
     await page.locator('#btn-finalizar-venda').click()
    response=await future.value;data=await response.json()
    if response.status!=200:raise RuntimeError('Venda recusada: '+str(data))
    sale=data[0];marker.write_text(json.dumps({'status':'saved','sale':sale}));marker.chmod(0o600)
    await page.wait_for_timeout(2000)
    verify=await page.context.new_page();await verify.goto(base+'/conferir/',wait_until='networkidle',timeout=30000)
    await verify.locator('#numero').fill(str(sale['numero_venda']));await verify.locator('button[value="aws"]').click()
    await verify.wait_for_function("document.querySelector('#msg').textContent.includes('encontrada e salva')",timeout=15000)
    await verify.reload(wait_until='networkidle');await verify.locator('#numero').fill(str(sale['numero_venda']));await verify.locator('button[value="aws"]').click()
    await verify.wait_for_function("document.querySelector('#msg').textContent.includes('encontrada e salva')",timeout=15000)
    await verify.screenshot(path=str(ROOT/'browser-sale-verified.png'))
    if '--roundtrip'in sys.argv:
     received=False
     for attempt in range(25):
      await verify.locator('button[value="return"]').click()
      try:await verify.wait_for_function("document.querySelector('#msg').textContent.includes('Venda recebida')",timeout=4000);received=True;break
      except Exception:pass
     if not received:raise RuntimeError('Retorno do ensaio não foi confirmado; não criar outra venda.')
     output=json.loads(await verify.locator('#resultado').inner_text())
     if not any(x['id']==sale['venda_id']for x in output['vendas']):raise RuntimeError('ID recebido difere da venda')
     await verify.screenshot(path=str(ROOT/'browser-sale-return-verified.png'))
    proof={'sale_id':sale['venda_id'],'number':sale['numero_venda'],'created_through_original_pos':True,'confirmed_after_reload':True,'primary_requests':len(primary),'primary_updated':False,'return_test_confirmed':'--roundtrip'in sys.argv}
    (ROOT/('sale-roundtrip-proof.json'if '--roundtrip'in sys.argv else 'sale-write-proof.json')).write_text(json.dumps(proof,indent=2));print(json.dumps(proof))
  await page.screenshot(path=str(ROOT/'browser-preview.png'),full_page=False)
  report={'logged_in':logged,'primary_requests':len(primary),'page_errors':errors,'failed_requests':failed,'auth_message':await page.locator('#auth-msg').inner_text()if not logged else ''}
  (ROOT/'browser-preview-report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report))
  await browser.close()
asyncio.run(main())
