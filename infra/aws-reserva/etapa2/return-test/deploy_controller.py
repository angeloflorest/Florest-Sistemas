from pathlib import Path
import sys,json,zlib,base64,subprocess,secrets,hashlib,tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from exportar_origem import send
from criar_ponte import CLI,ENV
root=Path(__file__).resolve().parent
files={name:(root/name).read_text()for name in ['replay.py','controller.py','pair.sql','apply.sql']}
for name in ['replay.py','controller.py']:compile(files[name],name,'exec')
name='/florest/reserva/test-control-code'
args=[CLI,'--profile','florest-reserva','--region','us-east-2','--output','json']
p=subprocess.run([*args,'ssm','get-parameter','--name',name,'--with-decryption'],env=ENV,capture_output=True,text=True)
if p.returncode==0:token=json.loads(p.stdout)['Parameter']['Value']
else:
 if 'ParameterNotFound'not in p.stderr:raise RuntimeError('Código de controle não pôde ser consultado')
 token=secrets.token_urlsafe(32)
 value={'Name':name,'Type':'SecureString','Tier':'Standard','Value':token,'Description':'Código do simulador Florest. Controla apenas as cópias de teste.'}
 with tempfile.NamedTemporaryFile(mode='w')as f:
  json.dump(value,f);f.flush()
  p=subprocess.run([*args,'ssm','put-parameter','--cli-input-json','file://'+f.name],env=ENV,capture_output=True,text=True)
  if p.returncode:raise RuntimeError('Código de controle não pôde ser armazenado')
files['controller-key.sha256']=hashlib.sha256(token.encode()).hexdigest()
payload=base64.b64encode(zlib.compress(json.dumps(files).encode())).decode()
code=r'''import pathlib,json,base64,zlib,subprocess,os,tempfile,secrets,hashlib,sys
root=pathlib.Path('/var/lib/florest-reserva/return-test')
subprocess.run(['systemctl','stop','florest-return-rehearsal.timer','florest-return-rehearsal.service'],capture_output=True)
subprocess.run(['systemctl','disable','florest-return-rehearsal.timer'],capture_output=True)
for name,value in json.loads(zlib.decompress(base64.b64decode("'''+payload+r'''"))).items():
 p=root/name;p.write_text(value);p.chmod(0o700 if name.endswith('.py')else0o600)
sys.path.insert(0,str(root));from replay import Replayer,SOURCE,TARGET
engine=Replayer()
for db in [SOURCE,TARGET]:
 engine.query((root/'pair.sql').read_text(),db)
 engine.query((root/'apply.sql').read_text(),db)
unit="[Unit]\nDescription=Florest isolated failover laboratory\nAfter=network-online.target docker.service\nWants=network-online.target\n[Service]\nExecStart=/usr/bin/python3 /var/lib/florest-reserva/return-test/controller.py\nRestart=always\nRestartSec=3\nTimeoutStartSec=90\nNoNewPrivileges=true\nProtectSystem=strict\nProtectHome=true\nReadWritePaths=/var/lib/florest-reserva/return-test\nPrivateTmp=true\nMemoryMax=192M\nTasksMax=48\n[Install]\nWantedBy=multi-user.target\n"
pathlib.Path('/etc/systemd/system/florest-test-controller.service').write_text(unit)
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','enable','--now','florest-test-controller.service'],capture_output=True,check=True)
print('Controle do laboratório preparado. Código protegido no Parameter Store; nenhuma conexão de escrita ao Supabase real.')
'''
# The raw template intentionally carries escaped unit newlines.
code=code.replace('else0o600','else 0o600')
compile(code,'deploy_lab_controller','exec')
print(send(["python3 - <<'FLOREST_LAB_CONTROLLER'\n"+code+'\nFLOREST_LAB_CONTROLLER'],'deploy_test_controller',300))
