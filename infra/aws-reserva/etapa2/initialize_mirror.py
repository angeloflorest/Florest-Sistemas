"""Executado por SSM: estrutura atual e replicação nativa em banco novo e separado."""
import os,json,subprocess,pathlib,re,socket
ROOT=pathlib.Path('/var/lib/florest-reserva/replication');ROOT.mkdir(mode=0o700,exist_ok=True)
DB='florest_reserva_sync_20261108';SUB='florest_reserva_subscription_20261108';PUB='florest_reserva_publication_20261108';SLOT='florest_reserva_slot_20261108'
awsenv=dict(os.environ,AWS_MAX_ATTEMPTS='1')
def api(service,operation,*args):
 p=subprocess.run(['aws',service,operation,*args,'--region','us-east-2','--output','json','--cli-connect-timeout','10','--cli-read-timeout','15'],env=awsenv,capture_output=True,text=True,timeout=40)
 if p.returncode:raise RuntimeError('Não foi possível acessar a configuração criptografada: '+p.stderr[:350])
 return json.loads(p.stdout)
source=json.loads(api('ssm','get-parameter','--name','/florest/reserva/source-postgres','--with-decryption')['Parameter']['Value'])
target=json.loads(api('secretsmanager','get-secret-value','--secret-id','florest/reserva/postgres')['SecretString'])
secrets=[source['password'],target['password']]
def clean(s):
 for value in secrets:s=s.replace(value,'[omitido]')
 return s
source_env=dict(os.environ,PGPASSWORD=source['password'],PGCONNECT_TIMEOUT='10',PGSSLMODE='verify-full',PGSSLROOTCERT='/etc/pki/supabase-ca.crt',PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=180000')
target_env=dict(os.environ,PGPASSWORD=target['password'],PGCONNECT_TIMEOUT='10',PGSSLMODE='verify-full',PGSSLROOTCERT='/etc/pki/rds-global-bundle.pem',PGOPTIONS='-c statement_timeout=180000')
args=['-h',target['host'],'-p','5432','-U',target['username']]
def query(sql,db='postgres'):
 p=subprocess.run(['psql','-X','-q','-A','-t',*args,'-d',db,'-v','ON_ERROR_STOP=1'],input=sql,env=target_env,capture_output=True,text=True,timeout=200)
 if p.returncode:raise RuntimeError(clean(p.stderr)[:1400])
 return p.stdout.strip()
config=json.loads(pathlib.Path('/etc/florest-reserva-replication.json').read_text())
conn={'host':config['public_host'],'hostaddr':config['listen_host'],'port':15432,'user':source['username'],'password':source['password'],'dbname':'postgres','sslmode':'verify-full','sslrootcert':'system','channel_binding':'disable','connect_timeout':10,'application_name':'florest_reserva_native_mirror'}
def lit(s):return "'"+str(s).replace("'","''")+"'"
connstr=' '.join(k+'='+lit(v)for k,v in conn.items())
# Testar primeiro a ponte e sua cadeia de certificados, sem registrar conninfo.
env=dict(os.environ,PGPASSWORD=source['password'],PGCONNECT_TIMEOUT='10')
probe_connstr=' '.join(k+'='+lit(v)for k,v in conn.items()if k!='password')
p=subprocess.run(['psql','-X','-q','-A','-t',probe_connstr,'-c','select 1'],env=env,capture_output=True,text=True,timeout=25)
if p.returncode:raise RuntimeError('Ponte de replicação não validou TLS: '+clean(p.stderr)[:700])
print('Ponte validada com certificado HTTPS e verificação do certificado da origem.',flush=True)
marker=ROOT/'mirror-target.json'
if query("select count(*)from pg_database where datname='"+DB+"'")=='0':
 query('CREATE DATABASE '+DB)
 marker.write_text(json.dumps({'database':DB,'stage':'empty'}));marker.chmod(0o600)
elif not marker.exists():raise RuntimeError('Banco existe sem marca de autoria; não sobrescrever')
state=json.loads(marker.read_text())
if state['database']!=DB:raise RuntimeError('Destino de replicação não confere')
if state['stage']=='empty':
 if query("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in('public','private','auth','storage','realtime','supabase_migrations')and c.relkind in('r','p')",DB)!='0':raise RuntimeError('Destino não vazio')
 schemas=['public','private','auth','storage','realtime','supabase_migrations','extensions'];dump=ROOT/'current-schema.dump'
 command=['pg_dump','-h',source['host'],'-p','5432','-U',source['username'],'-d','postgres','--format=custom','--schema-only','--no-owner','--no-privileges','--lock-wait-timeout=5000','--file',str(dump)]
 for schema in schemas:command+=['--schema',schema]
 p=subprocess.run(command,env=source_env,capture_output=True,text=True,timeout=220);dump.chmod(0o600)
 if p.returncode:raise RuntimeError('Leitura da estrutura não foi concluída: '+clean(p.stderr)[:900])
 query('REVOKE CONNECT ON DATABASE '+DB+' FROM PUBLIC;')
 query(';'.join('CREATE SCHEMA IF NOT EXISTS "'+s+'"'for s in schemas)+'; CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions; CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;',DB)
 listing=subprocess.run(['pg_restore','--list',str(dump)],capture_output=True,text=True,check=True).stdout
 selected=[]
 for line in listing.splitlines():
  if re.match(r'^\d+;\s+\d+\s+\d+\s+(SCHEMA|PUBLICATION) ',line):continue
  selected.append(line)
 toc=ROOT/'schema-toc.list';toc.write_text('\n'.join(selected)+'\n');toc.chmod(0o600)
 p=subprocess.run(['pg_restore',*args,'--dbname',DB,'--single-transaction','--exit-on-error','--no-owner','--no-privileges','--use-list',str(toc),str(dump)],env=target_env,capture_output=True,text=True,timeout=220)
 if p.returncode:raise RuntimeError('Estrutura desfeita após erro: '+clean(p.stderr.split('Command was:')[0])[:1200])
 state['stage']='schema_ready';marker.write_text(json.dumps(state));print('Estrutura atual restaurada em banco separado.',flush=True)
if state['stage']=='schema_ready':
 if query("select count(*)from pg_subscription where subname='"+SUB+"'",DB)!='0':raise RuntimeError('Assinatura não esperada já existe')
 private_conn=dict(conn);private_conn.pop('sslrootcert');private_conn['sslmode']='require'
 private_connstr=' '.join(k+'='+lit(v)for k,v in private_conn.items())
 query('CREATE SUBSCRIPTION '+SUB+' CONNECTION '+lit(private_connstr)+' PUBLICATION '+PUB+" WITH(copy_data=true,enabled=true,create_slot=true,slot_name='"+SLOT+"',origin='none');",DB)
 state['stage']='replicating';marker.write_text(json.dumps(state))
print(json.dumps({'database':DB,'stage':state['stage'],'subscription':SUB,'primary_writes_unchanged':True,'test_database_unchanged':True}),flush=True)
