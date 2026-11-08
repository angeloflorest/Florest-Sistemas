"""Diagnóstico somente leitura; grava apenas relatório técnico no próprio host."""
import os,json,subprocess,pathlib,datetime
ROOT=pathlib.Path('/var/lib/florest-reserva/replication');DB='florest_reserva_sync_20261108';SUB='florest_reserva_subscription_20261108'
def credential(service,op,*args):
 p=subprocess.run(['aws',service,op,*args,'--region','us-east-2','--output','json','--cli-connect-timeout','8','--cli-read-timeout','12'],env=dict(os.environ,AWS_MAX_ATTEMPTS='1'),capture_output=True,text=True,timeout=35)
 if p.returncode:raise RuntimeError('Não foi possível consultar a credencial de monitoramento')
 return json.loads(p.stdout)
s=json.loads(credential('ssm','get-parameter','--name','/florest/reserva/source-postgres','--with-decryption')['Parameter']['Value'])
t=json.loads(credential('secretsmanager','get-secret-value','--secret-id','florest/reserva/postgres')['SecretString'])
SCHEMA="(select md5(string_agg(v,'|'order by v))from(select n.nspname||'.'||c.relname||':'||a.attname||':'||format_type(a.atttypid,a.atttypmod)||':'||a.attnotnull::text as v from pg_attribute a join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname in('public','private','auth','storage')and c.relkind in('r','p')and a.attnum>0 and not a.attisdropped union all select n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||'):'||p.prosrc||':'||p.provolatile::text||':'||p.prosecdef::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','private','auth','storage'))shape)"
def query(c,db,ca,sql):
 sql="SET search_path=''; "+sql.replace('select json_build_object(',"select json_build_object('schema_hash',"+SCHEMA+",",1)
 env=dict(os.environ,PGPASSWORD=c['password'],PGCONNECT_TIMEOUT='8',PGSSLMODE='verify-full',PGSSLROOTCERT=ca,PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=10000')
 p=subprocess.run(['psql','-X','-q','-A','-t','-h',c['host'],'-p','5432','-U',c['username'],'-d',db,'-v','ON_ERROR_STOP=1'],input=sql,env=env,capture_output=True,text=True,timeout=20)
 if p.returncode:raise RuntimeError('Consulta de monitoramento não foi concluída')
 return json.loads(p.stdout)
source=query(s,'postgres','/etc/pki/supabase-ca.crt',"select json_build_object('slot',(select json_agg(json_build_object('active',active,'state',wal_status,'lag_bytes',pg_wal_lsn_diff(pg_current_wal_lsn(),confirmed_flush_lsn),'retained_bytes',pg_wal_lsn_diff(pg_current_wal_lsn(),restart_lsn)))from pg_replication_slots where slot_name='florest_reserva_slot_20261108'),'vendas',(select count(*)from public.vendas),'itens',(select count(*)from public.itens_venda),'vendas_total',(select sum(total)from public.vendas),'wal_keep_limit',current_setting('max_slot_wal_keep_size'));")
target=query(t,DB,'/etc/pki/rds-global-bundle.pem',"select json_build_object('states',(select coalesce(json_agg(x),'[]')from(select srsubstate as state,count(*)as tables from pg_subscription_rel where srsubid=(select oid from pg_subscription where subname='"+SUB+"')group by srsubstate)x),'apply',(select json_agg(json_build_object('running',pid is not null,'received_lsn',received_lsn,'latest_end_time',latest_end_time))from pg_stat_subscription where subname='"+SUB+"'and relid is null),'errors',(select json_agg(json_build_object('apply',apply_error_count,'sync',sync_error_count))from pg_stat_subscription_stats where subname='"+SUB+"'),'vendas',(select count(*)from public.vendas),'itens',(select count(*)from public.itens_venda),'vendas_total',(select sum(total)from public.vendas));")
ready=bool(target['states'])and all(x['state']=='r'for x in target['states']);running=any(x['running']for x in target.get('apply')or[])
schema_matches=source['schema_hash']==target['schema_hash']
report={'schema_matches':schema_matches,'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'database':DB,'all_tables_ready':ready,'running':running,'source':source,'target':target,'counts_equal_at_check':all(source[k]==target[k]for k in ['vendas','itens','vendas_total']),'production_switched':False,'failback_ready':False}
ROOT.mkdir(mode=0o700,exist_ok=True);p=ROOT/'mirror-health.json';p.write_text(json.dumps(report,indent=2));p.chmod(0o600)
summary={k:report[k]for k in ['checked_at','all_tables_ready','running','schema_matches','production_switched','failback_ready']}
summary['replica_is_not_test_database']=True
p=ROOT/'mirror-summary.json';p.write_text(json.dumps(summary));p.chmod(0o644)
if not ready or not running or not schema_matches:print('Espelhamento ainda sem validação final; consultar relatório técnico.',flush=True)
print(json.dumps(report),flush=True)
