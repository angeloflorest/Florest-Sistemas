const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {PGlite}=require(process.env.PGLITE_PATH||'/tmp/erp-perf-pg/node_modules/@electric-sql/pglite');
const policies=require('./fixtures/politicas-desempenho.json');
const id=n=>'00000000-0000-0000-0000-'+String(n).padStart(12,'0');
async function main(){const db=new PGlite();await db.exec(`CREATE SCHEMA private;CREATE SCHEMA auth;CREATE ROLE authenticated;
CREATE FUNCTION auth.uid() RETURNS uuid STABLE LANGUAGE sql AS $$SELECT current_setting('test.uid')::uuid$$;
CREATE FUNCTION private.exigir_empresa_ativa() RETURNS uuid STABLE LANGUAGE sql AS $$SELECT current_setting('test.empresa')::uuid$$;
CREATE FUNCTION private.perm(text) RETURNS boolean STABLE LANGUAGE sql AS $$SELECT $1=ANY(string_to_array(current_setting('test.perms'),','))$$;
CREATE TABLE public.perfis(id uuid,empresa_id uuid,ativo boolean,papel text);
CREATE TABLE public.pdv_movel_caixas(id integer,empresa_id uuid,aberto_por uuid);
CREATE TABLE public.fiscal_contadores(id integer,empresa_id uuid);
CREATE TABLE public.fiscal_pacotes_xml(id integer,empresa_id uuid);
CREATE TABLE public.empresas(id uuid,status_conta text);
CREATE INDEX empresas_status_idx ON public.empresas(status_conta);
CREATE INDEX idx_empresas_status_conta ON public.empresas(status_conta);
CREATE TABLE public.empresa_modulos(empresa_id uuid,modulo text,CONSTRAINT empresa_modulos_empresa_modulo_key UNIQUE(empresa_id,modulo));
CREATE UNIQUE INDEX uq_empresa_modulos_empresa_modulo ON public.empresa_modulos(empresa_id,modulo);
`);
for(let n=1;n<=4;n++)await db.query('INSERT INTO public.perfis VALUES($1,$2,$3,$4)',[id(n),id(n===4?20:10),n!==3,n===2?'funcionario':'proprietario']);
for(const t of ['fiscal_contadores','fiscal_pacotes_xml'])await db.query('INSERT INTO public.'+t+' VALUES(1,$1),(2,$2)',[id(10),id(20)]);
await db.query('INSERT INTO public.pdv_movel_caixas VALUES(1,$1,$2),(2,$1,$3),(3,$4,$5)',[id(10),id(1),id(2),id(20),id(4)]);
for(const p of policies){let sql=`CREATE POLICY ${p.policyname} ON public.${p.tablename} FOR ${p.cmd} TO authenticated`;if(p.qual)sql+=' USING ('+p.qual+')';if(p.with_check)sql+=' WITH CHECK ('+p.with_check+')';await db.exec(sql);}
async function outcomes(){const out=[];const ps=(await db.query("SELECT * FROM pg_policies WHERE schemaname='public' ORDER BY policyname")).rows;for(let n=1;n<=4;n++)for(const perms of ['','pdv','financeiro','relatorios']){
await db.query("SELECT set_config('test.uid',$1,false),set_config('test.empresa',$2,false),set_config('test.perms',$3,false)",[id(n),id(n===4?20:10),perms]);
for(const p of ps){const r=await db.query(`SELECT id,${p.qual||'NULL'} AS using_result,${p.with_check||'NULL'} AS check_result FROM public.${p.tablename} ORDER BY id`);out.push({usuario:n,perms,policy:p.policyname,rows:r.rows,roles:p.roles,cmd:p.cmd});}}
return out;}
const before=await outcomes();await db.exec('BEGIN');await db.exec(fs.readFileSync(path.resolve(__dirname,'../../../docs/pendencias/otimizar-politicas-e-indices.sql'),'utf8'));await db.exec('COMMIT');const after=await outcomes();assert.deepEqual(after,before);
const indices=(await db.query("SELECT indexname FROM pg_indexes WHERE schemaname='public'")).rows.map(r=>r.indexname);assert(indices.includes('empresas_status_idx'));assert(indices.includes('empresa_modulos_empresa_modulo_key'));assert(!indices.includes('idx_empresas_status_conta'));assert(!indices.includes('uq_empresa_modulos_empresa_modulo'));
await db.close();console.log('OK: 80 combinações de política/usuário/permissão iguais antes e depois; cópias removidas e índices canônicos preservados.');}
main().catch(e=>{console.error(e);process.exitCode=1});
