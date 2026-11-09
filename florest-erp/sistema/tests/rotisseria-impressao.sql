-- Execute only inside BEGIN ... ROLLBACK. No physical print or test data persists.
DO $test$
DECLARE e uuid:=gen_random_uuid();u uuid:=gen_random_uuid();p uuid;sid uuid;station uuid;printer uuid;key1 uuid:=gen_random_uuid();job uuid;r jsonb;req jsonb;before_stock numeric;bad boolean;cnt bigint;
BEGIN
 INSERT INTO public.empresas(id,nome,status_conta,bloqueado) VALUES(e,'EMPRESA TESTE IMPRESSÃO ROTISSERIA','aprovado',false);
 INSERT INTO auth.users(id,email) VALUES(u,'rot-print-'||u||'@example.invalid');
 INSERT INTO public.perfis(id,empresa_id,nome,papel,ativo) VALUES(u,e,'Operador teste','proprietario',true);
 INSERT INTO public.empresa_modulos(empresa_id,modulo,ativo) VALUES(e,'rotisseria',true);
 INSERT INTO public.produtos(empresa_id,nome,preco_venda,quantidade_estoque,unidade_comercial,venda_granel) VALUES(e,'Carne teste',40,100,'KG',true) RETURNING id INTO p;
 PERFORM set_config('request.jwt.claim.sub',u::text,true);
 r:=public.rotisseria_rpc('abrir_comanda','{"numero":1}');sid:=(r->>'id')::uuid;
 bad:=false;BEGIN PERFORM public.rotisseria_rpc('imprimir_comanda',jsonb_build_object('id',sid,'canal','navegador'));EXCEPTION WHEN OTHERS THEN bad:=true;END;IF NOT bad THEN RAISE EXCEPTION 'Imprimiu comanda vazia';END IF;
 PERFORM public.rotisseria_rpc('lancar',jsonb_build_object('id',sid,'produto_id',p,'preco',40,'quantidade',1.132,'chave',gen_random_uuid()));
 r:=public.rotisseria_rpc('lancar',jsonb_build_object('id',sid,'produto_id',p,'preco',40,'quantidade',1,'chave',gen_random_uuid()));
 PERFORM public.rotisseria_rpc('cancelar_item',jsonb_build_object('id',sid,'item_id',r->>'item_id'));
 r:=public.rotisseria_rpc('imprimir_comanda',jsonb_build_object('id',sid,'canal','navegador'));
 IF jsonb_array_length(r->'itens')<>1 OR (r->>'total')::numeric<>45.28 OR (r->>'ja_pago')::numeric<>0 OR (r->>'falta_pagar')::numeric<>45.28 OR r->>'empresa' NOT LIKE 'COMANDA 1 — %' THEN RAISE EXCEPTION 'Documento incorreto: %',r;END IF;
 IF (SELECT count(*) FROM public.impressao_jobs WHERE empresa_id=e)<>0 THEN RAISE EXCEPTION 'Prévia enfileirou impressão';END IF;
 bad:=false;BEGIN PERFORM public.rotisseria_rpc('imprimir_comanda',jsonb_build_object('id',gen_random_uuid(),'canal','navegador'));EXCEPTION WHEN OTHERS THEN bad:=true;END;IF NOT bad THEN RAISE EXCEPTION 'Aceitou comanda sem vínculo';END IF;
 bad:=false;BEGIN PERFORM public.rotisseria_rpc('imprimir_comanda',jsonb_build_object('id',sid,'canal','impressora','chave',key1));EXCEPTION WHEN OTHERS THEN bad:=true;END;IF NOT bad THEN RAISE EXCEPTION 'Enfileirou sem impressora';END IF;
 INSERT INTO public.impressao_estacoes(empresa_id,nome,identificador_instalacao) VALUES(e,'Estação teste',gen_random_uuid()::text) RETURNING id INTO station;
 INSERT INTO public.impressoras(empresa_id,estacao_id,nome,identificador_agente) VALUES(e,station,'Impressora teste','print-test') RETURNING id INTO printer;
 PERFORM public.rotisseria_rpc('config_salvar',jsonb_build_object('quantidade',5,'destaques',0,'produtos','[]'::jsonb,'impressora_id',printer));
 req:=jsonb_build_object('id',sid,'canal','impressora','chave',key1);
 r:=public.rotisseria_rpc('imprimir_comanda',req);job:=(r->>'job_id')::uuid;
 r:=public.rotisseria_rpc('imprimir_comanda',req);IF (r->>'job_id')::uuid<>job OR (SELECT count(*) FROM public.impressao_jobs WHERE empresa_id=e)<>1 THEN RAISE EXCEPTION 'Impressão duplicada';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.impressao_jobs WHERE id=job AND payload->>'rotisseria_impressora_propria'='true' AND payload->>'rotisseria_comanda_id'=sid::text AND payload->>'total'='45.28' AND payload->>'falta_pagar'='45.28' AND tipo='recibo') THEN RAISE EXCEPTION 'Roteamento ou valores incorretos';END IF;
 IF (SELECT estado FROM private.rotisseria_sessoes WHERE id=sid)<>'aberta' OR (SELECT quantidade_estoque FROM public.produtos WHERE id=p)<>100 OR EXISTS(SELECT 1 FROM public.vendas WHERE empresa_id=e) OR EXISTS(SELECT 1 FROM private.rotisseria_pagamentos WHERE empresa_id=e) THEN RAISE EXCEPTION 'Impressão alterou venda, caixa ou estoque';END IF;
END $test$;
SELECT 'PASS: prévia, lista, cancelados, totais, permissões, impressora própria, reenvio e ausência de efeitos financeiros' resultado;
