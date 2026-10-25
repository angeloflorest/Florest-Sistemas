BEGIN;
DO $guard$ BEGIN
 IF md5(replace(pg_get_functiondef('public.gastronomia_produto_salvar(uuid,uuid,text,text,boolean,jsonb,jsonb)'::regprocedure),chr(13)||chr(10),chr(10)))<>'aced1679d73cf4d480f9cd07261cb160' THEN RAISE EXCEPTION 'Base alterada: gastronomia_produto_salvar. Recompare, sem remover a guarda.'; END IF;
 IF md5(replace(pg_get_functiondef('public.gastronomia_rpc(text,jsonb,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'d06b3f2b183371c34e4f631659bca4ab' THEN RAISE EXCEPTION 'Base alterada: gastronomia_rpc. Recompare, sem remover a guarda.'; END IF;
 IF md5(replace(pg_get_functiondef('private.gastronomia_mesa_relatorio(uuid,uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'e476de1ffe2625cc24023aff2500f930' THEN RAISE EXCEPTION 'Base alterada: gastronomia_mesa_relatorio. Recompare, sem remover a guarda.'; END IF;
 IF md5(replace(pg_get_functiondef('private.gastronomia_servico_atualizar(uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'b417584bb677fd2146ac9f2ed24ce651' THEN RAISE EXCEPTION 'Base alterada: gastronomia_servico_atualizar. Recompare, sem remover a guarda.'; END IF;
 IF md5(replace(pg_get_functiondef('private.gastronomia_reimprimir(uuid,uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'395212d624cc05684d4b6855c6c63afd' THEN RAISE EXCEPTION 'Base alterada: gastronomia_reimprimir. Recompare, sem remover a guarda.'; END IF;
 IF md5(replace(pg_get_functiondef('private.gastronomia_imprimir(uuid,uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'30edbdea3151fa2d1b5540d5792db244' THEN RAISE EXCEPTION 'Base alterada: gastronomia_imprimir. Recompare, sem remover a guarda.'; END IF;
 IF md5(replace(pg_get_functiondef('private.gastronomia_resolver(jsonb,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'90f20c4887a2855262ac4e6bf7a39b8e' THEN RAISE EXCEPTION 'Base alterada: gastronomia_resolver. Recompare, sem remover a guarda.'; END IF;
 IF md5(replace(pg_get_functiondef('public.impressao_agente_jobs_reservar(uuid,text,text,integer,inet)'::regprocedure),chr(13)||chr(10),chr(10)))<>'fbec5654b530b8f152a7833bdb2ffa6e' THEN RAISE EXCEPTION 'Base de reserva de impressão alterada.'; END IF;
END $guard$;
CREATE TABLE private.gastronomia_links (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), empresa_id uuid NOT NULL REFERENCES public.empresas(id),
 mesa_id uuid, token text NOT NULL UNIQUE DEFAULT replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''), ativo boolean NOT NULL DEFAULT true,
 criado_em timestamptz NOT NULL DEFAULT now(), UNIQUE(empresa_id,id),
 FOREIGN KEY(empresa_id,mesa_id) REFERENCES public.gastronomia_mesas(empresa_id,id)
);
CREATE UNIQUE INDEX gastronomia_link_geral ON private.gastronomia_links(empresa_id) WHERE mesa_id IS NULL;
CREATE UNIQUE INDEX gastronomia_link_mesa ON private.gastronomia_links(empresa_id,mesa_id) WHERE mesa_id IS NOT NULL;
CREATE TABLE private.gastronomia_pedidos_publicos (
 empresa_id uuid NOT NULL, link_id uuid NOT NULL, chave uuid NOT NULL, dados jsonb NOT NULL,
 atendimento_id uuid NOT NULL, segredo text NOT NULL, resultado jsonb NOT NULL, criado_em timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(empresa_id,chave), FOREIGN KEY(empresa_id,link_id) REFERENCES private.gastronomia_links(empresa_id,id),
 FOREIGN KEY(empresa_id,atendimento_id) REFERENCES public.gastronomia_atendimentos(empresa_id,id)
);
CREATE TABLE private.gastronomia_whatsapp (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), empresa_id uuid NOT NULL, atendimento_id uuid NOT NULL,
 telefone text NOT NULL, mensagem text NOT NULL, estado text NOT NULL DEFAULT 'pendente'
 CHECK(estado IN ('pendente','processando','aceita_provedor','entregue','lida','falha','incerto')),
 provedor_id text, erro text, tentativas integer NOT NULL DEFAULT 0, criado_em timestamptz NOT NULL DEFAULT now(), atualizado_em timestamptz NOT NULL DEFAULT now(),
 UNIQUE(empresa_id,atendimento_id), FOREIGN KEY(empresa_id,atendimento_id) REFERENCES public.gastronomia_atendimentos(empresa_id,id)
);
ALTER TABLE private.gastronomia_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_pedidos_publicos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_whatsapp ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_links, private.gastronomia_pedidos_publicos, private.gastronomia_whatsapp FROM PUBLIC, anon, authenticated;

-- Origem real do canal público. Não atribui origem iFood a pedidos manuais.
ALTER TABLE public.gastronomia_atendimentos DROP CONSTRAINT gastronomia_atendimentos_origem_check;
ALTER TABLE public.gastronomia_atendimentos ADD CONSTRAINT gastronomia_atendimentos_origem_check CHECK(origem IN ('manual','telefone','whatsapp','site'));
-- O consumidor público não é funcionário. Não se faz impersonação de usuário do ERP.
ALTER TABLE public.gastronomia_atendimentos ALTER COLUMN criado_por DROP NOT NULL;
ALTER TABLE public.gastronomia_atendimentos ADD CONSTRAINT gastronomia_autor_publico_check CHECK(criado_por IS NOT NULL OR origem='site');
ALTER TABLE public.gastronomia_itens ALTER COLUMN criado_por DROP NOT NULL;
ALTER TABLE public.gastronomia_itens ADD CONSTRAINT gastronomia_item_autor_publico_check CHECK(criado_por IS NOT NULL OR (snapshot ? 'autor_publico' AND snapshot ? 'lote'));
ALTER TABLE public.gastronomia_eventos ALTER COLUMN autor DROP NOT NULL;
ALTER TABLE public.gastronomia_eventos ADD CONSTRAINT gastronomia_evento_autor_publico_check CHECK(autor IS NOT NULL OR tipo='cardapio_confirmar');

CREATE OR REPLACE FUNCTION private.gastronomia_whatsapp_pronto() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF NEW.tipo IN ('entrega','retirada') AND NEW.expedicao IN ('aguardando_retirada','aguardando_despacho') AND OLD.expedicao='pendente' THEN
  INSERT INTO private.gastronomia_whatsapp(empresa_id,atendimento_id,telefone,mensagem)
  VALUES(NEW.empresa_id,NEW.id,NEW.telefone,CASE WHEN NEW.tipo='retirada' THEN 'Seu pedido está pronto para retirada.' ELSE 'Seu pedido está pronto e aguardando saída para entrega.' END)
  ON CONFLICT(empresa_id,atendimento_id) DO NOTHING;
 END IF; RETURN NEW;
END $$;
CREATE TRIGGER gastronomia_whatsapp_pronto AFTER UPDATE OF expedicao ON public.gastronomia_atendimentos FOR EACH ROW EXECUTE FUNCTION private.gastronomia_whatsapp_pronto();
REVOKE ALL ON FUNCTION private.gastronomia_whatsapp_pronto() FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.gastronomia_resolver(p_itens jsonb, p_empresa uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$ DECLARE v_empresa uuid:=p_empresa; v_sem_estoque boolean; v_invalido boolean; r record; v_nome text; v_estoque numeric; v_result jsonb; BEGIN
 DROP TABLE IF EXISTS pg_temp._gas_itens_pedido,pg_temp._gas_escolhas_por_item,pg_temp._gas_baixas_por_item;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'O pedido precisa ter pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 200 then
    raise exception 'Itens demais em um único pedido (máximo 200).';
  end if;

  begin
    select exists (
      select 1 from jsonb_to_recordset(p_itens) as x(bar_produto_id uuid, quantidade numeric, observacao text, escolhas jsonb)
       where x.bar_produto_id is null or x.quantidade is null or x.quantidade <= 0
    ) into v_invalido;
  exception when others then
    v_invalido := true;
  end;
  if v_invalido then
    raise exception 'Item do pedido inválido (produto do cardápio e quantidade maior que zero são obrigatórios).';
  end if;

  select coalesce((select c.permitir_venda_sem_estoque from public.configuracoes_empresa c where c.empresa_id = v_empresa), false)
    into v_sem_estoque;

  -- Itens recebidos, na ordem enviada, já com o "instantâneo" do cardápio (preço/destino/produto
  -- núcleo) — e marcados se usam o modelo NOVO de grupos (usa_grupos = tem ao menos 1 grupo
  -- cadastrado para aquele bar_produto). Um composto sem nenhum grupo cadastrado continua sendo o
  -- modelo antigo (componentes), tratado exatamente como na Migration 016.
  create temporary table _gas_itens_pedido on commit drop as
  select x.ordem, x.bar_produto_id, round(x.quantidade, 4) as quantidade,
         nullif(btrim(coalesce(x.observacao, '')), '') as observacao, x.escolhas,
         bp.produto_id, bp.tipo, CASE WHEN bp.destino_operacional='sem_destino' THEN 'cozinha' ELSE bp.destino_operacional END destino_operacional, bp.ativo_cardapio,
         p.preco_venda, p.nome as produto_nome,
         exists (select 1 from public.bar_produto_grupos g where g.bar_produto_id = bp.id and g.empresa_id = v_empresa) as usa_grupos
    from rows from (jsonb_to_recordset(p_itens) as (bar_produto_id uuid, quantidade numeric, observacao text, escolhas jsonb))
         with ordinality as x(bar_produto_id, quantidade, observacao, escolhas, ordem)
    left join public.bar_produtos bp on bp.id = x.bar_produto_id and bp.empresa_id = v_empresa
    left join public.produtos p on p.id = bp.produto_id and p.empresa_id = v_empresa;

  if exists (select 1 from _gas_itens_pedido where produto_id is null) then
    raise exception 'Um ou mais itens do pedido não correspondem a produtos do cardápio do bar desta empresa.';
  end if;
  perform private.produtos_exigir_ativos(v_empresa, (select array_agg(ip.produto_id) from _gas_itens_pedido ip));   -- [046:bar_enviar_item]
  if exists (select 1 from _gas_itens_pedido where ativo_cardapio = false) then
    raise exception 'Um ou mais itens do pedido estão desativados no cardápio do bar.';
  end if;

  -- Valida e resolve as ESCOLHAS de cada item composto do modelo novo (requisitos #4/#5/#6):
  -- confere que a quantidade de escolhas bate com o configurado por grupo, que cada produto
  -- escolhido é opção válida daquele grupo, e BLOQUEIA o pedido inteiro se qualquer produto físico
  -- escolhido ainda estiver com destino "Não definido" (nunca lança "escondido" no destino errado).
  create temporary table _gas_escolhas_por_item (
    ordem integer, grupo_id uuid, grupo_nome text, produto_id uuid, produto_nome text,
    destino_operacional text, quantidade numeric(12,4)
  ) on commit drop;

  for r in select * from _gas_itens_pedido where tipo = 'composto' and usa_grupos loop
    IF r.escolhas IS NULL OR jsonb_typeof(r.escolhas)<>'array' THEN r.escolhas:='[]'::jsonb; END IF;
    IF EXISTS(SELECT 1 FROM public.bar_produto_grupos g WHERE g.bar_produto_id=r.bar_produto_id AND g.empresa_id=v_empresa AND (SELECT count(*) FROM jsonb_to_recordset(r.escolhas) e(grupo_id uuid,produto_id uuid) WHERE e.grupo_id=g.id) NOT BETWEEN coalesce((SELECT opcoes#>>ARRAY['cardapio','regras_grupos',g.id::text,'minimo'] FROM public.gastronomia_configuracoes WHERE empresa_id=v_empresa)::int,g.quantidade_escolhas) AND coalesce((SELECT opcoes#>>ARRAY['cardapio','regras_grupos',g.id::text,'maximo'] FROM public.gastronomia_configuracoes WHERE empresa_id=v_empresa)::int,g.quantidade_escolhas)) THEN RAISE EXCEPTION 'Preencha as escolhas obrigatórias e respeite os limites dos grupos de %.',r.produto_nome; END IF;
    if exists (
      select 1 from jsonb_to_recordset(r.escolhas) as e(grupo_id uuid, produto_id uuid)
       where not exists (
               select 1 from public.bar_produto_grupos g where g.id = e.grupo_id and g.bar_produto_id = r.bar_produto_id and g.empresa_id = v_empresa
             )
          or not exists (
               select 1 from public.bar_produto_grupo_opcoes o
                where o.grupo_id = e.grupo_id and o.produto_id = e.produto_id and o.empresa_id = v_empresa
             )
    ) then
      raise exception 'O item "%" tem uma escolha inválida (grupo ou produto não configurado para este item).', r.produto_nome;
    end if;

    insert into _gas_escolhas_por_item (ordem, grupo_id, grupo_nome, produto_id, produto_nome, destino_operacional, quantidade)
    select r.ordem, e.grupo_id, g.nome, e.produto_id, pr.nome, CASE WHEN bpe.destino_operacional='sem_destino' THEN 'cozinha' ELSE bpe.destino_operacional END,
           (r.quantidade * count(*))::numeric(12,4) as quantidade
      from jsonb_to_recordset(r.escolhas) as e(grupo_id uuid, produto_id uuid)
      join public.bar_produto_grupos g on g.id = e.grupo_id and g.empresa_id = v_empresa
      join public.produtos pr on pr.id = e.produto_id and pr.empresa_id = v_empresa
      join public.bar_produtos bpe on bpe.produto_id = e.produto_id and bpe.empresa_id = v_empresa
     group by r.ordem, e.grupo_id, e.produto_id, g.nome, pr.nome, bpe.destino_operacional;
  end loop;

  -- Baixa de estoque POR ITEM: simples (o próprio produto); composto modelo ANTIGO (componentes
  -- marcados baixar_estoque, idêntico à Migration 016); composto modelo NOVO (exatamente os
  -- produtos físicos escolhidos, já resolvidos acima em _gas_escolhas_por_item).
  create temporary table _gas_baixas_por_item on commit drop as
  select ip.ordem, ip.produto_id as produto_baixa_id, ip.quantidade as quantidade
    from _gas_itens_pedido ip
   where ip.tipo = 'simples'
  union all
  select ip.ordem, c.componente_produto_id as produto_baixa_id, (ip.quantidade * c.quantidade)::numeric as quantidade
    from _gas_itens_pedido ip
    join public.bar_produtos_componentes c on c.bar_produto_id = ip.bar_produto_id and c.empresa_id = v_empresa
   where ip.tipo = 'composto' and ip.usa_grupos = false and c.baixar_estoque = true
  union all
  select e.ordem, e.produto_id as produto_baixa_id, e.quantidade
    from _gas_escolhas_por_item e;

  -- Trava e baixa o estoque núcleo, um produto por vez, em ordem fixa (evita deadlock), pelo TOTAL
  -- agregado deste pedido — mesmo padrão de public.registrar_venda e da Migration 016.
  for r in
    select produto_baixa_id as produto_id, sum(quantidade) as qtd
      from _gas_baixas_por_item
     group by produto_baixa_id
     order by produto_baixa_id
  loop
    select p.nome, p.quantidade_estoque into v_nome, v_estoque
      from public.produtos p
     where p.id = r.produto_id and p.empresa_id = v_empresa
       for update;
    if not found then
      raise exception 'Produto do núcleo não encontrado para baixa de estoque.';
    end if;
    perform private.produto_exigir_ativo(v_empresa, r.produto_id);   -- [046:bar_enviar_baixa]
    if v_estoque < r.qtd and not v_sem_estoque then
      raise exception 'Estoque insuficiente para "%": disponível %, necessário %.', v_nome, v_estoque, r.qtd;
    end if;
    update public.produtos set quantidade_estoque = quantidade_estoque - r.qtd
     where id = r.produto_id and empresa_id = v_empresa;
  end loop;


 SELECT jsonb_agg(to_jsonb(i)||jsonb_build_object('baixas',coalesce((select jsonb_agg(to_jsonb(b)) from _gas_baixas_por_item b where b.ordem=i.ordem),'[]'::jsonb),'escolhas_resolvidas',coalesce((select jsonb_agg(to_jsonb(e)) from _gas_escolhas_por_item e where e.ordem=i.ordem),'[]'::jsonb)) ORDER BY i.ordem) INTO v_result FROM _gas_itens_pedido i; RETURN v_result; END $function$
;
CREATE OR REPLACE FUNCTION public.gastronomia_cardapio_admin(p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_configurar'); c jsonb; d jsonb:=coalesce(p_dados,'{}'); r record; b uuid; g jsonb; regras jsonb:='{}'; impressora uuid;
BEGIN
 INSERT INTO public.gastronomia_configuracoes(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
 PERFORM 1 FROM public.gastronomia_configuracoes WHERE empresa_id=e FOR UPDATE;
 SELECT coalesce(opcoes->'cardapio','{}') INTO c FROM public.gastronomia_configuracoes WHERE empresa_id=e;
 IF p_acao='obter' THEN
  RETURN jsonb_build_object('config',c,'links',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',l.id,'mesa_id',l.mesa_id,'mesa_numero',m.numero,'token',l.token,'ativo',l.ativo)),'[]') FROM private.gastronomia_links l LEFT JOIN public.gastronomia_mesas m ON m.id=l.mesa_id AND m.empresa_id=e WHERE l.empresa_id=e),'impressoras',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',i.id,'nome',i.nome)),'[]') FROM public.impressoras i WHERE i.empresa_id=e AND i.ativa));
 ELSIF p_acao='salvar' THEN
  IF jsonb_typeof(d->'categorias')<>'array' OR jsonb_array_length(d->'categorias')>100 OR jsonb_typeof(d->'produtos')<>'array' OR jsonb_array_length(d->'produtos')>1500 OR octet_length(d::text)>180000 THEN RAISE EXCEPTION 'Cardápio excede os limites ou tem formato inválido.'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_to_recordset(d->'categorias') x(id text,nome text,pai text) WHERE x.id IS NULL OR length(x.nome) NOT BETWEEN 1 AND 80 OR x.pai=x.id OR (x.pai IS NOT NULL AND NOT EXISTS(SELECT 1 FROM jsonb_to_recordset(d->'categorias') p(id text,pai text) WHERE p.id=x.pai AND p.pai IS NULL))) OR EXISTS(SELECT 1 FROM jsonb_to_recordset(d->'categorias') x(id text) GROUP BY id HAVING count(*)>1) THEN RAISE EXCEPTION 'Categorias inválidas: use apenas categoria e subcategoria, sem duplicação.'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_to_recordset(d->'produtos') x(id uuid,categoria text,foto text) WHERE NOT EXISTS(SELECT 1 FROM public.produtos p WHERE p.id=x.id AND p.empresa_id=e AND p.ativo) OR (x.categoria IS NOT NULL AND NOT EXISTS(SELECT 1 FROM jsonb_to_recordset(d->'categorias') c(id text) WHERE c.id=x.categoria)) OR length(coalesce(x.foto,''))>2000 OR (coalesce(x.foto,'')<>'' AND x.foto !~ '^https://[^[:space:]]+$')) OR EXISTS(SELECT 1 FROM jsonb_to_recordset(d->'produtos') x(id uuid) GROUP BY id HAVING count(*)>1) THEN RAISE EXCEPTION 'Produto, categoria ou foto inválidos para esta empresa.'; END IF;
  impressora:=(d->>'impressora_id')::uuid;
  IF impressora IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.impressoras WHERE empresa_id=e AND id=impressora AND ativa) THEN RAISE EXCEPTION 'Impressora de outra empresa ou inativa.'; END IF;
  c:=jsonb_build_object('ativo',coalesce((d->>'ativo')::boolean,false),'categorias',d->'categorias','produtos',d->'produtos','impressora_id',impressora,'regras_grupos',coalesce(c->'regras_grupos','{}'));
  UPDATE public.gastronomia_configuracoes SET opcoes=jsonb_set(opcoes,'{cardapio}',c) WHERE empresa_id=e;
 ELSIF p_acao='links' THEN
  INSERT INTO private.gastronomia_links(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
  INSERT INTO private.gastronomia_links(empresa_id,mesa_id) SELECT e,id FROM public.gastronomia_mesas WHERE empresa_id=e AND ativa ON CONFLICT DO NOTHING;
 ELSIF p_acao='composicao' THEN
  -- Reutiliza o cadastro existente. Destino operacional preservado, sem seletor por produto.
  SELECT * INTO r FROM public.bar_produtos WHERE produto_id=(d->>'produto_id')::uuid AND empresa_id=e FOR UPDATE;
  b:=public.gastronomia_produto_salvar(r.id,(d->>'produto_id')::uuid,d->>'tipo',coalesce(r.destino_operacional,'cozinha'),coalesce(r.ativo_cardapio,true),nullif(d->'componentes','null'::jsonb),nullif(d->'grupos','null'::jsonb));
  FOR g IN SELECT value FROM jsonb_array_elements(coalesce(nullif(d->'grupos','null'::jsonb),'[]')) LOOP
   IF coalesce((g->>'minimo')::int,(g->>'quantidade_escolhas')::int,1)<0 OR coalesce((g->>'minimo')::int,(g->>'quantidade_escolhas')::int,1)>coalesce((g->>'maximo')::int,(g->>'quantidade_escolhas')::int,1) OR coalesce((g->>'maximo')::int,(g->>'quantidade_escolhas')::int,1)>20 THEN RAISE EXCEPTION 'Limites de escolha inválidos.'; END IF;
   SELECT id INTO impressora FROM public.bar_produto_grupos WHERE empresa_id=e AND bar_produto_id=b AND nome=btrim(g->>'nome');
   regras:=regras||jsonb_build_object(impressora::text,jsonb_build_object('minimo',coalesce((g->>'minimo')::int,(g->>'quantidade_escolhas')::int,1),'maximo',coalesce((g->>'maximo')::int,(g->>'quantidade_escolhas')::int,1)));
  END LOOP;
  UPDATE public.gastronomia_configuracoes SET opcoes=jsonb_set(opcoes,'{cardapio}',c||jsonb_build_object('regras_grupos',coalesce(c->'regras_grupos','{}')||regras)) WHERE empresa_id=e;
 ELSE RAISE EXCEPTION 'Ação de configuração inválida.'; END IF;
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
 RETURN public.gastronomia_cardapio_admin('obter');
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_cardapio_admin(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_cardapio_admin(text,jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION private.gastronomia_duas_vias(p_id uuid,p_e uuid,p_lote uuid,p_reimpressao boolean) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE a public.gastronomia_atendimentos; itens jsonb; emp text; via text; job uuid;
BEGIN
 SELECT * INTO a FROM public.gastronomia_atendimentos WHERE id=p_id AND empresa_id=p_e;
 SELECT nome INTO emp FROM public.empresas WHERE id=p_e;
 SELECT jsonb_agg(jsonb_build_object('nome',i.snapshot->>'produto_nome','quantidade',i.quantidade,'preco_unitario',i.preco_unitario,'subtotal',round(i.quantidade*i.preco_unitario,2),'observacao',i.snapshot->>'observacao','filhos',(SELECT coalesce(jsonb_agg(jsonb_build_object('nome',c->>'produto_nome','quantidade',c->'quantidade','grupo',c->>'grupo_nome')),'[]') FROM jsonb_array_elements(i.snapshot->'escolhas_resolvidas') c)) ORDER BY i.criado_em,i.id) INTO itens FROM public.gastronomia_itens i WHERE i.empresa_id=p_e AND i.atendimento_id=p_id AND NOT i.cancelado AND (p_reimpressao OR i.snapshot->>'lote'=p_lote::text);
 IF itens IS NULL THEN RETURN; END IF;
 FOREACH via IN ARRAY ARRAY['COZINHA','CONFERÊNCIA CAIXA'] LOOP
  job:=private.impressao_job_criar(p_e,'caixa','pedido_bar','gastronomia:duas:'||p_lote||':'||via,(CASE WHEN p_reimpressao THEN 'REIMPRESSÃO · ' ELSE '' END)||via||' #'||a.numero,
   jsonb_build_object('gastronomia_atendimento_id',p_id,'gastronomia_impressora_propria',true,'versao',1,'tipo','pedido_bar','empresa',emp||' — '||upper(a.tipo)||' #'||a.numero,'setor',(CASE WHEN p_reimpressao THEN 'REIMPRESSÃO · ' ELSE '' END)||via,'mesa',(SELECT numero FROM public.gastronomia_mesas WHERE empresa_id=p_e AND id=a.mesa_id),'data_hora',to_char(now() AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),'itens',itens||jsonb_build_array(jsonb_build_object('nome',concat_ws(' · ',a.cliente_nome,a.telefone,a.endereco,a.referencia)),jsonb_build_object('nome','PEDIDO NÃO FISCAL — pagamento somente após confirmação do caixa'))),auth.uid());
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_duas_vias(uuid,uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION private.gastronomia_imprimir(p_id uuid,p_e uuid,p_lote uuid) RETURNS void LANGUAGE sql SET search_path='' AS $$ SELECT private.gastronomia_duas_vias(p_id,p_e,p_lote,false) $$;
CREATE OR REPLACE FUNCTION private.gastronomia_reimprimir(p_id uuid,p_e uuid,p_lote uuid) RETURNS void LANGUAGE sql SET search_path='' AS $$ SELECT private.gastronomia_duas_vias(p_id,p_e,p_lote,true) $$;
CREATE OR REPLACE FUNCTION private.gastronomia_impressao_estado(p_id uuid,p_e uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
SELECT jsonb_build_object('situacao',CASE WHEN count(*)=0 THEN 'aguardando' WHEN bool_or(j.status IN ('falhou','cancelado')) THEN 'falha' WHEN bool_and(j.status='impresso') THEN 'confirmada_agente' ELSE 'enviada' END,'jobs',coalesce(jsonb_agg(jsonb_build_object('id',j.id,'via',j.payload->>'setor','status',j.status,'erro',j.erro_mensagem,'confirmado_em',j.impresso_em) ORDER BY j.criado_em),'[]')) FROM public.impressao_jobs j WHERE j.empresa_id=p_e AND j.payload->>'gastronomia_atendimento_id'=p_id::text;
$$;

CREATE OR REPLACE FUNCTION public.impressao_agente_jobs_reservar(p_agente_id uuid, p_credencial_hash text, p_instalacao text, p_limite integer DEFAULT 3, p_ip inet DEFAULT NULL::inet)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_v      record;
  v_lim    integer := least(greatest(coalesce(p_limite, 3), 1), private.impressao_job_param('lote_max'));
  v_jobs   jsonb;
  v_lease  integer := private.impressao_job_param('reserva_segundos');
begin
  select * into v_v from private.impressao_agente_validar(p_agente_id, p_credencial_hash, p_instalacao, p_ip, false);
  if not v_v.r_ok then
    return jsonb_build_object('ok', false, 'erro', v_v.r_erro);
  end if;

  perform private.impressao_job_reciclar(v_v.r_empresa_id);

  with candidatos as (
    select j.id, a.impressora_id
      from public.impressao_jobs j
      join lateral (
        SELECT j.empresa_id, (c.opcoes#>>'{cardapio,impressora_id}')::uuid impressora_id FROM public.gastronomia_configuracoes c WHERE c.empresa_id=j.empresa_id AND j.payload->>'gastronomia_impressora_propria'='true' AND j.payload ? 'gastronomia_atendimento_id'
        UNION ALL
        SELECT m.empresa_id,m.impressora_id FROM public.impressao_destino_impressora m WHERE m.empresa_id=j.empresa_id AND m.destino_codigo=j.destino_codigo AND NOT (coalesce(j.payload->>'gastronomia_impressora_propria','false')='true' AND j.payload ? 'gastronomia_atendimento_id')
      ) a ON true
      join public.impressoras i
        on i.empresa_id = a.empresa_id and i.id = a.impressora_id
     where j.empresa_id = v_v.r_empresa_id          -- empresa do AGENTE (do banco), nunca do cliente
       and i.estacao_id = v_v.r_estacao_id          -- só impressoras da estação deste agente
       and j.status = 'pendente'
       and j.proxima_tentativa_em <= now()
       and j.expira_em > now()
       and j.tentativas < j.max_tentativas
     order by j.criado_em, j.id
     limit v_lim
       for update of j skip locked
  ),
  reservados as (
    update public.impressao_jobs j
       set status = 'processando',
           tentativas = j.tentativas + 1,
           agente_id = v_v.r_agente_id,
           estacao_id = v_v.r_estacao_id,
           impressora_id = c.impressora_id,
           reservado_em = now(),
           reserva_expira_em = now() + make_interval(secs => v_lease)
      from candidatos c
     where j.id = c.id and j.empresa_id = v_v.r_empresa_id
    returning j.*
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id',               r.id,
             'destino',          r.destino_codigo,
             'tipo',             r.tipo,
             'titulo',           r.titulo,
             'tentativa',        r.tentativas,
             'max_tentativas',   r.max_tentativas,
             'criado_em',        r.criado_em,
             'reserva_segundos', v_lease,
             'payload',          r.payload,
             'impressora', jsonb_build_object(
                'id',            i.id,
                'nome',          i.nome,
                'identificador', i.identificador_agente,
                'conexao',       i.conexao,
                'porta_windows', i.porta_windows)
           ) order by r.criado_em, r.id), '[]'::jsonb)
    into v_jobs
    from reservados r
    join public.impressoras i on i.empresa_id = r.empresa_id and i.id = r.impressora_id;

  return jsonb_build_object('ok', true, 'jobs', v_jobs, 'hora_servidor', now());
end;
$function$

;
CREATE OR REPLACE FUNCTION private.gastronomia_mesa_relatorio(p_id uuid, p_empresa uuid, p_chave uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE a public.gastronomia_atendimentos; f jsonb; itens jsonb; pagamentos jsonb; versao text; estacao uuid; numero integer; job uuid; nome text; linha record; BEGIN
 SELECT * INTO a FROM public.gastronomia_atendimentos WHERE id=p_id AND empresa_id=p_empresa;
 IF a.id IS NULL OR a.tipo<>'mesa' THEN RAISE EXCEPTION 'Atendimento de mesa não encontrado.'; END IF;
 SELECT m.numero INTO numero FROM public.gastronomia_mesas m WHERE m.id=a.mesa_id AND m.empresa_id=p_empresa;
 SELECT e.nome INTO nome FROM public.empresas e WHERE e.id=p_empresa;
 SELECT i.estacao_id INTO estacao FROM public.gastronomia_configuracoes c JOIN public.impressoras i ON i.id=(c.opcoes#>>'{cardapio,impressora_id}')::uuid AND i.empresa_id=p_empresa WHERE c.empresa_id=p_empresa;
 IF estacao IS NULL THEN RAISE EXCEPTION 'Configure a impressora do destino Caixa para imprimir o relatório da mesa.'; END IF;
 SELECT coalesce((SELECT ag.versao_agente FROM public.impressao_agentes ag WHERE ag.empresa_id=p_empresa AND ag.estacao_id=estacao AND ag.status='ativo' ORDER BY ag.ultimo_contato_em DESC NULLS LAST LIMIT 1),(SELECT s.versao_agente FROM public.impressao_estacoes s WHERE s.empresa_id=p_empresa AND s.id=estacao)) INTO versao;
 IF NOT private.impressao_versao_ge(versao,'1.2.0') THEN RAISE EXCEPTION 'O relatório exige Florest Print Agent 1.2.0 ou superior no Caixa.'; END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('nome',i.snapshot->>'produto_nome','quantidade',i.quantidade,'preco_unitario',i.preco_unitario,'subtotal',round(i.quantidade*i.preco_unitario,2),'observacao',i.snapshot->>'observacao','filhos',(SELECT coalesce(jsonb_agg(jsonb_build_object('nome',c->>'produto_nome','quantidade',c->'quantidade','grupo',c->>'grupo_nome')),'[]') FROM jsonb_array_elements(i.snapshot->'escolhas_resolvidas') c)) ORDER BY i.criado_em,i.id),'[]') INTO itens FROM public.gastronomia_itens i WHERE i.empresa_id=p_empresa AND i.atendimento_id=p_id AND NOT i.cancelado;
 IF jsonb_array_length(itens)=0 THEN RAISE EXCEPTION 'A mesa ainda não tem consumo para imprimir.'; END IF;
 f:=private.gastronomia_financeiro_detalhe(p_id,p_empresa);
 -- Linhas informativas só do papel, sem quantidade ou preço; não são produtos nem lançamentos.
 IF f#>>'{servico,regra}'='percentual_v1' THEN itens:=itens||jsonb_build_array(jsonb_build_object('nome','Regra de serviço: '||replace(trim_scale((f#>>'{servico,percentual}')::numeric)::text,'.',',')||'% sobre R$ '||replace(to_char((f#>>'{servico,base}')::numeric,'FM999999999990.00'),'.',',')));
 ELSE itens:=itens||jsonb_build_array(jsonb_build_object('nome','Serviço: ajuste legado em reais')); END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('forma',p.forma,'valor',p.valor) ORDER BY p.criado_em),'[]') INTO pagamentos FROM public.gastronomia_pagamentos p WHERE p.empresa_id=p_empresa AND p.atendimento_id=p_id AND NOT p.estornado;
 FOR linha IN SELECT p.forma,p.valor FROM public.gastronomia_pagamentos p WHERE p.empresa_id=p_empresa AND p.atendimento_id=p_id AND NOT p.estornado ORDER BY p.criado_em LOOP
  itens:=itens||jsonb_build_array(jsonb_build_object('nome','Recebido: '||linha.forma||' — R$ '||replace(to_char(linha.valor,'FM999999999990.00'),'.',',')));
 END LOOP;
 IF jsonb_array_length(itens)>200 THEN RAISE EXCEPTION 'O relatório excedeu o limite de 200 linhas do Print Agent.'; END IF;
 job:=private.impressao_job_criar(p_empresa,'caixa','relatorio_mesa','gastronomia:relatorio_mesa:'||p_chave,'Relatório da Mesa '||numero,jsonb_build_object('versao',1,'tipo','relatorio_mesa','empresa',nome,'setor','CAIXA','mesa',numero,'data_hora',to_char(now() AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),'itens',itens,'subtotal',f->'subtotal','desconto',f->'desconto','acrescimo',f->'acrescimo','taxa_servico',f#>'{servico,valor}','total',f->'total','ja_pago',f->'recebido','falta_pagar',f->'saldo','pagamentos',pagamentos,'gastronomia_atendimento_id',p_id,'gastronomia_impressora_propria',true),auth.uid());
 RETURN jsonb_build_object('ok',true,'job_id',job,'mesa_numero',numero,'tipo','relatorio_mesa');
END $function$
;
-- Somente a Edge Function usa esta API. anon/authenticated não executam diretamente.
CREATE OR REPLACE FUNCTION public.gastronomia_cardapio_publico(p_acao text,p_token text,p_dados jsonb DEFAULT '{}',p_chave uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l private.gastronomia_links; cfg public.gastronomia_configuracoes; c jsonb; d jsonb:=coalesce(p_dados,'{}'); pedido private.gastronomia_pedidos_publicos; a public.gastronomia_atendimentos; r jsonb; x jsonb; iid uuid; mid uuid; n int; segredo text; setores text[]; setor text; emp text; esperado numeric;
BEGIN
 IF length(coalesce(p_token,''))<>64 OR octet_length(d::text)>50000 THEN RAISE EXCEPTION 'Link ou solicitação inválida.' USING ERRCODE='42501'; END IF;
 SELECT * INTO l FROM private.gastronomia_links WHERE token=p_token AND ativo;
 IF l.id IS NULL OR NOT EXISTS(SELECT 1 FROM public.empresas e JOIN public.empresa_modulos m ON m.empresa_id=e.id WHERE e.id=l.empresa_id AND e.status_conta='aprovado' AND NOT e.bloqueado AND m.modulo='gastronomia' AND m.ativo) THEN RAISE EXCEPTION 'Cardápio indisponível.' USING ERRCODE='42501'; END IF;
 SELECT * INTO cfg FROM public.gastronomia_configuracoes WHERE empresa_id=l.empresa_id; c:=cfg.opcoes->'cardapio';
 IF NOT coalesce((c->>'ativo')::boolean,false) THEN RAISE EXCEPTION 'Cardápio indisponível.'; END IF;
 IF l.mesa_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.gastronomia_mesas WHERE id=l.mesa_id AND empresa_id=l.empresa_id AND ativa) THEN RAISE EXCEPTION 'Mesa indisponível.'; END IF;
 SELECT nome INTO emp FROM public.empresas WHERE id=l.empresa_id;
 IF p_acao='catalogo' THEN
  RETURN jsonb_build_object('nome',emp,'mesa',CASE WHEN l.mesa_id IS NOT NULL THEN (SELECT numero FROM public.gastronomia_mesas WHERE id=l.mesa_id AND empresa_id=l.empresa_id) END,'categorias',coalesce(c->'categorias','[]'),'taxa_entrega',cfg.taxa_entrega,'servico_percentual',coalesce((SELECT CASE WHEN g.servico_regra='percentual_v1' THEN g.servico_percentual ELSE 0 END FROM public.gastronomia_atendimentos g WHERE g.empresa_id=l.empresa_id AND g.mesa_id=l.mesa_id AND g.estado='aberto'),(cfg.opcoes->>'servico_percentual')::numeric,0),'entrega',coalesce((cfg.opcoes->>'entrega')::boolean,true),'retirada',coalesce((cfg.opcoes->>'retirada')::boolean,true),'produtos',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',bp.id,'produto_id',p.id,'nome',p.nome,'preco',p.preco_venda,'categoria',m->>'categoria','foto',m->>'foto','ordem',m->'ordem','grupos',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',g.id,'nome',g.nome,'minimo',coalesce((c#>>ARRAY['regras_grupos',g.id::text,'minimo'])::int,g.quantidade_escolhas),'maximo',coalesce((c#>>ARRAY['regras_grupos',g.id::text,'maximo'])::int,g.quantidade_escolhas),'opcoes',(SELECT coalesce(jsonb_agg(jsonb_build_object('produto_id',p2.id,'nome',p2.nome) ORDER BY o.ordem),'[]') FROM public.bar_produto_grupo_opcoes o JOIN public.produtos p2 ON p2.id=o.produto_id AND p2.empresa_id=l.empresa_id WHERE o.grupo_id=g.id AND o.empresa_id=l.empresa_id AND p2.ativo AND (p2.quantidade_estoque>0 OR coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=l.empresa_id),false)))) ORDER BY g.ordem),'[]') FROM public.bar_produto_grupos g WHERE g.bar_produto_id=bp.id AND g.empresa_id=l.empresa_id)) ORDER BY coalesce((m->>'ordem')::int,0),p.nome),'[]') FROM jsonb_array_elements(coalesce(c->'produtos','[]')) m JOIN public.produtos p ON p.id=(m->>'id')::uuid AND p.empresa_id=l.empresa_id JOIN public.bar_produtos bp ON bp.produto_id=p.id AND bp.empresa_id=l.empresa_id WHERE coalesce((m->>'ativo')::boolean,true) AND p.ativo AND bp.ativo_cardapio));
 ELSIF p_acao='acompanhar' THEN
  SELECT * INTO pedido FROM private.gastronomia_pedidos_publicos pp WHERE pp.empresa_id=l.empresa_id AND pp.link_id=l.id AND pp.chave=p_chave AND pp.segredo=d->>'segredo';
  IF NOT FOUND THEN RAISE EXCEPTION 'Pedido não encontrado.' USING ERRCODE='42501'; END IF;
  SELECT * INTO a FROM public.gastronomia_atendimentos WHERE id=pedido.atendimento_id AND empresa_id=l.empresa_id;
  RETURN pedido.resultado||jsonb_build_object('estado',a.estado,'andamento',a.expedicao,'total_pedido',pedido.resultado->'total','pagamento_confirmado',CASE WHEN a.tipo='mesa' THEN NULL ELSE private.gastronomia_pago(a.id,l.empresa_id)>=private.gastronomia_total(a.id,l.empresa_id) END);
 ELSIF p_acao<>'confirmar' THEN RAISE EXCEPTION 'Ação pública inválida.'; END IF;
 IF p_chave IS NULL THEN RAISE EXCEPTION 'Identificador obrigatório.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(l.empresa_id::text||':cardapio:'||p_chave,0));
 SELECT * INTO pedido FROM private.gastronomia_pedidos_publicos WHERE empresa_id=l.empresa_id AND chave=p_chave;
 IF FOUND THEN IF pedido.link_id<>l.id OR pedido.dados<>d THEN RAISE EXCEPTION 'Identificador já utilizado com outro pedido.'; END IF; RETURN pedido.resultado; END IF;
 IF (SELECT count(*) FROM private.gastronomia_pedidos_publicos WHERE link_id=l.id AND criado_em>now()-interval '1 minute')>=30 THEN RAISE EXCEPTION 'Muitos pedidos. Aguarde um minuto.'; END IF;
 IF jsonb_typeof(d->'itens')<>'array' OR jsonb_array_length(d->'itens') NOT BETWEEN 1 AND 50 OR EXISTS(SELECT 1 FROM jsonb_to_recordset(d->'itens') z(bar_produto_id uuid,quantidade numeric) WHERE z.quantidade IS NULL OR z.quantidade<=0 OR z.quantidade>100 OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(c->'produtos') m JOIN public.bar_produtos bp ON bp.produto_id=(m->>'id')::uuid AND bp.empresa_id=l.empresa_id WHERE bp.id=z.bar_produto_id AND coalesce((m->>'ativo')::boolean,true))) THEN RAISE EXCEPTION 'Produtos ou quantidades inválidos para este cardápio.'; END IF;
 IF d->>'forma' IS NULL OR d->>'forma' NOT IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito') THEN RAISE EXCEPTION 'Escolha a forma de pagamento.'; END IF;
 IF length(btrim(coalesce(d->>'nome','')))<2 OR length(coalesce(d->>'nome',''))>160 OR regexp_replace(coalesce(d->>'telefone',''),'\D','','g') !~ '^[0-9]{10,13}$' THEN RAISE EXCEPTION 'Informe nome e telefone válidos.'; END IF;
 IF l.mesa_id IS NULL THEN
  IF d->>'tipo' IS NULL OR d->>'tipo' NOT IN ('entrega','retirada') OR NOT coalesce((cfg.opcoes->>(d->>'tipo'))::boolean,true) THEN RAISE EXCEPTION 'Modalidade indisponível.'; END IF;
  IF d->>'tipo'='entrega' AND (length(btrim(coalesce(d->>'endereco','')))<8 OR length(d->>'endereco')>500) THEN RAISE EXCEPTION 'Informe o endereço completo.'; END IF;
 ELSE
  SELECT numero INTO n FROM public.gastronomia_mesas WHERE id=l.mesa_id AND empresa_id=l.empresa_id AND ativa FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(l.empresa_id::text||':mesa-fisica:'||n,0));
  IF EXISTS(SELECT 1 FROM public.bar_mesas WHERE empresa_id=l.empresa_id AND numero=n AND status='ocupada') THEN RAISE EXCEPTION 'Mesa ocupada em outra operação. Chame o atendimento.'; END IF;
  SELECT * INTO a FROM public.gastronomia_atendimentos WHERE empresa_id=l.empresa_id AND mesa_id=l.mesa_id AND estado='aberto' FOR UPDATE;
  IF a.venda_id IS NOT NULL OR (a.id IS NOT NULL AND private.gastronomia_pago(a.id,l.empresa_id)>0) THEN RAISE EXCEPTION 'Mesa em fechamento. Solicite atendimento.'; END IF;
 END IF;
 IF a.id IS NULL THEN
  UPDATE public.gastronomia_configuracoes SET ultimo_numero=ultimo_numero+1 WHERE empresa_id=l.empresa_id RETURNING ultimo_numero INTO n;
  INSERT INTO public.gastronomia_atendimentos(empresa_id,numero,tipo,origem,mesa_id,cliente_nome,telefone,endereco,referencia,taxa_entrega,servico_regra,servico_percentual)
  VALUES(l.empresa_id,n,CASE WHEN l.mesa_id IS NULL THEN d->>'tipo' ELSE 'mesa' END,'site',l.mesa_id,btrim(d->>'nome'),d->>'telefone',left(d->>'endereco',500),left(d->>'referencia',300),CASE WHEN l.mesa_id IS NULL AND d->>'tipo'='entrega' THEN cfg.taxa_entrega ELSE 0 END,'percentual_v1',coalesce((cfg.opcoes->>'servico_percentual')::numeric,0)) RETURNING * INTO a;
 END IF;
 -- Trava os produtos antes de conferir preço e baixar, evitando troca de preço simultânea.
 PERFORM p.id FROM public.produtos p JOIN public.bar_produtos bp ON bp.produto_id=p.id AND bp.empresa_id=l.empresa_id WHERE p.empresa_id=l.empresa_id AND bp.id IN (SELECT (z->>'bar_produto_id')::uuid FROM jsonb_array_elements(d->'itens') z) ORDER BY p.id FOR UPDATE OF p;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(d->'itens') z(bar_produto_id uuid,preco numeric) JOIN public.bar_produtos bp ON bp.id=z.bar_produto_id AND bp.empresa_id=l.empresa_id JOIN public.produtos p ON p.id=bp.produto_id AND p.empresa_id=l.empresa_id WHERE z.preco IS DISTINCT FROM p.preco_venda) THEN RAISE EXCEPTION 'O preço mudou. Atualize o cardápio e revise o carrinho antes de confirmar.'; END IF;
 SELECT round(sum(z.quantidade*p.preco_venda),2) INTO esperado FROM jsonb_to_recordset(d->'itens') z(bar_produto_id uuid,quantidade numeric) JOIN public.bar_produtos bp ON bp.id=z.bar_produto_id AND bp.empresa_id=l.empresa_id JOIN public.produtos p ON p.id=bp.produto_id AND p.empresa_id=l.empresa_id;
 esperado:=esperado+round(esperado*coalesce(a.servico_percentual,0)/100,2)+CASE WHEN a.tipo='entrega' THEN a.taxa_entrega ELSE 0 END;
 IF (d->>'expected_total')::numeric IS DISTINCT FROM esperado THEN RAISE EXCEPTION 'O total ou a taxa mudou. Revise o carrinho antes de confirmar.'; END IF;
 r:=private.gastronomia_resolver(d->'itens',l.empresa_id);
 FOR x IN SELECT value FROM jsonb_array_elements(r) LOOP
  INSERT INTO public.gastronomia_itens(empresa_id,atendimento_id,produto_id,quantidade,preco_unitario,snapshot)
  VALUES(l.empresa_id,a.id,(x->>'produto_id')::uuid,(x->>'quantidade')::numeric,(x->>'preco_venda')::numeric,x||jsonb_build_object('lote',p_chave,'autor_publico',left(d->>'nome',160),'forma_escolhida',d->>'forma')) RETURNING id INTO iid;
  SELECT array_agg(DISTINCT dest) INTO setores FROM (SELECT x->>'destino_operacional' dest UNION SELECT el->>'destino_operacional' FROM jsonb_array_elements(x->'escolhas_resolvidas') el) z WHERE dest IN ('bar','cozinha');
  IF coalesce(array_length(setores,1),0)=0 THEN setores:=ARRAY['cozinha']; END IF;
  FOREACH setor IN ARRAY setores LOOP INSERT INTO public.gastronomia_preparo(empresa_id,item_id,setor) VALUES(l.empresa_id,iid,setor); END LOOP;
 END LOOP;
 PERFORM private.gastronomia_servico_atualizar(a.id,l.empresa_id);
 UPDATE public.gastronomia_atendimentos SET versao=versao+1,atualizado_em=now(),expedicao='pendente' WHERE id=a.id AND empresa_id=l.empresa_id;
 PERFORM private.gastronomia_imprimir(a.id,l.empresa_id,p_chave);
 segredo:=replace(gen_random_uuid()::text||gen_random_uuid()::text,'-','');
 x:=jsonb_build_object('numero',a.numero,'tipo',a.tipo,'segredo',segredo,'forma_escolhida',d->>'forma','pagamento_confirmado',false,'total',(SELECT round(sum((z->>'quantidade')::numeric*(z->>'preco_venda')::numeric),2)+round(round(sum((z->>'quantidade')::numeric*(z->>'preco_venda')::numeric),2)*coalesce(a.servico_percentual,0)/100,2) FROM jsonb_array_elements(r) z)+CASE WHEN a.tipo='entrega' THEN a.taxa_entrega ELSE 0 END);
 INSERT INTO private.gastronomia_pedidos_publicos(empresa_id,link_id,chave,dados,atendimento_id,segredo,resultado) VALUES(l.empresa_id,l.id,p_chave,d,a.id,segredo,x);
 INSERT INTO public.gastronomia_eventos(empresa_id,atendimento_id,tipo,detalhes) VALUES(l.empresa_id,a.id,'cardapio_confirmar',jsonb_build_object('chave',p_chave,'forma_escolhida',d->>'forma','pagamento_confirmado',false));
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(l.empresa_id,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
 RETURN x;
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_cardapio_publico(text,text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.gastronomia_cardapio_publico(text,text,jsonb,uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.gastronomia_whatsapp_worker(p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE w private.gastronomia_whatsapp; d jsonb:=coalesce(p_dados,'{}');
BEGIN
 IF p_acao='reservar' THEN
  -- Uma reserva expirada é INCERTA: não reenviar cegamente após timeout do provedor.
  UPDATE private.gastronomia_whatsapp SET estado='incerto',erro='Reserva expirada. Conferir no provedor antes de repetir.',atualizado_em=now() WHERE estado='processando' AND atualizado_em<now()-interval '5 minutes';
  SELECT * INTO w FROM private.gastronomia_whatsapp WHERE estado='pendente' ORDER BY criado_em FOR UPDATE SKIP LOCKED LIMIT 1;
  IF NOT FOUND THEN RETURN '{}'::jsonb; END IF;
  UPDATE private.gastronomia_whatsapp SET estado='processando',tentativas=tentativas+1,atualizado_em=now() WHERE id=w.id;
  RETURN to_jsonb(w);
 ELSIF p_acao='resultado' THEN
  IF d->>'estado' NOT IN ('aceita_provedor','falha','incerto') THEN RAISE EXCEPTION 'Resultado inválido.'; END IF;
  UPDATE private.gastronomia_whatsapp SET estado=d->>'estado',provedor_id=left(d->>'provedor_id',250),erro=left(d->>'erro',500),atualizado_em=now() WHERE id=(d->>'id')::uuid AND empresa_id=(d->>'empresa_id')::uuid AND estado='processando';
 ELSIF p_acao='webhook' THEN
  IF d->>'estado' NOT IN ('entregue','lida','falha') THEN RAISE EXCEPTION 'Evento inválido.'; END IF;
  UPDATE private.gastronomia_whatsapp SET estado=d->>'estado',erro=left(d->>'erro',500),atualizado_em=now() WHERE provedor_id=d->>'provedor_id' AND estado<>'lida';
 ELSE RAISE EXCEPTION 'Ação inválida.'; END IF; RETURN jsonb_build_object('ok',true);
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_whatsapp_worker(text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.gastronomia_whatsapp_worker(text,jsonb) TO service_role;

CREATE OR REPLACE FUNCTION public.gastronomia_whatsapp_estado(p_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_pedidos'); BEGIN
 RETURN (SELECT jsonb_build_object('estado',estado,'erro',erro,'provedor_id',provedor_id,'atualizado_em',atualizado_em) FROM private.gastronomia_whatsapp WHERE empresa_id=e AND atendimento_id=p_id);
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_whatsapp_estado(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_whatsapp_estado(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.gastronomia_whatsapp_repetir(p_id uuid,p_chave uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_pedidos'); w private.gastronomia_whatsapp; req private.gastronomia_requisicoes; d jsonb:=jsonb_build_object('id',p_id); BEGIN
 IF p_chave IS NULL THEN RAISE EXCEPTION 'Identificador obrigatório.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia:'||p_chave,0));
 SELECT * INTO req FROM private.gastronomia_requisicoes WHERE empresa_id=e AND chave=p_chave;
 IF FOUND THEN IF req.acao<>'whatsapp_repetir' OR req.dados<>d THEN RAISE EXCEPTION 'Identificador reutilizado.'; END IF; RETURN req.resultado; END IF;
 SELECT * INTO w FROM private.gastronomia_whatsapp WHERE empresa_id=e AND atendimento_id=p_id FOR UPDATE;
 IF NOT FOUND OR w.estado<>'falha' THEN RAISE EXCEPTION 'Só falhas confirmadas podem ser reenviadas. Envios incertos exigem conferência no provedor.'; END IF;
 UPDATE private.gastronomia_whatsapp SET estado='pendente',provedor_id=NULL,erro=NULL,atualizado_em=now() WHERE id=w.id;
 INSERT INTO public.gastronomia_eventos(empresa_id,atendimento_id,tipo,autor,detalhes) VALUES(e,p_id,'whatsapp_repetir',auth.uid(),jsonb_build_object('falha_anterior',to_jsonb(w)));
 INSERT INTO private.gastronomia_requisicoes(empresa_id,chave,acao,dados,resultado) VALUES(e,p_chave,'whatsapp_repetir',d,'{"ok":true}');
 RETURN '{"ok":true}'::jsonb;
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_whatsapp_repetir(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_whatsapp_repetir(uuid,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.gastronomia_rpc(p_acao text, p_dados jsonb DEFAULT '{}'::jsonb, p_chave uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_visualizar'); a public.gastronomia_atendimentos; item public.gastronomia_itens; pg public.gastronomia_pagamentos; req private.gastronomia_requisicoes; autorizacao private.florest_autorizacoes; alvo uuid; resultado jsonb; resolvido jsonb; x jsonb; y jsonb; setores text[]; setor text; iid uuid; cx uuid; n bigint; r record; total numeric; pago numeric; soma numeric; motivo text; permissao text; dados jsonb:=coalesce(p_dados,'{}'); cfg public.gastronomia_configuracoes; novo text;
BEGIN
 IF p_acao='produtos_buscar' THEN
  PERFORM private.gastronomia_exigir('gastronomia_pedidos');
  novo:=nullif(btrim(left(coalesce(dados->>'busca',''),80)),'');
  IF novo IS NULL THEN RETURN jsonb_build_object('itens','[]'::jsonb); END IF;
  -- Mesma semântica de pesquisa do PDV, sem exigir/licenciar o PDV a um operador Gastronomia.
  setor:=CASE WHEN length(novo)=1 THEN '' ELSE '%' END||replace(replace(replace(novo,'\','\\'),'%','\%'),'_','\_')||'%';
  RETURN jsonb_build_object('itens',(SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.exato DESC NULLS LAST,z.nome,z.id),'[]') FROM (SELECT p.id,p.nome,p.codigo,p.gtin,p.preco_venda,bp.id bar_produto_id,coalesce(p.codigo=novo OR p.gtin=novo,false) exato FROM public.produtos p JOIN public.bar_produtos bp ON bp.produto_id=p.id AND bp.empresa_id=e WHERE p.empresa_id=e AND p.ativo AND bp.ativo_cardapio AND (p.nome ILIKE setor OR (length(novo)>1 AND (p.codigo ILIKE setor OR p.gtin ILIKE setor)) OR p.codigo=novo OR p.gtin=novo) ORDER BY (p.codigo=novo OR p.gtin=novo) DESC NULLS LAST,p.nome,p.id LIMIT 30) z));
 END IF;
 IF p_acao='mesa_consultar' THEN
  SELECT * INTO r FROM public.gastronomia_mesas WHERE empresa_id=e AND id=(dados->>'mesa_id')::uuid AND ativa;
  IF NOT FOUND THEN RAISE EXCEPTION 'Mesa não encontrada.' USING ERRCODE='42501'; END IF;
  SELECT g.id INTO alvo FROM public.gastronomia_atendimentos g WHERE g.empresa_id=e AND g.mesa_id=r.id AND g.estado='aberto';
  RETURN jsonb_build_object('mesa',to_jsonb(r),'atendimento',CASE WHEN alvo IS NOT NULL THEN public.gastronomia_rpc('atendimento_detalhe',jsonb_build_object('id',alvo))#>'{atendimentos,0}' ELSE NULL END);
 END IF;


 IF p_acao='caixa_detalhe' THEN
  PERFORM private.gastronomia_exigir('gastronomia_caixa');
  SELECT id INTO cx FROM public.caixas WHERE id=(dados->>'id')::uuid AND empresa_id=e AND tipo_caixa='GASTRONOMIA';
  IF cx IS NULL THEN RAISE EXCEPTION 'Caixa não encontrado.' USING ERRCODE='42501'; END IF;
  RETURN jsonb_build_object('caixa',(SELECT private.caixa_json(c) FROM public.caixas c WHERE c.id=cx AND c.empresa_id=e),'resumo',(SELECT private.gastronomia_caixa_calcular(c) FROM public.caixas c WHERE c.id=cx AND c.empresa_id=e),'movimentos',(SELECT coalesce(jsonb_agg(to_jsonb(p)||jsonb_build_object('canal',atd.tipo,'numero',atd.numero,'origem',atd.origem,'cliente_nome',atd.cliente_nome,'situacao_atendimento',atd.estado,'total_atendimento',private.gastronomia_total(atd.id,e),'mesa_numero',(SELECT numero FROM public.gastronomia_mesas WHERE id=atd.mesa_id AND empresa_id=e),'numero_venda',(SELECT numero_venda FROM public.vendas WHERE id=atd.venda_id AND empresa_id=e)) ORDER BY p.criado_em),'[]') FROM public.gastronomia_pagamentos p JOIN public.gastronomia_atendimentos atd ON atd.id=p.atendimento_id AND atd.empresa_id=e WHERE p.empresa_id=e AND p.caixa_id=cx));
 END IF;
 IF p_acao IN ('contexto','atendimento_detalhe') THEN
  RETURN jsonb_build_object('mesa_operacao_versao','mesas_20261025_v1','cardapio_versao','cardapio_20261025_v1','interface_versao','gastronomia_20261024_percentual_v1','empresa_id',e,'taxas',CASE WHEN private.perm('gastronomia_caixa') THEN public.taxas_pagamento_obter() ELSE NULL END,'permissoes',(SELECT jsonb_agg(p) FROM unnest(ARRAY['gastronomia_visualizar','gastronomia_mesas','gastronomia_pedidos','gastronomia_producao','gastronomia_expedicao','gastronomia_caixa','gastronomia_configurar','gastronomia_cancelar','gastronomia_estornar']) p WHERE private.perm(p)),
   'configuracao',(SELECT to_jsonb(c) FROM public.gastronomia_configuracoes c WHERE c.empresa_id=e),
   'mesas',(SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.numero),'[]') FROM public.gastronomia_mesas m WHERE m.empresa_id=e AND m.ativa),
   'catalogo',CASE WHEN private.perm('gastronomia_pedidos') OR private.perm('gastronomia_configurar') THEN (SELECT coalesce(jsonb_agg((to_jsonb(p)-'quantidade_estoque'-'estoque_minimo'-'preco_custo')||jsonb_build_object('bar_produto_id',bp.id,'tipo',bp.tipo,'destino',bp.destino_operacional,'ativo_cardapio',bp.ativo_cardapio,'componentes',(SELECT coalesce(jsonb_agg(to_jsonb(c)),'[]') FROM public.bar_produtos_componentes c WHERE c.bar_produto_id=bp.id AND c.empresa_id=e),'grupos',(SELECT coalesce(jsonb_agg(to_jsonb(g)||jsonb_build_object('opcoes',(SELECT jsonb_agg(to_jsonb(o)||jsonb_build_object('nome',pr.nome,'disponivel',pr.ativo AND (pr.quantidade_estoque>0 OR coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false)))) FROM public.bar_produto_grupo_opcoes o JOIN public.produtos pr ON pr.id=o.produto_id AND pr.empresa_id=e WHERE o.grupo_id=g.id AND o.empresa_id=e))),'[]') FROM public.bar_produto_grupos g WHERE g.bar_produto_id=bp.id AND g.empresa_id=e)) ORDER BY p.nome),'[]') FROM public.produtos p LEFT JOIN public.bar_produtos bp ON bp.produto_id=p.id AND bp.empresa_id=e WHERE p.empresa_id=e AND p.ativo) ELSE '[]'::jsonb END,
   'atendimentos',(SELECT coalesce(jsonb_agg(z.doc ORDER BY z.criado_em DESC),'[]') FROM (SELECT a1.criado_em,to_jsonb(a1)||jsonb_build_object('financeiro',private.gastronomia_financeiro_detalhe(a1.id,e),'numero_venda',(SELECT numero_venda FROM public.vendas WHERE id=a1.venda_id AND empresa_id=e),'impressao',private.gastronomia_impressao_estado(a1.id,e),'mesa_numero',(SELECT numero FROM public.gastronomia_mesas WHERE id=a1.mesa_id AND empresa_id=e),'total',private.gastronomia_total(a1.id,e),'pago',private.gastronomia_pago(a1.id,e),'itens',(SELECT coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('autor_nome',(SELECT pf.nome FROM public.perfis pf WHERE pf.id=i.criado_por AND pf.empresa_id=e),'preparo',(SELECT coalesce(jsonb_agg(to_jsonb(pr)),'[]') FROM public.gastronomia_preparo pr WHERE pr.item_id=i.id AND pr.empresa_id=e)) ORDER BY i.criado_em),'[]') FROM public.gastronomia_itens i WHERE i.atendimento_id=a1.id AND i.empresa_id=e),'pagamentos',CASE WHEN private.perm('gastronomia_caixa') OR private.perm('gastronomia_estornar') THEN (SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]') FROM public.gastronomia_pagamentos p WHERE p.atendimento_id=a1.id AND p.empresa_id=e) ELSE '[]'::jsonb END) doc FROM public.gastronomia_atendimentos a1 WHERE a1.empresa_id=e AND (p_acao='contexto' OR a1.id=(dados->>'id')::uuid) ORDER BY (a1.estado='aberto') DESC,a1.criado_em DESC LIMIT 500) z));
 END IF;
 permissao:=CASE p_acao WHEN 'mesa_lancar' THEN 'gastronomia_mesas' WHEN 'mesa_transferir' THEN CASE WHEN private.perm('gastronomia_mesas') THEN 'gastronomia_mesas' ELSE 'gastronomia_caixa' END WHEN 'mesa_relatorio' THEN CASE WHEN private.perm('gastronomia_mesas') THEN 'gastronomia_mesas' ELSE 'gastronomia_caixa' END WHEN 'configurar' THEN 'gastronomia_configurar' WHEN 'foto' THEN 'gastronomia_configurar' WHEN 'criar' THEN CASE WHEN dados->>'tipo'='mesa' THEN 'gastronomia_mesas' ELSE 'gastronomia_pedidos' END WHEN 'adicionar' THEN 'gastronomia_pedidos' WHEN 'preparo' THEN 'gastronomia_producao' WHEN 'expedicao' THEN 'gastronomia_expedicao' WHEN 'receber' THEN 'gastronomia_caixa' WHEN 'ajustar' THEN 'gastronomia_caixa' WHEN 'finalizar' THEN 'gastronomia_caixa' WHEN 'cancelar_item' THEN 'gastronomia_cancelar' WHEN 'cancelar' THEN 'gastronomia_cancelar' WHEN 'estornar' THEN 'gastronomia_estornar' WHEN 'reimprimir' THEN 'gastronomia_pedidos' WHEN 'editar' THEN 'gastronomia_pedidos' WHEN 'corrigir_item' THEN 'gastronomia_cancelar' WHEN 'pronto' THEN 'gastronomia_producao' ELSE NULL END;
 IF permissao IS NULL THEN RAISE EXCEPTION 'Ação inválida.'; END IF;
 PERFORM private.gastronomia_exigir(permissao);
 IF p_chave IS NULL THEN RAISE EXCEPTION 'Identificador da operação obrigatório.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia:'||p_chave,0));
 SELECT * INTO req FROM private.gastronomia_requisicoes WHERE empresa_id=e AND chave=p_chave;
 IF FOUND THEN IF req.acao<>p_acao OR req.dados<>dados THEN RAISE EXCEPTION 'Identificador já usado com outro conteúdo.'; END IF; RETURN req.resultado; END IF;
 IF p_acao='mesa_lancar' THEN
  SELECT * INTO r FROM public.gastronomia_mesas WHERE empresa_id=e AND id=(dados->>'mesa_id')::uuid AND ativa FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Mesa não encontrada.' USING ERRCODE='42501'; END IF;
  IF NOT pg_try_advisory_xact_lock(hashtextextended(e::text||':mesa-fisica:'||r.numero,0)) THEN RAISE EXCEPTION 'Mesa sendo alterada por outro terminal. Atualize e confira.' USING ERRCODE='40001'; END IF;
  IF EXISTS(SELECT 1 FROM public.gastronomia_atendimentos g WHERE g.empresa_id=e AND g.mesa_id=r.id AND g.estado='aberto') THEN RAISE EXCEPTION 'A mesa foi aberta em outro terminal. Reabra a conta existente antes de lançar.' USING ERRCODE='40001'; END IF;
  x:=public.gastronomia_rpc('criar',jsonb_build_object('tipo','mesa','mesa_id',r.id),md5(p_chave::text||':criar')::uuid);
  resultado:=public.gastronomia_rpc('adicionar',jsonb_build_object('id',x->>'id','versao',x->'versao','itens',dados->'itens'),md5(p_chave::text||':adicionar')::uuid);
  alvo:=(resultado->>'id')::uuid;
 ELSIF p_acao='foto' THEN
  IF NOT EXISTS(SELECT 1 FROM public.produtos WHERE id=(dados->>'produto_id')::uuid AND empresa_id=e AND ativo) THEN RAISE EXCEPTION 'Produto não encontrado.' USING ERRCODE='42501'; END IF;
  novo:=coalesce(dados->>'url','');
  IF length(novo)>2000 OR (novo<>'' AND novo !~ '^https://[^[:space:]]+$') THEN RAISE EXCEPTION 'Informe uma URL HTTPS válida para a foto.'; END IF;
  INSERT INTO public.gastronomia_configuracoes(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
  UPDATE public.gastronomia_configuracoes SET opcoes=jsonb_set(opcoes,'{fotos}',coalesce(opcoes->'fotos','{}')||jsonb_build_object(dados->>'produto_id',novo)) WHERE empresa_id=e;
  resultado:=jsonb_build_object('produto_id',dados->>'produto_id');
 ELSIF p_acao='configurar' THEN
  n:=(dados->>'mesas')::integer;
  IF n IS NULL OR n<0 OR n>500 OR coalesce((dados->>'taxa_entrega')::numeric,0)<0 THEN RAISE EXCEPTION 'Configuração inválida.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia:config',0));
  IF EXISTS(SELECT 1 FROM public.gastronomia_atendimentos a1 JOIN public.gastronomia_mesas m ON m.id=a1.mesa_id AND m.empresa_id=e WHERE a1.empresa_id=e AND a1.estado='aberto' AND m.numero>n) THEN RAISE EXCEPTION 'Não é possível desativar mesa ocupada.'; END IF;
  INSERT INTO public.gastronomia_configuracoes(empresa_id,quantidade_mesas,taxa_entrega,imprimir) VALUES(e,n,coalesce((dados->>'taxa_entrega')::numeric,0),true) ON CONFLICT(empresa_id) DO UPDATE SET quantidade_mesas=excluded.quantidade_mesas,taxa_entrega=excluded.taxa_entrega,imprimir=excluded.imprimir;
  IF dados ? 'opcoes' THEN
   x:=dados->'opcoes';
   IF (x ? 'servico_percentual' AND ((x->>'servico_percentual')::numeric IS NULL OR (x->>'servico_percentual')::numeric<0 OR (x->>'servico_percentual')::numeric>100 OR (x->>'servico_percentual')::numeric<>round((x->>'servico_percentual')::numeric,4))) OR jsonb_typeof(x)<>'object' OR octet_length(x::text)>40000 OR coalesce((x->>'taxa_servico')::numeric,0)<0 OR coalesce((x->>'taxa_servico')::numeric,0)>=100000000000 THEN RAISE EXCEPTION 'Configuração complementar inválida.'; END IF;
   UPDATE public.gastronomia_configuracoes SET opcoes=opcoes||jsonb_build_object('servico_percentual',coalesce((x->>'servico_percentual')::numeric,(opcoes->>'servico_percentual')::numeric,0),'taxa_servico_legada',opcoes->'taxa_servico','horarios',left(x->>'horarios',2000),'entrega',coalesce((x->>'entrega')::boolean,true),'retirada',coalesce((x->>'retirada')::boolean,true),'fotos',coalesce(opcoes->'fotos','{}')) WHERE empresa_id=e;
  END IF;
  INSERT INTO public.gastronomia_mesas(empresa_id,numero) SELECT e,generate_series(1,n) ON CONFLICT(empresa_id,numero) DO UPDATE SET ativa=true;
  UPDATE public.gastronomia_mesas SET ativa=false WHERE empresa_id=e AND numero>n;
  resultado:=jsonb_build_object('mesas',n);
 ELSIF p_acao='criar' THEN
  IF dados->>'tipo' NOT IN ('mesa','entrega','retirada') OR dados->>'tipo' IS NULL THEN RAISE EXCEPTION 'Escolha o atendimento.'; END IF;
  IF dados->>'tipo'='mesa' THEN
   SELECT id INTO alvo FROM public.gastronomia_mesas WHERE id=(dados->>'mesa_id')::uuid AND empresa_id=e AND ativa FOR UPDATE;
   IF alvo IS NULL THEN RAISE EXCEPTION 'Mesa não encontrada.'; END IF;
   SELECT numero INTO n FROM public.gastronomia_mesas WHERE id=alvo AND empresa_id=e;
   PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':mesa-fisica:'||n,0));
   IF EXISTS(SELECT 1 FROM public.bar_mesas WHERE empresa_id=e AND numero=n AND status='ocupada') THEN RAISE EXCEPTION 'Mesa física já ocupada no Bar.'; END IF;
  ELSE IF length(btrim(coalesce(dados->>'cliente_nome','')))=0 OR length(btrim(coalesce(dados->>'telefone','')))=0 THEN RAISE EXCEPTION 'Informe cliente e telefone.'; END IF; END IF;
  IF dados->>'tipo'='entrega' AND length(btrim(coalesce(dados->>'endereco','')))=0 THEN RAISE EXCEPTION 'Informe o endereço da entrega.'; END IF;
  IF dados->>'cliente_id' IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.clientes WHERE id=(dados->>'cliente_id')::uuid AND empresa_id=e) THEN RAISE EXCEPTION 'Cliente de outra empresa.' USING ERRCODE='42501'; END IF;
  INSERT INTO public.gastronomia_configuracoes(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
  UPDATE public.gastronomia_configuracoes SET ultimo_numero=ultimo_numero+1 WHERE empresa_id=e RETURNING * INTO cfg;
  INSERT INTO public.gastronomia_atendimentos(empresa_id,numero,tipo,origem,mesa_id,cliente_id,cliente_nome,telefone,endereco,referencia,taxa_entrega,criado_por)
  VALUES(e,cfg.ultimo_numero,dados->>'tipo',coalesce(dados->>'origem','manual'),alvo,(dados->>'cliente_id')::uuid,nullif(btrim(dados->>'cliente_nome'),''),dados->>'telefone',dados->>'endereco',dados->>'referencia',CASE WHEN dados->>'tipo'='entrega' THEN coalesce((dados->>'taxa_entrega')::numeric,cfg.taxa_entrega) ELSE 0 END,auth.uid()) RETURNING * INTO a;
  
  UPDATE public.gastronomia_atendimentos SET servico_regra='percentual_v1',servico_percentual=coalesce((cfg.opcoes->>'servico_percentual')::numeric,0),servico_base=0 WHERE id=a.id AND empresa_id=e;
  PERFORM private.gastronomia_servico_atualizar(a.id,e);
  alvo:=a.id; resultado:=jsonb_build_object('id',a.id,'numero',a.numero,'versao',a.versao);
 ELSE
  alvo:=(dados->>'id')::uuid;
  SELECT * INTO a FROM public.gastronomia_atendimentos WHERE id=alvo AND empresa_id=e FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Atendimento não encontrado.' USING ERRCODE='42501'; END IF;
  IF (dados->>'versao')::integer IS DISTINCT FROM a.versao THEN RAISE EXCEPTION 'Outro terminal alterou este atendimento. Atualize e confira.' USING ERRCODE='40001'; END IF;
  IF a.estado NOT IN ('aberto','em_ajuste') AND p_acao NOT IN ('estornar','reimprimir','mesa_relatorio') THEN RAISE EXCEPTION 'Atendimento já encerrado.'; END IF;
  IF p_acao IN ('cancelar_item','cancelar','estornar','corrigir_item') THEN
   motivo:=btrim(coalesce(dados->>'motivo','')); IF length(motivo)<3 THEN RAISE EXCEPTION 'Informe o motivo (mínimo 3 caracteres).'; END IF;
   autorizacao:=private.florest_autorizacao_consumir((dados->>'token')::uuid,auth.uid(),CASE WHEN p_acao='estornar' THEN 'gastronomia_estornar' ELSE 'gastronomia_cancelar' END,coalesce((dados->>'item_id')::uuid,(dados->>'pagamento_id')::uuid,alvo),jsonb_build_object('motivo',motivo));
   IF autorizacao.empresa_id IS DISTINCT FROM e OR autorizacao.transacao IS DISTINCT FROM txid_current() THEN RAISE EXCEPTION 'Autorização já utilizada.' USING ERRCODE='42501'; END IF;
   IF EXISTS(SELECT 1 FROM public.documentos_fiscais WHERE empresa_id=e AND venda_id=a.venda_id AND status IN ('processando','autorizada')) THEN RAISE EXCEPTION 'Trate o documento fiscal antes de cancelar ou estornar.'; END IF;
  END IF;
  IF p_acao='mesa_transferir' THEN
   IF a.tipo<>'mesa' OR a.estado<>'aberto' THEN RAISE EXCEPTION 'A transferência exige uma mesa com conta aberta.'; END IF;
   IF (dados->>'mesa_destino_id')::uuid IS NULL OR (dados->>'mesa_destino_id')::uuid=a.mesa_id THEN RAISE EXCEPTION 'Selecione outra mesa disponível.'; END IF;
   -- Mesas físicas em ordem estável; recusar disputa sem esperar por travas em ordem inversa.
   FOR r IN SELECT m.id,m.numero FROM public.gastronomia_mesas m WHERE m.empresa_id=e AND m.id IN (a.mesa_id,(dados->>'mesa_destino_id')::uuid) ORDER BY m.numero FOR UPDATE NOWAIT LOOP
    IF NOT pg_try_advisory_xact_lock(hashtextextended(e::text||':mesa-fisica:'||r.numero,0)) THEN RAISE EXCEPTION 'Mesa sendo alterada em outro terminal. Atualize e confira.' USING ERRCODE='40001'; END IF;
   END LOOP;
   SELECT jsonb_build_object('id',m.id,'numero',m.numero) INTO x FROM public.gastronomia_mesas m WHERE m.empresa_id=e AND m.id=a.mesa_id;
   SELECT jsonb_build_object('id',m.id,'numero',m.numero) INTO y FROM public.gastronomia_mesas m WHERE m.empresa_id=e AND m.id=(dados->>'mesa_destino_id')::uuid AND m.ativa;
   IF y IS NULL THEN RAISE EXCEPTION 'Mesa de destino indisponível.'; END IF;
   IF EXISTS(SELECT 1 FROM public.gastronomia_atendimentos g WHERE g.empresa_id=e AND g.mesa_id=(y->>'id')::uuid AND g.estado='aberto') OR EXISTS(SELECT 1 FROM public.bar_mesas bm WHERE bm.empresa_id=e AND bm.numero=(y->>'numero')::integer AND bm.status='ocupada') THEN RAISE EXCEPTION 'A mesa de destino está ocupada. Não é permitido unir contas.'; END IF;
   UPDATE public.gastronomia_atendimentos SET mesa_id=(y->>'id')::uuid WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='mesa_relatorio' THEN
   x:=private.gastronomia_mesa_relatorio(alvo,e,p_chave);
  ELSIF p_acao='editar' THEN
   IF a.venda_id IS NOT NULL OR private.gastronomia_pago(alvo,e)>0 OR a.expedicao IN ('saiu_entrega','entregue','retirado') THEN RAISE EXCEPTION 'Pedido pago ou em entrega: trate os recebimentos e as restrições fiscais antes da correção.'; END IF;
   IF a.tipo<>'mesa' AND (length(btrim(coalesce(dados->>'cliente_nome','')))=0 OR length(btrim(coalesce(dados->>'telefone','')))=0) THEN RAISE EXCEPTION 'Informe cliente e telefone.'; END IF;
   IF a.tipo='entrega' AND length(btrim(coalesce(dados->>'endereco','')))=0 THEN RAISE EXCEPTION 'Informe o endereço.'; END IF;
   UPDATE public.gastronomia_atendimentos SET cliente_nome=left(btrim(dados->>'cliente_nome'),160),telefone=left(dados->>'telefone',40),endereco=left(dados->>'endereco',500),referencia=left(dados->>'referencia',300) WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='corrigir_item' THEN
   IF a.venda_id IS NOT NULL OR private.gastronomia_pago(alvo,e)>0 OR a.expedicao IN ('saiu_entrega','entregue','retirado') THEN RAISE EXCEPTION 'Estorne os recebimentos e trate a venda/fiscal antes de corrigir itens.'; END IF;
   SELECT * INTO item FROM public.gastronomia_itens WHERE id=(dados->>'item_id')::uuid AND atendimento_id=alvo AND empresa_id=e AND NOT cancelado FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'Item indisponível.'; END IF;
   total:=(dados->>'quantidade')::numeric;
   IF total IS NULL OR total<=0 OR total>=100000000 OR total<>round(total,4) THEN RAISE EXCEPTION 'Quantidade inválida.'; END IF;
   x:=item.snapshot;
   IF total<>item.quantidade THEN
    -- A base é imutável: nunca consultar a composição atual para devolver/repor o lançamento antigo.
    resolvido:=coalesce(item.snapshot->'correcao_base',jsonb_build_object('quantidade',item.quantidade,'baixas',item.snapshot->'baixas','escolhas_resolvidas',coalesce(item.snapshot->'escolhas_resolvidas','[]')));
    -- Um registro antigo com fração inferior à precisão do estoque não prova a baixa física.
    -- Não adivinhar essa quantidade nem recalcular a receita: exigir conciliação antes de corrigir.
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(resolvido->'baixas') b GROUP BY b->>'produto_baixa_id' HAVING sum((b->>'quantidade')::numeric)<>round(sum((b->>'quantidade')::numeric),4)) THEN RAISE EXCEPTION 'Baixa original com precisão superior ao estoque: concilie o registro físico antes de corrigir a quantidade.'; END IF;
    IF total>item.quantidade AND NOT EXISTS(SELECT 1 FROM public.produtos WHERE id=item.produto_id AND empresa_id=e AND ativo) THEN RAISE EXCEPTION 'Produto inativo: não é possível aumentar o consumo.'; END IF;
    y:='[]'::jsonb;
    FOR r IN
     SELECT b.produto,round(b.qtd*total/(resolvido->>'quantidade')::numeric,4) nova,round(coalesce(c.qtd,0),4) anterior
     FROM (SELECT (b->>'produto_baixa_id')::uuid produto,sum((b->>'quantidade')::numeric) qtd FROM jsonb_array_elements(resolvido->'baixas') b GROUP BY 1) b
     LEFT JOIN (SELECT (b->>'produto_baixa_id')::uuid produto,sum((b->>'quantidade')::numeric) qtd FROM jsonb_array_elements(item.snapshot->'baixas') b GROUP BY 1) c USING(produto)
     ORDER BY b.produto
    LOOP
     PERFORM 1 FROM public.produtos WHERE id=r.produto AND empresa_id=e FOR UPDATE;
     IF NOT FOUND THEN RAISE EXCEPTION 'Produto físico não encontrado.'; END IF;
     IF r.nova>r.anterior AND EXISTS(SELECT 1 FROM public.produtos WHERE id=r.produto AND empresa_id=e AND (NOT ativo OR (quantidade_estoque<r.nova-r.anterior AND NOT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false)))) THEN RAISE EXCEPTION 'Componente indisponível para aumentar a quantidade.'; END IF;
     UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-(r.nova-r.anterior) WHERE id=r.produto AND empresa_id=e;
     y:=y||jsonb_build_array(jsonb_build_object('produto_baixa_id',r.produto,'quantidade',r.nova));
    END LOOP;
    x:=x||jsonb_build_object('quantidade',total,'correcao_base',resolvido,'baixas',y,'escolhas_resolvidas',(SELECT coalesce(jsonb_agg(b||jsonb_build_object('quantidade',round((b->>'quantidade')::numeric*total/(resolvido->>'quantidade')::numeric,4))),'[]') FROM jsonb_array_elements(resolvido->'escolhas_resolvidas') b));
    UPDATE public.gastronomia_preparo SET estado='novo',autor=auth.uid(),alterado_em=now() WHERE empresa_id=e AND item_id=item.id;
    UPDATE public.gastronomia_atendimentos SET expedicao='pendente' WHERE id=alvo AND empresa_id=e;
   END IF;
   UPDATE public.gastronomia_itens SET quantidade=total,snapshot=jsonb_set(x,'{observacao}',to_jsonb(left(coalesce(dados->>'observacao',item.snapshot->>'observacao',''),150))) WHERE id=item.id AND empresa_id=e;
  ELSIF p_acao='pronto' THEN
   IF NOT EXISTS(SELECT 1 FROM public.gastronomia_itens WHERE atendimento_id=alvo AND empresa_id=e AND NOT cancelado) THEN RAISE EXCEPTION 'Não há itens para preparar.'; END IF;
   UPDATE public.gastronomia_preparo pr SET estado='pronto',autor=auth.uid(),alterado_em=now() FROM public.gastronomia_itens i WHERE pr.item_id=i.id AND pr.empresa_id=e AND i.empresa_id=e AND i.atendimento_id=alvo AND NOT i.cancelado;
   UPDATE public.gastronomia_atendimentos SET expedicao=CASE WHEN tipo='retirada' THEN 'aguardando_retirada' WHEN tipo='entrega' THEN 'aguardando_despacho' ELSE expedicao END WHERE id=alvo AND empresa_id=e AND expedicao='pendente';
  ELSIF p_acao='adicionar' THEN

   IF a.expedicao IN ('saiu_entrega','entregue','retirado') THEN RAISE EXCEPTION 'O pedido já saiu da operação.'; END IF;
   resolvido:=private.gastronomia_resolver(dados->'itens',e);
   FOR x IN SELECT value FROM jsonb_array_elements(resolvido) LOOP
    INSERT INTO public.gastronomia_itens(empresa_id,atendimento_id,produto_id,quantidade,preco_unitario,snapshot,criado_por) VALUES(e,alvo,(x->>'produto_id')::uuid,(x->>'quantidade')::numeric,(x->>'preco_venda')::numeric,x||jsonb_build_object('lote',p_chave),auth.uid()) RETURNING id INTO iid;
    SELECT array_agg(DISTINCT dest) INTO setores FROM (SELECT x->>'destino_operacional' dest UNION SELECT el->>'destino_operacional' FROM jsonb_array_elements(x->'escolhas_resolvidas') el) z WHERE dest IN ('bar','cozinha');
    IF coalesce(array_length(setores,1),0)=0 THEN RAISE EXCEPTION 'Defina o destino de preparo do produto %.',x->>'produto_nome'; END IF;
    FOREACH setor IN ARRAY setores LOOP INSERT INTO public.gastronomia_preparo(empresa_id,item_id,setor) VALUES(e,iid,setor); END LOOP;
   END LOOP;
   UPDATE public.gastronomia_atendimentos SET expedicao='pendente' WHERE id=alvo AND empresa_id=e;
   PERFORM private.gastronomia_imprimir(alvo,e,p_chave);
  ELSIF p_acao='preparo' THEN
   SELECT i.* INTO item FROM public.gastronomia_itens i JOIN public.gastronomia_preparo pr ON pr.item_id=i.id AND pr.empresa_id=e WHERE pr.id=(dados->>'preparo_id')::uuid AND i.atendimento_id=alvo AND i.empresa_id=e AND NOT i.cancelado;
   IF NOT FOUND THEN RAISE EXCEPTION 'Item não disponível para preparo.'; END IF;
   novo:=dados->>'estado';
   UPDATE public.gastronomia_preparo SET estado=novo,autor=auth.uid(),alterado_em=now() WHERE id=(dados->>'preparo_id')::uuid AND empresa_id=e AND ((estado='novo' AND novo='em_preparo') OR (estado='em_preparo' AND novo='pronto'));
   IF NOT FOUND THEN RAISE EXCEPTION 'Transição de preparo inválida.'; END IF;
   IF NOT EXISTS(SELECT 1 FROM public.gastronomia_preparo pr JOIN public.gastronomia_itens i ON i.id=pr.item_id AND i.empresa_id=e WHERE i.atendimento_id=alvo AND pr.empresa_id=e AND NOT i.cancelado AND pr.estado<>'pronto') THEN UPDATE public.gastronomia_atendimentos SET expedicao=CASE WHEN tipo='retirada' THEN 'aguardando_retirada' WHEN tipo='entrega' THEN 'aguardando_despacho' ELSE expedicao END WHERE id=alvo AND empresa_id=e AND expedicao='pendente'; END IF;
  ELSIF p_acao='expedicao' THEN
   IF NOT EXISTS(SELECT 1 FROM public.gastronomia_itens WHERE atendimento_id=alvo AND empresa_id=e AND NOT cancelado) OR EXISTS(SELECT 1 FROM public.gastronomia_preparo pr JOIN public.gastronomia_itens i ON i.id=pr.item_id AND i.empresa_id=e WHERE i.atendimento_id=alvo AND pr.empresa_id=e AND NOT i.cancelado AND pr.estado<>'pronto') THEN RAISE EXCEPTION 'Ainda há itens em preparo.'; END IF;
   novo:=dados->>'estado';
   IF NOT ((a.tipo='mesa' AND a.expedicao='pendente' AND novo='entregue_mesa') OR (a.tipo='retirada' AND ((a.expedicao='pendente' AND novo='aguardando_retirada') OR (a.expedicao='aguardando_retirada' AND novo='retirado'))) OR (a.tipo='entrega' AND ((a.expedicao='pendente' AND novo='aguardando_despacho') OR (a.expedicao='aguardando_despacho' AND novo='saiu_entrega') OR (a.expedicao='saiu_entrega' AND novo='entregue')))) THEN RAISE EXCEPTION 'Transição de expedição inválida.'; END IF;
   IF novo='saiu_entrega' AND length(btrim(coalesce(dados->>'entregador',a.entregador,'')))=0 THEN RAISE EXCEPTION 'Informe o responsável pela entrega.'; END IF;
   UPDATE public.gastronomia_atendimentos SET expedicao=novo,entregador=coalesce(nullif(btrim(dados->>'entregador'),''),entregador) WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='ajustar' THEN
   IF dados ? 'servico_percentual' THEN
    total:=(dados->>'servico_percentual')::numeric;
    IF total IS NULL OR total<0 OR total>100 OR total<>round(total,4) THEN RAISE EXCEPTION 'Informe a taxa de serviço entre 0 e 100 por cento.'; END IF;
    IF a.venda_id IS NOT NULL OR private.gastronomia_pago(alvo,e)>0 THEN RAISE EXCEPTION 'Atendimento recebido ou consolidado: não alterar a regra de serviço.'; END IF;
    IF dados ? 'taxa_servico' THEN RAISE EXCEPTION 'Informe percentual ou ajuste legado em reais, nunca ambos.'; END IF;
    UPDATE public.gastronomia_atendimentos SET servico_regra='percentual_v1',servico_percentual=total WHERE id=alvo AND empresa_id=e;
   ELSIF a.servico_regra='percentual_v1' AND dados ? 'taxa_servico' THEN RAISE EXCEPTION 'Este atendimento usa serviço percentual. Atualize a interface antes de ajustar.';
   END IF;
   IF a.venda_id IS NOT NULL THEN RAISE EXCEPTION 'Venda consolidada: ajustes exigem o procedimento financeiro/fiscal.'; END IF;
   UPDATE public.gastronomia_atendimentos SET desconto=coalesce((dados->>'desconto')::numeric,desconto),acrescimo=coalesce((dados->>'acrescimo')::numeric,acrescimo),taxa_servico=coalesce((dados->>'taxa_servico')::numeric,taxa_servico),taxa_entrega=CASE WHEN tipo='entrega' THEN coalesce((dados->>'taxa_entrega')::numeric,taxa_entrega) ELSE 0 END WHERE id=alvo AND empresa_id=e;
   IF private.gastronomia_total(alvo,e)<private.gastronomia_pago(alvo,e) OR private.gastronomia_total(alvo,e)<0 THEN RAISE EXCEPTION 'Ajuste deixaria o total menor que o recebido.'; END IF;
  ELSIF p_acao='receber' THEN
   total:=private.gastronomia_total(alvo,e); pago:=private.gastronomia_pago(alvo,e);
   IF jsonb_typeof(dados->'formas') IS DISTINCT FROM 'array' OR jsonb_array_length(dados->'formas') NOT BETWEEN 1 AND 10 THEN RAISE EXCEPTION 'Informe de 1 a 10 pagamentos.'; END IF;
   SELECT sum((v->>'valor')::numeric) INTO soma FROM jsonb_array_elements(dados->'formas') v;
   IF soma IS NULL OR soma<=0 OR soma>total-pago THEN RAISE EXCEPTION 'Valor superior ao saldo ou inválido.'; END IF;
   cx:=private.caixa_exigir_aberto('GASTRONOMIA');
   FOR x IN SELECT value FROM jsonb_array_elements(dados->'formas') LOOP
    IF (x->>'valor')::numeric<>round((x->>'valor')::numeric,2) OR coalesce((x->>'valor')::numeric,0)<=0 THEN RAISE EXCEPTION 'Valor de pagamento inválido.'; END IF;
    INSERT INTO public.gastronomia_pagamentos(empresa_id,atendimento_id,caixa_id,forma,valor,criado_por,metadados) VALUES(e,alvo,cx,x->>'forma_pagamento',(x->>'valor')::numeric,auth.uid(),jsonb_build_object('taxas',x->'taxas'));
   END LOOP;
   PERFORM private.gastronomia_venda(alvo,e);
   IF a.tipo='mesa' AND private.gastronomia_total(alvo,e)>0 AND private.gastronomia_total(alvo,e)=private.gastronomia_pago(alvo,e) THEN
    UPDATE public.gastronomia_atendimentos SET estado='finalizado',finalizado_em=now() WHERE id=alvo AND empresa_id=e;
   END IF;
  ELSIF p_acao='estornar' THEN
   SELECT * INTO pg FROM public.gastronomia_pagamentos WHERE id=(dados->>'pagamento_id')::uuid AND atendimento_id=alvo AND empresa_id=e FOR UPDATE;
   IF NOT FOUND OR pg.estornado THEN RAISE EXCEPTION 'Pagamento indisponível para estorno.'; END IF;
   PERFORM 1 FROM public.caixas WHERE id=pg.caixa_id AND empresa_id=e AND status='aberto' FOR SHARE;
   IF NOT FOUND THEN RAISE EXCEPTION 'O caixa original já foi fechado. Estorno administrativo deve ser tratado separadamente.'; END IF;
   UPDATE public.gastronomia_pagamentos SET estornado=true,estornado_por=auth.uid(),estornado_em=now(),motivo=dados->>'motivo' WHERE id=pg.id AND empresa_id=e;
   -- Registro canônico permanece integral no razão e no evento; a projeção de pagamentos ativos é sincronizada.
   DELETE FROM public.vendas_pagamentos WHERE id=pg.id AND empresa_id=e;
   UPDATE private.taxas_pagamentos SET ativo=false WHERE empresa_id=e AND origem='pdv' AND pagamento_id=pg.id;
   FOR r IN SELECT DISTINCT data FROM private.taxas_pagamentos WHERE empresa_id=e AND origem='pdv' AND pagamento_id=pg.id LOOP PERFORM private.taxas_consolidar(e,r.data); END LOOP;
   UPDATE public.gastronomia_atendimentos SET estado=CASE WHEN estado='finalizado' THEN 'em_ajuste' ELSE estado END,finalizado_em=CASE WHEN estado='finalizado' THEN finalizado_em ELSE NULL END WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='cancelar_item' THEN
   SELECT * INTO item FROM public.gastronomia_itens WHERE id=(dados->>'item_id')::uuid AND atendimento_id=alvo AND empresa_id=e FOR UPDATE;
   IF NOT FOUND OR item.cancelado THEN RAISE EXCEPTION 'Item não disponível para cancelamento.'; END IF;
   IF item.item_venda_id IS NOT NULL AND private.gastronomia_pago(alvo,e)<>0 THEN RAISE EXCEPTION 'Estorne todos os pagamentos antes de cancelar item de venda consolidada.'; END IF;
   IF private.gastronomia_pago(alvo,e)>private.gastronomia_total(alvo,e)-round(item.quantidade*item.preco_unitario,2) THEN RAISE EXCEPTION 'Estorne os pagamentos excedentes antes de cancelar este item.'; END IF;
   FOR r IN SELECT (b->>'produto_baixa_id')::uuid produto,sum((b->>'quantidade')::numeric) quantidade FROM jsonb_array_elements(item.snapshot->'baixas') b GROUP BY 1 ORDER BY 1 LOOP
    UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+r.quantidade WHERE id=r.produto AND empresa_id=e; IF NOT FOUND THEN RAISE EXCEPTION 'Produto físico não encontrado.'; END IF;
   END LOOP;
   UPDATE public.gastronomia_itens SET cancelado=true WHERE id=item.id AND empresa_id=e;
   IF item.item_venda_id IS NOT NULL THEN DELETE FROM public.itens_venda WHERE id=item.item_venda_id AND empresa_id=e AND venda_id=a.venda_id; END IF;
  ELSIF p_acao='cancelar' THEN
   IF EXISTS(SELECT 1 FROM public.gastronomia_itens WHERE atendimento_id=alvo AND empresa_id=e AND NOT cancelado) OR private.gastronomia_pago(alvo,e)<>0 THEN RAISE EXCEPTION 'Cancele os itens e estorne os pagamentos antes de cancelar o atendimento.'; END IF;
   UPDATE public.gastronomia_atendimentos SET estado='cancelado',finalizado_em=now() WHERE id=alvo AND empresa_id=e;
   IF a.venda_id IS NOT NULL THEN UPDATE public.vendas SET cancelada_em=now(),cancelada_por=auth.uid(),motivo_cancelamento=motivo WHERE id=a.venda_id AND empresa_id=e; END IF;
  ELSIF p_acao='finalizar' THEN
   IF private.gastronomia_total(alvo,e)<=0 OR private.gastronomia_total(alvo,e)<>private.gastronomia_pago(alvo,e) THEN RAISE EXCEPTION 'Quite o saldo antes de encerrar.'; END IF;
   IF a.tipo<>'mesa' AND ((a.tipo='entrega' AND a.expedicao NOT IN ('saiu_entrega','entregue')) OR (a.tipo='retirada' AND a.expedicao<>'retirado')) THEN RAISE EXCEPTION 'Falta confirmar a saída com entregador (entrega) ou a retirada (retirada), após marcar pronto.'; END IF;
   PERFORM private.gastronomia_venda(alvo,e);
   UPDATE public.gastronomia_atendimentos SET estado='finalizado',finalizado_em=now() WHERE id=alvo AND empresa_id=e;
  ELSIF p_acao='reimprimir' THEN PERFORM private.gastronomia_reimprimir(alvo,e,p_chave);
  END IF;
  IF p_acao IN ('adicionar','corrigir_item','cancelar_item','ajustar') THEN
   PERFORM private.gastronomia_servico_atualizar(alvo,e);
   IF private.gastronomia_total(alvo,e)<private.gastronomia_pago(alvo,e) THEN RAISE EXCEPTION 'A alteração deixaria o total menor que o recebido. Regularize os pagamentos antes.'; END IF;
  END IF;
  UPDATE public.gastronomia_atendimentos SET versao=versao+1,atualizado_em=now() WHERE id=alvo AND empresa_id=e RETURNING * INTO a;
  resultado:=jsonb_build_object('id',alvo,'versao',a.versao,'total',private.gastronomia_total(alvo,e),'pago',private.gastronomia_pago(alvo,e),'venda_id',a.venda_id,'estado',a.estado)||CASE WHEN p_acao='mesa_transferir' THEN jsonb_build_object('mesa_origem',x,'mesa_destino',y) WHEN p_acao='mesa_relatorio' THEN jsonb_build_object('relatorio',x) ELSE '{}'::jsonb END;
 END IF;
 INSERT INTO public.gastronomia_eventos(empresa_id,atendimento_id,tipo,autor,autorizador,detalhes) VALUES(e,alvo,p_acao,auth.uid(),autorizacao.autorizador_id,(dados-'token')||jsonb_build_object('resultado',resultado,'item_antes',to_jsonb(item),'pagamento_antes',to_jsonb(pg)));
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
 INSERT INTO private.gastronomia_requisicoes(empresa_id,chave,acao,dados,resultado) VALUES(e,p_chave,p_acao,dados,resultado);
 RETURN resultado;
END $function$
;
COMMIT;
