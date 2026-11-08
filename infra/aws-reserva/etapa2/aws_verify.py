"""Valida o login original e RLS no clone privado; não cria vendas ou notas."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
import urllib.request
import urllib.error
from urllib.parse import urlencode

ROOT=Path('/var/lib/florest-reserva/backend-preview')
DB='florest_backend_teste_20261108'

def main():
    ctx=json.loads((ROOT/'.runtime/test-context.json').read_text())
    if ctx['database']!=DB:raise RuntimeError('Teste não pode usar outro banco')
    r=subprocess.run(['aws','secretsmanager','get-secret-value','--secret-id','florest/reserva/postgres','--region','us-east-2','--output','json'],capture_output=True,text=True,check=True)
    s=json.loads(json.loads(r.stdout)['SecretString'])
    env=dict(os.environ,PGPASSWORD=s['password'],PGCONNECT_TIMEOUT='15',PGSSLMODE='verify-full',PGSSLROOTCERT='/etc/pki/rds-global-bundle.pem')
    def sql(query):
        p=subprocess.run(['psql','-X','-q','-A','-t','-h',s['host'],'-p',str(s.get('port',5432)),'-U',s['username'],'-d',DB,'-v','ON_ERROR_STOP=1'],input=query,env=env,capture_output=True,text=True)
        if p.returncode:raise RuntimeError('Consulta técnica no clone falhou: '+p.stderr.replace(s['password'],'[omitido]')[:700])
        return p.stdout.strip()
    def call(path,method='GET',body=None,access=None,admin=False,extra=None):
        key=ctx['service_key'] if admin else ctx['anon_key']
        headers={'apikey':key,'authorization':'Bearer '+(access or key),'content-type':'application/json','origin':ctx['public_url'],**(extra or {})}
        req=urllib.request.Request(ctx['public_url']+path,headers=headers,method=method,data=None if body is None else json.dumps(body).encode())
        try:
            with urllib.request.urlopen(req,timeout=25) as res:return res.status,json.load(res),dict(res.headers)
        except urllib.error.HTTPError as res:
            try:data=json.load(res)
            except Exception:data={}
            return res.code,data,dict(res.headers)
    for _ in range(20):
        try:
            status,health,_=call('/healthz')
            if status==200:break
        except Exception:pass
        time.sleep(2)
    else:raise RuntimeError('Auth ou REST não ficaram saudáveis')
    users_file=ROOT/'.runtime/aws-test-users.json'
    if users_file.exists():actors=json.loads(users_file.read_text())
    else:
        companies=json.loads(sql("select json_agg(t) from(select e.id,e.email,(select count(*) from public.vendas v where v.empresa_id=e.id) as sales from public.empresas e where e.status_conta='aprovado' and not e.bloqueado and e.email like '%@%' and exists(select from public.vendas v where v.empresa_id=e.id) order by e.id limit 2)t;"))
        if len(companies)!=2:raise RuntimeError('Duas empresas de referência não foram encontradas')
        actors=[];nonce=secrets.token_hex(5);username='florest-preview-'+nonce
        for i,company in enumerate(companies):
            password='Teste_'+secrets.token_hex(20)
            status,user,_=call('/auth/v1/admin/users','POST',{'email':'aws-preview-'+nonce+'-'+str(i)+'@florest-test.invalid','password':password,'email_confirm':True},admin=True)
            if status!=200:raise RuntimeError('Criação da identidade técnica falhou: HTTP '+str(status)+' '+str(user.get('msg') or user.get('message') or user.get('error_code') or '')[:180])
            actor={'id':user['id'],'password':password,'username':username,'company':company['id'],'company_email':company['email'],'expected_sales':company['sales']}
            # Escrita técnica apenas no clone, usando o mesmo privilégio de manutenção
            # do administrador. Não cria empresa, venda, caixa, pagamento ou nota.
            statement="BEGIN; SET LOCAL request.jwt.claim.role='service_role'; SET LOCAL request.jwt.claims='{\"role\":\"service_role\"}'; INSERT INTO public.perfis(id,empresa_id,nome,usuario,papel,ativo,tipo_acesso) VALUES ('"+actor['id']+"','"+actor['company']+"','Teste técnico contingência','"+username+"','proprietario',true,'erp'); COMMIT;"
            sql(statement);actors.append(actor)
        users_file.write_text(json.dumps(actors));users_file.chmod(0o600)
    before=sql("select json_build_object('vendas',(select count(*) from public.vendas),'itens',(select count(*) from public.itens_venda),'counters',(select md5(string_agg(row_to_json(t)::text,'|' order by row_to_json(t)::text)) from public.contadores_fiscais t));")
    tests=[];sessions=[]
    def check(name,ok):
        tests.append({'test':name,'passed':bool(ok)})
        if not ok:raise RuntimeError('Teste falhou: '+name)
    check('Auth e REST saudáveis; prévia sem troca de produção',health.get('mode')=='preview_read_only' and health.get('production_switched') is False)
    for i,actor in enumerate(actors):
        status,data,_=call('/functions/v1/florest-login','POST',{'empresa':actor['company_email'],'usuario':actor['username'],'senha':actor['password'],'superficie':'erp'})
        check('Login original empresa '+str(i+1),status==200 and data.get('ok') is True and data['empresa']['id']==actor['company'] and data['perfil']['id']==actor['id'])
        session=data['session'];sessions.append(session)
        status,data,headers=call('/rest/v1/vendas?select=empresa_id&limit=1',access=session['access_token'],extra={'Prefer':'count=exact'})
        total=next((v for k,v in headers.items() if k.lower()=='content-range'),'').split('/')[-1]
        check('RLS e total de vendas empresa '+str(i+1),status in (200,206) and total==str(actor['expected_sales']) and all(x['empresa_id']==actor['company'] for x in data))
        other=actors[1-i]['company']
        status,data,_=call('/rest/v1/vendas?'+urlencode({'empresa_id':'eq.'+other,'select':'id'}),access=session['access_token'])
        check('Outra empresa invisível para empresa '+str(i+1),status==200 and data==[])
    status,_,_=call('/functions/v1/florest-login','POST',{'empresa':actors[0]['company_email'],'usuario':actors[0]['username'],'senha':actors[1]['password'],'superficie':'erp'})
    check('Senha de outra empresa rejeitada',status==401)
    status,data,_=call('/auth/v1/user',access=sessions[0]['access_token'])
    check('Usuário confirmado no Auth independente',status==200 and data.get('id')==actors[0]['id'])
    status,data,_=call('/auth/v1/token?grant_type=refresh_token','POST',{'refresh_token':sessions[0]['refresh_token']})
    check('Renovação de sessão independente',status==200 and data.get('user',{}).get('id')==actors[0]['id'])
    status,_,_=call('/rest/v1/vendas','POST',{},access=sessions[0]['access_token'])
    check('Gravação comercial bloqueada',status==423)
    status,_,_=call('/functions/v1/fiscal-nfe55','POST',{'acao':'emitir'},access=sessions[0]['access_token'])
    check('Transmissão fiscal bloqueada',status==503)
    after=sql("select json_build_object('vendas',(select count(*) from public.vendas),'itens',(select count(*) from public.itens_venda),'counters',(select md5(string_agg(row_to_json(t)::text,'|' order by row_to_json(t)::text)) from public.contadores_fiscais t));")
    check('Vendas, itens e numeração fiscal inalterados no clone',json.loads(before)==json.loads(after))
    report={'database':DB,'all_passed':all(x['passed'] for x in tests),'tests':tests,'production_switched':False,'fixture_operators':len(actors),'business_data_changed':False}
    p=ROOT/'.runtime/aws-verification.json';p.write_text(json.dumps(report,indent=2));p.chmod(0o600)
    print(json.dumps(report),flush=True)

if __name__=='__main__':main()
