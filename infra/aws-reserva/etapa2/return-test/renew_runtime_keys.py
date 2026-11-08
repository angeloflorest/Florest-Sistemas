"""Atualiza somente chaves internas do laboratório; não altera usuários ou dados."""
from pathlib import Path
import sys,base64,zlib
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from exportar_origem import send
source=Path(__file__).resolve().parents[1]/'gateway/server.mjs';encoded=base64.b64encode(zlib.compress(source.read_bytes())).decode()
code=r'''import pathlib,json,subprocess,os,hmac,hashlib,base64,time,zlib
root=pathlib.Path('/var/lib/florest-reserva/backend-preview');p=root/'.runtime/backend.env';values=dict(line.split('=',1)for line in p.read_text().splitlines()if '='in line)
(root/'gateway/server.mjs').write_bytes(zlib.decompress(base64.b64decode("'''+encoded+r'''")))
def b64(x):return base64.urlsafe_b64encode(x).decode().rstrip('=')
now=int(time.time())
def jwt(role):
 a=b64(b'{"alg":"HS256","typ":"JWT"}');b=b64(json.dumps({'iss':values['JWT_ISSUER'],'aud':'authenticated','role':role,'iat':now,'exp':now+86400*3650},separators=(',',':')).encode())
 return a+'.'+b+'.'+b64(hmac.new(values['JWT_SECRET'].encode(),(a+'.'+b).encode(),hashlib.sha256).digest())
values['ANON_KEY']=jwt('anon');values['SERVICE_ROLE_KEY']=jwt('service_role')
p.write_text('\n'.join(k+'='+v for k,v in values.items())+'\n');p.chmod(0o600)
p=root/'.runtime/test-context.json';ctx=json.loads(p.read_text());ctx.update(anon_key=values['ANON_KEY'],service_key=values['SERVICE_ROLE_KEY']);p.write_text(json.dumps(ctx));p.chmod(0o600)
build=subprocess.run(['docker','build','-t','florest-reserva-gateway:preview',str(root/'gateway')],env=dict(os.environ,DOCKER_BUILDKIT='0'),capture_output=True,text=True,timeout=90)
if build.returncode:raise RuntimeError('Build não concluído')
args=['docker','compose','-p','florest-reserva-preview','--env-file',str(root/'.runtime/backend.env'),'-f',str(root/'compose.yml'),'-f',str(root/'compose.public.yml'),'-f',str(root/'compose.return.yml'),'up','-d','--no-build','gateway','functions']
p=subprocess.run(args,cwd=root,capture_output=True,text=True,timeout=60)
if p.returncode:raise RuntimeError('Atualização das chaves não concluída')
print('Chaves internas renovadas; sessões dos usuários e dados preservados. Valores não registrados em logs.')
'''
compile(code,'renew_lab_keys','exec');print(send(["python3 - <<'FLOREST_LAB_KEYS'\n"+code+'\nFLOREST_LAB_KEYS'],'renew_lab_runtime_keys',180))
