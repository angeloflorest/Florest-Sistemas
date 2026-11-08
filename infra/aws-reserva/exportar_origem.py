"""Exportação sem credenciais em comandos, arquivos locais ou logs AWS."""
import base64
import json
import os
from pathlib import Path
import sys
import time
import urllib.request
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from criar_ponte import aws, state, save

HOST='aws-0-sa-east-1.pooler.supabase.com'
REF='etulhyboogqhyyevpnlo'

def send(commands,key,timeout=300):
    r=aws('ssm','send-command','--instance-ids',state['instance_id'],'--document-name','AWS-RunShellScript','--timeout-seconds',str(timeout),'--parameters',json.dumps({'commands':commands,'executionTimeout':[str(timeout)]}))
    state[key]=r['Command']['CommandId'];save();return state[key]

def result(key):
    return aws('ssm','get-command-invocation','--instance-id',state['instance_id'],'--command-id',state[key])

def main():
    action=sys.argv[1]
    if action=='preparar':
        code="""import socket,json,subprocess,pathlib
p=pathlib.Path('/run/florest-transfer');p.mkdir(mode=0o700,exist_ok=True)
key=p/'bridge-key.pem'
if not key.exists():
 subprocess.run(['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:4096','-out',str(key)],capture_output=True,check=True);key.chmod(0o600)
pub=subprocess.run(['openssl','pkey','-in',str(key),'-pubout'],capture_output=True,text=True,check=True).stdout
print(json.dumps({'public_key':pub,'source_ips':sorted(set(x[4][0] for x in socket.getaddrinfo('aws-0-sa-east-1.pooler.supabase.com',5432,socket.AF_INET)))}))
"""
        print(send(["python3 - <<'FLOREST'\n"+code+'\nFLOREST'],'transfer_prepare'));return
    if action=='resultado':
        r=result(sys.argv[2]);print(json.dumps({k:r.get(k) for k in ['Status','ResponseCode','StandardOutputContent','StandardErrorContent']}));return
    if action=='exportar':
        prep=result('transfer_prepare')
        if prep['Status']!='Success':raise RuntimeError('Ponte ainda não preparou a chave')
        meta=json.loads(prep['StandardOutputContent']);pub=serialization.load_pem_public_key(meta['public_key'].encode())
        # Conexão de saída do servidor AWS limitada aos IPs atuais do pooler.
        sg=aws('ec2','describe-security-groups','--group-ids',state['security_group'])['SecurityGroups'][0]
        current={ip['CidrIp'] for r in sg['IpPermissionsEgress'] if r.get('FromPort')==5432 for ip in r.get('IpRanges',[])}
        ips=[{'CidrIp':ip+'/32','Description':'Supabase source session pooler export'} for ip in meta['source_ips'] if ip+'/32' not in current]
        if ips:aws('ec2','authorize-security-group-egress','--group-id',state['security_group'],'--ip-permissions',json.dumps([{'IpProtocol':'tcp','FromPort':5432,'ToPort':5432,'IpRanges':ips}]))
        req=urllib.request.Request('https://api.supabase.com/v1/projects/'+REF+'/cli/login-role',data=json.dumps({'read_only':True}).encode(),headers={'Authorization':'Bearer '+os.environ['SUPABASE_ACCESS_TOKEN'],'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=30) as r:cred=json.load(r)
        print('Credencial oficial temporária criada em modo leitura; validade:',cred['ttl_seconds'],'segundos.',flush=True)
        ciphertext=pub.encrypt(json.dumps({'user':cred['role']+'.'+REF,'password':cred['password']}).encode(),padding.OAEP(mgf=padding.MGF1(hashes.SHA256()),algorithm=hashes.SHA256(),label=None))
        encrypted=base64.b64encode(ciphertext).decode()
        code="""import os,json,subprocess,base64,pathlib,hashlib,datetime
cipher=base64.b64decode('"""+encrypted+"""')
p=subprocess.run(['openssl','pkeyutl','-decrypt','-inkey','/run/florest-transfer/bridge-key.pem','-pkeyopt','rsa_padding_mode:oaep','-pkeyopt','rsa_oaep_md:sha256'],input=cipher,capture_output=True,check=True)
c=json.loads(p.stdout)
env=dict(os.environ,PGPASSWORD=c['password'],PGCONNECT_TIMEOUT='15',PGSSLMODE='verify-full',PGSSLROOTCERT='/etc/pki/supabase-ca.crt',PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=300000')
args=['-h','aws-0-sa-east-1.pooler.supabase.com','-p','5432','-U',c['user'],'-d','postgres']
check=subprocess.run(['psql','-X','-A','-t',*args,'-v','ON_ERROR_STOP=1','-c',"BEGIN READ ONLY; SET LOCAL ROLE supabase_read_only_user; select json_build_object('version',current_setting('server_version'),'readonly',current_setting('transaction_read_only'),'public_tables',(select count(*) from information_schema.tables where table_schema='public')); ROLLBACK;"],env=env,capture_output=True,text=True)
if check.returncode:
 print('Falha na conexão somente leitura à origem: '+check.stderr.replace(c['password'],'[omitido]')[:1200]);raise SystemExit(1)
print('Origem verificada: '+check.stdout.strip(),flush=True)
root=pathlib.Path('/var/lib/florest-reserva');root.mkdir(mode=0o700,exist_ok=True)
target=root/('supabase-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'.dump')
run=subprocess.run(['pg_dump',*args,'--role=supabase_read_only_user','--format=custom','--no-owner','--no-privileges','--lock-wait-timeout=5000','--file',str(target)],env=env,capture_output=True,text=True)
target.chmod(0o600)
if run.returncode:
 print('Exportação não concluída: '+run.stderr.replace(c['password'],'[omitido]')[:1800]);raise SystemExit(1)
manifest={'file':str(target),'bytes':target.stat().st_size,'sha256':hashlib.sha256(target.read_bytes()).hexdigest()}
(root/'export-manifest.json').write_text(json.dumps(manifest));(root/'export-manifest.json').chmod(0o600)
print('Exportação concluída: '+json.dumps(manifest),flush=True)
"""
        commands=['curl --fail --silent --show-error https://supabase-downloads.s3.amazonaws.com/prod/ssl/prod-ca-2021.crt -o /etc/pki/supabase-ca.crt',"python3 - <<'FLOREST_EXPORT'\n"+code+'\nFLOREST_EXPORT']
        print('Exportação enviada:',send(commands,'source_export',600));return
    raise SystemExit('Ação inválida')

if __name__=='__main__':main()
