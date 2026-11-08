"""Acesso exclusivo para leitura/replicação; nenhum dado comercial é alterado."""
import os,json,secrets,subprocess,urllib.request,urllib.error,tempfile
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from criar_ponte import CLI,ENV
NAME='/florest/reserva/source-postgres';ROLE='florest_reserva_repl'
base=[CLI,'--profile','florest-reserva','--region','us-east-2','--output','json']
r=subprocess.run([*base,'ssm','get-parameter','--name',NAME,'--with-decryption'],env=ENV,capture_output=True,text=True)
if r.returncode==0:config=json.loads(json.loads(r.stdout)['Parameter']['Value'])
else:
 if 'ParameterNotFound'not in r.stderr:raise RuntimeError('Não foi possível consultar o parâmetro de acesso')
 config={'username':ROLE,'password':secrets.token_hex(32),'host':'db.etulhyboogqhyyevpnlo.supabase.co','port':5432,'dbname':'postgres','purpose':'continuous-reserve-replication'}
 payload={'Name':NAME,'Type':'SecureString','Tier':'Standard','Value':json.dumps(config),'Description':'Leitura e replicação do Supabase para reserva Florest; acesso exclusivo do backend'}
 with tempfile.NamedTemporaryFile(mode='w',prefix='florest-parameter-',suffix='.json')as f:
  json.dump(payload,f);f.flush()
  r=subprocess.run([*base,'ssm','put-parameter','--cli-input-json','file://'+f.name],env=ENV,capture_output=True,text=True)
 if r.returncode:raise RuntimeError('Não foi possível guardar a credencial criptografada: '+r.stderr.replace(config['password'],'[omitido]')[:600])
query="""BEGIN;
DO $x$ BEGIN
 IF EXISTS(SELECT FROM pg_roles WHERE rolname='florest_reserva_repl') THEN
  IF shobj_description((SELECT oid FROM pg_roles WHERE rolname='florest_reserva_repl'),'pg_authid') IS DISTINCT FROM 'Florest reserve replication managed 20261108' THEN RAISE EXCEPTION 'Papel já existe sem marca de autoria'; END IF;
 ELSE
  CREATE ROLE florest_reserva_repl LOGIN INHERIT REPLICATION BYPASSRLS CONNECTION LIMIT 6 PASSWORD '"""+config['password']+"""';
  COMMENT ON ROLE florest_reserva_repl IS 'Florest reserve replication managed 20261108';
 END IF;
END $x$;
GRANT pg_read_all_data TO florest_reserva_repl;
GRANT USAGE ON SCHEMA public,private,auth,storage TO florest_reserva_repl;
GRANT SELECT ON ALL TABLES IN SCHEMA public,private,auth,storage TO florest_reserva_repl;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public,private,auth,storage TO florest_reserva_repl;
COMMIT;"""
req=urllib.request.Request('https://api.supabase.com/v1/projects/etulhyboogqhyyevpnlo/database/query',data=json.dumps({'query':query,'read_only':False}).encode(),headers={'Authorization':'Bearer '+os.environ['SUPABASE_ACCESS_TOKEN'],'Content-Type':'application/json'})
try:
 with urllib.request.urlopen(req,timeout=45)as res:json.load(res)
except urllib.error.HTTPError as e:
 error=e.read().decode().replace(config['password'],'[omitido]')
 raise RuntimeError('Acesso dedicado não pôde ser configurado: '+error[:700])
print('Acesso dedicado somente leitura/replicação preparado. Credencial criptografada no Parameter Store; nenhum slot ou publicação criado.')
