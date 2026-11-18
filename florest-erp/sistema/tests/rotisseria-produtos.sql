-- Run inside BEGIN ... ROLLBACK. Isolated company/user; never prints or persists a sale.
DO $test$
DECLARE e uuid:=gen_random_uuid();u uuid:=gen_random_uuid();meat uuid;bread uuid;potato uuid;salad uuid;side uuid;combo uuid;cid uuid:=gen_random_uuid();sideid uuid:=gen_random_uuid();gid uuid:=gen_random_uuid();sid uuid;device uuid:=gen_random_uuid();itemid uuid;vid uuid;
 r jsonb;d jsonb;req jsonb;recipe jsonb;choices jsonb;blocked boolean;photo text:='data:image/jpeg;base64,/9j/';i int;e2 uuid:=gen_random_uuid();u2 uuid:=gen_random_uuid();u3 uuid:=gen_random_uuid();
BEGIN
 INSERT INTO public.empresas(id,nome,status_conta,bloqueado) VALUES(e,'TESTE COMBOS ROTISSERIA','aprovado',false);
 INSERT INTO auth.users(id,email) VALUES(u,'rot-combo-'||u||'@example.invalid');
 INSERT INTO public.perfis(id,empresa_id,nome,papel,ativo) VALUES(u,e,'Teste combos','proprietario',true);
 INSERT INTO public.empresa_modulos(empresa_id,modulo,ativo) VALUES(e,'rotisseria',true);
 INSERT INTO public.produtos(empresa_id,nome,preco_venda,quantidade_estoque,unidade_comercial,venda_granel) VALUES(e,'Costela suína',100,100,'KG',true) RETURNING id INTO meat;
 INSERT INTO public.produtos(empresa_id,nome,preco_venda,quantidade_estoque,unidade_comercial) VALUES(e,'Pão artesanal',9,100,'UN') RETURNING id INTO bread;
 INSERT INTO public.produtos(empresa_id,nome,preco_venda,quantidade_estoque,unidade_comercial,venda_granel) VALUES(e,'Batata rústica',80,100,'KG',true) RETURNING id INTO potato;
 INSERT INTO public.produtos(empresa_id,nome,preco_venda,quantidade_estoque,unidade_comercial,venda_granel) VALUES(e,'Maionese',70,100,'KG',true) RETURNING id INTO salad;
 PERFORM set_config('request.jwt.claim.sub',u::text,true);
 recipe:=jsonb_build_object('id',sideid,'tipo','composto','modelo','escolhas','nome','Guarnição','preco',10,'componentes','[]'::jsonb,'grupos',jsonb_build_array(jsonb_build_object('id',gid,'nome','Escolha sua guarnição','quantidade_escolhas',1,'opcoes',jsonb_build_array(jsonb_build_object('produto_id',potato,'quantidade',.2,'descricao','Assada'),jsonb_build_object('produto_id',salad,'quantidade',.15)))));
 r:=public.rotisseria_rpc('catalogo_salvar',recipe);side:=(r->>'produto_id')::uuid;
 req:=jsonb_build_object('id',cid,'tipo','combo','modelo','fixo','nome','Combo texana','preco',59.90,'descricao','Almoço','grupos','[]'::jsonb,'componentes',jsonb_build_array(jsonb_build_object('produto_id',meat,'quantidade',.4,'grupo','principal','descricao','Defumada'),jsonb_build_object('produto_id',bread,'quantidade',1,'grupo','principal'),jsonb_build_object('produto_id',side,'quantidade',1,'grupo','acompanhamento')));
 r:=public.rotisseria_rpc('catalogo_salvar',req);combo:=(r->>'produto_id')::uuid;
 PERFORM public.rotisseria_rpc('catalogo_salvar',req);IF (SELECT count(*) FROM private.rotisseria_catalogo WHERE empresa_id=e AND tipo='combo')<>1 THEN RAISE EXCEPTION 'Cadastro repetido duplicou';END IF;
 r:=public.rotisseria_rpc('catalogo_venda',jsonb_build_object('produto_id',combo));IF r->'componentes'->2->'composto'->>'modelo'<>'escolhas' THEN RAISE EXCEPTION 'Acompanhamento composto ausente';END IF;
 blocked:=false;BEGIN PERFORM public.rotisseria_rpc('catalogo_salvar',req||jsonb_build_object('id',gen_random_uuid(),'nome','Rejeitar','componentes',jsonb_build_array(jsonb_build_object('produto_id',combo,'quantidade',1,'grupo','principal'))));EXCEPTION WHEN OTHERS THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Combo dentro de combo permitido';END IF;
 r:=public.rotisseria_rpc('abrir_comanda','{"numero":1}');sid:=(r->>'id')::uuid;
 choices:=jsonb_build_array(jsonb_build_object('produto_id',side,'catalogo_versao',1,'escolhas',jsonb_build_array(jsonb_build_object('grupo_id',gid,'produto_id',potato))));
 req:=jsonb_build_object('id',sid,'produto_id',combo,'quantidade',1,'preco',59.9,'chave',gen_random_uuid(),'catalogo_versao',1,'escolhas','[]'::jsonb,'acompanhamentos',choices);
 blocked:=false;BEGIN PERFORM public.rotisseria_rpc('lancar',req||'{"acompanhamentos":[]}');EXCEPTION WHEN OTHERS THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Lançou sem escolher acompanhamento';END IF;
 r:=public.rotisseria_rpc('lancar',req);itemid:=(r->>'item_id')::uuid;
 r:=public.rotisseria_rpc('lancar',req);IF r->>'repetido'<>'true' THEN RAISE EXCEPTION 'Reenvio não identificado';END IF;
 blocked:=false;BEGIN PERFORM public.rotisseria_rpc('lancar',req||jsonb_build_object('acompanhamentos',jsonb_build_array(jsonb_build_object('produto_id',side,'catalogo_versao',1,'escolhas',jsonb_build_array(jsonb_build_object('grupo_id',gid,'produto_id',salad))))));EXCEPTION WHEN OTHERS THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Reenvio com escolhas diferentes aceito';END IF;
 d:=public.rotisseria_rpc('detalhe',jsonb_build_object('id',sid));IF (d->>'total')::numeric<>59.9 OR jsonb_array_length(d->'itens')<>1 THEN RAISE EXCEPTION 'Somou preços dos componentes';END IF;
 r:=public.rotisseria_rpc('imprimir_comanda',jsonb_build_object('id',sid,'canal','navegador'));
 IF (SELECT string_agg(x->>'nome',' | ' ORDER BY ord) FROM jsonb_array_elements(r->'itens') WITH ORDINALITY t(x,ord)) NOT LIKE '%Produtos:%Costela suína — Defumada%Pão artesanal%Acompanhamentos:%Guarnição%Batata rústica — Assada%' OR (r->'itens'->0->>'subtotal')::numeric<>59.9 OR EXISTS(SELECT 1 FROM jsonb_array_elements(r->'itens') x WHERE (x->>'descritivo')::boolean AND (x ? 'quantidade' OR x ? 'preco_unitario' OR x ? 'subtotal')) THEN RAISE EXCEPTION 'Descrição ou preço do comprovante incorretos: %',r;END IF;
 IF EXISTS(SELECT 1 FROM public.produtos WHERE empresa_id=e AND id IN (meat,bread,potato,salad) AND quantidade_estoque<>100) THEN RAISE EXCEPTION 'Baixou estoque antes do pagamento';END IF;
 -- A recipe edit cannot rewrite an existing order's ingredients or its printed details.
 PERFORM public.rotisseria_rpc('catalogo_salvar',recipe||jsonb_build_object('produto_id',side,'versao',1,'grupos',jsonb_build_array(jsonb_build_object('id',gid,'nome','Nova guarnição','quantidade_escolhas',1,'opcoes',jsonb_build_array(jsonb_build_object('produto_id',potato,'quantidade',.3))))));
 PERFORM public.rotisseria_rpc('caixa_vincular','{}',device);
 INSERT INTO public.caixas(empresa_id,tipo_caixa,numero,aberto_por,aberto_por_nome) VALUES(e,'ROTISSERIA',1,u,'Teste');
 req:=jsonb_build_object('id',sid,'versao',d->'versao','forma','Pix','valor',10,'chave',gen_random_uuid());
 PERFORM public.rotisseria_rpc('receber',req,device);PERFORM public.rotisseria_rpc('receber',req,device);
 IF (SELECT quantidade_estoque FROM public.produtos WHERE id=meat)<>99.6 OR (SELECT quantidade_estoque FROM public.produtos WHERE id=bread)<>99 OR (SELECT quantidade_estoque FROM public.produtos WHERE id=potato)<>99.8 OR (SELECT quantidade_estoque FROM public.produtos WHERE id=salad)<>100 OR (SELECT quantidade_estoque FROM public.produtos WHERE id=combo)<>0 OR (SELECT quantidade_estoque FROM public.produtos WHERE id=side)<>0 THEN RAISE EXCEPTION 'Baixa de componentes incorreta ou duplicada';END IF;
 -- Later launch uses the new recipe, reserves immediately, and cancellation restores that snapshot.
 r:=public.rotisseria_rpc('lancar',jsonb_build_object('id',sid,'produto_id',combo,'quantidade',1,'preco',59.9,'chave',gen_random_uuid(),'catalogo_versao',1,'escolhas','[]'::jsonb,'acompanhamentos',jsonb_build_array(jsonb_build_object('produto_id',side,'catalogo_versao',2,'escolhas',jsonb_build_array(jsonb_build_object('grupo_id',gid,'produto_id',potato))))));
 IF (SELECT quantidade_estoque FROM public.produtos WHERE id=potato)<>99.5 THEN RAISE EXCEPTION 'Lançamento pós-parcial não reservou';END IF;
 PERFORM public.rotisseria_rpc('cancelar_item',jsonb_build_object('id',sid,'item_id',r->>'item_id'));
 IF (SELECT quantidade_estoque FROM public.produtos WHERE id=potato)<>99.8 THEN RAISE EXCEPTION 'Cancelamento não restituiu composição';END IF;
 d:=public.rotisseria_rpc('detalhe',jsonb_build_object('id',sid));r:=public.rotisseria_rpc('receber',jsonb_build_object('id',sid,'versao',d->'versao','forma','Pix','valor',49.9,'chave',gen_random_uuid()),device);vid:=(r->>'venda_id')::uuid;
 IF r->>'finalizada'<>'true' OR (SELECT total FROM public.vendas WHERE id=vid)<>59.9 OR (SELECT count(*) FROM public.itens_venda WHERE venda_id=vid)<>1 OR (SELECT quantidade_estoque FROM public.produtos WHERE id=potato)<>99.8 THEN RAISE EXCEPTION 'Finalização ou estoque duplicado';END IF;
 -- Photos cover combo titles and mirror legacy highlights.
 PERFORM public.rotisseria_rpc('config_salvar',jsonb_build_object('quantidade',5,'destaques',1,'produtos',jsonb_build_array(jsonb_build_object('id',combo,'foto',''))));
 PERFORM public.rotisseria_rpc('foto_salvar',jsonb_build_object('produto_id',combo,'foto',photo));r:=public.rotisseria_rpc('contexto');
 IF r->'destaques'->0->>'foto'<>photo OR r->'destaques'->0->>'tipo_item'<>'combo' THEN RAISE EXCEPTION 'Foto do combo não aparece nos destaques';END IF;
 -- Reject oversized and invalid recipes without leaving orphan commercial titles.
 i:=(SELECT count(*) FROM public.produtos WHERE empresa_id=e);
 blocked:=false;BEGIN PERFORM public.rotisseria_rpc('catalogo_salvar',jsonb_build_object('id',gen_random_uuid(),'tipo','combo','nome','Inválido','preco',10,'componentes',(SELECT jsonb_agg(jsonb_build_object('produto_id',bread,'quantidade',1,'grupo','principal')) FROM generate_series(1,11))));EXCEPTION WHEN OTHERS THEN blocked:=true;END;
 IF NOT blocked OR (SELECT count(*) FROM public.produtos WHERE empresa_id=e)<>i THEN RAISE EXCEPTION 'Limite por combo ou rollback incorreto';END IF;
 INSERT INTO public.empresas(id,nome,status_conta,bloqueado) VALUES(e2,'TESTE ISOLAMENTO COMBOS','aprovado',false);
 INSERT INTO auth.users(id,email) VALUES(u2,'rot-tenant-'||u2||'@example.invalid');
 INSERT INTO public.perfis(id,empresa_id,nome,papel,ativo) VALUES(u2,e2,'Outra empresa','proprietario',true);
 INSERT INTO public.empresa_modulos(empresa_id,modulo,ativo) VALUES(e2,'rotisseria',true);
 PERFORM set_config('request.jwt.claim.sub',u2::text,true);
 blocked:=false;BEGIN PERFORM public.rotisseria_rpc('catalogo_venda',jsonb_build_object('produto_id',combo));EXCEPTION WHEN OTHERS THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Composição de outra empresa exposta';END IF;
 blocked:=false;BEGIN PERFORM public.rotisseria_rpc('foto_salvar',jsonb_build_object('produto_id',combo,'foto',photo));EXCEPTION WHEN OTHERS THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Foto de outra empresa alterada';END IF;
 blocked:=false;BEGIN PERFORM public.rotisseria_rpc('catalogo_salvar',jsonb_build_object('id',cid,'tipo','combo','nome','Sobrescrever','preco',10,'componentes','[]'::jsonb));EXCEPTION WHEN insufficient_privilege THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Cadastro de outra empresa sobrescrito';END IF;
 PERFORM set_config('request.jwt.claim.sub',u::text,true);
 -- No total cap of twenty combos; only each recipe is bounded to 10 + 10.
 FOR i IN 1..21 LOOP PERFORM public.rotisseria_rpc('catalogo_salvar',jsonb_build_object('id',gen_random_uuid(),'tipo','combo','nome','Combo teste '||i,'preco',10,'componentes',jsonb_build_array(jsonb_build_object('produto_id',bread,'quantidade',1,'grupo','principal'))));END LOOP;
 IF (SELECT count(*) FROM private.rotisseria_catalogo WHERE empresa_id=e AND tipo='combo')<>22 THEN RAISE EXCEPTION 'Limite indevido de combos';END IF;
 r:=public.rotisseria_rpc('catalogo_listar','{"tipo":"combo","pagina":1}');IF jsonb_array_length(r->'itens')<>2 THEN RAISE EXCEPTION 'Paginação do catálogo incorreta';END IF;
 IF has_table_privilege('authenticated','private.rotisseria_catalogo','INSERT') OR has_function_privilege('authenticated','private.rotisseria_resolver_catalogo(uuid,uuid,int,jsonb,jsonb,int)','EXECUTE') THEN RAISE EXCEPTION 'Acesso direto à composição permitido';END IF;
 INSERT INTO auth.users(id,email) VALUES(u3,'rot-operator-'||u3||'@example.invalid');
 INSERT INTO public.perfis(id,empresa_id,nome,papel,ativo,permissoes) VALUES(u3,e,'Operador teste','funcionario',true,ARRAY['rotisseria_visualizar','rotisseria_lancar']);
 PERFORM set_config('request.jwt.claim.sub',u3::text,true);
 blocked:=false;BEGIN PERFORM public.rotisseria_rpc('catalogo_listar');EXCEPTION WHEN insufficient_privilege THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Operador configurou catálogo sem permissão';END IF;
 PERFORM public.rotisseria_rpc('catalogo_venda',jsonb_build_object('produto_id',combo));
 UPDATE public.empresa_modulos SET ativo=false WHERE empresa_id=e AND modulo='rotisseria';
 blocked:=false;BEGIN PERFORM public.rotisseria_rpc('catalogo_venda',jsonb_build_object('produto_id',combo));EXCEPTION WHEN insufficient_privilege THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Módulo desativado acessível';END IF;
END $test$;
SELECT 'PASS: preço fixo, escolhas do acompanhamento, reenvios, consumo em kg, parcial, estorno, composição histórica, finalização, fotos, paginação e permissões' resultado;
