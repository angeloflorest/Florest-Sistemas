-- Fixtures isoladas; executar entre BEGIN e ROLLBACK.
DO $test$
DECLARE e uuid:=gen_random_uuid();u uuid:=gen_random_uuid();p uuid;t text;req jsonb;r jsonb;sid uuid;k uuid;blocked boolean;mode text;
BEGIN
 INSERT INTO public.empresas(id,nome,status_conta,bloqueado) VALUES(e,'TESTE MODALIDADE ROTISSERIA','aprovado',false);
 INSERT INTO auth.users(id,email) VALUES(u,'rt-entrega-'||u||'@example.invalid');
 INSERT INTO public.perfis(id,empresa_id,nome,papel,ativo) VALUES(u,e,'Teste','proprietario',true);
 INSERT INTO public.empresa_modulos(empresa_id,modulo,ativo) VALUES(e,'rotisseria',true);
 INSERT INTO public.produtos(empresa_id,nome,preco_venda,quantidade_estoque,unidade_comercial) VALUES(e,'Teste produto',25,10,'UN') RETURNING id INTO p;
 PERFORM set_config('request.jwt.claim.sub',u::text,true);
 t:=public.rotisseria_rpc('cardapio_dados')->>'token';
 PERFORM public.rotisseria_rpc('cardapio_produto',jsonb_build_object('produto_id',p,'disponivel',true));
 PERFORM public.rotisseria_rpc('cardapio_salvar','{"ativo":true}');
 req:=jsonb_build_object('nome','Cliente teste','telefone','11999999999','total',25,'itens',jsonb_build_array(jsonb_build_object('produto_id',p,'quantidade',1,'preco',25)));
 FOREACH mode IN ARRAY ARRAY['entrega','retirada','legado'] LOOP
  k:=gen_random_uuid();r:=public.rotisseria_cardapio_publico('confirmar',t,req||CASE WHEN mode='legado' THEN '{}'::jsonb ELSE jsonb_build_object('modalidade',mode,'endereco','Rua Teste, 10, Centro, Cidade') END,k,md5(mode)||md5(mode));
  SELECT sessao_id INTO sid FROM private.rotisseria_cardapio_envios WHERE empresa_id=e AND chave=k;
  IF (SELECT solicitante->>'modalidade' FROM private.rotisseria_sessoes WHERE id=sid)<>(CASE WHEN mode='entrega' THEN 'entrega' ELSE 'retirada' END) THEN RAISE EXCEPTION 'Modalidade não persistida'; END IF;
  IF mode='entrega' AND (SELECT solicitante->>'endereco' FROM private.rotisseria_sessoes WHERE id=sid)<>'Rua Teste, 10, Centro, Cidade' THEN RAISE EXCEPTION 'Endereço perdido'; END IF;
  r:=public.rotisseria_rpc('detalhe',jsonb_build_object('id',sid));IF r#>>'{solicitante,modalidade}' IS NULL THEN RAISE EXCEPTION 'Modalidade ausente no atendimento'; END IF;
 END LOOP;
 blocked:=false;BEGIN PERFORM public.rotisseria_cardapio_publico('confirmar',t,req||'{"modalidade":"entrega","endereco":"  "}',gen_random_uuid(),repeat('f',64));EXCEPTION WHEN raise_exception THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Entrega sem endereço aceita';END IF;
 blocked:=false;BEGIN PERFORM public.rotisseria_cardapio_publico('confirmar',t,req||'{"modalidade":"invalida"}',gen_random_uuid(),repeat('e',64));EXCEPTION WHEN raise_exception THEN blocked:=true;END;IF NOT blocked THEN RAISE EXCEPTION 'Modalidade inválida aceita';END IF;
 IF (SELECT count(*) FROM private.rotisseria_sessoes WHERE empresa_id=e)<>3 THEN RAISE EXCEPTION 'Pedidos inválidos criaram comandas';END IF;
 IF (SELECT quantidade_estoque FROM public.produtos WHERE id=p)<>10 THEN RAISE EXCEPTION 'Movimentou estoque ao pedir';END IF;
END $test$;
