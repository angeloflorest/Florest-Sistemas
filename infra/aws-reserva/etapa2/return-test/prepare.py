"""SSM: diário no clone de teste e segundo banco para ensaiar o retorno."""
import json,os,subprocess,pathlib,hashlib,re
ROOT=pathlib.Path('/var/lib/florest-reserva/return-test');ROOT.mkdir(mode=0o700,exist_ok=True)
SOURCE='florest_backend_teste_20261108';TARGET='florest_retorno_teste_20261108'
p=subprocess.run(['aws','secretsmanager','get-secret-value','--secret-id','florest/reserva/postgres','--region','us-east-2','--output','json','--cli-connect-timeout','8','--cli-read-timeout','12'],env=dict(os.environ,AWS_MAX_ATTEMPTS='1'),capture_output=True,text=True,timeout=35,check=True)
s=json.loads(json.loads(p.stdout)['SecretString'])
env=dict(os.environ,PGPASSWORD=s['password'],PGCONNECT_TIMEOUT='10',PGSSLMODE='verify-full',PGSSLROOTCERT='/etc/pki/rds-global-bundle.pem',PGOPTIONS='-c statement_timeout=300000')
args=['-h',s['host'],'-p','5432','-U',s['username']]
def query(sql,db=SOURCE):
 p=subprocess.run(['psql','-X','-q','-A','-t',*args,'-d',db,'-v','ON_ERROR_STOP=1'],input=sql,env=env,capture_output=True,text=True,timeout=320)
 if p.returncode:raise RuntimeError('Operação isolada não concluída; nenhum detalhe de registro foi exposto')
 return p.stdout.strip()
marker=ROOT/'state.json';state=json.loads(marker.read_text())if marker.exists()else{'source':SOURCE,'target':TARGET,'stage':'new'}
if state['source']!=SOURCE or state['target']!=TARGET:raise RuntimeError('Bancos de teste não conferem')
if state['stage']=='new':
 sql=(ROOT/'journal.sql').read_text().replace('BEGIN;','BEGIN; SET LOCAL lock_timeout=\'3s\';',1)
 query(sql);state['stage']='journal_installed';marker.write_text(json.dumps(state));marker.chmod(0o600)
 print('Diário transacional instalado somente no clone de teste.',flush=True)
if state['stage']=='journal_installed':
 if query("select count(*)from pg_database where datname='"+TARGET+"'",'postgres')!='0':raise RuntimeError('Destino já existe; não sobrescrever')
 subprocess.run(['docker','pull','postgres:18-alpine'],capture_output=True,check=True,timeout=180)
 dump=ROOT/'sandbox-baseline.dump'
 command=['docker','run','--rm','--network','host','--env','PGPASSWORD','--env','PGSSLMODE=verify-full','--env','PGSSLROOTCERT=/run/rds-ca.pem','--env','PGCONNECT_TIMEOUT=10','--volume','/etc/pki/rds-global-bundle.pem:/run/rds-ca.pem:ro','--volume',str(ROOT)+':/backup','postgres:18-alpine','pg_dump',*args,'-d',SOURCE,'--format=custom','--no-owner','--no-publications','--no-subscriptions','--lock-wait-timeout=5000','--file','/backup/sandbox-baseline.dump']
 for name in ['public','private','auth','storage','realtime','extensions','supabase_migrations','contingencia_journal']:command+=['--schema',name]
 p=subprocess.run(command,env=env,capture_output=True,text=True,timeout=240)
 if p.returncode:raise RuntimeError('Cópia consistente do ambiente de teste não foi concluída')
 dump.chmod(0o600);state['backup_sha256']=hashlib.sha256(dump.read_bytes()).hexdigest()
 query('CREATE DATABASE '+TARGET,'postgres');query('REVOKE CONNECT ON DATABASE '+TARGET+' FROM PUBLIC;',TARGET)
 state['stage']='target_empty';marker.write_text(json.dumps(state))
 print('Snapshot consistente do clone capturado sem interromper o login.',flush=True)
if state['stage']=='target_empty':
 dump=ROOT/'sandbox-baseline.dump'
 if hashlib.sha256(dump.read_bytes()).hexdigest()!=state['backup_sha256']:raise RuntimeError('Checksum do ensaio inválido')
 schemas=['public','private','auth','storage','realtime','extensions','supabase_migrations','contingencia_journal']
 query(';'.join('CREATE SCHEMA IF NOT EXISTS "'+x+'"'for x in schemas)+';CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;',TARGET)
 base=['docker','run','--rm','--network','host','--env','PGPASSWORD','--env','PGSSLMODE=verify-full','--env','PGSSLROOTCERT=/run/rds-ca.pem','--env','PGCONNECT_TIMEOUT=10','--volume','/etc/pki/rds-global-bundle.pem:/run/rds-ca.pem:ro','--volume',str(ROOT)+':/backup','postgres:18-alpine','pg_restore']
 listing=subprocess.run([*base,'--list','/backup/sandbox-baseline.dump'],env=env,capture_output=True,text=True,check=True).stdout
 toc=[]
 for line in listing.splitlines():
  if re.match(r'^\d+;\s+\d+\s+\d+\s+(SCHEMA|PUBLICATION|SUBSCRIPTION) ',line):continue
  toc.append(line)
 (ROOT/'toc.list').write_text('\n'.join(toc)+'\n');(ROOT/'toc.list').chmod(0o600)
 p=subprocess.run([*base,*args,'-d',TARGET,'--single-transaction','--exit-on-error','--no-owner','--use-list','/backup/toc.list','/backup/sandbox-baseline.dump'],env=env,capture_output=True,text=True,timeout=240)
 if p.returncode:raise RuntimeError('Restauração do ensaio desfeita após falha; destino de produção não foi usado')
 query("""BEGIN;DO $b$DECLARE t record;kind text;BEGIN FOR t IN SELECT n.nspname,c.relname,c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN('public','private')AND c.relkind IN('r','p','v','m','S')ORDER BY CASE WHEN c.relkind='S'THEN 1 ELSE 0 END LOOP kind:=CASE t.relkind WHEN'S'THEN'SEQUENCE'WHEN'v'THEN'VIEW'WHEN'm'THEN'MATERIALIZED VIEW'ELSE'TABLE'END;EXECUTE format('ALTER %s %I.%I OWNER TO florest_preview_owner',kind,t.nspname,t.relname);END LOOP;END$b$;COMMIT;""",TARGET)
 query("BEGIN;UPDATE contingencia_journal.instance SET instance_id=gen_random_uuid(),purpose='Isolated return rehearsal';INSERT INTO contingencia_journal.applied(origin,event_id)SELECT origin,event_id FROM contingencia_journal.event ON CONFLICT DO NOTHING;COMMIT;",TARGET)
 query((ROOT/'apply.sql').read_text(),TARGET)
 state['stage']='ready';state['target_instance']=query('SELECT instance_id FROM contingencia_journal.instance WHERE id;',TARGET);state['source_instance']=query('SELECT instance_id FROM contingencia_journal.instance WHERE id;',SOURCE)
 marker.write_text(json.dumps(state));marker.chmod(0o600)
 print('Ambiente de retorno isolado preparado, com controle de duplicidade.',flush=True)
print(json.dumps({'source':SOURCE,'target':TARGET,'stage':state['stage'],'production_target':False}),flush=True)
