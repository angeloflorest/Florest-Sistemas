-- Run ONLY in the isolated synthetic database from base_isolada.sql.
insert into empresas values('10000000-0000-0000-0000-000000000001'),('10000000-0000-0000-0000-000000000002');
insert into perfis(id,empresa_id,nome,papel,permissoes) values
 ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Dono A','proprietario','{}'),
 ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','Dono B','proprietario','{}'),
 ('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','Operador','funcionario','{pdv}'),
 ('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','Sem acesso','funcionario','{}');
insert into configuracoes_fiscais values('10000000-0000-0000-0000-000000000001',false),('10000000-0000-0000-0000-000000000002',false);
insert into produtos(id,empresa_id,nome,preco_venda,quantidade_estoque) values('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Produto sintético',12,10),('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','Produto outra empresa',12,10);
insert into clientes values('40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Cliente teste');
insert into caixas(empresa_id,tipo_caixa,numero) values('10000000-0000-0000-0000-000000000001','PDV',1),('10000000-0000-0000-0000-000000000001','BAR',1),('10000000-0000-0000-0000-000000000001','GASTRONOMIA',1);
set request.jwt.claim.sub='20000000-0000-0000-0000-000000000001';
do $$
declare a jsonb; b jsonb; c uuid; c2 uuid; sale jsonb; r jsonb; req jsonb; prior numeric; key uuid; amount numeric;
begin
 a:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000001','open-cash','60000000-0000-0000-0000-000000000001','{"nome":"Celular A","valor_inicial":10}');
 if a->>'state'<>'confirmed' then raise exception 'Abertura: %',a; end if;
 c:=(a->'result'->'caixa'->>'id')::uuid;
 b:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000002','open-cash','60000000-0000-0000-0000-000000000002','{"nome":"Celular B","valor_inicial":0}');
 if b->>'state'<>'confirmed' or (select count(*) from pdv_movel_caixas where status='aberto')<>2 then raise exception 'Dois celulares não são independentes: %',b; end if;
 c2:=(b->'result'->'caixa'->>'id')::uuid;
 req:=jsonb_build_object('caixa_id',c,'itens','[{"produto_id":"30000000-0000-0000-0000-000000000001","quantidade":2,"preco_base":12,"desconto":0,"acrescimo":0}]'::jsonb,'pagamentos','[{"forma_pagamento":"Pix","valor":12},{"forma_pagamento":"Pix","valor":12}]'::jsonb,'prazo',false);
 sale:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000001','sale','60000000-0000-0000-0000-000000000003',req);
 if sale->>'state'<>'confirmed' then raise exception 'Venda: %',sale; end if;
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000001','sale','60000000-0000-0000-0000-000000000003',req);
 if r<>sale or (select count(*) from vendas)<>1 or (select quantidade_estoque from produtos where id='30000000-0000-0000-0000-000000000001')<>8 then raise exception 'Duplicidade/estoque'; end if;
 if (select count(*) from vendas_pagamentos)<>2 or (select sum(valor) from vendas_pagamentos)<>24 or (select count(*) from private.taxas_chamadas)<>2 then raise exception 'Pagamentos agrupados ou taxas não chamadas'; end if;
 if exists(select 1 from vendas where caixa_id is not null) then raise exception 'Misturou caixa principal'; end if;
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000002','sale',gen_random_uuid(),req);
 if r->>'state'<>'rejected' then raise exception 'Permitiu caixa de outro celular'; end if;
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000001','sale',gen_random_uuid(),jsonb_set(req,'{pagamentos}','[{"forma_pagamento":"Pix","valor":1}]'));
 if r->>'state'<>'rejected' then raise exception 'Aceitou soma incorreta'; end if;
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000001','sale',gen_random_uuid(),jsonb_set(req,'{itens,0,quantidade}','999'));
 if r->>'state'<>'rejected' then raise exception 'Aceitou estoque insuficiente'; end if;
 if (select quantidade_estoque from produtos where id='30000000-0000-0000-0000-000000000001')<>8 or (select count(*) from vendas)<>1 then raise exception 'Não reverteu erro'; end if;
 key:=gen_random_uuid();
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000001','sale',key,jsonb_set(req,'{itens,0,preco_base}','1'));
 if r->>'state'<>'rejected' then raise exception 'Aceitou preço adulterado'; end if;
 if public.pdv_movel_operacao_consultar('50000000-0000-0000-0000-000000000001','sale',key)<>r then raise exception 'Rejeição não recuperável'; end if;
 req:=jsonb_set(jsonb_set(jsonb_set(jsonb_set(req,'{cliente_id}','"40000000-0000-0000-0000-000000000001"'),'{prazo}','true'),'{pagamentos}','[]'),'{itens,0,quantidade}','1');
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000001','sale',gen_random_uuid(),req);
 if r->>'state'<>'confirmed' or (select count(*) from contas_receber)<>1 or (select count(*) from vendas_pagamentos)<>2 then raise exception 'Prazo/recebimentos: %',r; end if;
 if (select quantidade_estoque from produtos where id='30000000-0000-0000-0000-000000000001')<>7 then raise exception 'Estoque prazo'; end if;
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000001','close-cash',gen_random_uuid(),jsonb_build_object('caixa_id',c));
 if r->>'state'<>'confirmed' or (r->'result'->'resumo'->>'total_vendido')::numeric<>36 or (r->'result'->'resumo'->>'nota_prazo')::numeric<>12 or (r->'result'->'resumo'->>'dinheiro_esperado')::numeric<>10 then raise exception 'Fechamento divergente: %',r; end if;
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000001','sale',gen_random_uuid(),req);
 if r->>'state'<>'rejected' then raise exception 'Vendeu com caixa fechado'; end if;
 if exists(select 1 from caixas where status<>'aberto') or (select status from pdv_movel_caixas where id=c2)<>'aberto' then raise exception 'Alterou outros caixas'; end if;
 if jsonb_array_length(public.pdv_movel_vendas_listar('{}'))<>2 then raise exception 'Histórico'; end if;
 if public.pdv_movel_venda_detalhar((sale->'result'->>'venda_id')::uuid)->'venda'->>'origem'<>'PDV Móvel' then raise exception 'Origem'; end if;
 perform set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000002',false);
 if jsonb_array_length(public.pdv_movel_vendas_listar('{}'))<>0 then raise exception 'Vazou empresa'; end if;
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000002','close-cash',gen_random_uuid(),jsonb_build_object('caixa_id',c2));
 if r->>'state'<>'rejected' then raise exception 'Fechou caixa de outra empresa'; end if;
 perform set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000003',false);
 if jsonb_array_length(public.pdv_movel_vendas_listar('{}'))<>0 then raise exception 'Operador viu vendas de terceiros'; end if;
 perform set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',false);
 update configuracoes_fiscais set emite_nota_fiscal=true where empresa_id='10000000-0000-0000-0000-000000000001';
 r:=public.pdv_movel_operar('50000000-0000-0000-0000-000000000002','sale',gen_random_uuid(),jsonb_set(req,'{caixa_id}',to_jsonb(c2)));
 if r->>'state'<>'rejected' then raise exception 'Contornou configuração fiscal'; end if;
 update configuracoes_fiscais set emite_nota_fiscal=false where empresa_id='10000000-0000-0000-0000-000000000001';
 raise notice 'OK: abertura por dispositivo, venda, pagamentos separados, estoque, rollback, idempotência, prazo, fechamento, histórico, isolamento e fiscal';
end $$;
