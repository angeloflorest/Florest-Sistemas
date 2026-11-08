import pathlib,json,subprocess,os,sys
sys.path.insert(0,'/var/lib/florest-reserva/return-test')
from replay import Replayer,SOURCE,TARGET,ReplayError
r=Replayer();root=pathlib.Path('/var/lib/florest-reserva/backend-preview');ctx=json.loads((root/'.runtime/test-context.json').read_text());actors=json.loads((root/'.runtime/aws-test-users.json').read_text())
import urllib.request,urllib.error
base=ctx['public_url']
def call(path,body=None,access=None):
 headers={'apikey':ctx['anon_key'],'authorization':'Bearer '+(access or ctx['anon_key']),'content-type':'application/json','origin':base}
 req=urllib.request.Request(base+path,headers=headers,data=None if body is None else json.dumps(body).encode())
 try:
  with urllib.request.urlopen(req,timeout=45)as x:return x.status,json.load(x)
 except urllib.error.HTTPError as e:
  try:data=json.load(e)
  except Exception:data={}
  return e.code,data
checks=[]
def check(name,ok):
 checks.append({'test':name,'passed':bool(ok)})
 if not ok:raise RuntimeError('Validação recusada: '+name)
for index,actor in enumerate(actors):
 status,data=call('/functions/v1/florest-login',{'empresa':actor['company_email'],'usuario':actor['username'],'senha':actor['password'],'superficie':'erp'})
 check('Login no principal de teste da empresa '+str(index+1),status==200 and data.get('ok')is True)
 token=data['session']['access_token'];other=actors[1-index]['company']
 for path,label in [('/rest/v1/','ativo'),('/reserva/rest/v1/','reserva'),('/retorno/rest/v1/','retorno')]:
  status,rows=call(path+'vendas?select=id&empresa_id=eq.'+other,access=token)
  check('Outra empresa invisível no banco '+label+' para usuário '+str(index+1),status==200 and rows==[])
# Provar a barreira no próprio PostgreSQL, não apenas na API.
check('Reserva em espera no estado final',r.query('SELECT writable FROM contingencia_journal.writer_control WHERE id;',SOURCE)=='f')
product=r.query("SELECT id FROM public.produtos WHERE empresa_id='"+actors[0]['company']+"'LIMIT 1;",SOURCE)
try:
 r.query("BEGIN;SET LOCAL request.jwt.claim.role='service_role';SET LOCAL request.jwt.claims='{\"role\":\"service_role\"}';UPDATE public.produtos SET nome=nome WHERE id='"+product+"';ROLLBACK;",SOURCE)
 denied=False
except ReplayError as e:denied='55000'in str(e)
check('Banco em espera recusa gravação diretamente no PostgreSQL',denied)
proof={'all_passed':all(x['passed']for x in checks),'tests':checks,'production_changed':False};p=pathlib.Path('/var/lib/florest-reserva/return-test/permissions-proof.json');p.write_text(json.dumps(proof,indent=2));p.chmod(0o600);print(json.dumps(proof))
