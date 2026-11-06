"""Somente PostgreSQL LOCAL em Docker. Nunca usa URL/token de produção."""
import os,subprocess,pathlib,concurrent.futures
ROOT=pathlib.Path(__file__).resolve().parent
CONTAINER=os.environ.get('NFE55_TEST_CONTAINER','florest-nfe55-test')
if CONTAINER!='florest-nfe55-test':raise SystemExit('Use o container local exclusivo florest-nfe55-test.')
def psql(sql,ok=True):
 r=subprocess.run(['docker','--host=unix:///var/run/docker.sock','exec','-i',CONTAINER,'psql','-U','postgres','-d','nfe55','-X','-v','ON_ERROR_STOP=1','-At'],input=sql,text=True,capture_output=True)
 if ok and r.returncode:raise RuntimeError(r.stderr)
 if not ok and not r.returncode:raise AssertionError('Esperava bloqueio SQL.')
 return r.stdout.strip()
subprocess.run(['docker','exec',CONTAINER,'psql','-U','postgres','-c','create database nfe55'],check=True,capture_output=True)
psql((ROOT/'nfe55-schema-isolado.sql').read_text())
psql((ROOT.parent/'migrations/20261106_nfe55.sql').read_text())
e='11111111-1111-4111-8111-111111111111';e2='22222222-2222-4222-8222-222222222222';u='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';u2='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
v=lambda n:f'00000000-0000-4000-8000-{n:012d}'
psql(f"insert into empresas(id) values('{e}'),('{e2}');insert into perfis(id,empresa_id,permissoes) values('{u}','{e}',array['fiscal','configuracoes']),('{u2}','{e2}',array['pdv']);insert into contadores_fiscais values('{e}','nfe','1',40,now());"+''.join(f"insert into vendas(id,empresa_id,total,numero_venda) values('{v(i)}','{e}',20,{i});" for i in range(1,8)))
def auth(sql,user=u):return f"begin;set local role authenticated;select set_config('request.jwt.claim.sub','{user}',true);"+sql+';commit;'
psql(f"insert into configuracoes_fiscais(empresa_id,nfce_serie,nfce_csc) values('{e}','9','csc-ficticio-teste');insert into contadores_fiscais values('{e}','nfce','9',900,now());")
def reservar(n):return auth(f"select numero from fiscal_nfe55_reservar('{v(n)}',fiscal_nfe55_contexto('{v(n)}'),'{{}}'::jsonb)")
psql(reservar(1),False)
psql(auth("select fiscal_nfe55_numeracao_salvar('1',150,false)"),False)
assert '151' in psql(auth("select fiscal_nfe55_numeracao_salvar('1',150,true)"))
assert '151' in psql(reservar(1))
psql(reservar(1),False)
psql(f"insert into documentos_fiscais(empresa_id,venda_id,tipo_documento,status) values('{e}','{v(1)}','nfce','nao_emitida')",False)
psql(f"insert into documentos_fiscais(empresa_id,venda_id,tipo_documento,status) values('{e}','{v(2)}','nfce','autorizada')")
psql(reservar(2),False)
psql(auth(f"select fiscal_nfe55_contexto('{v(1)}')",u2),False)
psql(auth(f"select fiscal_nfe55_credencial('{e}')"),False)
psql(auth(f"insert into fiscal_nfe55_emissoes(empresa_id) values('{e}')"),False)
assert '\n0\n' in '\n'+psql(auth('select count(*) from fiscal_nfe55_emissoes',u2))+'\n'
# Duas requisições simultâneas: uma reserva, uma recusa, uma única numeração.
with concurrent.futures.ThreadPoolExecutor() as pool:
 results=list(pool.map(lambda _:subprocess.run(['docker','exec','-i',CONTAINER,'psql','-U','postgres','-d','nfe55','-X','-v','ON_ERROR_STOP=1','-At'],input=reservar(3),text=True,capture_output=True).returncode,[1,2]))
assert sorted(results)==[0,3],results
assert psql(f"select ultimo_numero from contadores_fiscais where empresa_id='{e}' and tipo_documento='nfe' and serie='1'")=='152'
assert psql('select count(*) from fiscal_nfe55_emissoes')=='2'
assert psql('select sum(total) from vendas')=='140'
assert psql('select count(*) from documentos_fiscais')=='1'
# Concorrência entre reserva NF-e e criação NFC-e: somente uma operação pode vencer.
def nfce():return subprocess.run(['docker','exec','-i',CONTAINER,'psql','-U','postgres','-d','nfe55','-X','-v','ON_ERROR_STOP=1','-At'],input=f"insert into documentos_fiscais(empresa_id,venda_id,tipo_documento,status) values('{e}','{v(4)}','nfce','nao_emitida');",text=True,capture_output=True).returncode
def nfe():return subprocess.run(['docker','exec','-i',CONTAINER,'psql','-U','postgres','-d','nfe55','-X','-v','ON_ERROR_STOP=1','-At'],input=reservar(4),text=True,capture_output=True).returncode
with concurrent.futures.ThreadPoolExecutor() as pool:
 a=pool.submit(nfce);b=pool.submit(nfe);assert sorted([a.result(),b.result()])==[0,3]
# Série e sequência próprias: 150 -> 151; série 2 possui sua própria sequência.
psql(auth("select fiscal_nfe55_numeracao_salvar('1',149,true)"),False)
serie1_atual=psql(f"select ultimo_numero from contadores_fiscais where empresa_id='{e}' and tipo_documento='nfe' and serie='1'")
psql(auth("select fiscal_nfe55_numeracao_salvar('2',40,true)"))
assert '41' in psql(reservar(5))
assert psql(f"select serie from fiscal_nfe55_emissoes where venda_id='{v(5)}'")=='2'
assert psql(f"select nfe_ultimo_numero from configuracoes_fiscais where empresa_id='{e}'")=='41'
psql(auth("select fiscal_nfe55_numeracao_salvar('2',1,true)"),False)
assert serie1_atual in psql(auth("select fiscal_nfe55_numeracao_obter('1')"))
assert psql(f"select nfce_serie||':'||nfce_csc from configuracoes_fiscais where empresa_id='{e}'")=='9:csc-ficticio-teste'
assert psql(f"select ultimo_numero from contadores_fiscais where empresa_id='{e}' and tipo_documento='nfce' and serie='9'")=='900'
psql(auth("select fiscal_nfe55_numeracao_salvar('2',99,true)",u2),False)
# Duas vendas diferentes recebem números distintos na mesma série, sem perder incremento.
def reservar_concorrente(i):
 return subprocess.run(['docker','exec','-i',CONTAINER,'psql','-U','postgres','-d','nfe55','-X','-v','ON_ERROR_STOP=1','-At'],input=reservar(i),text=True,capture_output=True)
with concurrent.futures.ThreadPoolExecutor() as pool:
 results=list(pool.map(reservar_concorrente,[6,7]));assert all(r.returncode==0 for r in results),[r.stderr for r in results]
assert psql(f"select string_agg(numero::text,',' order by numero) from fiscal_nfe55_emissoes where serie='2'")=='41,42,43'
psql(f"update fiscal_nfe55_emissoes set status='pendente' where venda_id='{v(6)}';update fiscal_nfe55_emissoes set status='rejeitada' where venda_id='{v(7)}'")
psql(reservar(6),False);psql(reservar(7),False)
assert psql(f"select ultimo_numero from contadores_fiscais where empresa_id='{e}' and tipo_documento='nfe' and serie='2'")=='43'
# Segunda empresa possui a mesma série/número, sem afetar a primeira.
psql(f"update perfis set permissoes=array['fiscal','configuracoes'] where id='{u2}';insert into configuracoes_fiscais(empresa_id) values('{e2}');insert into vendas(id,empresa_id,total,numero_venda) values('{v(8)}','{e2}',20,8)")
psql(auth("select fiscal_nfe55_numeracao_salvar('1',150,true)",u2))
assert '151' in psql(auth(f"select numero from fiscal_nfe55_reservar('{v(8)}',fiscal_nfe55_contexto('{v(8)}'),'{{}}'::jsonb)",u2))
assert psql(f"select ultimo_numero from contadores_fiscais where empresa_id='{e}' and tipo_documento='nfe' and serie='2'")=='43'
assert psql(auth("select count(*) from fiscal_nfe55_emissoes",u2)).splitlines()[-2]=='1'
psql("update fiscal_nfe55_emissoes set numero=numero+100",False)
psql("update fiscal_nfe55_emissoes set payload='{}'::jsonb")
psql("update fiscal_nfe55_emissoes set payload='[1]'::jsonb",False)
# Pesquisa de destinatário: CPF/CNPJ e nome, somente da própria empresa; sem wildcard SQL.
psql(f"insert into clientes(id,empresa_id,nome,cpf) values('44444444-4444-4444-8444-444444444444','{e}','Cliente CPF','52998224725'),('55555555-5555-4555-8555-555555555555','{e2}','Cliente CNPJ','11222333000181')")
r=psql(auth("select fiscal_nfe55_clientes_pesquisar('Cliente')"));assert '52998224725' in r and '11222333000181' not in r
r=psql(auth("select fiscal_nfe55_clientes_pesquisar('Cliente')",u2));assert '11222333000181' in r and '52998224725' not in r
assert '"clientes": []' in psql(auth("select fiscal_nfe55_clientes_pesquisar('%%')"))
psql(auth("select fiscal_nfe55_clientes_pesquisar('a')"),False)
# Campos novos não podem ser confirmados diretamente, mesmo quando a tabela permite editar o cadastro.
psql('grant select,update,insert on configuracoes_fiscais to authenticated')
psql(auth(f"update configuracoes_fiscais set nfe_ultimo_numero=1 where empresa_id='{e}'"),False)
psql(auth(f"update configuracoes_fiscais set razao_social='Empresa sintética' where empresa_id='{e}'"))
psql(auth("insert into configuracoes_fiscais(empresa_id,nfe_numeracao_confirmada_em) values('33333333-3333-4333-8333-333333333333',now())"),False)
print('PASSOU: migração local, RLS, permissões, sequências por série 150→151 e 40→41, duplicidade, concorrência NF-e/NFC-e e preservação das vendas.')
