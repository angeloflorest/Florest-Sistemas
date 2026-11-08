"""Retorno apenas entre os dois bancos de ensaio; nunca usa a origem de produção."""
import json,os,subprocess,pathlib,base64,re,datetime
ROOT=pathlib.Path('/var/lib/florest-reserva/return-test');SOURCE='florest_backend_teste_20261108';TARGET='florest_retorno_teste_20261108'
class ReplayError(Exception):pass
class BeforeImageConflict(ReplayError):pass
class Replayer:
 def __init__(self,source=SOURCE,target=TARGET):
  if {source,target}!={SOURCE,TARGET}:raise ReplayError('Par de teste não autorizado')
  self.source=source;self.target=target
  self.state=json.loads((ROOT/'state.json').read_text())
  if self.state['source']!=SOURCE or self.state['target']!=TARGET or self.state['stage']!='ready':raise ReplayError('Bancos de ensaio não confirmados')
  p=subprocess.run(['aws','secretsmanager','get-secret-value','--secret-id','florest/reserva/postgres','--region','us-east-2','--output','json','--cli-connect-timeout','8','--cli-read-timeout','12'],env=dict(os.environ,AWS_MAX_ATTEMPTS='1'),capture_output=True,text=True,timeout=35,check=True)
  s=json.loads(json.loads(p.stdout)['SecretString'])
  self.env=dict(os.environ,PGPASSWORD=s['password'],PGCONNECT_TIMEOUT='10',PGSSLMODE='verify-full',PGSSLROOTCERT='/etc/pki/rds-global-bundle.pem',PGOPTIONS='-c statement_timeout=30000 -c lock_timeout=3000')
  self.args=['psql','-X','-q','-A','-t','-h',s['host'],'-p','5432','-U',s['username'],'-v','ON_ERROR_STOP=1','-v','VERBOSITY=sqlstate']
  self.state=dict(self.state)
  self.state['source_instance']=self.query('SELECT instance_id FROM contingencia_journal.instance WHERE id;',source)
  self.state['target_instance']=self.query('SELECT instance_id FROM contingencia_journal.instance WHERE id;',target)
 def query(self,sql,db=None):
  db=db or self.source
  if db not in [SOURCE,TARGET]:raise ReplayError('Destino fora do ensaio')
  p=subprocess.run([*self.args,'-d',db],input=sql,env=self.env,capture_output=True,text=True,timeout=40)
  if p.returncode:
   code=re.search(r'ERROR:\s+([A-Z0-9]{5})',p.stderr)
   code=code.group(1)if code else 'unknown'
   if code=='40001':raise BeforeImageConflict('Alteração divergente; transação inteira desfeita')
   raise ReplayError('Operação de ensaio recusada; SQLSTATE='+code)
  return p.stdout.strip()
 def pending(self):
  dest=self.state['target_instance']
  raw=self.query("select coalesce(jsonb_agg(x order by x.first_seq),'[]')from(select e.origin,e.tx,min(e.seq)as first_seq from contingencia_journal.event e where e.origin='"+self.state['source_instance']+"'and not exists(select from contingencia_journal.delivery d where d.origin=e.origin and d.event_id=e.event_id and d.target='"+dest+"')group by e.origin,e.tx order by min(e.seq)limit 100)x;")
  return json.loads(raw)
 def apply_transaction(self,origin,tx,acknowledge=True):
  # Seleciona a transação inteira em um único snapshot; mantém o JSON como texto
  # para não converter valores NUMERIC em ponto flutuante no Python.
  raw=self.query("select coalesce(jsonb_agg(to_jsonb(e)order by seq),'[]')from contingencia_journal.event e where origin='"+origin+"'and tx="+str(int(tx))+";")
  payload=base64.b64encode(raw.encode()).decode()
  expression="convert_from(decode('"+payload+"','base64'),'UTF8')::jsonb"
  sql="""BEGIN;
CREATE TEMP TABLE florest_replay_result(changed integer,events integer)ON COMMIT DROP;
DO $replay$ DECLARE e jsonb;changed integer:=0;events integer:=0;BEGIN
 FOR e IN SELECT value FROM jsonb_array_elements("""+expression+""")WITH ORDINALITY x(value,ord)ORDER BY ord LOOP
  changed:=changed+contingencia_journal.apply(e)::integer;events:=events+1;
 END LOOP;
 INSERT INTO florest_replay_result VALUES(changed,events);
END $replay$;
SELECT json_build_object('changed',changed,'events',events)FROM florest_replay_result;
COMMIT;"""
  result=json.loads(self.query(sql,self.target))
  if acknowledge:
   self.query("INSERT INTO contingencia_journal.delivery(origin,event_id,target)SELECT(value->>'origin')::uuid,(value->>'event_id')::uuid,'"+self.state['target_instance']+"'::uuid FROM jsonb_array_elements("+expression+")ON CONFLICT DO NOTHING;")
  return result
 def run(self,passes=4):
  changed=events=transactions=0;conflicts=[]
  for _ in range(passes):
   todo=self.pending()
   if not todo:conflicts=[];break
   progress=0;conflicts=[]
   for item in todo:
    try:
     r=self.apply_transaction(item['origin'],item['tx']);changed+=r['changed'];events+=r['events'];transactions+=1;progress+=1
    except BeforeImageConflict:conflicts.append({'origin':item['origin'],'transaction':item['tx']})
   if not progress:break
  report={'checked_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source':self.source,'target':self.target,'transactions':transactions,'events':events,'changed_rows':changed,'conflicts':conflicts,'pending_transactions':len(self.pending()),'production_target':False,'supabase_updated':False}
  p=ROOT/'return-health.json';p.write_text(json.dumps(report,indent=2));p.chmod(0o600)
  return report
if __name__=='__main__':print(json.dumps(Replayer().run()),flush=True)
