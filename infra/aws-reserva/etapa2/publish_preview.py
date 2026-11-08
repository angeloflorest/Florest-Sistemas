"""Publica teste HTTPS na EC2 existente; não altera ERP/Vercel/Supabase principal."""
from pathlib import Path
import json,sys,base64,zlib
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from criar_ponte import aws,state,save
from exportar_origem import send
ROOT=Path(__file__).resolve().parent
instance=aws('ec2','describe-instances','--instance-ids',state['instance_id'])['Reservations'][0]['Instances'][0]
ip=instance['PublicIpAddress'];host='florest-reserva.'+ip.replace('.','-')+'.sslip.io'
state['preview_host']=host;state['preview_url']='https://'+host;save()
sg=aws('ec2','describe-security-groups','--group-ids',state['security_group'])['SecurityGroups'][0]
for port in [80,443]:
 if not any(p.get('FromPort')==port and p.get('ToPort')==port and any(x.get('CidrIp')=='0.0.0.0/0' for x in p.get('IpRanges',[]))for p in sg['IpPermissions']):
  aws('ec2','authorize-security-group-ingress','--group-id',state['security_group'],'--ip-permissions',json.dumps([{'IpProtocol':'tcp','FromPort':port,'ToPort':port,'IpRanges':[{'CidrIp':'0.0.0.0/0','Description':'HTTPS isolated AWS test ERP' if port==443 else 'ACME HTTP challenge and HTTPS redirect'}]}]))
caddy_template="""__HOST__ {
 encode gzip
 @admin path /auth/v1/admin/*
 respond @admin 403
 header {
  -Server
  X-Content-Type-Options nosniff
  X-Frame-Options DENY
  Referrer-Policy no-referrer
  Strict-Transport-Security "max-age=86400"
  Cache-Control no-store
  Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data: blob:; connect-src 'self' https://cdn.jsdelivr.net; worker-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
 }
 reverse_proxy gateway:8080
}
"""
payload={name:(ROOT/name).read_text()for name in ['compose.yml','aws_bootstrap.py','gateway/server.mjs','gateway/Dockerfile','preview.js','conferir.html','web-source-manifest.json']}
payload['Caddyfile']=caddy_template.replace('__HOST__',host)
payload['compose.public.yml']='services:\n  gateway:\n    restart: unless-stopped\n  auth:\n    restart: unless-stopped\n  rest:\n    restart: unless-stopped\n  functions:\n    restart: unless-stopped\n  tls:\n    image: caddy:2.10.2-alpine\n    ports:\n      - "80:80"\n      - "443:443"\n    volumes:\n      - ./Caddyfile:/etc/caddy/Caddyfile:ro\n      - caddy_data:/data\n      - caddy_config:/config\n    mem_limit: 96m\n    restart: unless-stopped\n    cap_drop: [ALL]\n    cap_add: [NET_BIND_SERVICE]\n    security_opt: [no-new-privileges:true]\nvolumes:\n  caddy_data:\n  caddy_config:\n'
encoded=base64.b64encode(zlib.compress(json.dumps(payload).encode(),9)).decode()
code=r'''import base64,zlib,json,pathlib,subprocess,urllib.request,hashlib,os
root=pathlib.Path('/var/lib/florest-reserva/backend-preview')
data=json.loads(zlib.decompress(base64.b64decode("'''+encoded+r'''")))
for name,value in data.items():
 p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(value);p.chmod(0o644)
config_file=root/'.runtime/aws-config.json';config=json.loads(config_file.read_text());config.update({'public_url':'https://'''+host+r'''','sandbox_writes':True,'allow_existing_users':True});config_file.write_text(json.dumps(config));config_file.chmod(0o600)
manifest=json.loads((root/'web-source-manifest.json').read_text());web=root/'web';web.mkdir(mode=0o755,exist_ok=True)
for item in manifest['files']:
 relative=item['path'];destination=web/'erp'/relative
 if '..' in pathlib.Path(relative).parts or relative.startswith('/'):raise RuntimeError('Caminho de frontend inválido')
 if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest()==item['sha256']:continue
 url='https://raw.githubusercontent.com/angeloflorest/Florest-Sistemas/'+manifest['sha']+'/florest-erp/sistema/'+relative
 with urllib.request.urlopen(url,timeout=45)as res:content=res.read()
 if hashlib.sha256(content).hexdigest()!=item['sha256']:raise RuntimeError('Checksum do frontend divergente')
 destination.parent.mkdir(parents=True,exist_ok=True);destination.write_bytes(content);destination.chmod(0o644)
p=web/'erp/index.html';html=p.read_text()
import re
html,n=re.subn(r"const SUPABASE_URL = '[^']+';","const SUPABASE_URL = window.FLOREST_PREVIEW.url;",html,count=1)
if n!=1:raise RuntimeError('Configuração de URL não localizada')
html,n=re.subn(r"const SUPABASE_ANON_KEY = '[^']+';","const SUPABASE_ANON_KEY = window.FLOREST_PREVIEW.anonKey;",html,count=1)
if n!=1:raise RuntimeError('Configuração da chave pública não localizada')
html=html.replace('createClient(SUPABASE_URL, SUPABASE_ANON_KEY)','createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {auth:{storageKey:"florest-aws-teste-session"}})')
html=html.replace('</head>','<script src="/preview-config.js"></script><script src="/preview.js" defer></script></head>',1)
html=html.replace('<title>','<title>TESTE AWS · ',1)
p.write_text(html)
(web/'preview.js').write_text((root/'preview.js').read_text());(web/'conferir').mkdir(exist_ok=True);(web/'conferir/index.html').write_text((root/'conferir.html').read_text())
subprocess.run(['python3',str(root/'aws_bootstrap.py')],check=True)
p=root/'.runtime/backend.env';values=p.read_text().replace('READONLY_RPC_NAMES=pdv_desktop_contexto,pdv_movel_contexto','READONLY_RPC_NAMES=pdv_desktop_contexto,pdv_movel_contexto,fiscal_emissao_caixa_obter,fiscal_contingencia_status,fiscal_contingencia_pendentes_listar,fiscal_contingencia_reconciliacao_listar,fiscal_configuracao_obter,fiscal_emitente_obter');p.write_text(values);p.chmod(0o600)
build=subprocess.run(['docker','build','-t','florest-reserva-gateway:preview',str(root/'gateway')],env=dict(os.environ,DOCKER_BUILDKIT='0'),capture_output=True,text=True)
if build.returncode:raise RuntimeError('Build falhou')
command=['docker','compose','-p','florest-reserva-preview','--env-file',str(root/'.runtime/backend.env'),'-f',str(root/'compose.yml'),'-f',str(root/'compose.public.yml'),'up','-d','--no-build']
p=subprocess.run(command,capture_output=True,text=True,cwd=root)
if p.returncode:raise RuntimeError('Inicialização de HTTPS falhou: '+p.stderr[-700:])
print(json.dumps({'public_url':config['public_url'],'frontend_sha':manifest['sha'],'sandbox_writes':True,'primary_changed':False,'database':config['database']}),flush=True)
'''
compile(code,'public_preview','exec')
print(send(["python3 - <<'FLOREST_PUBLIC_PREVIEW'\n"+code+'\nFLOREST_PUBLIC_PREVIEW'],'publish_https_preview',900))
