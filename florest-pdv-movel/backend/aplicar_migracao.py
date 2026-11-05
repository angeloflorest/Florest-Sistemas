"""Apply only the reviewed PDV Móvel migration. Never executes commercial tests remotely."""
import hashlib
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request
ROOT=Path(__file__).resolve().parent
PROJECT='etulhyboogqhyyevpnlo'
def query(sql,read_only=True):
 token=os.environ.get('SUPABASE_ACCESS_TOKEN')
 if not token:raise RuntimeError('SUPABASE_ACCESS_TOKEN ausente no ambiente de gestão.')
 req=urllib.request.Request('https://api.supabase.com/v1/projects/'+PROJECT+'/database/query',data=json.dumps({'query':sql,'read_only':read_only}).encode(),headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
 try:
  with urllib.request.urlopen(req,timeout=60) as f:return json.load(f)
 except urllib.error.HTTPError as e:
  # SQL diagnostics contain code/schema errors, not a credential or customer row dump.
  body=e.read().decode(errors='replace')
  (ROOT/'local'/'erro-migracao.txt').write_text(body)
  raise RuntimeError('API HTTP '+str(e.code)+'. Diagnóstico SQL salvo localmente, sem executar vendas.') from None

def main():
 capability=query("select current_user papel,current_setting('transaction_read_only') modo;",False)[0]
 if capability['papel']=='supabase_read_only_user' or capability['modo']=='on':
  raise RuntimeError('A API está usando '+capability['papel']+' em modo somente leitura, mesmo com read_only=false. É necessária permissão database:write/DDL para aplicar a migração; nenhuma operação comercial será executada automaticamente.')
 state=query("select to_regclass('public.pdv_movel_caixas')::text objeto;")
 if state[0]['objeto'] is not None:raise RuntimeError('Objetos móveis já existem. Verifique o estado em vez de reaplicar.')
 # Read-only preflight verifies exactly the inspected core contracts.
 query((ROOT/'migrations/20261105_precondicoes.sql').read_text())
 migration=(ROOT/'migrations/20261105_pdv_movel.sql').read_text()
 result=query(migration,False)
 verification=query("select to_regclass('public.pdv_movel_caixas') is not null caixas, to_regclass('private.pdv_movel_operacoes') is not null operacoes, (select count(*) from public.pdv_movel_caixas) caixas_criados,(select count(*) from private.pdv_movel_operacoes) operacoes_criadas;")
 assert verification[0]['caixas'] and verification[0]['operacoes']
 (ROOT/'local'/'migracao-aplicada.json').write_text(json.dumps({'project':PROJECT,'sha256':hashlib.sha256(migration.encode()).hexdigest(),'verification':verification},indent=2))
 print('Migração aplicada e objetos verificados. Nenhuma venda ou caixa de teste foi criado no projeto remoto.')
if __name__=='__main__':
 try:main()
 except Exception as e:print(str(e),file=sys.stderr);sys.exit(1)
