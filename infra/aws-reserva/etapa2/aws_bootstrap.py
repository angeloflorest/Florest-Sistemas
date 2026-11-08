"""Executado na ponte: prepara APENAS a cópia de teste, sem tocar no principal."""
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import subprocess
import time
from urllib.parse import quote

ROOT=Path('/var/lib/florest-reserva/backend-preview')
RUNTIME=ROOT/'.runtime'
DB='florest_backend_teste_20261108'
SOURCE='florest_erp_reserva_20261107'
AUTH='florest_preview_auth'
REST='florest_preview_authenticator'
OWNER='florest_preview_owner'

def main():
    RUNTIME.mkdir(parents=True,exist_ok=True,mode=0o700);RUNTIME.chmod(0o700)
    r=subprocess.run(['aws','secretsmanager','get-secret-value','--secret-id','florest/reserva/postgres','--region','us-east-2','--output','json'],capture_output=True,text=True,check=True)
    s=json.loads(json.loads(r.stdout)['SecretString'])
    if s['host']!='florest-reserva.c7s6kiq0igz3.us-east-2.rds.amazonaws.com':raise RuntimeError('Host do banco não confere')
    config_file=RUNTIME/'aws-config.json'
    if config_file.exists():config=json.loads(config_file.read_text())
    else:
        config={'database':DB,'source_database':SOURCE,'auth_password':secrets.token_hex(24),'rest_password':secrets.token_hex(24),'jwt_secret':secrets.token_hex(48),'stage':'new'}
        config_file.write_text(json.dumps(config));config_file.chmod(0o600)
    if config['database']!=DB or config['source_database']!=SOURCE:raise RuntimeError('Identidade da configuração de teste inválida')
    private=[s['password'],config['auth_password'],config['rest_password'],config['jwt_secret']]
    env=dict(os.environ,PGPASSWORD=s['password'],PGCONNECT_TIMEOUT='15',PGSSLMODE='verify-full',PGSSLROOTCERT='/etc/pki/rds-global-bundle.pem')
    def query(sql,database='postgres'):
        p=subprocess.run(['psql','-X','-q','-A','-t','-h',s['host'],'-p',str(s.get('port',5432)),'-U',s['username'],'-d',database,'-v','ON_ERROR_STOP=1'],input=sql,env=env,capture_output=True,text=True)
        if p.returncode:
            error=p.stderr
            for value in private:error=error.replace(value,'[omitido]')
            raise RuntimeError(error[:1500])
        return p.stdout.strip()
    if config['stage']=='new':
        if query("select count(*) from pg_database where datname='"+DB+"'")!='0':raise RuntimeError('Banco de teste já existe sem marca de autoria; não sobrescrever')
        if query("select count(*) from pg_stat_activity where datname='"+SOURCE+"' and pid<>pg_backend_pid()")!='0':raise RuntimeError('Cópia original está em uso; clonagem não será forçada')
        query('CREATE DATABASE '+DB+' TEMPLATE '+SOURCE)
        config['stage']='cloned';config_file.write_text(json.dumps(config))
    if config['stage']=='cloned':
        # Não remover RLS forçado para conceder acesso administrativo.
        if query("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname in ('public','private') and c.relforcerowsecurity",DB)!='0':raise RuntimeError('FORCE RLS requer revisão específica')
        sql=['BEGIN;']
        for name in [AUTH,REST,OWNER]:
            sql.append("DO $$ BEGIN IF NOT EXISTS(select from pg_roles where rolname='"+name+"') THEN CREATE ROLE "+name+" NOLOGIN; END IF; END $$;")
        sql += [
            "ALTER ROLE "+AUTH+" LOGIN NOINHERIT PASSWORD '"+config['auth_password']+"';",
            "ALTER ROLE "+REST+" LOGIN NOINHERIT PASSWORD '"+config['rest_password']+"';",
            'GRANT '+OWNER+' TO postgres;',
            'GRANT '+AUTH+' TO postgres;',
            'GRANT '+OWNER+' TO service_role;',
            'GRANT anon,authenticated,service_role TO '+REST+';',
            'ALTER ROLE '+AUTH+' SET search_path=auth,public,extensions;',
        ]
        query('\n'.join(sql)+'\nCOMMIT;')
        query('REVOKE CONNECT ON DATABASE '+DB+' FROM PUBLIC; GRANT CONNECT ON DATABASE '+DB+' TO postgres,'+AUTH+','+REST+';')
        sql=r"""
BEGIN;
DO $block$ DECLARE x record; cmd text; BEGIN
 FOR x IN SELECT n.nspname,c.relname,c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','private') AND c.relkind IN ('r','p','v','m','S') ORDER BY CASE WHEN c.relkind='S' THEN 1 ELSE 0 END LOOP
  cmd:=CASE x.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END;
  EXECUTE format('ALTER %s %I.%I OWNER TO florest_preview_owner',cmd,x.nspname,x.relname);
 END LOOP;
 FOR x IN SELECT c.relname,c.relkind FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='auth' AND c.relkind IN ('r','p','v','m','S') ORDER BY CASE WHEN c.relkind='S' THEN 1 ELSE 0 END LOOP
  cmd:=CASE x.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END;
  EXECUTE format('ALTER %s auth.%I OWNER TO florest_preview_auth',cmd,x.relname);
 END LOOP;
 FOR x IN SELECT p.oid,p.prokind FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='auth' AND p.prokind IN ('f','p') LOOP
  cmd:=CASE x.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END;
  EXECUTE format('ALTER %s %s OWNER TO florest_preview_auth',cmd,x.oid::regprocedure);
 END LOOP;
 FOR x IN SELECT t.typname FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='auth' AND t.typtype IN ('e','d') LOOP
  EXECUTE format('ALTER TYPE auth.%I OWNER TO florest_preview_auth',x.typname);
 END LOOP;
END $block$;
ALTER SCHEMA auth OWNER TO florest_preview_auth;
GRANT USAGE ON SCHEMA public,private,auth,extensions TO florest_preview_owner;
GRANT USAGE ON SCHEMA public,extensions TO florest_preview_auth;
-- Descarta sessões copiadas SOMENTE neste clone de teste. Usuários, senhas
-- e o snapshot de reserva original são preservados.
DELETE FROM auth.refresh_tokens;
DELETE FROM auth.sessions;
COMMIT;
"""
        query(sql,DB)
        config['stage']='configured';config_file.write_text(json.dumps(config))
    def b64(value):return base64.urlsafe_b64encode(value).decode().rstrip('=')
    public=config.get('public_url','http://127.0.0.1:18180');issuer=public+'/auth/v1';now=int(time.time())
    def jwt(role):
        a=b64(b'{"alg":"HS256","typ":"JWT"}')
        b=b64(json.dumps({'iss':issuer,'aud':'authenticated','role':role,'iat':now,'exp':now+86400*3650},separators=(',',':')).encode())
        return a+'.'+b+'.'+b64(hmac.new(config['jwt_secret'].encode(),(a+'.'+b).encode(),hashlib.sha256).digest())
    suffix='@'+s['host']+':5432/'+DB+'?sslmode=verify-full&sslrootcert=/run/rds-ca.pem'
    values={'JWT_SECRET':config['jwt_secret'],'ANON_KEY':jwt('anon'),'SERVICE_ROLE_KEY':jwt('service_role'),'JWT_ISSUER':issuer,'PUBLIC_URL':public,'AUTH_DATABASE_URL':'postgres://'+AUTH+':'+quote(config['auth_password'])+suffix,'REST_DATABASE_URL':'postgres://'+REST+':'+quote(config['rest_password'])+suffix,'READONLY_RPC_NAMES':'pdv_desktop_contexto,pdv_movel_contexto','SYSTEM_CA_PATH':'/etc/pki/tls/certs/ca-bundle.crt','RDS_CA_PATH':'/etc/pki/rds-global-bundle.pem','INTERNAL_NO_PROXY':'localhost,127.0.0.1,gateway,auth,rest,functions,postgres'}
    values['SANDBOX_WRITES']='true' if config.get('sandbox_writes') else 'false'
    values['ALLOW_EXISTING_USERS']='true' if config.get('allow_existing_users') else 'false'
    p=RUNTIME/'backend.env';p.write_text('\n'.join(k+'='+v for k,v in values.items())+'\n');p.chmod(0o600)
    p=RUNTIME/'test-context.json';p.write_text(json.dumps({'public_url':public,'anon_key':values['ANON_KEY'],'service_key':values['SERVICE_ROLE_KEY'],'database':DB}));p.chmod(0o600)
    print(json.dumps({'database':DB,'source_snapshot_preserved':SOURCE,'dedicated_logins':[AUTH,REST],'gateway_listen':'127.0.0.1:18180','business_writes_enabled':config.get('sandbox_writes',False)}))

if __name__=='__main__':main()
