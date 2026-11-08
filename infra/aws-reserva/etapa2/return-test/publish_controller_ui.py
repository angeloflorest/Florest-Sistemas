from pathlib import Path
import sys,json,zlib,base64
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from criar_ponte import aws,state
from exportar_origem import send
root=Path(__file__).resolve().parent;base=root.parent
instance=aws('ec2','describe-instances','--instance-ids',state['instance_id'])['Reservations'][0]['Instances'][0]
files={'gateway/server.mjs':(base/'gateway/server.mjs').read_text(),'preview.js':(base/'preview.js').read_text(),'conferir.html':(base/'conferir.html').read_text(),'simulador.html':(root/'simulador.html').read_text(),'frontend-helper.js':(root/'frontend-helper.js').read_text()}
encoded=base64.b64encode(zlib.compress(json.dumps(files).encode())).decode()
code=r'''import pathlib,json,base64,zlib,subprocess,os,urllib.request
root=pathlib.Path('/var/lib/florest-reserva/backend-preview');control='http://'''+instance['PrivateIpAddress']+r''':18200'
with urllib.request.urlopen(control+'/state',timeout=10)as response:state=json.load(response)
if not state.get('sandbox_only'):raise RuntimeError('Controle do laboratório não confirmado')
for name,text in json.loads(zlib.decompress(base64.b64decode("'''+encoded+r'''"))).items():
 p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text);p.chmod(0o644)
web=root/'web';(web/'simulador').mkdir(exist_ok=True)
(web/'simulador/index.html').write_text((root/'simulador.html').read_text());(web/'preview.js').write_text((root/'preview.js').read_text());(web/'conferir/index.html').write_text((root/'conferir.html').read_text())
p=web/'erp/index.html';html=p.read_text()
if 'async function florestSandboxVendaMista(args)'not in html:
 needle=": await supabase.rpc('registrar_venda_mista', {"
 if html.count(needle)!=1:raise RuntimeError('Fluxo de venda original não localizado; HTML preservado')
 html=html.replace(needle,': await florestSandboxVendaMista({',1)
 html=html.replace('instalarTaxasPagamento(supabase);','instalarTaxasPagamento(supabase);\n'+(root/'frontend-helper.js').read_text(),1)
 p.write_text(html)
else:
 start=html.index('async function florestSandboxVendaMista(args){');end=html.index('\nconst $ = (id)',start)
 html=html[:start]+(root/'frontend-helper.js').read_text()+html[end:];p.write_text(html)
p=root/'.runtime/backend.env';values=dict(line.split('=',1)for line in p.read_text().splitlines()if '='in line);values['LAB_CONTROL_URL']=control;p.write_text('\n'.join(k+'='+v for k,v in values.items())+'\n');p.chmod(0o600)
p=root/'compose.return.yml';text='\n'.join(line for line in p.read_text().splitlines()if not line.strip().startswith('LAB_CONTROL_URL:'))+'\n';text=text.replace('      RETURN_REST_URL: http://return-rest:3000','      RETURN_REST_URL: http://return-rest:3000\n      LAB_CONTROL_URL: ${LAB_CONTROL_URL:?}');p.write_text(text)
build=subprocess.run(['docker','build','-t','florest-reserva-gateway:preview',str(root/'gateway')],env=dict(os.environ,DOCKER_BUILDKIT='0'),capture_output=True,text=True,timeout=90)
if build.returncode:raise RuntimeError('Gateway do simulador não compilado')
args=['docker','compose','-p','florest-reserva-preview','--env-file',str(root/'.runtime/backend.env'),'-f',str(root/'compose.yml'),'-f',str(root/'compose.public.yml'),'-f',str(root/'compose.return.yml'),'up','-d','--no-build','gateway']
p=subprocess.run(args,cwd=root,capture_output=True,text=True,timeout=60)
if p.returncode:raise RuntimeError('Gateway do simulador não iniciou')
print('Simulador publicado com banco único para gravação, diário e confirmação das vendas no espelho quando disponível.')
'''
compile(code,'publish_lab_ui','exec')
print(send(["python3 - <<'FLOREST_LAB_UI'\n"+code+'\nFLOREST_LAB_UI'],'publish_lab_ui',240))
