-- Pedidos digitais do Bar: opt-in, por empresa, sem mesas artificiais.
-- Não substitui funções de mesas, vendas, pagamentos ou fiscal existentes.
CREATE TABLE private.bar_cardapio_config (
 empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id),
 token text NOT NULL UNIQUE DEFAULT encode(extensions.gen_random_bytes(32),'hex'),
 ativo boolean NOT NULL DEFAULT false,
 titulo text NOT NULL DEFAULT '', descricao text NOT NULL DEFAULT '',
 cor text NOT NULL DEFAULT '#0b2a4d', fundo text NOT NULL DEFAULT '#edf0f3',
 layout text NOT NULL DEFAULT 'lista' CHECK(layout IN ('lista','grade')),
 ultimo_numero bigint NOT NULL DEFAULT 0,
 CHECK(length(titulo)<=100 AND length(descricao)<=300 AND cor ~ '^#[0-9a-fA-F]{6}$' AND fundo ~ '^#[0-9a-fA-F]{6}$')
);
CREATE TABLE private.bar_cardapio_produtos (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id),
 bar_produto_id uuid NOT NULL,
 disponivel boolean NOT NULL DEFAULT false,
 descricao text NOT NULL DEFAULT '',categoria text NOT NULL DEFAULT '',foto text NOT NULL DEFAULT '',
 PRIMARY KEY(empresa_id,bar_produto_id),
 FOREIGN KEY(empresa_id,bar_produto_id) REFERENCES public.bar_produtos(empresa_id,id),
 CHECK(length(descricao)<=500 AND length(categoria)<=80 AND length(foto)<=250000),
 CHECK(foto='' OR foto ~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$')
);
CREATE TABLE private.bar_cardapio_pedidos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 empresa_id uuid NOT NULL REFERENCES public.empresas(id), numero bigint NOT NULL,
 chave uuid NOT NULL, segredo text NOT NULL DEFAULT encode(extensions.gen_random_bytes(32),'hex'),
 dados jsonb NOT NULL, itens jsonb NOT NULL, total numeric(12,2) NOT NULL CHECK(total>0),
 estado text NOT NULL DEFAULT 'recebido' CHECK(estado IN ('recebido','preparando','pronto','saiu','finalizado','cancelado')),
 comanda_id uuid, criado_em timestamptz NOT NULL DEFAULT now(), atualizado_em timestamptz NOT NULL DEFAULT now(),
 UNIQUE(empresa_id,chave),UNIQUE(empresa_id,numero),UNIQUE(comanda_id),
 FOREIGN KEY(empresa_id,comanda_id) REFERENCES public.bar_comandas(empresa_id,id)
);
CREATE INDEX bar_cardapio_pedidos_abertos ON private.bar_cardapio_pedidos(empresa_id,criado_em DESC) WHERE estado NOT IN ('finalizado','cancelado');
CREATE INDEX bar_cardapio_pedidos_historico ON private.bar_cardapio_pedidos(empresa_id,criado_em DESC);
CREATE TABLE private.bar_cardapio_limites (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id), ip text NOT NULL, acao text NOT NULL,
 minuto timestamptz NOT NULL, quantidade int NOT NULL DEFAULT 1,
 PRIMARY KEY(empresa_id,ip,acao,minuto)
);
ALTER TABLE private.bar_cardapio_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.bar_cardapio_produtos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.bar_cardapio_pedidos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.bar_cardapio_limites ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.bar_cardapio_config,private.bar_cardapio_produtos,private.bar_cardapio_pedidos,private.bar_cardapio_limites FROM PUBLIC,anon,authenticated;
-- Só os novos atendimentos digitais são criados sem mesa. FKs de empresa permanecem.
ALTER TABLE public.bar_comandas ALTER COLUMN mesa_id DROP NOT NULL;
ALTER TABLE public.bar_pedidos ALTER COLUMN mesa_id DROP NOT NULL;

CREATE FUNCTION private.bar_cardapio_catalogo(e uuid, pagina int DEFAULT 0, busca text DEFAULT '', administrativo boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT coalesce(jsonb_agg(x.item ORDER BY x.nome,x.id),'[]'::jsonb) FROM (
 SELECT p.nome,b.id,jsonb_build_object('id',b.id,'nome',p.nome,'preco',round(p.preco_venda,2),'unidade',coalesce(p.unidade_comercial,'UN'),
 'disponivel',coalesce(m.disponivel,false),'descricao',coalesce(m.descricao,''),'categoria',coalesce(m.categoria,''),'foto',coalesce(m.foto,''),
 'grupos',coalesce((SELECT jsonb_agg(jsonb_build_object('id',g.id,'nome',g.nome,'quantidade',g.quantidade_escolhas,'opcoes',
 (SELECT coalesce(jsonb_agg(jsonb_build_object('id',p2.id,'nome',p2.nome) ORDER BY o.ordem,p2.nome),'[]'::jsonb)
 FROM public.bar_produto_grupo_opcoes o JOIN public.produtos p2 ON p2.id=o.produto_id AND p2.empresa_id=e AND p2.ativo
 JOIN public.bar_produtos b2 ON b2.produto_id=p2.id AND b2.empresa_id=e AND b2.destino_operacional<>'sem_destino'
 WHERE o.grupo_id=g.id AND o.empresa_id=e)) ORDER BY g.ordem,g.id)
 FROM public.bar_produto_grupos g WHERE g.bar_produto_id=b.id AND g.empresa_id=e),'[]'::jsonb)) item
 FROM public.bar_produtos b JOIN public.produtos p ON p.id=b.produto_id AND p.empresa_id=e
 LEFT JOIN private.bar_cardapio_produtos m ON m.empresa_id=e AND m.bar_produto_id=b.id
 WHERE b.empresa_id=e AND p.ativo AND b.ativo_cardapio AND p.preco_venda>0
 AND (administrativo OR m.disponivel) AND p.nome ILIKE '%'||left(busca,80)||'%'
 ORDER BY p.nome,b.id LIMIT 21 OFFSET greatest(0,least(pagina,10000))*20
 ) x
$$;
REVOKE ALL ON FUNCTION private.bar_cardapio_catalogo(uuid,int,text,boolean) FROM PUBLIC,anon,authenticated;

-- Validação comercial dos pedidos públicos; os preços nunca vêm do comprador.
CREATE FUNCTION private.bar_cardapio_validar(e uuid, entrada jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE i jsonb;b record;g record;es jsonb;linhas jsonb:='[]';q numeric;total numeric:=0;subtotal numeric;
BEGIN
 IF jsonb_typeof(entrada) IS DISTINCT FROM 'array' OR jsonb_array_length(entrada) NOT BETWEEN 1 AND 30 THEN RAISE EXCEPTION 'Escolha de 1 a 30 itens.';END IF;
 FOR i IN SELECT value FROM jsonb_array_elements(entrada) LOOP
  SELECT bp.*,p.nome,p.preco_venda,p.unidade_comercial INTO b FROM public.bar_produtos bp
  JOIN public.produtos p ON p.id=bp.produto_id AND p.empresa_id=e AND p.ativo
  JOIN private.bar_cardapio_produtos m ON m.empresa_id=e AND m.bar_produto_id=bp.id AND m.disponivel
  WHERE bp.id=(i->>'bar_produto_id')::uuid AND bp.empresa_id=e AND bp.ativo_cardapio AND p.preco_venda>0;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produto indisponível neste cardápio. Atualize o pedido.';END IF;
  q:=(i->>'quantidade')::numeric;
  IF q IS NULL OR q::text IN ('NaN','Infinity','-Infinity') OR q NOT BETWEEN .0001 AND 99 OR q<>round(q,4)
  OR (upper(coalesce(b.unidade_comercial,'UN')) NOT IN ('KG','G','LT','L','M') AND q<>trunc(q)) THEN RAISE EXCEPTION 'Quantidade inválida.';END IF;
  IF length(coalesce(i->>'observacao',''))>300 OR (i->>'preco')::numeric IS DISTINCT FROM round(b.preco_venda,2) THEN RAISE EXCEPTION 'O preço mudou ou a observação é muito longa. Atualize o cardápio.';END IF;
  es:=coalesce(i->'escolhas','[]'::jsonb);
  IF jsonb_typeof(es)<>'array' OR jsonb_array_length(es)>50 THEN RAISE EXCEPTION 'Escolhas inválidas.';END IF;
  FOR g IN SELECT * FROM public.bar_produto_grupos WHERE empresa_id=e AND bar_produto_id=b.id LOOP
   IF (SELECT count(*) FROM jsonb_array_elements(es) x WHERE x->>'grupo_id'=g.id::text)<>g.quantidade_escolhas THEN RAISE EXCEPTION 'Confira as escolhas de %.',g.nome;END IF;
  END LOOP;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(es) x WHERE NOT EXISTS(
   SELECT 1 FROM public.bar_produto_grupos gr JOIN public.bar_produto_grupo_opcoes op ON op.grupo_id=gr.id AND op.empresa_id=e
   JOIN public.produtos p ON p.id=op.produto_id AND p.empresa_id=e AND p.ativo
   JOIN public.bar_produtos bp ON bp.produto_id=p.id AND bp.empresa_id=e AND bp.destino_operacional<>'sem_destino'
   WHERE gr.id=(x->>'grupo_id')::uuid AND gr.empresa_id=e AND gr.bar_produto_id=b.id AND op.produto_id=(x->>'produto_id')::uuid)) THEN RAISE EXCEPTION 'Escolha indisponível neste produto.';END IF;
  subtotal:=round(q*round(b.preco_venda,2),2);IF subtotal<=0 THEN RAISE EXCEPTION 'Quantidade muito pequena.';END IF;total:=total+q*round(b.preco_venda,2);
  linhas:=linhas||jsonb_build_array(jsonb_build_object('bar_produto_id',b.id,'nome',b.nome,'quantidade',q,'preco',round(b.preco_venda,2),'subtotal',subtotal,'observacao',coalesce(i->>'observacao',''),'escolhas',es,
   'escolhas_nomes',coalesce((SELECT jsonb_agg(p.nome) FROM jsonb_array_elements(es) x JOIN public.produtos p ON p.id=(x->>'produto_id')::uuid AND p.empresa_id=e),'[]'::jsonb)));
 END LOOP;
 total:=round(total,2);
 IF total<=0 OR total>999999 THEN RAISE EXCEPTION 'Total inválido.';END IF;
 RETURN jsonb_build_object('itens',linhas,'total',total);
END $$;
REVOKE ALL ON FUNCTION private.bar_cardapio_validar(uuid,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.bar_cardapio_publico(p_acao text,p_token text,p_dados jsonb,p_chave uuid,p_ip text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c private.bar_cardapio_config;r private.bar_cardapio_pedidos;v jsonb;num bigint;hits int;
BEGIN
 IF p_token !~ '^[a-f0-9]{64}$' OR p_ip !~ '^[a-f0-9]{64}$' OR p_acao NOT IN ('catalogo','confirmar','acompanhar') OR octet_length(p_dados::text)>55000 THEN RAISE EXCEPTION 'Solicitação inválida.';END IF;
 SELECT cfg.* INTO c FROM private.bar_cardapio_config cfg JOIN public.empresas e ON e.id=cfg.empresa_id AND e.status_conta='aprovado' AND NOT e.bloqueado
 JOIN public.empresa_modulos m ON m.empresa_id=e.id AND m.modulo='bar' AND m.ativo WHERE cfg.token=p_token;
 IF NOT FOUND THEN RAISE EXCEPTION 'Cardápio indisponível.';END IF;
 INSERT INTO private.bar_cardapio_limites AS l(empresa_id,ip,acao,minuto) VALUES(c.empresa_id,p_ip,p_acao,date_trunc('minute',now()))
 ON CONFLICT(empresa_id,ip,acao,minuto) DO UPDATE SET quantidade=l.quantidade+1 RETURNING quantidade INTO hits;
 IF hits>(CASE WHEN p_acao='confirmar' THEN 10 ELSE 90 END) THEN RAISE EXCEPTION 'Muitas solicitações. Aguarde um minuto.';END IF;
 DELETE FROM private.bar_cardapio_limites WHERE empresa_id=c.empresa_id AND minuto<now()-interval '2 hours';
 IF p_acao='acompanhar' THEN
  SELECT * INTO r FROM private.bar_cardapio_pedidos WHERE empresa_id=c.empresa_id AND chave=p_chave AND segredo=p_dados->>'segredo';
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado.';END IF;
  RETURN jsonb_build_object('numero',r.numero,'estado',r.estado,'total',r.total);
 END IF;
 IF p_acao='catalogo' THEN
  IF NOT c.ativo THEN RAISE EXCEPTION 'Pedidos pelo cardápio estão pausados.';END IF;
  RETURN jsonb_build_object('nome',coalesce(nullif(c.titulo,''),(SELECT nome FROM public.empresas WHERE id=c.empresa_id)),'descricao',c.descricao,'cor',c.cor,'fundo',c.fundo,'layout',c.layout,
  'produtos',private.bar_cardapio_catalogo(c.empresa_id,coalesce((p_dados->>'pagina')::int,0),coalesce(p_dados->>'busca','')));
 END IF;
 IF p_chave IS NULL THEN RAISE EXCEPTION 'Identificador do pedido obrigatório.';END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(c.empresa_id::text||':bar:publico:'||p_chave,0));
 SELECT * INTO r FROM private.bar_cardapio_pedidos WHERE empresa_id=c.empresa_id AND chave=p_chave;
 IF FOUND THEN
  IF r.dados IS DISTINCT FROM (p_dados-'itens'-'total') THEN RAISE EXCEPTION 'Reenvio alterado.';END IF;
  -- Compara a solicitação original inteira para recuperar o mesmo pedido com segurança.
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(r.itens) WITH ORDINALITY x(item,n) FULL JOIN jsonb_array_elements(p_dados->'itens') WITH ORDINALITY y(item,n) USING(n)
   WHERE x.item->'bar_produto_id' IS DISTINCT FROM y.item->'bar_produto_id' OR x.item->'quantidade' IS DISTINCT FROM y.item->'quantidade' OR x.item->'preco' IS DISTINCT FROM y.item->'preco'
   OR coalesce(x.item->>'observacao','') IS DISTINCT FROM coalesce(y.item->>'observacao','') OR x.item->'escolhas' IS DISTINCT FROM coalesce(y.item->'escolhas','[]'::jsonb)) THEN RAISE EXCEPTION 'Reenvio alterado.';END IF;
  RETURN jsonb_build_object('numero',r.numero,'estado',r.estado,'total',r.total,'segredo',r.segredo,'repetido',true);
 END IF;
 IF NOT c.ativo THEN RAISE EXCEPTION 'Pedidos pelo cardápio estão pausados.';END IF;
 IF length(btrim(coalesce(p_dados->>'nome',''))) NOT BETWEEN 2 AND 100 OR regexp_replace(coalesce(p_dados->>'telefone',''),'[^0-9]','','g') !~ '^[1-9][0-9]{9,12}$' THEN RAISE EXCEPTION 'Informe nome e telefone com DDD.';END IF;
 IF coalesce(p_dados->>'modalidade','') NOT IN ('entrega','retirada') OR length(btrim(coalesce(p_dados->>'endereco',''))) NOT BETWEEN 5 AND 500 OR length(coalesce(p_dados->>'observacao',''))>500 THEN RAISE EXCEPTION 'Escolha entrega ou retirada e informe seu endereço completo.';END IF;
 v:=private.bar_cardapio_validar(c.empresa_id,p_dados->'itens');
 IF (p_dados->>'total')::numeric IS DISTINCT FROM (v->>'total')::numeric THEN RAISE EXCEPTION 'O total mudou. Confira seu pedido.';END IF;
 UPDATE private.bar_cardapio_config SET ultimo_numero=ultimo_numero+1 WHERE empresa_id=c.empresa_id RETURNING ultimo_numero INTO num;
 INSERT INTO private.bar_cardapio_pedidos(empresa_id,numero,chave,dados,itens,total) VALUES(c.empresa_id,num,p_chave,p_dados-'itens'-'total',v->'itens',(v->>'total')::numeric) RETURNING * INTO r;
 RETURN jsonb_build_object('numero',r.numero,'estado',r.estado,'total',r.total,'segredo',r.segredo);
END $$;
-- Bridge service_role; nenhuma sessão de funcionário é simulada no envio público.
CREATE FUNCTION public.bar_cardapio_publico(p_acao text,p_token text,p_dados jsonb DEFAULT '{}',p_chave uuid DEFAULT NULL,p_ip text DEFAULT '')
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.bar_cardapio_publico(p_acao,p_token,p_dados,p_chave,p_ip) $$;
REVOKE ALL ON FUNCTION private.bar_cardapio_publico(text,text,jsonb,uuid,text),public.bar_cardapio_publico(text,text,jsonb,uuid,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.bar_cardapio_publico(text,text,jsonb,uuid,text),public.bar_cardapio_publico(text,text,jsonb,uuid,text) TO service_role;

-- Adaptação privada do recebimento atual: só remove a dependência de mesa física.
-- A função original de pagamento permanece byte a byte intacta.
DO $migration$
DECLARE d text;
BEGIN
 d:=pg_get_functiondef('public.bar_comanda_pagar_valor(uuid,numeric,jsonb,uuid,numeric,numeric,numeric)'::regprocedure);
 IF md5(d)<>'e3701d39eedc890f8d732bcf9aef4285' THEN RAISE EXCEPTION 'Pagamento do Bar mudou. Recompare a adaptação digital antes de aplicar.';END IF;
 d:=replace(d,'public.bar_comanda_pagar_valor(','private.bar_cardapio_pagar_valor(');
 d:=replace(d,$old$  select * into v_mesa from public.bar_mesas
   where id = v_comanda.mesa_id and empresa_id = v_empresa
     for update;
  if not found then
    raise exception 'Mesa não encontrada.';
  end if;$old$,$new$  IF v_comanda.mesa_id IS NOT NULL OR NOT EXISTS(SELECT 1 FROM private.bar_cardapio_pedidos dp WHERE dp.empresa_id=v_empresa AND dp.comanda_id=p_comanda_id) THEN RAISE EXCEPTION 'Pedido digital não encontrado.';END IF;$new$);
 d:=replace(d,'perform public.bar_mesa_fechar(v_mesa.id);', 'update public.bar_comandas bc set status=''fechada'',fechada_em=now() where bc.id=p_comanda_id and bc.empresa_id=v_empresa;');
 EXECUTE d;
END $migration$;
REVOKE ALL ON FUNCTION private.bar_cardapio_pagar_valor(uuid,numeric,jsonb,uuid,numeric,numeric,numeric) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.bar_cardapio_admin(p_acao text,p_dados jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid;c private.bar_cardapio_config;r private.bar_cardapio_pedidos;v jsonb;com uuid;linhas jsonb;res record;
BEGIN
 e:=private.bar_historico_exigir(CASE WHEN p_acao IN ('config','salvar_config','produto') THEN 'bar_configurar' WHEN p_acao='finalizar' OR (p_acao='listar' AND private.perm('bar_caixa')) THEN 'bar_caixa' ELSE 'bar_pedidos' END);
 IF p_acao IN ('config','salvar_config','produto') THEN
  INSERT INTO private.bar_cardapio_config(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
  IF p_acao='salvar_config' THEN
   UPDATE private.bar_cardapio_config SET ativo=coalesce((p_dados->>'ativo')::boolean,false),titulo=btrim(coalesce(p_dados->>'titulo','')),descricao=btrim(coalesce(p_dados->>'descricao','')),cor=p_dados->>'cor',fundo=p_dados->>'fundo',layout=p_dados->>'layout' WHERE empresa_id=e;
  ELSIF p_acao='produto' THEN
   IF NOT EXISTS(SELECT 1 FROM public.bar_produtos WHERE id=(p_dados->>'id')::uuid AND empresa_id=e) THEN RAISE EXCEPTION 'Produto não encontrado.';END IF;
   INSERT INTO private.bar_cardapio_produtos(empresa_id,bar_produto_id,disponivel,descricao,categoria,foto) VALUES(e,(p_dados->>'id')::uuid,coalesce((p_dados->>'disponivel')::boolean,false),coalesce(p_dados->>'descricao',''),coalesce(p_dados->>'categoria',''),coalesce(p_dados->>'foto',''))
   ON CONFLICT(empresa_id,bar_produto_id) DO UPDATE SET disponivel=excluded.disponivel,descricao=excluded.descricao,categoria=excluded.categoria,foto=excluded.foto;
  END IF;
  SELECT * INTO c FROM private.bar_cardapio_config WHERE empresa_id=e;
  RETURN to_jsonb(c)-'empresa_id'-'ultimo_numero'||jsonb_build_object('produtos',private.bar_cardapio_catalogo(e,coalesce((p_dados->>'pagina')::int,0),coalesce(p_dados->>'busca',''),true));
 END IF;
 IF p_acao='listar' THEN
  RETURN jsonb_build_object('pedidos',coalesce((SELECT jsonb_agg(to_jsonb(x)-'segredo'-'chave'-'empresa_id') FROM (
   SELECT p.* FROM private.bar_cardapio_pedidos p WHERE p.empresa_id=e AND
   CASE WHEN coalesce((p_dados->>'historico')::boolean,false) THEN p.estado IN ('finalizado','cancelado') ELSE p.estado NOT IN ('finalizado','cancelado') END
   ORDER BY p.criado_em DESC LIMIT 51 OFFSET greatest(0,coalesce((p_dados->>'pagina')::int,0))*50)x),'[]'::jsonb));
 END IF;
 SELECT * INTO r FROM private.bar_cardapio_pedidos WHERE id=(p_dados->>'id')::uuid AND empresa_id=e FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado.';END IF;
 IF p_acao='aceitar' THEN
  IF r.estado='recebido' THEN
   v:=private.bar_cardapio_validar(e,r.itens);
   IF v->'itens' IS DISTINCT FROM r.itens THEN RAISE EXCEPTION 'O cadastro dos produtos mudou. Confira o pedido antes de aceitar.';END IF;
   INSERT INTO public.bar_comandas(empresa_id,mesa_id,criado_por) VALUES(e,NULL,auth.uid()) RETURNING id INTO com;
   UPDATE private.bar_cardapio_pedidos SET comanda_id=com WHERE id=r.id;
   SELECT jsonb_agg(jsonb_build_object('bar_produto_id',x->'bar_produto_id','quantidade',x->'quantidade','observacao',concat_ws(E'\n','Pedido '||r.numero||' · '||(r.dados->>'nome'),upper(r.dados->>'modalidade')||' · '||(r.dados->>'telefone'),'Endereço: '||(r.dados->>'endereco'),nullif(r.dados->>'observacao',''),nullif(x->>'observacao','')),'escolhas',x->'escolhas')) INTO linhas FROM jsonb_array_elements(r.itens)x;
   PERFORM public.bar_pedido_enviar(com,linhas,r.chave);
   UPDATE private.bar_cardapio_pedidos SET estado='preparando',atualizado_em=now() WHERE id=r.id;
  ELSIF r.estado IN ('cancelado','finalizado') THEN RAISE EXCEPTION 'Este pedido já foi encerrado.';
  END IF;
 ELSIF p_acao='estado' THEN
  IF NOT ((r.estado='preparando' AND p_dados->>'estado'='pronto') OR (r.estado='pronto' AND p_dados->>'estado'='saiu' AND r.dados->>'modalidade'='entrega')) THEN RAISE EXCEPTION 'Transição inválida. Atualize a lista.';END IF;
  UPDATE private.bar_cardapio_pedidos SET estado=p_dados->>'estado',atualizado_em=now() WHERE id=r.id;
 ELSIF p_acao='cancelar' THEN
  IF r.estado<>'recebido' THEN RAISE EXCEPTION 'Só pedidos ainda não aceitos podem ser recusados nesta tela.';END IF;
  UPDATE private.bar_cardapio_pedidos SET estado='cancelado',atualizado_em=now() WHERE id=r.id;
 ELSIF p_acao='finalizar' THEN
  IF r.estado='finalizado' THEN
   RETURN (SELECT jsonb_build_object('venda_id',b.venda_id,'numero_venda',v.numero_venda,'repetido',true) FROM public.bar_comandas b JOIN public.vendas v ON v.id=b.venda_id AND v.empresa_id=e WHERE b.id=r.comanda_id AND b.empresa_id=e);
  END IF;
  IF r.comanda_id IS NULL OR r.estado='cancelado' THEN RAISE EXCEPTION 'Aceite o pedido antes de finalizar.';END IF;
  IF (p_dados->>'total')::numeric IS DISTINCT FROM r.total THEN RAISE EXCEPTION 'Confira o total do pedido.';END IF;
  IF coalesce(p_dados->>'forma','') NOT IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito') THEN RAISE EXCEPTION 'Selecione a forma de pagamento.';END IF;
  v:=coalesce(p_dados->'formas',jsonb_build_array(jsonb_build_object('forma_pagamento',p_dados->>'forma','valor',r.total)));
  IF jsonb_typeof(v)<>'array' OR jsonb_array_length(v)<>1 OR v->0->>'forma_pagamento' IS DISTINCT FROM p_dados->>'forma' OR (v->0->>'valor')::numeric IS DISTINCT FROM r.total THEN RAISE EXCEPTION 'Pagamento incompatível com o total do pedido.';END IF;
  SELECT * INTO res FROM private.bar_cardapio_pagar_valor(r.comanda_id,r.total,v,r.chave,NULL,NULL,NULL);
  IF NOT res.mesa_liberada OR res.venda_id IS NULL THEN RAISE EXCEPTION 'Pedido não quitado. Confira o recebimento.';END IF;
  UPDATE private.bar_cardapio_pedidos SET estado='finalizado',atualizado_em=now() WHERE id=r.id;
  RETURN jsonb_build_object('venda_id',res.venda_id,'numero_venda',res.numero_venda);
 ELSE RAISE EXCEPTION 'Operação inválida.';END IF;
 RETURN jsonb_build_object('ok',true);
END $$;
CREATE FUNCTION public.bar_cardapio_admin(p_acao text,p_dados jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.bar_cardapio_admin(p_acao,p_dados)$$;
REVOKE ALL ON FUNCTION private.bar_cardapio_admin(text,jsonb),public.bar_cardapio_admin(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.bar_cardapio_admin(text,jsonb),public.bar_cardapio_admin(text,jsonb) TO authenticated;
