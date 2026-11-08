from pathlib import Path
import sys,json,base64,zlib
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from exportar_origem import send
base=Path(__file__).resolve().parent.parent
payload={'gateway/server.mjs':(base/'gateway/server.mjs').read_text(),'conferir.html':(base/'conferir.html').read_text(),'compose.return.yml':(base/'return-test/compose.return.yml').read_text()}
encoded=base64.b64encode(zlib.compress(json.dumps(payload).encode())).decode()
code=r'''import pathlib,json,subprocess,os,base64,zlib
root=pathlib.Path('/var/lib/florest-reserva/backend-preview');ret=pathlib.Path('/var/lib/florest-reserva/return-test')
state=json.loads((ret/'state.json').read_text())
if state['target']!='florest_retorno_teste_20261108'or state['stage']!='ready':raise RuntimeError('Retorno isolado não confirmado')
for name,text in json.loads(zlib.decompress(base64.b64decode("'''+encoded+r'''"))).items():
 p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text);p.chmod(0o644)
(root/'web/conferir/index.html').write_text((root/'conferir.html').read_text())
p=root/'.runtime/backend.env';lines=p.read_text().splitlines();values=dict(line.split('=',1)for line in lines if '='in line)
if '/florest_backend_teste_20261108?'not in values['REST_DATABASE_URL']:raise RuntimeError('URI do clone de teste não confere')
values['RETURN_DATABASE_URL']=values['REST_DATABASE_URL'].replace('/florest_backend_teste_20261108?','/florest_retorno_teste_20261108?')
p.write_text('\n'.join(k+'='+v for k,v in values.items())+'\n');p.chmod(0o600)
r=subprocess.run(['aws','secretsmanager','get-secret-value','--secret-id','florest/reserva/postgres','--region','us-east-2','--output','json','--cli-connect-timeout','8','--cli-read-timeout','12'],env=dict(os.environ,AWS_MAX_ATTEMPTS='1'),capture_output=True,text=True,timeout=35,check=True);s=json.loads(json.loads(r.stdout)['SecretString'])
env=dict(os.environ,PGPASSWORD=s['password'],PGSSLMODE='verify-full',PGSSLROOTCERT='/etc/pki/rds-global-bundle.pem',PGCONNECT_TIMEOUT='8')
r=subprocess.run(['psql','-X','-q','-A','-t','-h',s['host'],'-U',s['username'],'-d','postgres','-v','ON_ERROR_STOP=1'],input='GRANT CONNECT ON DATABASE florest_retorno_teste_20261108 TO florest_preview_authenticator;',env=env,capture_output=True,text=True,timeout=20)
if r.returncode:raise RuntimeError('Conexão ao retorno isolado não foi concedida')
build=subprocess.run(['docker','build','-t','florest-reserva-gateway:preview',str(root/'gateway')],env=dict(os.environ,DOCKER_BUILDKIT='0'),capture_output=True,text=True,timeout=90)
if build.returncode:raise RuntimeError('Build da consulta de retorno não concluído')
args=['docker','compose','-p','florest-reserva-preview','--env-file',str(root/'.runtime/backend.env'),'-f',str(root/'compose.yml'),'-f',str(root/'compose.public.yml'),'-f',str(root/'compose.return.yml'),'up','-d','--no-build','gateway','return-rest']
r=subprocess.run(args,cwd=root,capture_output=True,text=True,timeout=60)
if r.returncode:raise RuntimeError('Serviço de consulta do retorno não inicializado')
unit="[Unit]\nDescription=Replay AWS sandbox changes to isolated return rehearsal\nAfter=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/bin/python3 /var/lib/florest-reserva/return-test/replay.py\nTimeoutStartSec=180\nNoNewPrivileges=true\nProtectSystem=strict\nProtectHome=true\nReadWritePaths=/var/lib/florest-reserva/return-test\nPrivateTmp=true\nMemoryMax=160M\n"
timer="[Unit]\nDescription=Update isolated return rehearsal every 20 seconds\n[Timer]\nOnBootSec=120\nOnUnitInactiveSec=20\nPersistent=true\n[Install]\nWantedBy=timers.target\n"
pathlib.Path('/etc/systemd/system/florest-return-rehearsal.service').write_text(unit)
pathlib.Path('/etc/systemd/system/florest-return-rehearsal.timer').write_text(timer)
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','enable','--now','florest-return-rehearsal.timer'],check=True,capture_output=True)
print('Consulta do retorno publicada e transferência automática do ensaio ativada. Supabase real permanece sem receber dados do teste.')
'''
compile(code,'publish_return_check','exec')
print(send(["python3 - <<'FLOREST_RETURN_CHECK'\n"+code+'\nFLOREST_RETURN_CHECK'],'publish_return_check',300))
