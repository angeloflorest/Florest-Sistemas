-- Run only inside BEGIN ... ROLLBACK. Never leaves sales, stock or print jobs behind.
SELECT set_config('request.jwt.claim.sub','eaf55d51-bbfb-408e-94e8-8b26c169c463',true);
DO $test$
DECLARE e uuid:='8b48baee-bb29-45ac-8e4d-b9432c603f38';p uuid;otherp uuid;sid uuid;v uuid;key uuid:=gen_random_uuid();device uuid:=gen_random_uuid();r jsonb;d jsonb;changed boolean;before_stock numeric;before_pdv bigint;before_bar bigint;before_gastro bigint;cnt bigint;other_e uuid; printer uuid; job uuid;
BEGIN
 SELECT count(*) INTO before_pdv FROM public.vendas WHERE empresa_id=e AND tipo IS NULL;
 SELECT count(*) INTO before_bar FROM public.vendas WHERE empresa_id=e AND tipo='bar';
 SELECT count(*) INTO before_gastro FROM public.vendas WHERE empresa_id=e AND tipo='gastronomia';
 INSERT INTO public.empresa_modulos(empresa_id,modulo,ativo) VALUES(e,'rotisseria',true) ON CONFLICT(empresa_id,modulo) DO UPDATE SET ativo=true;
 INSERT INTO public.produtos(empresa_id,nome,preco_venda,quantidade_estoque,unidade_comercial,venda_granel) VALUES(e,'TESTE TRANSACIONAL ROTISSERIA',40,100,'KG',true) RETURNING id INTO p;
 r:=public.rotisseria_rpc('contexto');IF jsonb_array_length(r->'comandas')<>5 THEN RAISE EXCEPTION 'Quantidade padrão incorreta';END IF;
 PERFORM public.rotisseria_rpc('config_salvar',jsonb_build_object('quantidade',5,'destaques',1,'produtos',jsonb_build_array(jsonb_build_object('id',p,'foto',''))));
 r:=public.rotisseria_rpc('buscar',jsonb_build_object('busca','TESTE TRANSACIONAL ROTISSERIA'));IF r->0->>'id'<>p::text THEN RAISE EXCEPTION 'Busca não encontrou cadastro compartilhado';END IF;
 r:=public.rotisseria_rpc('abrir_comanda','{"numero":1}');sid:=(r->>'id')::uuid;
 d:=public.rotisseria_rpc('abrir_comanda','{"numero":1}');IF (d->>'id')::uuid<>sid THEN RAISE EXCEPTION 'Abertura duplicada';END IF;
 PERFORM public.rotisseria_rpc('lancar',jsonb_build_object('id',sid,'produto_id',p,'quantidade',1.132,'preco',40,'chave',key));
 PERFORM public.rotisseria_rpc('lancar',jsonb_build_object('id',sid,'produto_id',p,'quantidade',1.132,'preco',40,'chave',key));
 d:=public.rotisseria_rpc('detalhe',jsonb_build_object('id',sid));IF jsonb_array_length(d->'itens')<>1 OR (d->>'total')::numeric<>45.28 THEN RAISE EXCEPTION 'Peso ou deduplicação incorretos: %',d;END IF;
 -- Exercise the unchanged PDV sale path in a subtransaction and roll it back.
 BEGIN
  SELECT venda_id INTO v FROM public.registrar_venda(NULL,'Dinheiro',jsonb_build_array(jsonb_build_object('produto_id',p,'quantidade',1,'preco_unitario',40)));
  IF NOT EXISTS(SELECT 1 FROM public.vendas WHERE id=v AND tipo IS NULL AND total=40) THEN RAISE EXCEPTION 'PDV sofreu regressão';END IF;
  RAISE EXCEPTION '__rollback_pdv__';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'__rollback_pdv__' THEN RAISE;END IF;END;
 SELECT quantidade_estoque INTO before_stock FROM public.produtos WHERE id=p;IF before_stock<>100 THEN RAISE EXCEPTION 'Baixa antes da venda';END IF;
 changed:=false;BEGIN PERFORM public.rotisseria_rpc('receber',jsonb_build_object('id',sid,'versao',d->'versao','forma','Dinheiro','valor',50),gen_random_uuid());EXCEPTION WHEN insufficient_privilege THEN changed:=true;END;IF NOT changed THEN RAISE EXCEPTION 'Tablet recebeu sem dispositivo';END IF;
 PERFORM public.rotisseria_rpc('caixa_vincular','{}',device);PERFORM public.rotisseria_rpc('caixa_abrir','{"valor":10}',device);
 changed:=false;BEGIN PERFORM public.rotisseria_rpc('receber',jsonb_build_object('id',sid,'versao',1,'forma','Dinheiro','valor',50),device);EXCEPTION WHEN OTHERS THEN changed:=true;END;IF NOT changed THEN RAISE EXCEPTION 'Pagamento aceitou versão antiga';END IF;
 r:=public.rotisseria_rpc('receber',jsonb_build_object('id',sid,'versao',d->'versao','forma','Dinheiro','valor',50),device);v:=(r->>'venda_id')::uuid;
 IF (r->>'troco')::numeric<>4.72 THEN RAISE EXCEPTION 'Troco incorreto';END IF;
 r:=public.rotisseria_rpc('receber',jsonb_build_object('id',sid,'versao',d->'versao','forma','Dinheiro','valor',50),device);IF (r->>'venda_id')::uuid<>v THEN RAISE EXCEPTION 'Reenvio duplicou venda';END IF;
 IF (SELECT quantidade_estoque FROM public.produtos WHERE id=p)<>98.868 THEN RAISE EXCEPTION 'Baixa incorreta ou duplicada';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.vendas WHERE id=v AND tipo='rotisseria' AND total=45.28) THEN RAISE EXCEPTION 'Venda não integrada ao ERP';END IF;
 IF (SELECT sum(subtotal) FROM public.itens_venda WHERE venda_id=v)<>45.28 OR (SELECT sum(valor) FROM public.vendas_pagamentos WHERE venda_id=v)<>45.28 THEN RAISE EXCEPTION 'Itens ou financeiro divergentes';END IF;
 changed:=false;BEGIN PERFORM public.rotisseria_rpc('lancar',jsonb_build_object('id',sid,'produto_id',p,'quantidade',1,'preco',40,'chave',gen_random_uuid()));EXCEPTION WHEN OTHERS THEN changed:=true;END;IF NOT changed THEN RAISE EXCEPTION 'Item entrou após finalização';END IF;
 r:=public.rotisseria_rpc('caixa_dados','{}',device);IF (r->'resumo'->>'total_recebido')::numeric<>45.28 OR (r->'resumo'->>'saldo_dinheiro_esperado')::numeric<>55.28 THEN RAISE EXCEPTION 'Resumo do caixa incorreto %',r;END IF;
 PERFORM public.rotisseria_rpc('caixa_fechar',jsonb_build_object('id',r->'caixa'->>'id'),device);
 IF (SELECT fechamento_resumo->>'total_recebido' FROM public.caixas WHERE id=(r->'caixa'->>'id')::uuid)<>'45.28' THEN RAISE EXCEPTION 'Fechamento incorreto';END IF;
 r:=public.rotisseria_rpc('historico','{}',device);IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r) x WHERE x->>'id'=v::text) THEN RAISE EXCEPTION 'Histórico não encontrou venda';END IF;
 SELECT id INTO printer FROM public.impressoras WHERE empresa_id=e AND ativa LIMIT 1;
 IF printer IS NOT NULL THEN
  UPDATE private.rotisseria_config SET impressora_id=printer WHERE empresa_id=e;
  r:=public.rotisseria_rpc('imprimir',jsonb_build_object('venda_id',v,'chave',gen_random_uuid()),device);job:=(r->>'job_id')::uuid;
  IF NOT EXISTS(SELECT 1 FROM public.impressao_jobs WHERE id=job AND payload->>'rotisseria_impressora_propria'='true' AND payload->>'total'='45.28' AND tipo='recibo') THEN RAISE EXCEPTION 'Impressão não usa rota própria';END IF;
 END IF;
 r:=public.rotisseria_rpc('fiscal',jsonb_build_object('venda_id',v),device);IF jsonb_array_length(r)<>1 OR r->0->>'tipo_documento'<>'nfce' THEN RAISE EXCEPTION 'NFC-e não integrada';END IF;
 r:=public.rotisseria_rpc('fiscal',jsonb_build_object('venda_id',v),device);IF jsonb_array_length(r)<>1 THEN RAISE EXCEPTION 'NFC-e duplicada';END IF;
 SELECT id INTO other_e FROM public.empresas WHERE id<>e LIMIT 1;
 INSERT INTO public.produtos(empresa_id,nome,preco_venda,quantidade_estoque) VALUES(other_e,'TESTE OUTRA EMPRESA ROTISSERIA',10,10) RETURNING id INTO otherp;
 r:=public.rotisseria_rpc('abrir_comanda','{"numero":2}');sid:=(r->>'id')::uuid;
 changed:=false;BEGIN PERFORM public.rotisseria_rpc('lancar',jsonb_build_object('id',sid,'produto_id',otherp,'quantidade',1,'preco',10,'chave',gen_random_uuid()));EXCEPTION WHEN OTHERS THEN changed:=true;END;IF NOT changed THEN RAISE EXCEPTION 'Produto de outra empresa aceito';END IF;
 changed:=false;BEGIN PERFORM public.rotisseria_rpc('config_salvar',jsonb_build_object('quantidade',1,'destaques',0));EXCEPTION WHEN OTHERS THEN changed:=true;END;IF NOT changed THEN RAISE EXCEPTION 'Redução ocultou comanda aberta';END IF;
 PERFORM public.rotisseria_rpc('fechar_vazia',jsonb_build_object('id',sid));
 -- Insufficient stock aborts the entire payment and leaves the comanda available.
 r:=public.rotisseria_rpc('abrir_comanda','{"numero":3}');sid:=(r->>'id')::uuid;
 PERFORM public.rotisseria_rpc('lancar',jsonb_build_object('id',sid,'produto_id',p,'quantidade',1000,'preco',40,'chave',gen_random_uuid()));d:=public.rotisseria_rpc('detalhe',jsonb_build_object('id',sid));
 PERFORM public.rotisseria_rpc('caixa_abrir','{"valor":0}',device);
 UPDATE public.configuracoes_empresa SET permitir_venda_sem_estoque=false WHERE empresa_id=e;
 changed:=false;BEGIN PERFORM public.rotisseria_rpc('receber',jsonb_build_object('id',sid,'versao',d->'versao','forma','Pix','valor',40000),device);EXCEPTION WHEN OTHERS THEN changed:=true;END;IF NOT changed THEN RAISE EXCEPTION 'Pagamento ignorou saldo';END IF;
 IF (SELECT quantidade_estoque FROM public.produtos WHERE id=p)<>98.868 THEN RAISE EXCEPTION 'Falha alterou estoque';END IF;
 IF before_pdv<>(SELECT count(*) FROM public.vendas WHERE empresa_id=e AND tipo IS NULL) OR before_bar<>(SELECT count(*) FROM public.vendas WHERE empresa_id=e AND tipo='bar') OR before_gastro<>(SELECT count(*) FROM public.vendas WHERE empresa_id=e AND tipo='gastronomia') THEN RAISE EXCEPTION 'Outro módulo foi alterado';END IF;
 UPDATE public.empresa_modulos SET ativo=false WHERE empresa_id=e AND modulo='rotisseria';
 changed:=false;BEGIN PERFORM public.rotisseria_rpc('contexto');EXCEPTION WHEN insufficient_privilege THEN changed:=true;END;IF NOT changed THEN RAISE EXCEPTION 'Módulo desativado continuou acessível';END IF;
 UPDATE public.empresa_modulos SET ativo=true WHERE empresa_id=e AND modulo='rotisseria';
 IF has_function_privilege('anon','public.rotisseria_rpc(text,jsonb,uuid)','EXECUTE') THEN RAISE EXCEPTION 'RPC anônima';END IF;
END $test$;
SET LOCAL ROLE authenticated;
SELECT public.rotisseria_rpc('contexto')->>'empresa_id' empresa_confirmada;
RESET ROLE;
SELECT 'Rotisseria: peso, deduplicação, dispositivo de caixa, versão, estoque, venda, financeiro, fechamento, histórico, fiscal, isolamento e rollback OK' resultado;
