"""Controle exclusivo do laboratório A/B. Não contém endereço do Supabase real."""
import os,json,pathlib,threading,time,uuid,hashlib,hmac,tempfile,datetime
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from replay import Replayer,ReplayError,SOURCE,TARGET
ROOT=pathlib.Path('/var/lib/florest-reserva/return-test');STATE=ROOT/'controller-state.json'
A=SOURCE;B=TARGET
forward=Replayer(A,B);reverse=Replayer(B,A);operation_lock=threading.Lock();state_lock=threading.Lock()
key_hash=(ROOT/'controller-key.sha256').read_text().strip();bad_attempts={}
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def read_state():
 with state_lock:return dict(state)
def update(**values):
 with state_lock:
  state.update(values);state['updated_at']=now()
  temporary=ROOT/'controller-state.next'
  with temporary.open('w')as f:json.dump(state,f);f.flush();os.fsync(f.fileno())
  temporary.chmod(0o600);os.replace(temporary,STATE)
  fd=os.open(str(ROOT),os.O_RDONLY)
  try:os.fsync(fd)
  finally:os.close(fd)
 return read_state()
def flag(db,writable):
 forward.query("BEGIN;SET LOCAL lock_timeout='15s';UPDATE contingencia_journal.writer_control SET writable="+('true'if writable else 'false')+" WHERE id;COMMIT;",db)
def writable(db):return forward.query('SELECT writable FROM contingencia_journal.writer_control WHERE id;',db)=='t'
if STATE.exists():state=json.loads(STATE.read_text())
else:
 flags={db:writable(db)for db in [A,B]};active=next((db for db in [A,B]if flags[db]),None)if sum(flags.values())==1 else None
 state={'active_database':active,'status':'ready'if active else'maintenance','primary_available':True,'epoch':1,'sandbox_only':True,'production_changed':False}
if state.get('status')not in ['ready','primary_down']or(state.get('active_database')and(not writable(state['active_database'])or writable(B if state['active_database']==A else A))):
 flag(A,False);flag(B,False);state.update(active_database=None,status='maintenance',error='Troca anterior interrompida. Escolha um destino para concluir o ensaio.')
update()
def label(db):return'AWS reserva de teste'if db==A else'Principal de teste'if db==B else'Nenhum banco ativo'
def business_pending(engine):
 dest=engine.state['target_instance'];origin=engine.state['source_instance']
 return int(engine.query("SELECT count(DISTINCT e.tx)FROM contingencia_journal.event e WHERE e.origin='"+origin+"'AND e.schema_name IN('public','private','storage','contingencia_journal')AND NOT EXISTS(SELECT FROM contingencia_journal.delivery d WHERE d.origin=e.origin AND d.event_id=e.event_id AND d.target='"+dest+"');"))
def sync_one(engine):
 report=engine.run()
 if report['conflicts']:raise ReplayError('Há uma divergência no ensaio. O destino não foi sobrescrito.')
 return report
def sync_available():
 if state['primary_available']:sync_one(forward)
 sync_one(reverse)
 return {'pending_return':business_pending(forward),'pending_reserve':business_pending(reverse)}
def sequences(db,other):
 # RESTART invalida os valores em cache dos outros backends, ao contrário de setval.
 for target,source in [(db,other)]:
  rows=json.loads(forward.query("SELECT coalesce(json_agg(x),'[]')FROM(SELECT s.oid::regclass::text AS seq,n.nspname AS schema,c.relname AS table_name,a.attname AS column_name,ps.seqincrement,ps.seqmax FROM pg_class s JOIN pg_namespace sn ON sn.oid=s.relnamespace JOIN pg_sequence ps ON ps.seqrelid=s.oid JOIN pg_depend d ON d.objid=s.oid AND d.deptype IN('a','i')JOIN pg_class c ON c.oid=d.refobjid JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=d.refobjsubid WHERE s.relkind='S'AND n.nspname IN('public','private','storage'))x;",target))
  for row in rows:
   if row['seqincrement']!=1:raise ReplayError('Sequência especial requer revisão; troca interrompida.')
   def ident(v):return'"'+v.replace('"','""')+'"'
   seq=row['seq'];table=ident(row['schema'])+'.'+ident(row['table_name']);column=ident(row['column_name'])
   last=int(forward.query('SELECT last_value FROM '+seq+';',target));other_last=int(forward.query('SELECT last_value FROM '+seq+';',source))
   maximum=int(forward.query('SELECT coalesce(max('+column+'),0)FROM '+table+';',target))
   value=max(last,other_last,maximum)+1
   if value>row['seqmax']:raise ReplayError('Sequência sem espaço disponível; troca interrompida.')
   forward.query('ALTER SEQUENCE '+seq+' RESTART WITH '+str(value)+';',target)
def switch(target,make_available=False):
 if target not in [A,B]:raise ReplayError('Destino fora do laboratório')
 old=state.get('active_database');old_available=state['primary_available']
 if old==target and state['status']=='ready'and(not make_available or old_available):return read_state()
 update(status='switching',previous_database=old,error=None)
 try:
  flag(A,False);flag(B,False)
  if make_available:update(primary_available=True)
  for _ in range(8):
   pending=sync_available()
   if pending['pending_reserve']==0 and(target==A or pending['pending_return']==0):break
  else:raise ReplayError('Ainda há alterações pendentes; nenhuma troca foi concluída.')
  sequences(target,B if target==A else A)
  flag(target,True)
  return update(active_database=target,status='ready',epoch=state['epoch']+1,previous_database=None,error=None,**pending)
 except Exception:
  flag(A,False);flag(B,False)
  if old:flag(old,True)
  update(active_database=old,status='ready'if old else'maintenance',primary_available=old_available,error='Troca não concluída. Banco anterior preservado; confira as pendências do ensaio.')
  raise
def simulate_failure():
 old=state.get('active_database')
 update(status='switching',previous_database=old,error=None)
 if old==B:
  flag(B,False)
  # O ensaio fecha o principal após confirmar o espelhamento das vendas já aceitas.
  for _ in range(8):
   sync_one(reverse)
   if business_pending(reverse)==0:break
  else:raise ReplayError('Não foi possível fechar o principal com segurança.')
  return update(primary_available=False,active_database=None,status='primary_down',epoch=state['epoch']+1)
 return update(primary_available=False,status='ready'if old else'primary_down',epoch=state['epoch']+1)
def confirmation(data):
 source=data.get('source')
 if source not in [A,B]:raise ReplayError('Origem não autorizada')
 engine=forward if source==A else reverse
 operation=data.get('operation');actor=data.get('actor')
 if operation:
  operation=str(uuid.UUID(operation));actor=str(uuid.UUID(actor))
  where=" WHERE id='"+operation+"'AND actor='"+actor+"'"
  query="SELECT coalesce((SELECT md5(response::text)FROM contingencia_journal.operation"+where+"),'')"
  digest=engine.query(query,source)
  if not digest:raise ReplayError('Venda ainda não confirmada no banco ativo.')
 if source==A and not state['primary_available']:
  return {'ok':True,'durable_in_reserve':True,'pending_return':True}
 for _ in range(4):
  sync_one(engine)
  if business_pending(engine)==0:break
 else:raise ReplayError('Operação gravada, mas confirmação do espelho ainda pendente. Consulte o histórico antes de repetir.')
 if operation and engine.query(query,engine.target)!=digest:raise ReplayError('Comprovante da operação ainda não chegou ao espelho.')
 return {'ok':True,'shadow_confirmed':True,'pending_return':False}
def background():
 while True:
  time.sleep(20)
  if not operation_lock.acquire(blocking=False):continue
  try:
   if state['status']=='ready':update(**sync_available())
  except Exception:update(error='A transferência do ensaio está pendente; as alterações continuam no diário do banco ativo.')
  finally:operation_lock.release()
class Server(ThreadingHTTPServer):daemon_threads=True
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def result(self,status,data):
  body=json.dumps(data).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
 def do_GET(self):
  if self.path!='/state':return self.result(404,{'error':'rota_indisponivel'})
  data=read_state();data['active_label']=label(data.get('active_database'));return self.result(200,data)
 def do_POST(self):
  if self.path not in ['/action','/confirm']:return self.result(404,{'error':'rota_indisponivel'})
  try:
   size=int(self.headers.get('content-length','0'))
   if size<1 or size>4096:return self.result(413,{'error':'corpo_invalido'})
   data=json.loads(self.rfile.read(size))
  except Exception:return self.result(400,{'error':'json_invalido'})
  if self.path=='/action':
   token=self.headers.get('x-florest-test-control','');valid=hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(),key_hash)
   if not valid:
    key=self.client_address[0];record=bad_attempts.get(key,[time.time(),0]);record=record if time.time()-record[0]<60 else[time.time(),0];record[1]+=1;bad_attempts[key]=record
    return self.result(429 if record[1]>5 else 401,{'error':'codigo_de_controle_invalido'})
  if not operation_lock.acquire(timeout=12):return self.result(409,{'error':'ensaio_ocupado','message':'Aguarde a transferência em andamento e tente novamente.'})
  try:
   if self.path=='/confirm':return self.result(200,confirmation(data))
   action=data.get('action')
   if action=='activate_reserve':out=switch(A)
   elif action=='return_primary':out=switch(B,make_available=True)
   elif action=='simulate_primary_failure':out=simulate_failure()
   else:return self.result(400,{'error':'acao_invalida'})
   return self.result(200,out)
  except Exception:return self.result(409,{'error':'troca_nao_confirmada','message':'A operação do ensaio não foi concluída. Confira o estado e o histórico; nenhuma venda deve ser reenviada automaticamente.'})
  finally:operation_lock.release()
threading.Thread(target=background,daemon=True).start()
Server(('0.0.0.0',18200),Handler).serve_forever()
