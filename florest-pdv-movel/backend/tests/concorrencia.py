"""Concurrency tests against ONLY the synthetic florest-mobile-pg container."""
import concurrent.futures
import json
import subprocess
D=['docker','--host=unix:///var/run/docker.sock','exec','-i','florest-mobile-pg','psql','-X','-qAt','-U','postgres','-d','mobile_test','-v','ON_ERROR_STOP=1']
def sql(q):
 r=subprocess.run(D,input="set request.jwt.claim.sub='20000000-0000-0000-0000-000000000001';\n"+q,text=True,capture_output=True,check=True)
 return r.stdout.strip()
caixa=sql("select id from pdv_movel_caixas where dispositivo_id='50000000-0000-0000-0000-000000000002' and status='aberto';")
pedido=json.dumps({'caixa_id':caixa,'itens':[{'produto_id':'30000000-0000-0000-0000-000000000001','quantidade':1,'preco_base':12,'desconto':0,'acrescimo':0}],'pagamentos':[{'forma_pagamento':'Dinheiro','valor':12}],'prazo':False})
query="select public.pdv_movel_operar('50000000-0000-0000-0000-000000000002','sale','60000000-0000-0000-0000-000000000090', $pedido$"+pedido+"$pedido$::jsonb);"
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
 replies=[json.loads(x) for x in pool.map(sql,[query]*6)]
assert all(r['state']=='confirmed' for r in replies),replies
assert len({r['result']['venda_id'] for r in replies})==1
assert float(sql("select quantidade_estoque from produtos where id='30000000-0000-0000-0000-000000000001';"))==6
assert sql('select count(*) from vendas;')=='3'
assert sql("select count(*) from vendas_pagamentos where venda_id='"+replies[0]['result']['venda_id']+"';")=='1'
print('OK: 6 chamadas simultâneas com a mesma chave: uma venda, um pagamento e uma baixa.')
# Race close and sale: sale may commit before close, or be rejected after close.
query2=query.replace('000000000090','000000000091')
close="select public.pdv_movel_operar('50000000-0000-0000-0000-000000000002','close-cash','60000000-0000-0000-0000-000000000092',jsonb_build_object('caixa_id','"+caixa+"'));"
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 a,b=[json.loads(x) for x in pool.map(sql,[query2,close])]
assert b['state']=='confirmed',b
actual=sql("select coalesce(sum(total),0) from vendas where pdv_movel_caixa_id='"+caixa+"' and cancelada_em is null;")
assert float(actual)==float(b['result']['resumo']['total_vendido'])
assert a['state'] in ('confirmed','rejected')
print('OK: corrida venda/fechamento: resumo consistente, sem venda fora do caixa.')
