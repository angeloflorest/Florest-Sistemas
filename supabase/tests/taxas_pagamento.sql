-- Ensaios de regressão: executar em ambiente de teste após a migration de taxas.
-- Cada bloco usa transação revertida e não deixa cadastros ou vendas persistidos.

begin;

do $test$
declare u uuid; e uuid; outra uuid; cfg jsonb; cfg2 jsonb; v uuid; p uuid; p2 uuid; m uuid; c uuid; bp uuid; bf uuid; n integer; d date:=(now() at time zone 'America/Sao_Paulo')::date; bloqueou boolean;
begin
 select pr.id,pr.empresa_id into u,e from public.perfis pr join public.empresas emp on emp.id=pr.empresa_id where pr.ativo and pr.papel='proprietario' and emp.status_conta='aprovado' and not emp.bloqueado limit 1;
 if u is null then raise exception 'Sem perfil para ensaio transacional'; end if;
 perform set_config('request.jwt.claim.sub',u::text,true);
 cfg:=public.taxas_pagamento_obter();

 cfg:=public.taxas_pagamento_salvar(true,'[{"forma":"Cartão de Débito","bandeira":"Visa","percentual":2},{"forma":"Pix","bandeira":null,"percentual":1}]');
 select coalesce(max(numero_venda),0)+1 into n from public.vendas where empresa_id=e;
 insert into public.vendas(empresa_id,numero_venda,forma_pagamento,total) values(e,n,'Cartão de Débito',100) returning id into v;
 insert into public.vendas_pagamentos(empresa_id,venda_id,forma_pagamento,valor,ordem) values(e,v,'Cartão de Débito',100,1) returning id into p;
 perform private.taxas_registrar('pdv',p,jsonb_build_object('taxas',jsonb_build_object('config_id',cfg->>'id','bandeira','Visa')));
 if (select valor from public.despesas where empresa_id=e and data=d and taxas_automaticas)<>2 then raise exception 'Taxa incorreta'; end if;
 perform private.taxas_registrar('pdv',p,jsonb_build_object('taxas',jsonb_build_object('config_id',cfg->>'id','bandeira','Visa')));
 if (select count(*) from private.taxas_pagamentos where pagamento_id=p)<>1 then raise exception 'Duplicou'; end if;
 cfg2:=public.taxas_pagamento_salvar(true,'[{"forma":"Cartão de Débito","bandeira":"Visa","percentual":5}]');
 if (select percentual from private.taxas_pagamentos where pagamento_id=p)<>2 then raise exception 'Histórico mudou'; end if;
 insert into public.vendas_pagamentos(empresa_id,venda_id,forma_pagamento,valor,ordem) values(e,v,'Pix',50,2) returning id into p2;
 perform private.taxas_registrar('pdv',p2,jsonb_build_object('taxas',jsonb_build_object('config_id',cfg->>'id','bandeira',null)));
 if (select valor from public.despesas where empresa_id=e and data=d and taxas_automaticas)<>2.50 then raise exception 'Consolidação incorreta'; end if;
 bloqueou:=false; begin update public.despesas set valor=999 where empresa_id=e and taxas_automaticas; exception when insufficient_privilege then bloqueou:=true; end;
 if not bloqueou then raise exception 'Permitida edição manual de despesa automática'; end if;
 update public.vendas set cancelada_em=now() where id=v;
 if exists(select 1 from public.despesas where empresa_id=e and taxas_automaticas) then raise exception 'Cancelamento deixou despesa'; end if;
 update public.vendas set cancelada_em=null where id=v;
 if (select valor from public.despesas where empresa_id=e and data=d and taxas_automaticas)<>2.50 then raise exception 'Restauração incorreta'; end if;
 insert into public.bar_mesas(empresa_id,numero) select e,coalesce(max(numero),0)+1 from public.bar_mesas where empresa_id=e returning id into m;
 insert into public.bar_comandas(empresa_id,mesa_id) values(e,m) returning id into c;
 insert into public.bar_pagamentos(empresa_id,comanda_id,subtotal,total) values(e,c,100,100) returning id into bp;
 insert into public.bar_pagamentos_formas(empresa_id,pagamento_id,forma_pagamento,valor) values(e,bp,'Cartão de Débito',100) returning id into bf;
 perform private.taxas_registrar('bar',bf,jsonb_build_object('taxas',jsonb_build_object('config_id',cfg->>'id','bandeira','Visa')));
 if (select valor from public.despesas where empresa_id=e and data=d and taxas_automaticas)<>4.50 then raise exception 'Bar não consolidou'; end if;
 update public.bar_pagamentos set estornado=true,estornado_em=now(),estornado_por=u,estorno_motivo='Ensaio transacional' where id=bp;
 if (select valor from public.despesas where empresa_id=e and data=d and taxas_automaticas)<>2.50 then raise exception 'Bar estorno incorreto'; end if;
 insert into public.empresas(nome,status_conta) values('Ensaio temporário taxas','aprovado') returning id into outra;
 insert into private.taxas_versoes(empresa_id,ativo,regras,criado_por) values(outra,true,'[]',u) returning jsonb_build_object('config_id',id,'bandeira','Visa') into cfg2;
 bloqueou:=false; begin perform private.taxas_registrar('pdv',p,jsonb_build_object('taxas',cfg2)); exception when insufficient_privilege then bloqueou:=true; end;
 if not bloqueou then raise exception 'Falha isolamento CNPJ'; end if;
 bloqueou:=false; begin perform public.taxas_pagamento_salvar(true,'[{"forma":"Cartão de Débito","bandeira":"Discover","percentual":2}]'); exception when raise_exception then bloqueou:=true; end;
 if not bloqueou then raise exception 'Aceitou bandeira não autorizada'; end if;
 if (select total from public.vendas where id=v)<>100 then raise exception 'Bruto alterado'; end if;
end $test$;

rollback;

begin;

do $test$
declare u uuid; e uuid; cfg jsonb; cx uuid; pr uuid; v uuid; n bigint; pedido jsonb; meta jsonb; a jsonb; b jsonb; chave uuid:=gen_random_uuid(); inicial integer;
begin
 select pf.id,pf.empresa_id into u,e from public.perfis pf join public.empresas em on em.id=pf.empresa_id where pf.ativo and pf.papel='proprietario' and em.status_conta='aprovado' and not em.bloqueado limit 1;
 perform set_config('request.jwt.claim.sub',u::text,true);
 cfg:=public.taxas_pagamento_salvar(true,'[{"forma":"Cartão de Débito","bandeira":"Visa","percentual":2}]');
 select id into cx from public.caixas where empresa_id=e and tipo_caixa='PDV' and status='aberto';
 if cx is null then insert into public.caixas(empresa_id,tipo_caixa,numero,aberto_por,aberto_por_nome) select e,'PDV',coalesce(max(numero),0)+1,u,'Ensaio' from public.caixas where empresa_id=e and tipo_caixa='PDV' returning id into cx; end if;
 insert into public.produtos(empresa_id,nome,preco_venda,quantidade_estoque) values(e,'Ensaio temporário taxas',100,10) returning id into pr;
 meta:=jsonb_build_object('config_id',cfg->>'id','bandeira','Visa');
 select r.venda_id,r.numero_venda into v,n from public.registrar_venda_mista(null,jsonb_build_array(jsonb_build_object('produto_id',pr,'quantidade',1,'preco_unitario',100)),jsonb_build_array(jsonb_build_object('forma_pagamento','Cartão de Débito','valor',100,'taxas',meta))) r;
 if not exists(select 1 from private.taxas_pagamentos where venda_id=v and valor_taxa=2 and percentual=2 and bandeira='Visa') then raise exception 'RPC não registrou snapshot'; end if;
 pedido:=jsonb_build_object('itens',jsonb_build_array(jsonb_build_object('produto_id',pr,'quantidade',1,'preco_unitario',100)),'pagamentos',jsonb_build_array(jsonb_build_object('forma_pagamento','Cartão de Débito','valor',100,'taxas',meta)),'prazo',false);
 a:=public.pdv_desktop_sincronizar(chave,cx,pedido,now());
 b:=public.pdv_desktop_sincronizar(chave,cx,pedido,now());
 if a->>'idRemoto' is distinct from b->>'idRemoto' or (b->>'repetida')::boolean is distinct from true then raise exception 'Reenvio não idempotente'; end if;
 if (select count(*) from private.taxas_pagamentos where venda_id=(a->>'idRemoto')::uuid)<>1 then raise exception 'Taxa duplicada offline'; end if;
 if (select quantidade_estoque from public.produtos where id=pr)<>8 then raise exception 'Estoque divergente'; end if;
 if (select valor from public.despesas where empresa_id=e and taxas_automaticas)<>4 then raise exception 'Despesa divergente'; end if;
 if (public.pdv_desktop_contexto()->'taxas_pagamento'->>'id') is distinct from cfg->>'id' then raise exception 'Contexto sem configuração'; end if;

 -- Comanda compartilhada usa o mesmo registro de taxas.
 declare
  cli uuid; slot uuid; sessao uuid; aberta jsonb; fim jsonb; formas jsonb;
 begin
  insert into public.clientes(empresa_id,nome) values(e,'Ensaio temporário taxas') returning id into cli;
  select id into slot from public.pdv_comandas where empresa_id=e and ativa and sessao_atual_id is null order by numero limit 1;
  if slot is null then raise exception 'Sem comanda livre para ensaio'; end if;
  aberta:=public.pdv_comanda_abrir(slot,cli);
  sessao:=(aberta->>'sessao_id')::uuid;
  perform public.pdv_comanda_item_adicionar(sessao,pr,1);
  formas:=jsonb_build_array(jsonb_build_object('forma_pagamento','Cartão de Débito','valor',100,'taxas',meta));
  fim:=public.pdv_comanda_finalizar(sessao,'ensaio-taxas-'||gen_random_uuid()::text,formas,false,null);
  if (select valor from public.despesas where empresa_id=e and taxas_automaticas)<>6 then raise exception 'Comanda não registrou taxa'; end if;
 end;
end $test$;
rollback;

begin;

do $test$
declare u uuid; e uuid; cfg jsonb; cx uuid; pr uuid; bpr uuid; mesa uuid; cmd uuid; ped uuid; item uuid; recebido uuid; chave uuid; formas jsonb; r record; i integer;
begin
 select pf.id,pf.empresa_id into u,e from public.perfis pf join public.empresas em on em.id=pf.empresa_id where pf.ativo and pf.papel='proprietario' and em.status_conta='aprovado' and not em.bloqueado limit 1;
 perform set_config('request.jwt.claim.sub',u::text,true);
 insert into public.empresa_modulos(empresa_id,modulo,ativo) values(e,'bar',true) on conflict(empresa_id,modulo) do update set ativo=true;
 cfg:=public.taxas_pagamento_salvar(true,'[{"forma":"Cartão de Débito","bandeira":"Visa","percentual":2}]');
 select id into cx from public.caixas where empresa_id=e and tipo_caixa='BAR' and status='aberto';
 if cx is null then insert into public.caixas(empresa_id,tipo_caixa,numero,aberto_por,aberto_por_nome) select e,'BAR',coalesce(max(numero),0)+1,u,'Ensaio' from public.caixas where empresa_id=e and tipo_caixa='BAR' returning id into cx; end if;
 insert into public.produtos(empresa_id,nome,preco_venda,quantidade_estoque) values(e,'Ensaio temporário taxas Bar',100,10) returning id into pr;
 insert into public.bar_produtos(empresa_id,produto_id) values(e,pr) on conflict(empresa_id,produto_id) do update set ativo_cardapio=true returning id into bpr;
 formas:=jsonb_build_array(jsonb_build_object('forma_pagamento','Cartão de Débito','valor',100,'taxas',jsonb_build_object('config_id',cfg->>'id','bandeira','Visa')));
 for i in 1..2 loop
  insert into public.bar_mesas(empresa_id,numero,status,pessoas_atual) select e,coalesce(max(numero),0)+1,'ocupada',1 from public.bar_mesas where empresa_id=e returning id into mesa;
  insert into public.bar_comandas(empresa_id,mesa_id) values(e,mesa) returning id into cmd;
  update public.bar_mesas set comanda_atual_id=cmd where id=mesa;
  insert into public.bar_pedidos(empresa_id,comanda_id,mesa_id,idempotencia_key) values(e,cmd,mesa,gen_random_uuid()) returning id into ped;
  insert into public.bar_pedidos_itens(empresa_id,pedido_id,comanda_id,bar_produto_id,produto_id,quantidade,preco_unitario,destino_operacional) values(e,ped,cmd,bpr,pr,1,100,'sem_destino') returning id into item;
  if i=1 then
   chave:=gen_random_uuid();
   select * into r from public.bar_comanda_pagar_valor(cmd,100,formas,chave);
   recebido:=r.pagamento_id;
   perform public.bar_comanda_pagar_valor(cmd,100,formas,chave);
  else
   select * into r from public.bar_comanda_pagar(cmd,null,formas);
   recebido:=r.pagamento_id;
  end if;
  if (select count(*) from private.taxas_pagamentos where bar_pagamento_id=recebido and valor_taxa=2 and bandeira='Visa')<>1 then raise exception 'Integração Bar % falhou',i; end if;
 end loop;
 if (select valor from public.despesas where empresa_id=e and taxas_automaticas)<>4 then raise exception 'Despesa Bar divergente'; end if;
end $test$;
rollback;
