-- Isolated fixtures: execute only inside a transaction ending in ROLLBACK.
DO $test$
DECLARE e uuid:=gen_random_uuid();u uuid:=gen_random_uuid();p uuid;combo uuid;side uuid;gid uuid:=gen_random_uuid();cfg jsonb;token text;r jsonb;req jsonb;k uuid:=gen_random_uuid();sid uuid;manual uuid;d jsonb;device uuid:=gen_random_uuid();blocked boolean;i int;before_stock numeric;
BEGIN
 INSERT INTO public.empresas(id,nome,status_conta,bloqueado) VALUES(e,'TESTE CARDAPIO ROTISSERIA','aprovado',false);
 INSERT INTO auth.users(id,email) VALUES(u,'rot-menu-'||u||'@example.invalid');
 INSERT INTO public.perfis(id,empresa_id,nome,papel,ativo) VALUES(u,e,'Operador teste','proprietario',true);
 INSERT INTO public.empresa_modulos(empresa_id,modulo,ativo) VALUES(e,'rotisseria',true);
 INSERT INTO public.produtos(empresa_id,nome,preco_venda,quantidade_estoque,unidade_comercial,venda_granel) VALUES(e,'Linguiça',54,100,'KG',true) RETURNING id INTO p;
 PERFORM set_config('request.jwt.claim.sub',u::text,true);
 cfg:=public.rotisseria_rpc('cardapio_dados');token:=cfg->>'token';
 blocked:=false;BEGIN PERFORM public.rotisseria_cardapio_publico('catalogo',token,'{}',NULL,repeat('a',64));EXCEPTION WHEN OTHERS THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Cardápio pausado exposto';END IF;
 PERFORM public.rotisseria_rpc('cardapio_produto',jsonb_build_object('produto_id',p,'disponivel',true));PERFORM public.rotisseria_rpc('cardapio_salvar','{"ativo":true}');
 PERFORM public.rotisseria_rpc('config_salvar',jsonb_build_object('quantidade',50,'destaques',1,'produtos',jsonb_build_array(jsonb_build_object('id',p,'foto','data:image/jpeg;base64,/9j/'))));
 r:=public.rotisseria_cardapio_publico('catalogo',token,'{}',NULL,repeat('a',64));IF r->'produtos'->0->>'foto'<>'data:image/jpeg;base64,/9j/' THEN RAISE EXCEPTION 'Foto existente não reaproveitada';END IF;
 IF r->'produtos'->0 ? 'quantidade_estoque' OR r->'produtos'->0 ? 'empresa_id' THEN RAISE EXCEPTION 'Catálogo expôs informações internas';END IF;
 req:=jsonb_build_object('nome','Ângelo Floresta','telefone','11999999999','total',27,'itens',jsonb_build_array(jsonb_build_object('produto_id',p,'quantidade',.5,'preco',54)));
 r:=public.rotisseria_cardapio_publico('confirmar',token,req,k,repeat('a',64));IF (r->>'numero')::int<>1 OR (r->>'total')::numeric<>27 THEN RAISE EXCEPTION 'Primeiro pedido ou peso incorreto';END IF;
 r:=public.rotisseria_cardapio_publico('confirmar',token,req,k,repeat('a',64));IF r->>'repetido'<>'true' THEN RAISE EXCEPTION 'Reenvio duplicou';END IF;
 IF (SELECT count(*) FROM private.rotisseria_sessoes WHERE empresa_id=e)<>1 OR (SELECT quantidade_estoque FROM public.produtos WHERE id=p)<>100 THEN RAISE EXCEPTION 'Pedido deu baixa ou duplicou sessão';END IF;
 sid:=(SELECT id FROM private.rotisseria_sessoes WHERE empresa_id=e AND origem='cardapio' AND numero=1);
 r:=public.rotisseria_rpc('abrir_comanda','{"numero":1}');manual:=(r->>'id')::uuid;IF manual=sid THEN RAISE EXCEPTION 'Pedido ocupou numeração da comanda';END IF;
 r:=public.rotisseria_rpc('contexto');IF jsonb_array_length(r->'comandas')<>51 OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r->'comandas') x WHERE x->>'origem'='cardapio' AND x->'solicitante'->>'nome'='Ângelo Floresta') THEN RAISE EXCEPTION 'Pedido ou comandas não aparecem no contexto: %',r;END IF;
 blocked:=false;BEGIN PERFORM public.rotisseria_cardapio_publico('confirmar',token,req||'{"nome":"Outra pessoa"}',k,repeat('a',64));EXCEPTION WHEN OTHERS THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Mesmo envio aceitou alteração';END IF;
 blocked:=false;BEGIN PERFORM public.rotisseria_cardapio_publico('confirmar',token,req||'{"total":1}',gen_random_uuid(),repeat('a',64));EXCEPTION WHEN OTHERS THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Aceitou total adulterado';END IF;
 -- More than 50 digital orders coexist independently of the 50 manual comandas.
 FOR i IN 2..55 LOOP r:=public.rotisseria_cardapio_publico('confirmar',token,req,gen_random_uuid(),md5(i::text)||md5('ip'||i));IF (r->>'numero')::int<>i THEN RAISE EXCEPTION 'Sequência de pedidos incorreta';END IF;END LOOP;
 IF (SELECT count(*) FROM private.rotisseria_sessoes WHERE empresa_id=e AND origem='cardapio')<>55 THEN RAISE EXCEPTION 'Limitou pedidos digitais a 50';END IF;
 -- Public combos retain fixed price and expand only selected accompaniment ingredients.
 r:=public.rotisseria_rpc('catalogo_salvar',jsonb_build_object('id',gen_random_uuid(),'tipo','composto','modelo','escolhas','nome','Guarnição digital','preco',10,'grupos',jsonb_build_array(jsonb_build_object('id',gid,'nome','Escolha','quantidade_escolhas',1,'opcoes',jsonb_build_array(jsonb_build_object('produto_id',p,'quantidade',.1))))));side:=(r->>'produto_id')::uuid;
 r:=public.rotisseria_rpc('catalogo_salvar',jsonb_build_object('id',gen_random_uuid(),'tipo','combo','nome','Combo digital','preco',59.9,'componentes',jsonb_build_array(jsonb_build_object('produto_id',p,'quantidade',.4,'grupo','principal'),jsonb_build_object('produto_id',side,'quantidade',1,'grupo','acompanhamento'))));combo:=(r->>'produto_id')::uuid;
 PERFORM public.rotisseria_rpc('cardapio_produto',jsonb_build_object('produto_id',combo,'disponivel',true));
 r:=public.rotisseria_cardapio_publico('catalogo',token,'{"busca":"Combo digital"}',NULL,repeat('a',64));IF r->'produtos'->0->'componentes'->1->'composto'->>'modelo'<>'escolhas' OR r->'produtos'->0->'componentes'->0 ? 'quantidade' THEN RAISE EXCEPTION 'Combo público não descreve acompanhamento ou expõe consumo técnico';END IF;
 r:=public.rotisseria_cardapio_publico('confirmar',token,jsonb_build_object('nome','Cliente combo','telefone','11999999999','total',59.9,'itens',jsonb_build_array(jsonb_build_object('produto_id',combo,'preco',59.9,'quantidade',1,'catalogo_versao',1,'acompanhamentos',jsonb_build_array(jsonb_build_object('produto_id',side,'catalogo_versao',1,'escolhas',jsonb_build_array(jsonb_build_object('grupo_id',gid,'produto_id',p))))))),gen_random_uuid(),repeat('b',64));
 IF (r->>'numero')::int<>56 OR (r->>'total')::numeric<>59.9 OR NOT EXISTS(SELECT 1 FROM private.rotisseria_itens it JOIN private.rotisseria_sessoes ss ON ss.id=it.sessao_id WHERE ss.empresa_id=e AND ss.origem='cardapio' AND ss.numero=56 AND (it.composicao->'baixas'->0->>'quantidade')::numeric=.5) THEN RAISE EXCEPTION 'Combo digital somou preços ou perdeu consumo da escolha';END IF;
 -- Receives through the existing Rotisseria cash flow; stock is deducted once on payment.
 PERFORM public.rotisseria_rpc('caixa_vincular','{}',device);
 INSERT INTO public.caixas(empresa_id,tipo_caixa,numero,aberto_por,aberto_por_nome) VALUES(e,'ROTISSERIA',1,u,'Teste');
 d:=public.rotisseria_rpc('detalhe',jsonb_build_object('id',sid));r:=public.rotisseria_rpc('receber',jsonb_build_object('id',sid,'versao',d->'versao','forma','Pix','valor',27,'chave',gen_random_uuid()),device);
 IF r->>'finalizada'<>'true' OR (SELECT quantidade_estoque FROM public.produtos WHERE id=p)<>99.5 THEN RAISE EXCEPTION 'Pedido não finalizou ou estoque incorreto';END IF;
 r:=public.rotisseria_rpc('imprimir_comanda',jsonb_build_object('id',sid,'canal','navegador'));IF r->>'origem'<>'cardapio' OR r->>'empresa' NOT LIKE 'PEDIDO 1%' THEN RAISE EXCEPTION 'Impressão confundiu pedido e comanda';END IF;
 r:=public.rotisseria_cardapio_publico('acompanhar',token,jsonb_build_object('segredo',(SELECT resultado->>'segredo' FROM private.rotisseria_cardapio_envios WHERE empresa_id=e AND chave=k)),k,repeat('a',64));IF r->>'estado'<>'concluida' THEN RAISE EXCEPTION 'Acompanhamento não mostra finalização';END IF;
 blocked:=false;BEGIN PERFORM public.rotisseria_cardapio_publico('acompanhar',token,jsonb_build_object('segredo',repeat('0',64)),k,repeat('a',64));EXCEPTION WHEN OTHERS THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Pedido exposto sem segredo';END IF;
 IF has_function_privilege('anon','public.rotisseria_cardapio_publico(text,text,jsonb,uuid,text)','EXECUTE') OR has_table_privilege('authenticated','private.rotisseria_cardapio_envios','SELECT') THEN RAISE EXCEPTION 'Acesso direto ao endpoint privilegiado';END IF;
 PERFORM public.rotisseria_rpc('cardapio_produto',jsonb_build_object('produto_id',p,'disponivel',false));r:=public.rotisseria_cardapio_publico('catalogo',token,'{}',NULL,repeat('a',64));IF EXISTS(SELECT 1 FROM jsonb_array_elements(r->'produtos') x WHERE x->>'id'=p::text) THEN RAISE EXCEPTION 'Produto indisponível continuou no cardápio';END IF;
END $test$;
SELECT 'PASS: fotos, catálogo público, 500g, reenvio, sequência até 55, 50 comandas independentes, caixa, estoque, impressão, acompanhamento e permissões' resultado;
