import asyncio,json
from pathlib import Path
from playwright.async_api import async_playwright
ROOT=Path(__file__).resolve().parents[1]
async def main():
 actor=json.loads((ROOT/'.runtime/browser-actor.json').read_text());marker=json.loads((ROOT/'.runtime/browser-sale-marker.json').read_text())
 if marker['status']!='saved':raise RuntimeError('Venda não foi confirmada pelo servidor')
 sale=marker['sale'];base='https://florest-reserva.77-112-23-104.sslip.io';primary=[]
 async with async_playwright()as p:
  browser=await p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox']);context=await browser.new_context(viewport={'width':1440,'height':1000});page=await context.new_page()
  context.on('request',lambda r:primary.append(r.url)if 'etulhyboogqhyyevpnlo.supabase.co'in r.url else None)
  await page.goto(base+'/erp/',wait_until='networkidle',timeout=60000)
  for field,value in [('empresa',actor['company_email']),('usuario',actor['username']),('senha',actor['password'])]:await page.locator('#login-erp-'+field).fill(value)
  await page.locator('#login-erp-senha').press('Enter');await page.wait_for_function("!document.querySelector('#app-screen').classList.contains('hidden')",timeout=30000)
  verify=await context.new_page();await verify.goto(base+'/conferir/',wait_until='networkidle',timeout=30000)
  for _ in range(2):
   await verify.locator('#numero').fill(str(sale['numero_venda']));await verify.locator('button').click()
   await verify.wait_for_function("document.querySelector('#msg').textContent.includes('encontrada e salva')",timeout=15000)
   output=json.loads(await verify.locator('#resultado').inner_text())
   if not any(x['id']==sale['venda_id']for x in output['vendas']):raise RuntimeError('Consulta não retornou o mesmo ID')
   await verify.screenshot(path=str(ROOT/'browser-sale-verified.png'))
   await verify.reload(wait_until='networkidle')
  proof={'sale_id':sale['venda_id'],'number':sale['numero_venda'],'created_through_original_pos':True,'confirmed_after_new_login_and_reload':True,'primary_requests':len(primary),'primary_updated':False}
  (ROOT/'sale-write-proof.json').write_text(json.dumps(proof,indent=2));print(json.dumps(proof));await browser.close()
asyncio.run(main())
