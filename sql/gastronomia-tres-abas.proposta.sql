-- CORREÇÃO PONTUAL DO PACOTE, CONSOLIDADA. NÃO EXECUTADA EM PRODUÇÃO.
-- Substitui a proposta anterior; aplicar somente depois de conferir a base e autorizar.
-- Sem cópia, conversão ou alteração automática de receitas/pedidos/pagamentos existentes.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('private.gastronomia_exigir(text)') IS NULL
 OR to_regprocedure('public.gastronomia_produto_salvar(uuid,uuid,text,text,boolean,jsonb,jsonb)') IS NULL
 OR to_regclass('public.perfis') IS NULL THEN RAISE EXCEPTION 'Base Gastronomia incompatível.'; END IF;
 IF to_regprocedure('public.gastronomia_ferramentas(text,jsonb)') IS NOT NULL
 OR to_regprocedure('public.gastronomia_garcom_vincular(uuid,uuid,text,text)') IS NOT NULL
 OR to_regprocedure('private.gastronomia_garcons_dono(uuid)') IS NOT NULL THEN
  RAISE EXCEPTION 'As ferramentas já existem. Não reinstalar esta proposta.';
 END IF;
END $$;
DO $compatibilidade$ BEGIN
 IF to_regclass('private.gastronomia_composicoes') IS NOT NULL THEN RAISE EXCEPTION 'Composições específicas já instaladas. Não reinstalar.'; END IF;
 IF current_setting('server_version_num')::integer<150000 THEN RAISE EXCEPTION 'Base requer PostgreSQL 15 ou superior.'; END IF;
 IF md5(replace((SELECT prosrc FROM pg_proc WHERE oid='public.gastronomia_produto_salvar(uuid,uuid,text,text,boolean,jsonb,jsonb)'::regprocedure),chr(13),''))<>'867cf9961edfec5a1ef20b5ed752be35' THEN RAISE EXCEPTION 'Base alterada: public.gastronomia_produto_salvar. Conferir antes de aplicar, sem remover a guarda.'; END IF;
 IF md5(replace((SELECT prosrc FROM pg_proc WHERE oid='private.gastronomia_resolver(jsonb,uuid)'::regprocedure),chr(13),''))<>'0cdbd1778ca95d4a1bdca855f4162e8c' THEN RAISE EXCEPTION 'Base alterada: private.gastronomia_resolver. Conferir antes de aplicar, sem remover a guarda.'; END IF;
 IF md5(replace((SELECT prosrc FROM pg_proc WHERE oid='public.gastronomia_rpc(text,jsonb,uuid)'::regprocedure),chr(13),''))<>'3d19b829c12938c946d10dfde8b75038' THEN RAISE EXCEPTION 'Base alterada: public.gastronomia_rpc. Conferir antes de aplicar, sem remover a guarda.'; END IF;
 IF md5(replace((SELECT prosrc FROM pg_proc WHERE oid='public.gastronomia_cardapio_admin(text,jsonb)'::regprocedure),chr(13),''))<>'b499b4f08fe6c587c18c3cd6376e44eb' THEN RAISE EXCEPTION 'Base alterada: public.gastronomia_cardapio_admin. Conferir antes de aplicar, sem remover a guarda.'; END IF;
 IF md5(replace((SELECT prosrc FROM pg_proc WHERE oid='public.gastronomia_cardapio_publico(text,text,jsonb,uuid)'::regprocedure),chr(13),''))<>'f604cf7cccb111ca0e4662431413edd1' THEN RAISE EXCEPTION 'Base alterada: public.gastronomia_cardapio_publico. Conferir antes de aplicar, sem remover a guarda.'; END IF;
END $compatibilidade$;

-- Uma receita específica por produto/empresa/módulo. Não duplica produtos nem converte dados antigos.
CREATE TABLE private.gastronomia_composicoes (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id),
 modulo text NOT NULL DEFAULT 'gastronomia' CHECK(modulo='gastronomia'),
 produto_id uuid NOT NULL,
 tipo text NOT NULL CHECK(tipo IN ('simples','composto')),
 destino_operacional text NOT NULL CHECK(destino_operacional IN ('bar','cozinha','sem_destino')),
 ativo_cardapio boolean NOT NULL DEFAULT true,
 componentes jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(componentes)='array'),
 grupos jsonb NOT NULL DEFAULT '[]' CHECK(jsonb_typeof(grupos)='array'),
 atualizado_em timestamptz NOT NULL DEFAULT now(), atualizado_por uuid,
 PRIMARY KEY(empresa_id,modulo,produto_id),
 FOREIGN KEY(empresa_id,produto_id) REFERENCES public.produtos(empresa_id,id)
);
ALTER TABLE private.gastronomia_composicoes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.gastronomia_composicoes FROM PUBLIC,anon,authenticated;

CREATE VIEW private.gastronomia_produtos_operacionais WITH(security_invoker=true) AS
 SELECT b.id,b.empresa_id,b.produto_id,coalesce(r.tipo,b.tipo) AS tipo,
 coalesce(r.destino_operacional,b.destino_operacional) AS destino_operacional,
 coalesce(r.ativo_cardapio,b.ativo_cardapio) AS ativo_cardapio
 FROM public.bar_produtos b LEFT JOIN private.gastronomia_composicoes r
 ON r.empresa_id=b.empresa_id AND r.produto_id=b.produto_id AND r.modulo='gastronomia';

CREATE VIEW private.gastronomia_componentes_operacionais WITH(security_invoker=true) AS
 SELECT c.id,c.empresa_id,c.bar_produto_id,c.componente_produto_id,c.quantidade,c.baixar_estoque,c.ordem
 FROM public.bar_produtos_componentes c JOIN public.bar_produtos b ON b.id=c.bar_produto_id AND b.empresa_id=c.empresa_id
 WHERE NOT EXISTS(SELECT 1 FROM private.gastronomia_composicoes r WHERE r.empresa_id=b.empresa_id AND r.produto_id=b.produto_id AND r.modulo='gastronomia')
 UNION ALL
 SELECT x.id,r.empresa_id,b.id,x.componente_produto_id,x.quantidade,x.baixar_estoque,x.ordem
 FROM private.gastronomia_composicoes r JOIN public.bar_produtos b ON b.empresa_id=r.empresa_id AND b.produto_id=r.produto_id
 CROSS JOIN LATERAL jsonb_to_recordset(r.componentes) x(id uuid,componente_produto_id uuid,quantidade numeric,baixar_estoque boolean,ordem integer)
 WHERE r.modulo='gastronomia';

CREATE VIEW private.gastronomia_grupos_operacionais WITH(security_invoker=true) AS
 SELECT g.id,g.empresa_id,g.bar_produto_id,g.nome,g.quantidade_escolhas,g.ordem
 FROM public.bar_produto_grupos g JOIN public.bar_produtos b ON b.id=g.bar_produto_id AND b.empresa_id=g.empresa_id
 WHERE NOT EXISTS(SELECT 1 FROM private.gastronomia_composicoes r WHERE r.empresa_id=b.empresa_id AND r.produto_id=b.produto_id AND r.modulo='gastronomia')
 UNION ALL
 SELECT x.id,r.empresa_id,b.id,x.nome,x.quantidade_escolhas,x.ordem
 FROM private.gastronomia_composicoes r JOIN public.bar_produtos b ON b.empresa_id=r.empresa_id AND b.produto_id=r.produto_id
 CROSS JOIN LATERAL jsonb_to_recordset(r.grupos) x(id uuid,nome text,quantidade_escolhas integer,ordem integer)
 WHERE r.modulo='gastronomia';

CREATE VIEW private.gastronomia_opcoes_operacionais WITH(security_invoker=true) AS
 SELECT o.id,o.empresa_id,o.grupo_id,o.produto_id,o.ordem
 FROM public.bar_produto_grupo_opcoes o JOIN public.bar_produto_grupos g ON g.id=o.grupo_id AND g.empresa_id=o.empresa_id
 JOIN public.bar_produtos b ON b.id=g.bar_produto_id AND b.empresa_id=g.empresa_id
 WHERE NOT EXISTS(SELECT 1 FROM private.gastronomia_composicoes r WHERE r.empresa_id=b.empresa_id AND r.produto_id=b.produto_id AND r.modulo='gastronomia')
 UNION ALL
 SELECT o.id,r.empresa_id,g.id,o.produto_id,o.ordem
 FROM private.gastronomia_composicoes r
 CROSS JOIN LATERAL jsonb_to_recordset(r.grupos) g(id uuid,opcoes jsonb)
 CROSS JOIN LATERAL jsonb_to_recordset(g.opcoes) o(id uuid,produto_id uuid,ordem integer)
 WHERE r.modulo='gastronomia';
REVOKE ALL ON TABLE private.gastronomia_produtos_operacionais,private.gastronomia_componentes_operacionais,private.gastronomia_grupos_operacionais,private.gastronomia_opcoes_operacionais FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.gastronomia_produto_salvar(p_id uuid, p_produto_id uuid, p_tipo text, p_destino_operacional text, p_ativo_cardapio boolean, p_componentes jsonb DEFAULT NULL::jsonb, p_grupos jsonb DEFAULT NULL::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa    uuid := private.exigir_empresa_ativa();
  v_id         uuid;
  v_tipo       text := lower(btrim(coalesce(p_tipo, '')));
  v_destino    text := lower(btrim(coalesce(p_destino_operacional, '')));
  v_invalido   boolean;
  v_grupo      record;
  v_grupo_id   uuid;
  v_componentes_isolados jsonb; v_grupos_isolados jsonb; v_opcoes_isoladas jsonb;
begin
  if not private.empresa_tem_modulo('gastronomia') then
    raise exception 'Este recurso exige o módulo Gastronomia ativo para esta empresa.' using errcode = '42501';
  end if;
  if not private.perm('gastronomia_configurar') then
    raise exception 'Você não tem permissão para configurar o cardápio do bar.' using errcode = '42501';
  end if;

  PERFORM 1 FROM public.gastronomia_configuracoes cfg WHERE cfg.empresa_id=v_empresa FOR UPDATE;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_empresa::text||':gastronomia:composicao:'||p_produto_id::text,0));
  if v_tipo not in ('simples', 'composto') then
    raise exception 'Tipo de item do cardápio inválido.';
  end if;
  if p_produto_id is null or not exists (
       select 1 from public.produtos pr where pr.id = p_produto_id and pr.empresa_id = v_empresa
     ) then
    raise exception 'Produto do catálogo não encontrado.';
  end if;

  -- CORREÇÃO (revisão de segurança pré-produção): com o auto-provisionamento desta mesma migration
  -- (seção 6), TODO produto já nasce com uma linha em bar_produtos (tipo simples, sem_destino) — ou
  -- seja, ao contrário da Migration 016, quando o dono clica em "+ Criar produto composto" e escolhe
  -- um produto do catálogo, quase sempre JÁ existe uma linha bar_produtos para aquele produto_id
  -- (a auto-provisionada). O frontend, ao criar, sempre manda p_id = null (não sabe o id da linha
  -- auto-provisionada). Sem este ajuste, o bloco abaixo bloquearia TODA criação de composto com a
  -- mensagem "Este produto já está cadastrado no cardápio do bar" (e, se não bloqueasse, o INSERT
  -- mais abaixo ainda falharia por violar bar_produtos_empresa_produto_key, o unique(empresa_id,
  -- produto_id) da Migration 016). A correção resolve isto de forma transparente: se p_id não foi
  -- informado mas já existe uma linha para este produto_id (o caso normal, pós auto-provisionamento),
  -- passamos a EDITAR essa linha existente em vez de tentar inserir uma segunda — exatamente o que o
  -- dono espera ("converter este produto em composto"), sem exigir que o frontend descubra o id da
  -- linha auto-provisionada antes de chamar esta função.
  if p_id is null then
    select bp.id into p_id from private.gastronomia_produtos_operacionais bp
     where bp.empresa_id = v_empresa and bp.produto_id = p_produto_id;
  end if;

  if exists (
       select 1 from private.gastronomia_produtos_operacionais bp
        where bp.empresa_id = v_empresa and bp.produto_id = p_produto_id and bp.id <> coalesce(p_id, '00000000-0000-0000-0000-000000000000'::uuid)
     ) then
    raise exception 'Este produto já está cadastrado no cardápio do bar.';
  end if;

  if v_tipo = 'simples' then
    -- Item simples: destino é o que o dono escolheu (tela "Destino dos Produtos", individual ou
    -- em lote — ver bar_produtos_definir_destino_em_lote).
    if v_destino not in ('bar', 'cozinha', 'sem_destino') then
      raise exception 'Destino operacional inválido.';
    end if;
    if p_componentes is not null or p_grupos is not null then
      raise exception 'Um item simples não pode ter componentes nem grupos de escolha.';
    end if;
  else
    -- Item composto: destino NUNCA é fixo aqui (requisito #6) — é sempre determinado pelos
    -- produtos físicos efetivamente escolhidos no lançamento do pedido (ver bar_pedido_enviar).
    -- p_destino_operacional é ignorado de propósito para composto.
    v_destino := 'sem_destino';
    if (p_componentes is not null) = (p_grupos is not null) then
      raise exception 'Um item composto precisa de componentes (modelo antigo) OU de grupos de escolha (modelo novo) — nunca os dois, nem nenhum.';
    end if;

    if p_componentes is not null then
      -- Modelo antigo (Migration 016) — mantido tal e qual, só para edição de itens já existentes.
      if jsonb_typeof(p_componentes) <> 'array' or jsonb_array_length(p_componentes) = 0 then
        raise exception 'Um item composto precisa de pelo menos um componente.';
      end if;
      if jsonb_array_length(p_componentes) > 100 then
        raise exception 'Componentes demais em um único item (máximo 100).';
      end if;
      begin
        select exists (
          select 1 from jsonb_to_recordset(p_componentes) as x(componente_produto_id uuid, quantidade numeric, baixar_estoque boolean, ordem integer)
           where x.componente_produto_id is null or x.quantidade is null or x.quantidade <= 0
        ) into v_invalido;
      exception when others then
        v_invalido := true;
      end;
      if v_invalido then
        raise exception 'Componente inválido (produto e quantidade maior que zero são obrigatórios).';
      end if;
      if exists (
           select componente_produto_id
             from jsonb_to_recordset(p_componentes) as x(componente_produto_id uuid, quantidade numeric, baixar_estoque boolean, ordem integer)
            group by componente_produto_id having count(*) > 1
         ) then
        raise exception 'Um componente não pode aparecer duas vezes na mesma lista.';
      end if;
      if exists (
           select 1 from jsonb_to_recordset(p_componentes) as x(componente_produto_id uuid, quantidade numeric, baixar_estoque boolean, ordem integer)
            where x.componente_produto_id = p_produto_id
         ) then
        raise exception 'Um item composto não pode ter a si mesmo como componente.';
      end if;
      if exists (
           select 1 from jsonb_to_recordset(p_componentes) as x(componente_produto_id uuid, quantidade numeric, baixar_estoque boolean, ordem integer)
            where not exists (select 1 from public.produtos pr where pr.id = x.componente_produto_id and pr.empresa_id = v_empresa)
         ) then
        raise exception 'Um ou mais componentes não correspondem a produtos do catálogo desta empresa.';
      end if;
      -- CORREÇÃO (revisão de segurança pré-produção): um componente precisa ser sempre um produto
      -- FÍSICO (requisito #1/#3 — "produtos físicos já cadastrados"), nunca outro item composto. Sem
      -- esta checagem seria possível aninhar um composto dentro de outro (ex.: usar "Jantinha" como
      -- componente do "Combo Família"); o backend trataria esse componente como se fosse um produto
      -- de estoque simples e daria baixa direta em produtos.quantidade_estoque do composto aninhado
      -- (que normalmente não é controlado como estoque), em vez de expandir recursivamente a receita
      -- dele — corrompendo silenciosamente o estoque e os dois relatórios.
      if exists (
           select 1 from jsonb_to_recordset(p_componentes) as x(componente_produto_id uuid, quantidade numeric, baixar_estoque boolean, ordem integer)
            join private.gastronomia_produtos_operacionais bp2 on bp2.produto_id = x.componente_produto_id and bp2.empresa_id = v_empresa
           where bp2.tipo = 'composto'
         ) then
        raise exception 'Um componente precisa ser um produto físico simples — um item composto (ex.: outra Jantinha ou Combo) não pode ser componente de outro composto.';
      end if;
    else
      -- Modelo novo (requisito #5): p_grupos = array de
      --   { "nome": text, "quantidade_escolhas": int, "ordem": int,
      --     "opcoes": [ { "produto_id": uuid, "ordem": int }, ... ] }
      if jsonb_typeof(p_grupos) <> 'array' or jsonb_array_length(p_grupos) = 0 then
        raise exception 'Um produto composto precisa de pelo menos um grupo de escolha (ex.: "Escolha o espeto").';
      end if;
      if jsonb_array_length(p_grupos) > 20 then
        raise exception 'Grupos de escolha demais em um único produto composto (máximo 20).';
      end if;
      begin
        select exists (
          select 1 from jsonb_to_recordset(p_grupos) as g(nome text, quantidade_escolhas integer, ordem integer, opcoes jsonb)
           where g.nome is null or length(btrim(g.nome)) = 0
              or g.opcoes is null or jsonb_typeof(g.opcoes) <> 'array' or jsonb_array_length(g.opcoes) = 0
        ) into v_invalido;
      exception when others then
        v_invalido := true;
      end;
      if v_invalido then
        raise exception 'Grupo de escolha inválido (nome e ao menos uma opção são obrigatórios).';
      end if;
      if exists (
           select 1 from jsonb_to_recordset(p_grupos) as g(nome text, quantidade_escolhas integer, ordem integer, opcoes jsonb)
            where coalesce(g.quantidade_escolhas, 1) < 1 or coalesce(g.quantidade_escolhas, 1) > jsonb_array_length(g.opcoes)
         ) then
        raise exception 'A quantidade de escolhas de um grupo não pode ser menor que 1 nem maior que o número de opções cadastradas nele.';
      end if;
      begin
        select exists (
          select 1
            from jsonb_to_recordset(p_grupos) as g(nome text, quantidade_escolhas integer, ordem integer, opcoes jsonb)
            cross join lateral jsonb_to_recordset(g.opcoes) as op(produto_id uuid, ordem integer)
           where op.produto_id is null
              or op.produto_id = p_produto_id
              or not exists (select 1 from public.produtos pr where pr.id = op.produto_id and pr.empresa_id = v_empresa)
        ) into v_invalido;
      exception when others then
        v_invalido := true;
      end;
      if v_invalido then
        raise exception 'Uma ou mais opções de grupo são inválidas, não correspondem a produtos do catálogo desta empresa, ou referenciam o próprio produto composto.';
      end if;
      -- CORREÇÃO (revisão de segurança pré-produção): mesma proteção do modelo antigo de componentes,
      -- aplicada às opções de um grupo — uma opção precisa ser sempre um produto FÍSICO, nunca outro
      -- item composto (evita compostos aninhados e a corrupção de estoque/relatórios descrita acima).
      if exists (
           select 1
             from jsonb_to_recordset(p_grupos) as g(nome text, quantidade_escolhas integer, ordem integer, opcoes jsonb)
             cross join lateral jsonb_to_recordset(g.opcoes) as op(produto_id uuid, ordem integer)
             join private.gastronomia_produtos_operacionais bp2 on bp2.produto_id = op.produto_id and bp2.empresa_id = v_empresa
            where bp2.tipo = 'composto'
         ) then
        raise exception 'Uma opção de grupo precisa ser um produto físico simples — um item composto (ex.: outra Jantinha ou Combo) não pode ser opção de escolha de outro composto.';
      end if;
      if exists (
           select 1
             from jsonb_to_recordset(p_grupos) as g(nome text, quantidade_escolhas integer, ordem integer, opcoes jsonb)
             cross join lateral jsonb_to_recordset(g.opcoes) as op(produto_id uuid, ordem integer)
            group by g.nome, op.produto_id
           having count(*) > 1
         ) then
        raise exception 'Uma opção não pode aparecer duas vezes no mesmo grupo.';
      end if;
    end if;
  end if;

  if v_tipo = 'composto' then   -- [046:bar_produto_salvar]
    perform private.produtos_exigir_ativos(v_empresa, (
      select array_agg(z.pid) from (
        select x.componente_produto_id as pid
          from jsonb_to_recordset(coalesce(p_componentes, '[]'::jsonb)) as x(componente_produto_id uuid)
        union all
        select op.produto_id
          from jsonb_to_recordset(coalesce(p_grupos, '[]'::jsonb)) as g(opcoes jsonb)
          cross join lateral jsonb_to_recordset(g.opcoes) as op(produto_id uuid)) z));
  end if;
  -- Grava somente a receita da Gastronomia; os registros do Bar não são alterados.
  SELECT b.id INTO v_id FROM public.bar_produtos b WHERE b.empresa_id=v_empresa AND b.produto_id=p_produto_id AND b.id=p_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'Produto-base da operação não encontrado. Atualize o cadastro antes de salvar.'; END IF;
  IF v_tipo='composto' AND (SELECT b.tipo FROM private.gastronomia_produtos_operacionais b WHERE b.empresa_id=v_empresa AND b.id=v_id)='simples'
   AND (EXISTS(SELECT 1 FROM private.gastronomia_componentes_operacionais c WHERE c.empresa_id=v_empresa AND c.componente_produto_id=p_produto_id)
   OR EXISTS(SELECT 1 FROM private.gastronomia_opcoes_operacionais o WHERE o.empresa_id=v_empresa AND o.produto_id=p_produto_id)) THEN
   RAISE EXCEPTION 'Produto já utilizado como componente de outra receita da Gastronomia. Não criar composição aninhada.';
  END IF;
  v_componentes_isolados:='[]'::jsonb;v_grupos_isolados:='[]'::jsonb;
  IF v_tipo='composto' AND p_componentes IS NOT NULL THEN
   SELECT coalesce(jsonb_agg(jsonb_build_object('id',gen_random_uuid(),'componente_produto_id',x.componente_produto_id,'quantidade',x.quantidade,'baixar_estoque',coalesce(x.baixar_estoque,true),'ordem',coalesce(x.ordem,0)) ORDER BY coalesce(x.ordem,0)),'[]') INTO v_componentes_isolados
   FROM jsonb_to_recordset(p_componentes) x(componente_produto_id uuid,quantidade numeric,baixar_estoque boolean,ordem integer);
  ELSIF v_tipo='composto' AND p_grupos IS NOT NULL THEN
   FOR v_grupo IN SELECT g.nome,coalesce(g.quantidade_escolhas,1) quantidade_escolhas,coalesce(g.ordem,0) ordem,g.opcoes FROM jsonb_to_recordset(p_grupos) g(nome text,quantidade_escolhas integer,ordem integer,opcoes jsonb) ORDER BY coalesce(g.ordem,0) LOOP
    -- Conserva a identidade lógica do grupo para manter suas regras no Cardápio.
    SELECT g.id INTO v_grupo_id FROM private.gastronomia_grupos_operacionais g
     WHERE g.empresa_id=v_empresa AND g.bar_produto_id=v_id AND g.ordem=v_grupo.ordem
     ORDER BY (g.nome=btrim(v_grupo.nome)) DESC,g.id LIMIT 1;
    v_grupo_id:=coalesce(v_grupo_id,gen_random_uuid());
    SELECT coalesce(jsonb_agg(jsonb_build_object('id',gen_random_uuid(),'produto_id',o.produto_id,'ordem',coalesce(o.ordem,0)) ORDER BY coalesce(o.ordem,0)),'[]') INTO v_opcoes_isoladas FROM jsonb_to_recordset(v_grupo.opcoes) o(produto_id uuid,ordem integer);
    v_grupos_isolados:=v_grupos_isolados||jsonb_build_array(jsonb_build_object('id',v_grupo_id,'nome',btrim(v_grupo.nome),'quantidade_escolhas',v_grupo.quantidade_escolhas,'ordem',v_grupo.ordem,'opcoes',v_opcoes_isoladas));
   END LOOP;
  END IF;
  INSERT INTO private.gastronomia_composicoes(empresa_id,modulo,produto_id,tipo,destino_operacional,ativo_cardapio,componentes,grupos,atualizado_por)
  VALUES(v_empresa,'gastronomia',p_produto_id,v_tipo,v_destino,coalesce(p_ativo_cardapio,true),v_componentes_isolados,v_grupos_isolados,auth.uid())
  ON CONFLICT(empresa_id,modulo,produto_id) DO UPDATE SET tipo=excluded.tipo,destino_operacional=excluded.destino_operacional,ativo_cardapio=excluded.ativo_cardapio,componentes=excluded.componentes,grupos=excluded.grupos,atualizado_em=now(),atualizado_por=auth.uid();

  return v_id;
end;
$function$;
DO $adaptar$
DECLARE original text;
BEGIN
 original:=pg_get_functiondef('private.gastronomia_resolver(jsonb,uuid)'::regprocedure);
 original:=replace(original,'public.bar_produto_grupo_opcoes','private.gastronomia_opcoes_operacionais');
 original:=replace(original,'public.bar_produtos_componentes','private.gastronomia_componentes_operacionais');
 original:=replace(original,'public.bar_produto_grupos','private.gastronomia_grupos_operacionais');
 original:=replace(original,'public.bar_produtos','private.gastronomia_produtos_operacionais');
 IF position('CREATE OR REPLACE FUNCTION private.gastronomia_resolver(' in original)<>1 THEN RAISE EXCEPTION 'Definição incompatível: private.gastronomia_resolver.'; END IF;
 EXECUTE original;
 original:=pg_get_functiondef('public.gastronomia_rpc(text,jsonb,uuid)'::regprocedure);
 original:=replace(original,'public.bar_produto_grupo_opcoes','private.gastronomia_opcoes_operacionais');
 original:=replace(original,'public.bar_produtos_componentes','private.gastronomia_componentes_operacionais');
 original:=replace(original,'public.bar_produto_grupos','private.gastronomia_grupos_operacionais');
 original:=replace(original,'public.bar_produtos','private.gastronomia_produtos_operacionais');
 IF position('CREATE OR REPLACE FUNCTION public.gastronomia_rpc(' in original)<>1 THEN RAISE EXCEPTION 'Definição incompatível: public.gastronomia_rpc.'; END IF;
 EXECUTE original;
 original:=pg_get_functiondef('public.gastronomia_cardapio_admin(text,jsonb)'::regprocedure);
 original:=replace(original,'public.bar_produto_grupo_opcoes','private.gastronomia_opcoes_operacionais');
 original:=replace(original,'public.bar_produtos_componentes','private.gastronomia_componentes_operacionais');
 original:=replace(original,'public.bar_produto_grupos','private.gastronomia_grupos_operacionais');
 original:=replace(original,'public.bar_produtos','private.gastronomia_produtos_operacionais');
 original:=replace(original,$antes$SELECT * INTO r FROM private.gastronomia_produtos_operacionais WHERE produto_id=(d->>'produto_id')::uuid AND empresa_id=e FOR UPDATE;$antes$,$depois$SELECT * INTO r FROM private.gastronomia_produtos_operacionais WHERE produto_id=(d->>'produto_id')::uuid AND empresa_id=e;$depois$);
 IF position('CREATE OR REPLACE FUNCTION public.gastronomia_cardapio_admin(' in original)<>1 THEN RAISE EXCEPTION 'Definição incompatível: public.gastronomia_cardapio_admin.'; END IF;
 EXECUTE original;
 original:=pg_get_functiondef('public.gastronomia_cardapio_publico(text,text,jsonb,uuid)'::regprocedure);
 original:=replace(original,'public.bar_produto_grupo_opcoes','private.gastronomia_opcoes_operacionais');
 original:=replace(original,'public.bar_produtos_componentes','private.gastronomia_componentes_operacionais');
 original:=replace(original,'public.bar_produto_grupos','private.gastronomia_grupos_operacionais');
 original:=replace(original,'public.bar_produtos','private.gastronomia_produtos_operacionais');
 IF position('CREATE OR REPLACE FUNCTION public.gastronomia_cardapio_publico(' in original)<>1 THEN RAISE EXCEPTION 'Definição incompatível: public.gastronomia_cardapio_publico.'; END IF;
 EXECUTE original;
END $adaptar$;



CREATE FUNCTION private.gastronomia_garcons_dono(p_ator uuid) RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid;
BEGIN
 SELECT p.empresa_id INTO e FROM public.perfis p JOIN public.empresas em ON em.id=p.empresa_id
 WHERE p.id=p_ator AND p.ativo AND p.papel='proprietario'
 AND em.status_conta='aprovado' AND NOT em.bloqueado
 AND EXISTS(SELECT 1 FROM public.empresa_modulos m WHERE m.empresa_id=p.empresa_id AND m.modulo='gastronomia' AND m.ativo);
 IF e IS NULL THEN RAISE EXCEPTION 'Somente o proprietário ativo da Gastronomia pode gerenciar garçons.' USING ERRCODE='42501'; END IF;
 RETURN e;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_garcons_dono(uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.gastronomia_garcom_vincular(p_ator uuid,p_user_id uuid,p_nome text,p_usuario text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.gastronomia_garcons_dono(p_ator); v_nome text:=btrim(coalesce(p_nome,'')); v_usuario text:=lower(btrim(coalesce(p_usuario,'')));
BEGIN
 IF length(v_nome) NOT BETWEEN 2 AND 200 OR v_usuario !~ '^\S{2,60}$' THEN RAISE EXCEPTION 'Informe nome de 2 a 200 caracteres e usuário sem espaços de 2 a 60 caracteres.'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':gastronomia:garcons',0));
 IF NOT EXISTS(SELECT 1 FROM auth.users u WHERE u.id=p_user_id
  AND u.raw_app_meta_data->>'gastronomia_garcom_empresa'=e::text
  AND u.raw_app_meta_data->>'gastronomia_garcom_ator'=p_ator::text) THEN
  RAISE EXCEPTION 'Login não criado para este cadastro da Gastronomia.' USING ERRCODE='42501';
 END IF;
 IF EXISTS(SELECT 1 FROM public.perfis p WHERE p.id=p_user_id) THEN
  IF EXISTS(SELECT 1 FROM public.perfis p WHERE p.id=p_user_id AND p.empresa_id=e AND p.criado_por=p_ator AND p.tipo_acesso='garcom' AND p.usuario=v_usuario) THEN RETURN p_user_id; END IF;
  RAISE EXCEPTION 'Login já vinculado. Nenhum cadastro existente será transferido.';
 END IF;
 IF (SELECT count(*) FROM public.perfis p WHERE p.empresa_id=e AND p.papel='funcionario')>=50 THEN RAISE EXCEPTION 'Limite de 50 funcionários por empresa atingido.'; END IF;
 IF EXISTS(SELECT 1 FROM public.perfis p WHERE p.empresa_id=e AND lower(p.usuario)=v_usuario) THEN RAISE EXCEPTION 'Este usuário já existe nesta empresa.'; END IF;
 INSERT INTO public.perfis(id,empresa_id,nome,usuario,papel,permissoes,ativo,criado_por,tipo_acesso)
 VALUES(p_user_id,e,v_nome,v_usuario,'funcionario',ARRAY['gastronomia_visualizar','gastronomia_mesas','gastronomia_pedidos'],true,p_ator,'garcom');
 RETURN p_user_id;
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_garcom_vincular(uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.gastronomia_garcom_vincular(uuid,uuid,text,text) TO service_role;

CREATE FUNCTION public.gastronomia_ferramentas(p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid; d jsonb:=coalesce(p_dados,'{}'); alvo uuid; r jsonb; bp record;
 v_nome text; v_usuario text; pagina integer:=coalesce((d->>'pagina')::integer,0); compartilhado boolean;
 permiss text[]:=ARRAY['gastronomia_visualizar','gastronomia_mesas','gastronomia_pedidos'];
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sessão expirada.' USING ERRCODE='28000'; END IF;
 IF octet_length(d::text)>50000 OR pagina<0 OR pagina>100000 THEN RAISE EXCEPTION 'Solicitação inválida.'; END IF;
 IF p_acao IN ('g_autorizar','g_listar','g_salvar','g_ativo') THEN
  e:=private.gastronomia_garcons_dono(auth.uid());
 ELSIF p_acao IN ('c_listar','c_salvar','c_ativo') THEN e:=private.gastronomia_exigir('gastronomia_configurar');
 ELSIF p_acao IN ('h_listar','h_detalhar') THEN e:=private.gastronomia_exigir('gastronomia_caixa');
 ELSE RAISE EXCEPTION 'Ação não permitida.'; END IF;
 IF d->>'empresa_esperada' IS NOT NULL AND d->>'empresa_esperada'<>e::text THEN RAISE EXCEPTION 'A empresa da sessão mudou.' USING ERRCODE='42501'; END IF;

 IF p_acao='g_autorizar' THEN RETURN jsonb_build_object('empresa_id',e);
 ELSIF p_acao='g_listar' THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nome',p.nome,'usuario',p.usuario,'ativo',p.ativo,
   'editavel',p.permissoes<@permiss) ORDER BY lower(p.nome),p.id),'[]') INTO r
  FROM public.perfis p WHERE p.empresa_id=e AND p.tipo_acesso='garcom' AND p.papel='funcionario' AND p.permissoes@>permiss;
  RETURN jsonb_build_object('empresa_id',e,'itens',r);
 ELSIF p_acao IN ('g_salvar','g_ativo') THEN
  alvo:=(d->>'id')::uuid;
  PERFORM 1 FROM public.perfis p WHERE p.id=alvo AND p.empresa_id=e AND p.papel='funcionario' AND p.tipo_acesso='garcom'
   AND p.permissoes@>permiss AND p.permissoes<@permiss FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Garçom não encontrado ou cadastro compartilhado protegido.' USING ERRCODE='42501'; END IF;
  IF p_acao='g_salvar' THEN
   v_nome:=btrim(coalesce(d->>'nome',''));v_usuario:=lower(btrim(coalesce(d->>'usuario','')));
   IF length(v_nome) NOT BETWEEN 2 AND 200 OR v_usuario !~ '^\S{2,60}$' THEN RAISE EXCEPTION 'Nome ou usuário inválido.'; END IF;
   IF EXISTS(SELECT 1 FROM public.perfis p WHERE p.empresa_id=e AND lower(p.usuario)=v_usuario AND p.id<>alvo) THEN RAISE EXCEPTION 'Este usuário já existe nesta empresa.'; END IF;
   UPDATE public.perfis SET nome=v_nome,usuario=v_usuario WHERE id=alvo AND empresa_id=e;
  ELSE
   IF jsonb_typeof(d->'ativo') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Situação inválida.'; END IF;
   UPDATE public.perfis SET ativo=(d->>'ativo')::boolean WHERE id=alvo AND empresa_id=e;
  END IF;
  RETURN jsonb_build_object('ok',true,'id',alvo);
 ELSIF p_acao='c_listar' THEN
  SELECT coalesce(jsonb_agg(doc ORDER BY doc->>'nome'),'[]') INTO r FROM (
   SELECT to_jsonb(b)||jsonb_build_object('nome',p.nome,'preco',p.preco_venda,'fonte',CASE WHEN EXISTS(SELECT 1 FROM private.gastronomia_composicoes r WHERE r.empresa_id=e AND r.produto_id=p.id AND r.modulo='gastronomia') THEN 'gastronomia' ELSE 'legado' END,
    'publicado',EXISTS(SELECT 1 FROM public.gastronomia_configuracoes cfg CROSS JOIN LATERAL jsonb_array_elements(coalesce(cfg.opcoes#>'{cardapio,produtos}','[]')) x WHERE cfg.empresa_id=e AND x->>'id'=p.id::text AND coalesce((x->>'ativo')::boolean,true)),
    'componentes',(SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.ordem),'[]') FROM private.gastronomia_componentes_operacionais c WHERE c.empresa_id=e AND c.bar_produto_id=b.id),
    'grupos',(SELECT coalesce(jsonb_agg(to_jsonb(g)||jsonb_build_object('minimo',coalesce((SELECT (cfg.opcoes#>>ARRAY['cardapio','regras_grupos',g.id::text,'minimo'])::integer FROM public.gastronomia_configuracoes cfg WHERE cfg.empresa_id=e),g.quantidade_escolhas),'maximo',coalesce((SELECT (cfg.opcoes#>>ARRAY['cardapio','regras_grupos',g.id::text,'maximo'])::integer FROM public.gastronomia_configuracoes cfg WHERE cfg.empresa_id=e),g.quantidade_escolhas),'opcoes',(SELECT coalesce(jsonb_agg(to_jsonb(o) ORDER BY o.ordem),'[]') FROM private.gastronomia_opcoes_operacionais o WHERE o.empresa_id=e AND o.grupo_id=g.id)) ORDER BY g.ordem),'[]') FROM private.gastronomia_grupos_operacionais g WHERE g.empresa_id=e AND g.bar_produto_id=b.id)) doc
   FROM private.gastronomia_produtos_operacionais b JOIN public.produtos p ON p.id=b.produto_id AND p.empresa_id=e
   WHERE b.empresa_id=e AND b.tipo='composto' AND position(lower(left(coalesce(d->>'busca',''),100)) in lower(p.nome))>0
   ORDER BY lower(p.nome),b.id LIMIT 50 OFFSET pagina*50
  ) t;
  RETURN jsonb_build_object('empresa_id',e,'itens',r,'receitas_isoladas',true,'catalogo',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nome',p.nome,'preco_venda',p.preco_venda,'tipo',b.tipo,'bar_produto_id',b.id) ORDER BY p.nome,p.id),'[]') FROM public.produtos p JOIN private.gastronomia_produtos_operacionais b ON b.produto_id=p.id AND b.empresa_id=e WHERE p.empresa_id=e AND p.ativo),'pagina',pagina,'tem_mais',jsonb_array_length(r)=50);
 ELSIF p_acao IN ('c_salvar','c_ativo') THEN
  alvo:=(d->>'produto_id')::uuid;
  PERFORM 1 FROM public.produtos p WHERE p.id=alvo AND p.empresa_id=e FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Produto não encontrado nesta empresa.'; END IF;
  SELECT * INTO bp FROM private.gastronomia_produtos_operacionais b WHERE b.empresa_id=e AND b.produto_id=alvo;
  IF d->>'id' IS NOT NULL AND (bp.id IS NULL OR bp.id<>(d->>'id')::uuid) THEN RAISE EXCEPTION 'A configuração mudou. Reabra o produto.'; END IF;
  IF p_acao='c_salvar' AND bp.tipo='composto' AND d->>'id' IS NULL THEN RAISE EXCEPTION 'O produto já possui composição. Abra a edição pelo registro existente.'; END IF;
  IF p_acao='c_ativo' THEN
   IF bp.id IS NULL OR bp.tipo<>'composto' OR jsonb_typeof(d->'ativo') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'Produto composto ou situação inválida.'; END IF;
   PERFORM public.gastronomia_produto_salvar(bp.id,alvo,'composto',bp.destino_operacional,(d->>'ativo')::boolean,
    CASE WHEN EXISTS(SELECT 1 FROM private.gastronomia_grupos_operacionais g WHERE g.empresa_id=e AND g.bar_produto_id=bp.id) THEN NULL ELSE (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.ordem),'[]') FROM private.gastronomia_componentes_operacionais x WHERE x.empresa_id=e AND x.bar_produto_id=bp.id) END,
    CASE WHEN EXISTS(SELECT 1 FROM private.gastronomia_grupos_operacionais g WHERE g.empresa_id=e AND g.bar_produto_id=bp.id) THEN (SELECT jsonb_agg(to_jsonb(g)||jsonb_build_object('opcoes',(SELECT jsonb_agg(to_jsonb(o) ORDER BY o.ordem) FROM private.gastronomia_opcoes_operacionais o WHERE o.empresa_id=e AND o.grupo_id=g.id)) ORDER BY g.ordem) FROM private.gastronomia_grupos_operacionais g WHERE g.empresa_id=e AND g.bar_produto_id=bp.id) ELSE NULL END);
   RETURN jsonb_build_object('ok',true,'id',bp.id);
  END IF;
  IF bp.tipo IS DISTINCT FROM 'composto' AND (EXISTS(SELECT 1 FROM private.gastronomia_componentes_operacionais c WHERE c.empresa_id=e AND c.componente_produto_id=alvo) OR EXISTS(SELECT 1 FROM private.gastronomia_opcoes_operacionais o WHERE o.empresa_id=e AND o.produto_id=alvo)) THEN RAISE EXCEPTION 'Este produto já é componente de outra receita. Não converter em composto.'; END IF;
  PERFORM public.gastronomia_cardapio_admin('composicao',jsonb_build_object('produto_id',alvo,'tipo','composto','componentes',d->'componentes','grupos',d->'grupos'));
  alvo:=bp.id;
  RETURN jsonb_build_object('ok',true,'id',alvo);
 ELSIF p_acao='h_listar' THEN
  IF nullif(d->>'inicio','')::date>nullif(d->>'fim','')::date THEN RAISE EXCEPTION 'Período inválido.'; END IF;
  SELECT coalesce(jsonb_agg(doc ORDER BY (doc->>'numero_venda')::bigint DESC),'[]') INTO r FROM (
   SELECT to_jsonb(v)||jsonb_build_object('atendimento_id',a.id,'mesa_numero',m.numero,'cliente_nome',a.cliente_nome,'canal',a.tipo,
    'situacao',CASE WHEN v.cancelada_em IS NOT NULL THEN 'Cancelada' WHEN a.estado='em_ajuste' THEN 'Em ajuste' WHEN a.estado='aberto' THEN 'Em aberto' ELSE 'Concluída' END) doc
   FROM public.vendas v JOIN public.gastronomia_atendimentos a ON a.venda_id=v.id AND a.empresa_id=e
   LEFT JOIN public.gastronomia_mesas m ON m.id=a.mesa_id AND m.empresa_id=e
   WHERE v.empresa_id=e AND v.tipo='gastronomia'
   AND (nullif(d->>'numero','') IS NULL OR v.numero_venda=(d->>'numero')::bigint)
   AND (nullif(d->>'mesa','') IS NULL OR m.numero=(d->>'mesa')::integer)
   AND position(lower(left(coalesce(d->>'cliente',''),100)) in lower(coalesce(a.cliente_nome,'')))>0
   AND (nullif(d->>'inicio','') IS NULL OR v.criado_em>=((d->>'inicio')::date::timestamp AT TIME ZONE 'America/Sao_Paulo'))
   AND (nullif(d->>'fim','') IS NULL OR v.criado_em<(((d->>'fim')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo'))
   AND (coalesce(d->>'status','')='' OR d->>'status'=CASE WHEN v.cancelada_em IS NOT NULL THEN 'Cancelada' WHEN a.estado='em_ajuste' THEN 'Em ajuste' WHEN a.estado='aberto' THEN 'Em aberto' ELSE 'Concluída' END)
   ORDER BY v.numero_venda DESC LIMIT 50 OFFSET pagina*50
  ) t;
  RETURN jsonb_build_object('empresa_id',e,'itens',r,'pagina',pagina,'tem_mais',jsonb_array_length(r)=50);
 ELSIF p_acao='h_detalhar' THEN
  alvo:=(d->>'id')::uuid;
  SELECT jsonb_build_object('venda',to_jsonb(v),'atendimento',to_jsonb(a)||jsonb_build_object('mesa_numero',m.numero),
   'itens',(SELECT coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('nome',p.nome) ORDER BY i.id),'[]') FROM public.itens_venda i LEFT JOIN public.produtos p ON p.id=i.produto_id AND p.empresa_id=e WHERE i.venda_id=v.id AND i.empresa_id=e),
   'pagamentos',(SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.criado_em,g.id),'[]') FROM public.gastronomia_pagamentos g WHERE g.atendimento_id=a.id AND g.empresa_id=e)) INTO r
  FROM public.vendas v JOIN public.gastronomia_atendimentos a ON a.venda_id=v.id AND a.empresa_id=e LEFT JOIN public.gastronomia_mesas m ON m.id=a.mesa_id AND m.empresa_id=e
  WHERE v.id=alvo AND v.empresa_id=e AND v.tipo='gastronomia';
  IF r IS NULL THEN RAISE EXCEPTION 'Venda não encontrada nesta empresa.' USING ERRCODE='42501'; END IF;
  RETURN r;
 END IF;
 RAISE EXCEPTION 'Ação não permitida.';
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_ferramentas(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_ferramentas(text,jsonb) TO authenticated;
COMMIT;

