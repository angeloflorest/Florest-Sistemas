from pathlib import Path
import sys,json,zlib,base64
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from criar_ponte import aws,state
from exportar_origem import send
root=Path(__file__).resolve().parent
instance=aws('ec2','describe-instances','--instance-ids',state['instance_id'])['Reservations'][0]['Instances'][0]
sg=aws('ec2','describe-security-groups','--group-ids',state['security_group'])['SecurityGroups'][0]
if not any(p.get('FromPort')==15432 and any(x.get('GroupId')==state['db_security_group'] for x in p.get('UserIdGroupPairs',[]))for p in sg['IpPermissions']):
 aws('ec2','authorize-security-group-ingress','--group-id',state['security_group'],'--ip-permissions',json.dumps([{'IpProtocol':'tcp','FromPort':15432,'ToPort':15432,'UserIdGroupPairs':[{'GroupId':state['db_security_group'],'Description':'Private RDS subscription with verified TLS'}]}]))
payload={'program':(root/'tls_replication_bridge.py').read_text(),'config':{'listen_host':instance['PrivateIpAddress'],'source_host':'db.etulhyboogqhyyevpnlo.supabase.co','source_ca':'/etc/pki/supabase-ca.crt','public_host':state['preview_host'],'certificates':'/var/lib/docker/volumes/florest-reserva-preview_caddy_data/_data/caddy/certificates'}}
encoded=base64.b64encode(zlib.compress(json.dumps(payload).encode())).decode()
code=r'''import pathlib,json,base64,zlib,subprocess
payload=json.loads(zlib.decompress(base64.b64decode("'''+encoded+r'''")))
p=pathlib.Path('/usr/local/sbin/florest-tls-replication.py');p.write_text(payload['program']);p.chmod(0o700)
p=pathlib.Path('/etc/florest-reserva-replication.json');p.write_text(json.dumps(payload['config']));p.chmod(0o600)
unit="[Unit]\nDescription=Florest private PostgreSQL TLS bridge\nAfter=network-online.target docker.service\nWants=network-online.target\n[Service]\nExecStart=/usr/bin/python3 /usr/local/sbin/florest-tls-replication.py\nRestart=on-failure\nRestartSec=3\nNoNewPrivileges=true\nProtectSystem=strict\nProtectHome=true\nPrivateTmp=true\nMemoryMax=64M\nTasksMax=32\nLimitNOFILE=128\n[Install]\nWantedBy=multi-user.target\n"
# Decode the unit's intentional newlines; the program/config are written verbatim.
pathlib.Path('/etc/systemd/system/florest-replication-tls.service').write_text(unit.replace('\\n','\n'))
subprocess.run(['systemctl','daemon-reload'],check=True)
subprocess.run(['systemctl','enable','--now','florest-replication-tls.service'],check=True,capture_output=True)
print('Ponte TLS privada preparada. RDS permanece sem acesso público.')
'''
compile(code,'bridge_deploy','exec')
print(send(["python3 - <<'FLOREST_TLS_BRIDGE'\n"+code+'\nFLOREST_TLS_BRIDGE'],'deploy_replication_bridge',120))
