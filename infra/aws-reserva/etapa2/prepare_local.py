"""Sobe serviços oficiais com dados sintéticos; não usa AWS ou Supabase de produção."""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent
RUNTIME=ROOT/'.runtime'
RUNTIME.mkdir(mode=0o700,exist_ok=True)
ENV=os.environ.copy()
for key in ['DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH']:ENV.pop(key,None)
BASE=['docker','--host=unix:///var/run/docker.sock','compose','-p','florest-reserva-preview','--env-file',str(RUNTIME/'local.env'),'-f',str(ROOT/'compose.yml'),'-f',str(ROOT/'compose.local.yml')]

def command(args,**kwargs):
    r=subprocess.run(args,env=ENV,capture_output=True,text=True,**kwargs)
    if r.returncode:
        # Não mostrar configuração, tokens ou dados privados de autenticação.
        print('Comando falhou:',args[:5],flush=True)
        if args[0]=='docker' and 'logs' not in args:print(r.stderr[-1200:])
        raise RuntimeError('Falha no ambiente local de teste')
    return r

def compose(*args,**kwargs):return command([*BASE,*args],**kwargs)
def b64(value):return base64.urlsafe_b64encode(value).decode().rstrip('=')
def jwt(role,key,issuer):
    now=int(time.time())
    body=b64(json.dumps({'iss':issuer,'aud':'authenticated','role':role,'iat':now,'exp':now+86400},separators=(',',':')).encode())
    header=b64(b'{"alg":"HS256","typ":"JWT"}')
    return header+'.'+body+'.'+b64(hmac.new(key.encode(),(header+'.'+body).encode(),hashlib.sha256).digest())

def main():
    if len(sys.argv)>1 and sys.argv[1]=='down':
        compose('down','--volumes');print('Ambiente sintético removido.');return
    if (RUNTIME/'local.env').exists():
        compose('down','--volumes')
    key=secrets.token_hex(48);dbpass=secrets.token_hex(24);authpass=secrets.token_hex(24);restpass=secrets.token_hex(24)
    public='http://127.0.0.1:18180';issuer=public+'/auth/v1'
    ca=Path('/etc/ssl/certs/ca-certificates.crt').read_bytes()
    extra=os.environ.get('CODEX_PROXY_CERT')
    if extra and Path(extra).is_file():ca+=b'\n'+Path(extra).read_bytes()
    bundle=RUNTIME/'system-ca.pem';bundle.write_bytes(ca);bundle.chmod(0o644)
    values={'LOCAL_DB_PASSWORD':dbpass,'JWT_SECRET':key,'ANON_KEY':jwt('anon',key,issuer),'SERVICE_ROLE_KEY':jwt('service_role',key,issuer),'JWT_ISSUER':issuer,'PUBLIC_URL':public,'AUTH_DATABASE_URL':'postgres://supabase_auth_admin:'+authpass+'@postgres:5432/florest_preview','REST_DATABASE_URL':'postgres://authenticator:'+restpass+'@postgres:5432/florest_preview','READONLY_RPC_NAMES':'contexto','SYSTEM_CA_PATH':str(bundle)}
    values['INTERNAL_NO_PROXY']=','.join(filter(None,[os.environ.get('NO_PROXY',''),'localhost','127.0.0.1','gateway','auth','rest','functions','postgres']))
    p=RUNTIME/'local.env';p.write_text('\n'.join(k+'='+v for k,v in values.items())+'\n');p.chmod(0o600)
    p=RUNTIME/'test-context.json';p.write_text(json.dumps({'public_url':public,'anon_key':values['ANON_KEY'],'service_key':values['SERVICE_ROLE_KEY']}));p.chmod(0o600)
    # Manter a implementação publicada; fixar apenas a versão já presente no bundle.
    src=ROOT/'vendor/florest-login/index.ts'
    text=src.read_text().replace('npm:@supabase/supabase-js@2"','npm:@supabase/supabase-js@2.117.2"');src.write_text(text)
    for folder in [ROOT/'functions',ROOT/'vendor']:
        for file in folder.rglob('*'):
            file.chmod(0o755 if file.is_dir() else 0o644)
        folder.chmod(0o755)
    print('Iniciando PostgreSQL descartável com dados sintéticos.',flush=True)
    compose('up','-d','postgres')
    for _ in range(30):
        r=subprocess.run([*BASE,'exec','-T','postgres','pg_isready','-U','postgres','-d','florest_preview'],env=ENV,capture_output=True,text=True)
        if r.returncode==0:break
        time.sleep(1)
    else:raise RuntimeError('PostgreSQL local não iniciou')
    sql=(ROOT/'tests/fixture.sql').read_text().replace('__AUTH_PASSWORD__',authpass).replace('__REST_PASSWORD__',restpass)
    compose('exec','-T','postgres','psql','-X','-U','postgres','-d','florest_preview','-v','ON_ERROR_STOP=1',input=sql)
    print('Iniciando Auth, API REST e login original em contêineres locais.',flush=True)
    compose('up','-d','--build','auth','rest','functions','gateway')
    print('Serviços iniciados; nenhum recurso AWS ou dado de produção foi alterado.',flush=True)

if __name__=='__main__':main()
