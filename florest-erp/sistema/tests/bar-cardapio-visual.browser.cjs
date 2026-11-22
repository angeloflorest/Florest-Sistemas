const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {chromium}=require(process.env.BAR_MENU_BROWSER||'/opt/codex/runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const root=path.resolve(__dirname,'..'),endpoint='https://etulhyboogqhyyevpnlo.supabase.co/functions/v1/bar-cardapio',token='a'.repeat(64);
test('cardápio: fotos verticais e horizontais inteiras, detalhes, identidade e navegação sem perder o link da loja',{timeout:60000},async()=>{
 const browser=await chromium.launch({executablePath:'/usr/bin/chromium',args:['--no-sandbox']});try{for(const width of [320,390,1440]){
  const page=await browser.newPage({viewport:{width,height:900}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto('about:blank');const photos=await page.evaluate(()=>[ [100,300], [300,100] ].map(([w,h])=>{const c=document.createElement('canvas');c.width=w;c.height=h;const x=c.getContext('2d');x.fillStyle='#173951';x.fillRect(0,0,w,h);x.fillStyle='#c5a46a';x.fillRect(0,0,w,10);x.fillRect(0,h-10,w,10);return c.toDataURL('image/png')}));
  let logo=null;const products=photos.map((foto,i)=>({id:String(i),nome:i?'Porção especial':'Bebida 600ml',preco:15,unidade:'UN',foto,grupos:[]}));
  await page.route('https://bar.test/**',r=>{const file=new URL(r.request().url()).pathname.slice(1);return r.fulfill({contentType:file.endsWith('.js')?'text/javascript':file.endsWith('.css')?'text/css':'text/html',body:fs.readFileSync(path.join(root,file),'utf8')})});
  await page.route(endpoint,r=>{assert.equal(r.request().postDataJSON().acao,'catalogo');return r.fulfill({headers:{'access-control-allow-origin':'*'},json:{nome:'RESTAURANTE NOVA PONTE',cor:'#0b2a4d',fundo:'#edf0f3',layout:'grade',logo,produtos:products}})});
  await page.goto('https://bar.test/bar-cardapio.html#loja='+token);await page.getByRole('heading',{name:'RESTAURANTE NOVA PONTE',exact:true}).waitFor();
  for(const photo of await page.locator('.product img').all()){await photo.scrollIntoViewIfNeeded();await photo.evaluate(i=>i.decode());assert.equal(await photo.evaluate(i=>getComputedStyle(i).objectFit),'contain');}
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);assert.equal(await page.locator('#marca-loja').textContent(),'NP');assert.equal(await page.locator('#logo-loja').isVisible(),false);
  await page.getByRole('button',{name:'Escolher Bebida 600ml',exact:true}).click();assert.equal(await page.locator('dialog .detail-picture').evaluate(i=>getComputedStyle(i).objectFit),'contain');await page.getByRole('button',{name:'Fechar',exact:true}).click();
  const original=page.url();await page.locator('.skip-link').focus();await page.locator('.skip-link').press('Enter');assert.equal(page.url(),original);
  logo=photos[0];await page.reload();await page.getByRole('img',{name:'Logo de RESTAURANTE NOVA PONTE',exact:true}).waitFor();assert.equal(await page.locator('#marca-loja').isVisible(),false);assert.deepEqual(errors,[]);await page.close();
 }}finally{await browser.close()}
});
