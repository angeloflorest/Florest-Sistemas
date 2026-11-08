import os,json,urllib.request,sys,base64,zlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from exportar_origem import send
q="select n.nspname as schema,c.relname as table_name,a.attname as column_name,case when x.grantee=0 then 'PUBLIC'else r.rolname end as role_name,x.privilege_type,x.is_grantable from pg_attribute a join pg_class c on c.oid=a.attrelid join pg_namespace n on n.oid=c.relnamespace cross join lateral aclexplode(a.attacl)x left join pg_roles r on r.oid=x.grantee where n.nspname in('public','private','auth','storage')and a.attnum>0 and not a.attisdropped;"
req=urllib.request.Request('https://api.supabase.com/v1/projects/etulhyboogqhyyevpnlo/database/query',data=json.dumps({'query':q,'read_only':True}).encode(),headers={'Authorization':'Bearer '+os.environ['SUPABASE_ACCESS_TOKEN'],'Content-Type':'application/json'})
with urllib.request.urlopen(req,timeout=40)as r:data=json.load(r)
Path(__file__).with_name('source-column-acl.json').write_text(json.dumps(data,indent=2))
def ident(s):return '"'+s.replace('"','""')+'"'
sql=['BEGIN;']
for x in data:
 if x['role_name'] in ['postgres','supabase_admin']:continue
 if x['privilege_type']not in ['SELECT','INSERT','UPDATE','REFERENCES']:raise RuntimeError('Privilégio inesperado')
 sql.append('GRANT '+x['privilege_type']+' ('+ident(x['column_name'])+') ON '+ident(x['schema'])+'.'+ident(x['table_name'])+' TO '+('PUBLIC'if x['role_name']=='PUBLIC'else ident(x['role_name']))+(' WITH GRANT OPTION'if x['is_grantable']else '')+';')
sql.append('COMMIT;')
encoded=base64.b64encode(zlib.compress('\n'.join(sql).encode())).decode()
code='''import json,subprocess,os,base64,zlib
r=subprocess.run(['aws','secretsmanager','get-secret-value','--secret-id','florest/reserva/postgres','--region','us-east-2','--output','json'],capture_output=True,text=True,check=True);s=json.loads(json.loads(r.stdout)['SecretString'])
env=dict(os.environ,PGPASSWORD=s['password'],PGSSLMODE='verify-full',PGSSLROOTCERT='/etc/pki/rds-global-bundle.pem')
sql=zlib.decompress(base64.b64decode("'''+encoded+'''"))
p=subprocess.run(['psql','-X','-A','-t','-h',s['host'],'-U',s['username'],'-d','florest_backend_teste_20261108','-v','ON_ERROR_STOP=1'],input=sql,env=env,capture_output=True)
if p.returncode:raise RuntimeError('Falha ao restaurar permissões de colunas: '+p.stderr.decode()[:800])
print('Permissões por coluna restauradas no clone, sem abrir acesso a colunas adicionais.')
'''
print('Concessões por coluna:',len(data));print(send(["python3 - <<'FLOREST_COLUMN_ACL'\n"+code+'\nFLOREST_COLUMN_ACL'],'copy_column_acl',120))
