BEGIN;

DO $g$ BEGIN IF md5(regexp_replace(replace(pg_get_functiondef('private.rotisseria_rpc(text,jsonb,uuid)'::regprocedure),chr(13)||chr(10),chr(10)),'[[:space:]]+$',''))<>'0863124ba9f2873116da9b4af053fd41' THEN RAISE EXCEPTION 'Base alterada: private.rotisseria_rpc(text,jsonb,uuid). Recompare antes de aplicar.';END IF;END $g$;

DO $g$ BEGIN IF md5(regexp_replace(replace(pg_get_functiondef('private.rotisseria_receber(jsonb,uuid)'::regprocedure),chr(13)||chr(10),chr(10)),'[[:space:]]+$',''))<>'a781fb5425e03be04d8a8b80211f6ead' THEN RAISE EXCEPTION 'Base alterada: private.rotisseria_receber(jsonb,uuid). Recompare antes de aplicar.';END IF;END $g$;

CREATE TABLE private.rotisseria_catalogo(
 id uuid PRIMARY KEY,empresa_id uuid NOT NULL REFERENCES public.empresas(id),produto_id uuid NOT NULL,
 tipo text NOT NULL CHECK(tipo IN ('combo','composto')),modelo text NOT NULL CHECK(modelo IN ('fixo','escolhas')),
 descricao text NOT NULL DEFAULT '' CHECK(length(descricao)<=3000),componentes jsonb NOT NULL DEFAULT '[]',grupos jsonb NOT NULL DEFAULT '[]',
 ativo boolean NOT NULL DEFAULT true,versao integer NOT NULL DEFAULT 1,ultima_solicitacao jsonb NOT NULL,
 criado_por uuid NOT NULL REFERENCES public.perfis(id),atualizado_em timestamptz NOT NULL DEFAULT clock_timestamp(),
 UNIQUE(empresa_id,id),UNIQUE(empresa_id,produto_id),FOREIGN KEY(empresa_id,produto_id) REFERENCES public.produtos(empresa_id,id),
 CHECK(jsonb_typeof(componentes)='array' AND jsonb_typeof(grupos)='array' AND octet_length(componentes::text)+octet_length(grupos::text)<200000));
CREATE INDEX rotisseria_catalogo_lista ON private.rotisseria_catalogo(empresa_id,tipo,id);
ALTER TABLE private.rotisseria_catalogo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.rotisseria_catalogo FROM PUBLIC,anon,authenticated;
CREATE TABLE private.rotisseria_fotos(empresa_id uuid NOT NULL,produto_id uuid NOT NULL,foto text NOT NULL CHECK(length(foto)<=100000 AND (foto='' OR foto LIKE 'data:image/jpeg;base64,%')),PRIMARY KEY(empresa_id,produto_id),FOREIGN KEY(empresa_id,produto_id) REFERENCES public.produtos(empresa_id,id));
ALTER TABLE private.rotisseria_fotos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.rotisseria_fotos FROM PUBLIC,anon,authenticated;
ALTER TABLE private.rotisseria_itens ADD COLUMN composicao jsonb,ADD COLUMN solicitacao_especial jsonb;

CREATE FUNCTION private.rotisseria_validar_componente(p_empresa uuid,p_titulo uuid,p_produto uuid,p_quantidade numeric,p_aceitar_composto boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF p_produto IS NULL OR p_produto=p_titulo OR p_quantidade IS NULL OR p_quantidade<=0 OR p_quantidade>9999999 OR round(p_quantidade,4)<>p_quantidade THEN RAISE EXCEPTION 'Selecione um componente válido e uma quantidade positiva com até quatro casas decimais.';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.produtos WHERE empresa_id=p_empresa AND id=p_produto AND ativo AND tipo_fiscal='produto') THEN RAISE EXCEPTION 'Componente inexistente, inativo ou de outra empresa.';END IF;
 IF p_aceitar_composto AND EXISTS(SELECT 1 FROM private.rotisseria_catalogo c WHERE c.empresa_id=p_empresa AND c.produto_id=p_produto AND c.tipo='composto' AND c.ativo) THEN RETURN;END IF;
 IF EXISTS(SELECT 1 FROM private.rotisseria_catalogo WHERE empresa_id=p_empresa AND produto_id=p_produto) OR EXISTS(SELECT 1 FROM public.bar_produtos WHERE empresa_id=p_empresa AND produto_id=p_produto AND tipo='composto') THEN RAISE EXCEPTION 'Use produtos físicos simples nos componentes; não aninhe combos ou compostos.';END IF;
END $$;
REVOKE ALL ON FUNCTION private.rotisseria_validar_componente(uuid,uuid,uuid,numeric,boolean) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.rotisseria_baixas(p_empresa uuid,p_sessao uuid,p_item uuid DEFAULT NULL) RETURNS TABLE(produto_id uuid,qtd numeric) LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT x.produto_id,sum(x.qtd) FROM (
 SELECT i.produto_id,i.quantidade qtd FROM private.rotisseria_itens i WHERE i.empresa_id=p_empresa AND i.sessao_id=p_sessao AND NOT i.cancelado AND i.composicao IS NULL AND (p_item IS NULL OR i.id=p_item)
 UNION ALL
 SELECT b.produto_id,i.quantidade*b.quantidade FROM private.rotisseria_itens i CROSS JOIN LATERAL jsonb_to_recordset(coalesce(i.composicao->'baixas','[]')) b(produto_id uuid,quantidade numeric) WHERE i.empresa_id=p_empresa AND i.sessao_id=p_sessao AND NOT i.cancelado AND i.composicao IS NOT NULL AND (p_item IS NULL OR i.id=p_item)
 ) x GROUP BY x.produto_id
$$;
REVOKE ALL ON FUNCTION private.rotisseria_baixas(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.rotisseria_catalogo_rpc(p_acao text,p_dados jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
#variable_conflict use_column
DECLARE e uuid:=private.exigir_empresa_ativa();u uuid:=auth.uid();c private.rotisseria_catalogo;prod public.produtos;r record;g record;
 cid uuid:=nullif(p_dados->>'id','')::uuid;pid uuid:=nullif(p_dados->>'produto_id','')::uuid;titulo text:=btrim(coalesce(p_dados->>'nome',''));
 tipo text:=p_dados->>'tipo';modelo text:=coalesce(p_dados->>'modelo','fixo');descr text:=coalesce(p_dados->>'descricao','');comp jsonb:=coalesce(p_dados->'componentes','[]');grupos jsonb:=coalesce(p_dados->'grupos','[]');
 result jsonb;foto text;pagina int:=greatest(0,coalesce((p_dados->>'pagina')::int,0));inativos boolean:=coalesce((p_dados->>'inativos')::boolean,false);novo boolean;
BEGIN
 IF NOT private.empresa_tem_modulo('rotisseria') OR NOT private.perm('rotisseria_visualizar') THEN RAISE EXCEPTION 'Módulo Rotisseria indisponível.' USING errcode='42501';END IF;
 IF p_acao IN ('catalogo_listar','catalogo_obter','catalogo_salvar','catalogo_ativar','foto_listar','foto_salvar') AND NOT private.perm('rotisseria_configurar') THEN RAISE EXCEPTION 'Sem permissão para configurar produtos da Rotisseria.' USING errcode='42501';END IF;
 IF p_acao IN ('catalogo_listar','foto_listar','catalogo_base') THEN
  RETURN jsonb_build_object('pagina',pagina,'itens',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.nome,x.id),'[]') FROM (
    SELECT p.id,p.nome,p.preco_venda,p.unidade_comercial,p.venda_granel,p.ativo,c.id catalogo_id,c.tipo tipo_item,c.modelo,c.descricao,c.versao,c.ativo catalogo_ativo,
    coalesce(f.foto,(SELECT q->>'foto' FROM private.rotisseria_config cfg CROSS JOIN LATERAL jsonb_array_elements(cfg.produtos) q WHERE cfg.empresa_id=e AND q->>'id'=p.id::text LIMIT 1),'') foto
    FROM public.produtos p LEFT JOIN private.rotisseria_catalogo c ON c.empresa_id=p.empresa_id AND c.produto_id=p.id LEFT JOIN private.rotisseria_fotos f ON f.empresa_id=p.empresa_id AND f.produto_id=p.id
    WHERE p.empresa_id=e AND (p.ativo OR inativos) AND (coalesce(p_dados->>'busca','')='' OR p.nome ILIKE '%'||left(p_dados->>'busca',100)||'%')
    AND CASE WHEN p_acao='catalogo_listar' THEN c.id IS NOT NULL AND (p_dados->>'tipo' IS NULL OR c.tipo=p_dados->>'tipo') AND (c.ativo OR inativos)
      WHEN p_acao='catalogo_base' THEN (c.id IS NULL OR (coalesce((p_dados->>'incluir_compostos')::boolean,false) AND c.tipo='composto' AND c.ativo)) AND p.tipo_fiscal='produto' AND (c.id IS NOT NULL OR NOT EXISTS(SELECT 1 FROM public.bar_produtos b WHERE b.empresa_id=e AND b.produto_id=p.id AND b.tipo='composto'))
      ELSE (c.id IS NULL OR c.ativo OR inativos) END
    ORDER BY p.nome,p.id LIMIT 21 OFFSET pagina*20
  ) x));
 ELSIF p_acao IN ('catalogo_obter','catalogo_venda') THEN
  SELECT * INTO c FROM private.rotisseria_catalogo WHERE empresa_id=e AND (id=cid OR (cid IS NULL AND produto_id=pid));
  IF c.id IS NULL OR (p_acao='catalogo_venda' AND NOT c.ativo) THEN RAISE EXCEPTION 'Cadastro não encontrado ou indisponível nesta empresa.';END IF;
  SELECT * INTO prod FROM public.produtos WHERE empresa_id=e AND id=c.produto_id;
  RETURN to_jsonb(c)||jsonb_build_object('nome',prod.nome,'preco_venda',prod.preco_venda,'unidade_comercial',prod.unidade_comercial,
 'componentes',(SELECT coalesce(jsonb_agg(x||jsonb_build_object('nome',p.nome,'unidade',p.unidade_comercial,'ativo',p.ativo,'composto',CASE WHEN c.tipo='combo' AND x->>'grupo'='acompanhamento' AND EXISTS(SELECT 1 FROM private.rotisseria_catalogo cc WHERE cc.empresa_id=e AND cc.produto_id=p.id AND cc.tipo='composto') THEN private.rotisseria_catalogo_rpc(p_acao,jsonb_build_object('produto_id',p.id)) ELSE NULL END) ORDER BY ord),'[]') FROM jsonb_array_elements(c.componentes) WITH ORDINALITY t(x,ord) JOIN public.produtos p ON p.empresa_id=e AND p.id=(x->>'produto_id')::uuid),
 'grupos',(SELECT coalesce(jsonb_agg(g||jsonb_build_object('opcoes',(SELECT coalesce(jsonb_agg(x||jsonb_build_object('nome',p.nome,'unidade',p.unidade_comercial,'ativo',p.ativo) ORDER BY pos),'[]') FROM jsonb_array_elements(g->'opcoes') WITH ORDINALITY t(x,pos) JOIN public.produtos p ON p.empresa_id=e AND p.id=(x->>'produto_id')::uuid)) ORDER BY ord),'[]') FROM jsonb_array_elements(c.grupos) WITH ORDINALITY t(g,ord)));
 ELSIF p_acao='foto_salvar' THEN
  foto:=coalesce(p_dados->>'foto','');IF length(foto)>100000 OR (foto<>'' AND foto NOT LIKE 'data:image/jpeg;base64,%') THEN RAISE EXCEPTION 'Foto inválida.';END IF;
  IF NOT EXISTS(SELECT 1 FROM public.produtos WHERE empresa_id=e AND id=pid AND ativo) THEN RAISE EXCEPTION 'Produto não encontrado nesta empresa.';END IF;
  INSERT INTO private.rotisseria_fotos(empresa_id,produto_id,foto) VALUES(e,pid,foto) ON CONFLICT(empresa_id,produto_id) DO UPDATE SET foto=excluded.foto;
  INSERT INTO private.rotisseria_config(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;
  UPDATE private.rotisseria_config SET produtos=(SELECT coalesce(jsonb_agg(CASE WHEN x->>'id'=pid::text THEN jsonb_set(x,'{foto}',to_jsonb(foto)) ELSE x END ORDER BY ord),'[]') FROM jsonb_array_elements(produtos) WITH ORDINALITY t(x,ord)),atualizado_em=clock_timestamp() WHERE empresa_id=e;
 ELSIF p_acao IN ('catalogo_salvar','catalogo_ativar') THEN
  IF cid IS NULL THEN RAISE EXCEPTION 'Identificação do cadastro obrigatória.';END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':rotisseria-catalogo',0));
  SELECT * INTO c FROM private.rotisseria_catalogo WHERE empresa_id=e AND id=cid FOR UPDATE;novo:=c.id IS NULL;
  IF EXISTS(SELECT 1 FROM private.rotisseria_catalogo WHERE id=cid AND empresa_id<>e) THEN RAISE EXCEPTION 'Cadastro de outra empresa.' USING errcode='42501';END IF;
  IF p_acao='catalogo_ativar' THEN
   IF novo THEN RAISE EXCEPTION 'Cadastro não encontrado.';END IF;
   UPDATE private.rotisseria_catalogo SET ativo=(p_dados->>'ativo')::boolean,versao=versao+1,atualizado_em=clock_timestamp() WHERE empresa_id=e AND id=cid;
  ELSE
   IF NOT novo AND c.ultima_solicitacao=p_dados THEN RETURN jsonb_build_object('id',c.id,'produto_id',c.produto_id,'versao',c.versao);END IF;
   IF NOT novo AND (p_dados->>'versao')::int IS DISTINCT FROM c.versao THEN RAISE EXCEPTION 'Este cadastro mudou. Reabra antes de salvar.';END IF;
   IF tipo IS NULL OR tipo NOT IN ('combo','composto') OR modelo NOT IN ('fixo','escolhas') OR (tipo='combo' AND modelo<>'fixo') OR length(descr)>3000 THEN RAISE EXCEPTION 'Tipo, modelo ou descrição inválidos.';END IF;
   IF NOT novo AND (c.produto_id IS DISTINCT FROM pid OR c.tipo<>tipo) THEN RAISE EXCEPTION 'O produto-base e o tipo não podem ser trocados na edição.';END IF;
   IF pid IS NULL THEN
    IF NOT novo OR length(titulo) NOT BETWEEN 1 AND 150 OR (p_dados->>'preco')::numeric IS NULL OR (p_dados->>'preco')::numeric<0 OR (p_dados->>'preco')::numeric>99999999.99 THEN RAISE EXCEPTION 'Informe o título e um preço de venda válido.';END IF;
    pid:=gen_random_uuid();
    INSERT INTO public.produtos(id,empresa_id,nome,preco_venda,unidade_comercial,quantidade_estoque,tipo_fiscal) VALUES(pid,e,titulo,round((p_dados->>'preco')::numeric,2),'UN',0,'produto');
   END IF;
   SELECT * INTO prod FROM public.produtos WHERE empresa_id=e AND id=pid AND ativo AND tipo_fiscal='produto';
   IF prod.id IS NULL OR (tipo='combo' AND (upper(coalesce(prod.unidade_comercial,'UN')) NOT IN ('UN','UND','UNID','UNIDADE') OR prod.venda_granel)) THEN RAISE EXCEPTION 'Escolha um título ativo vendido por unidade.';END IF;
   IF EXISTS(SELECT 1 FROM private.rotisseria_catalogo WHERE empresa_id=e AND produto_id=pid AND id<>cid) THEN RAISE EXCEPTION 'Este produto já possui cadastro na Rotisseria. Use Editar.';END IF;
   IF novo AND (EXISTS(SELECT 1 FROM private.rotisseria_catalogo z CROSS JOIN LATERAL jsonb_array_elements(z.componentes) x WHERE z.empresa_id=e AND x->>'produto_id'=pid::text) OR EXISTS(SELECT 1 FROM private.rotisseria_catalogo z CROSS JOIN LATERAL jsonb_array_elements(z.grupos) g CROSS JOIN LATERAL jsonb_array_elements(g->'opcoes') x WHERE z.empresa_id=e AND x->>'produto_id'=pid::text)) THEN RAISE EXCEPTION 'Este produto é componente de outro cadastro; escolha outro título.';END IF;
   IF jsonb_typeof(comp)<>'array' OR jsonb_typeof(grupos)<>'array' THEN RAISE EXCEPTION 'Composição inválida.';END IF;
   IF modelo='fixo' THEN
    IF jsonb_array_length(comp) NOT BETWEEN 1 AND 100 OR jsonb_array_length(grupos)<>0 THEN RAISE EXCEPTION 'Informe de 1 a 100 componentes e nenhum grupo.';END IF;
    IF tipo='combo' AND ((SELECT count(*) FROM jsonb_array_elements(comp) x WHERE x->>'grupo'='principal') NOT BETWEEN 1 AND 10 OR (SELECT count(*) FROM jsonb_array_elements(comp) x WHERE x->>'grupo'='acompanhamento')>10 OR EXISTS(SELECT 1 FROM jsonb_array_elements(comp) x WHERE coalesce(x->>'grupo','') NOT IN ('principal','acompanhamento'))) THEN RAISE EXCEPTION 'O combo permite de 1 a 10 produtos principais e até 10 acompanhamentos.';END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(comp) x GROUP BY x->>'produto_id',coalesce(x->>'grupo','componente') HAVING count(*)>1) THEN RAISE EXCEPTION 'Produto repetido no mesmo grupo. Ajuste seu consumo para estoque.';END IF;
    FOR r IN SELECT * FROM jsonb_to_recordset(comp) x(produto_id uuid,quantidade numeric,descricao text,baixar_estoque boolean,grupo text) LOOP
     PERFORM private.rotisseria_validar_componente(e,pid,r.produto_id,r.quantidade,tipo='combo' AND r.grupo='acompanhamento');IF length(coalesce(r.descricao,''))>500 THEN RAISE EXCEPTION 'Descrição do componente muito longa.';END IF;
    END LOOP;
   ELSE
    IF jsonb_array_length(grupos) NOT BETWEEN 1 AND 20 OR jsonb_array_length(comp)<>0 THEN RAISE EXCEPTION 'Informe de 1 a 20 grupos e nenhum componente fixo.';END IF;
    IF EXISTS(SELECT 1 FROM jsonb_array_elements(grupos) g GROUP BY g->>'id' HAVING count(*)>1) THEN RAISE EXCEPTION 'Grupo repetido.';END IF;
    FOR g IN SELECT * FROM jsonb_to_recordset(grupos) x(id uuid,nome text,quantidade_escolhas integer,opcoes jsonb) LOOP
     IF g.opcoes IS NULL OR g.id IS NULL OR length(btrim(coalesce(g.nome,''))) NOT BETWEEN 1 AND 100 OR jsonb_typeof(g.opcoes)<>'array' OR jsonb_array_length(g.opcoes) NOT BETWEEN 1 AND 100 OR g.quantidade_escolhas IS NULL OR g.quantidade_escolhas NOT BETWEEN 1 AND jsonb_array_length(g.opcoes) THEN RAISE EXCEPTION 'Grupo inválido: informe nome, opções e quantidade de escolhas.';END IF;
     IF EXISTS(SELECT 1 FROM jsonb_array_elements(g.opcoes) x GROUP BY x->>'produto_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'Opção repetida no grupo.';END IF;
     FOR r IN SELECT * FROM jsonb_to_recordset(g.opcoes) x(produto_id uuid,quantidade numeric,descricao text) LOOP
      PERFORM private.rotisseria_validar_componente(e,pid,r.produto_id,r.quantidade);IF length(coalesce(r.descricao,''))>500 THEN RAISE EXCEPTION 'Descrição da opção muito longa.';END IF;
     END LOOP;
    END LOOP;
   END IF;
   INSERT INTO private.rotisseria_catalogo(id,empresa_id,produto_id,tipo,modelo,descricao,componentes,grupos,ultima_solicitacao,criado_por)
   VALUES(cid,e,pid,tipo,modelo,descr,comp,grupos,p_dados,u) ON CONFLICT(id) DO UPDATE SET modelo=excluded.modelo,descricao=excluded.descricao,componentes=excluded.componentes,grupos=excluded.grupos,versao=rotisseria_catalogo.versao+1,ultima_solicitacao=excluded.ultima_solicitacao,atualizado_em=clock_timestamp();
  END IF;
  result:=jsonb_build_object('id',cid,'produto_id',coalesce(pid,c.produto_id));
  INSERT INTO private.rotisseria_config(empresa_id) VALUES(e) ON CONFLICT DO NOTHING;UPDATE private.rotisseria_config SET atualizado_em=clock_timestamp() WHERE empresa_id=e;
 ELSE RAISE EXCEPTION 'Ação de catálogo inválida.';END IF;
 INSERT INTO public.rotisseria_sinais(empresa_id) VALUES(e) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.rotisseria_sinais.revisao+1;
 RETURN coalesce(result,'{}');
END $$;
REVOKE ALL ON FUNCTION private.rotisseria_catalogo_rpc(text,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.rotisseria_resolver_catalogo(p_empresa uuid,p_produto uuid,p_versao int,p_escolhas jsonb,p_acompanhamentos jsonb,p_nivel int DEFAULT 0) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
#variable_conflict use_column
DECLARE c private.rotisseria_catalogo;g record;entry jsonb;line jsonb;child jsonb;choice jsonb;child_def private.rotisseria_catalogo;
 itens jsonb:='[]';baixas jsonb;nome text;unidade text;baixar boolean;expected int:=0;inclusoes jsonb:='[]';
BEGIN
 IF p_nivel NOT BETWEEN 0 AND 1 THEN RAISE EXCEPTION 'Composição aninhada inválida.';END IF;
 SELECT * INTO c FROM private.rotisseria_catalogo WHERE empresa_id=p_empresa AND produto_id=p_produto FOR SHARE;
 IF c.id IS NULL OR NOT c.ativo OR NOT EXISTS(SELECT 1 FROM public.produtos WHERE empresa_id=p_empresa AND id=p_produto AND ativo) THEN RAISE EXCEPTION 'Combo ou composto indisponível.';END IF;
 IF p_versao IS DISTINCT FROM c.versao THEN RAISE EXCEPTION 'A composição mudou. Abra o produto novamente antes de lançar.';END IF;
 IF p_nivel=1 AND c.tipo<>'composto' THEN RAISE EXCEPTION 'Somente um produto composto pode ser acompanhamento.';END IF;
 IF p_escolhas IS NULL OR p_acompanhamentos IS NULL OR jsonb_typeof(p_escolhas)<>'array' OR jsonb_typeof(p_acompanhamentos)<>'array' OR jsonb_array_length(p_escolhas)>2000 OR jsonb_array_length(p_acompanhamentos)>10 THEN RAISE EXCEPTION 'Escolhas inválidas.';END IF;
 IF c.modelo='fixo' THEN
  IF jsonb_array_length(p_escolhas)<>0 THEN RAISE EXCEPTION 'Todos os produtos deste cadastro entram automaticamente.';END IF;
  FOR entry IN SELECT value FROM jsonb_array_elements(c.componentes) LOOP
   SELECT produtos.nome,coalesce(unidade_comercial,'UN') INTO nome,unidade FROM public.produtos WHERE empresa_id=p_empresa AND id=(entry->>'produto_id')::uuid;
   SELECT * INTO child_def FROM private.rotisseria_catalogo WHERE empresa_id=p_empresa AND produto_id=(entry->>'produto_id')::uuid;
   IF c.tipo='combo' AND entry->>'grupo'='acompanhamento' AND child_def.tipo='composto' THEN
    expected:=expected+1;
    IF p_nivel<>0 OR (SELECT count(*) FROM jsonb_array_elements(p_acompanhamentos) x WHERE x->>'produto_id'=entry->>'produto_id')<>1 THEN RAISE EXCEPTION 'Preencha o acompanhamento composto %.',nome;END IF;
    SELECT value INTO choice FROM jsonb_array_elements(p_acompanhamentos) x WHERE x->>'produto_id'=entry->>'produto_id';
    child:=private.rotisseria_resolver_catalogo(p_empresa,child_def.produto_id,(choice->>'catalogo_versao')::int,coalesce(choice->'escolhas','[]'),'[]',p_nivel+1);
    inclusoes:=inclusoes||jsonb_build_array(jsonb_build_object('nome',nome,'descricao',coalesce(entry->>'descricao',''),'grupo','acompanhamento','escolhidos',child->'itens'));
    FOR line IN SELECT value FROM jsonb_array_elements(child->'itens') LOOP
     itens:=itens||jsonb_build_array(line||jsonb_build_object('quantidade',round((line->>'quantidade')::numeric*(entry->>'quantidade')::numeric,4),'acompanhamento',nome,'acompanhamento_id',child_def.produto_id,'acompanhamento_versao',child_def.versao));
    END LOOP;
   ELSE
    PERFORM private.rotisseria_validar_componente(p_empresa,p_produto,(entry->>'produto_id')::uuid,(entry->>'quantidade')::numeric);
    inclusoes:=inclusoes||jsonb_build_array(jsonb_build_object('nome',nome,'descricao',coalesce(entry->>'descricao',''),'grupo',coalesce(entry->>'grupo','componente')));
    baixar:=c.tipo='combo' OR coalesce((entry->>'baixar_estoque')::boolean,true);
    itens:=itens||jsonb_build_array(jsonb_build_object('produto_id',entry->>'produto_id','nome',nome,'unidade',unidade,'descricao',coalesce(entry->>'descricao',''),'grupo',coalesce(entry->>'grupo','componente'),'quantidade',(entry->>'quantidade')::numeric,'baixar_estoque',baixar));
   END IF;
  END LOOP;
 ELSE
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_escolhas) x WHERE NOT EXISTS(SELECT 1 FROM jsonb_array_elements(c.grupos) gg WHERE gg->>'id'=x->>'grupo_id')) THEN RAISE EXCEPTION 'Grupo de escolhas inválido.';END IF;
  FOR g IN SELECT * FROM jsonb_to_recordset(c.grupos) x(id uuid,nome text,quantidade_escolhas integer,opcoes jsonb) LOOP
   IF (SELECT count(*) FROM jsonb_array_elements(p_escolhas) x WHERE x->>'grupo_id'=g.id::text)<>g.quantidade_escolhas THEN RAISE EXCEPTION 'Preencha % escolha(s) do grupo %.',g.quantidade_escolhas,g.nome;END IF;
   FOR entry IN SELECT value FROM jsonb_array_elements(p_escolhas) x WHERE x->>'grupo_id'=g.id::text LOOP
    SELECT value INTO line FROM jsonb_array_elements(g.opcoes) x WHERE x->>'produto_id'=entry->>'produto_id';
    IF line IS NULL THEN RAISE EXCEPTION 'Produto não pertence ao grupo de escolhas.';END IF;
    PERFORM private.rotisseria_validar_componente(p_empresa,p_produto,(line->>'produto_id')::uuid,(line->>'quantidade')::numeric);
    SELECT produtos.nome,coalesce(unidade_comercial,'UN') INTO nome,unidade FROM public.produtos WHERE empresa_id=p_empresa AND id=(line->>'produto_id')::uuid;
    itens:=itens||jsonb_build_array(jsonb_build_object('produto_id',line->>'produto_id','nome',nome,'unidade',unidade,'descricao',coalesce(line->>'descricao',''),'grupo',g.nome,'quantidade',(line->>'quantidade')::numeric,'baixar_estoque',true));
   END LOOP;
  END LOOP;
 END IF;
 IF jsonb_array_length(p_acompanhamentos)<>expected THEN RAISE EXCEPTION 'Acompanhamentos informados não correspondem ao combo.';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(itens) x WHERE (x->>'quantidade')::numeric<=0) THEN RAISE EXCEPTION 'Consumo muito pequeno: use pelo menos 0,0001 da unidade cadastrada.';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('produto_id',z.pid,'quantidade',z.qtd) ORDER BY z.pid),'[]') INTO baixas FROM (SELECT (x->>'produto_id')::uuid pid,sum((x->>'quantidade')::numeric) qtd FROM jsonb_array_elements(itens) x WHERE (x->>'baixar_estoque')::boolean GROUP BY x->>'produto_id') z;
 RETURN jsonb_build_object('catalogo_id',c.id,'versao',c.versao,'tipo',c.tipo,'descricao',c.descricao,'itens',itens,'inclusoes',inclusoes,'baixas',baixas);
END $$;
REVOKE ALL ON FUNCTION private.rotisseria_resolver_catalogo(uuid,uuid,int,jsonb,jsonb,int) FROM PUBLIC,anon,authenticated;

-- Emit separate descriptive rows: existing Print Agent limits each name to 200 chars
-- and receipt mode does not print nested children. No agent/shared receipt changes.
CREATE FUNCTION private.rotisseria_item_impressao(p_item private.rotisseria_itens) RETURNS SETOF jsonb LANGUAGE plpgsql STABLE SET search_path='' AS $$
DECLARE x jsonb;y jsonb;line text;combo boolean:=coalesce(p_item.composicao->>'tipo'='combo',false);current_group text:='';position int;
BEGIN
 IF p_item.composicao IS NULL THEN
  RETURN NEXT jsonb_build_object('nome',p_item.nome||' ('||p_item.unidade||')','quantidade',trim_scale(p_item.quantidade),'preco_unitario',p_item.preco,'subtotal',p_item.subtotal);RETURN;
 END IF;
 RETURN NEXT jsonb_strip_nulls(jsonb_build_object('nome',p_item.nome,'quantidade',CASE WHEN combo THEN NULL ELSE trim_scale(p_item.quantidade) END,'preco_unitario',CASE WHEN combo THEN NULL ELSE p_item.preco END,'subtotal',p_item.subtotal));
 line:=coalesce(p_item.composicao->>'descricao','');
 IF line<>'' THEN FOR position IN 0..((length(line)-1)/180) LOOP RETURN NEXT jsonb_build_object('nome',substring(line FROM position*180+1 FOR 180),'descritivo',true);END LOOP;END IF;
 IF combo THEN
  FOR x IN SELECT value FROM jsonb_array_elements(p_item.composicao->'inclusoes') WITH ORDINALITY t(value,n) ORDER BY CASE WHEN value->>'grupo'='principal' THEN 0 ELSE 1 END,n LOOP
   IF x->>'grupo' IS DISTINCT FROM current_group THEN current_group:=x->>'grupo';RETURN NEXT jsonb_build_object('nome',CASE WHEN current_group='principal' THEN 'Produtos:' ELSE 'Acompanhamentos:' END,'descritivo',true);END IF;
   line:=(x->>'nome')||coalesce(' — '||nullif(x->>'descricao',''),'');
   FOR position IN 0..((length(line)-1)/180) LOOP RETURN NEXT jsonb_build_object('nome','  '||substring(line FROM position*180+1 FOR 180),'descritivo',true);END LOOP;
   FOR y IN SELECT value FROM jsonb_array_elements(coalesce(x->'escolhidos','[]')) LOOP
    line:=(y->>'nome')||coalesce(' — '||nullif(y->>'descricao',''),'');
    FOR position IN 0..((length(line)-1)/180) LOOP RETURN NEXT jsonb_build_object('nome','    > '||substring(line FROM position*180+1 FOR 180),'descritivo',true);END LOOP;
   END LOOP;
  END LOOP;
 ELSE
  FOR x IN SELECT value FROM jsonb_array_elements(p_item.composicao->'itens') LOOP
   line:=coalesce(x->>'grupo','Componente')||': '||(x->>'nome')||coalesce(' — '||nullif(x->>'descricao',''),'');
   FOR position IN 0..((length(line)-1)/180) LOOP RETURN NEXT jsonb_build_object('nome','  '||substring(line FROM position*180+1 FOR 180),'descritivo',true);END LOOP;
  END LOOP;
 END IF;
END $$;
REVOKE ALL ON FUNCTION private.rotisseria_item_impressao(private.rotisseria_itens) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.rotisseria_lancar_catalogo(p_dados jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
#variable_conflict use_column
DECLARE e uuid:=private.exigir_empresa_ativa();u uuid:=auth.uid();s private.rotisseria_sessoes;c private.rotisseria_catalogo;p public.produtos;i private.rotisseria_itens;r record;g record;
 v_quantidade numeric:=(p_dados->>'quantidade')::numeric;key1 uuid:=(p_dados->>'chave')::uuid;pid uuid:=(p_dados->>'produto_id')::uuid;escolhas jsonb:=coalesce(p_dados->'escolhas','[]');
 itens jsonb:='[]';baixas jsonb;line jsonb;entry jsonb;nome text;unidade text;ativos boolean;baixar boolean;permitido boolean;snapshot jsonb;itemid uuid;saldo_estoque numeric;
BEGIN
 IF NOT private.empresa_tem_modulo('rotisseria') OR NOT private.perm('rotisseria_visualizar') OR NOT private.perm('rotisseria_lancar') THEN RAISE EXCEPTION 'Sem permissão para lançar na Rotisseria.' USING errcode='42501';END IF;
 SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid FOR UPDATE;
 IF s.id IS NULL OR s.estado<>'aberta' THEN RAISE EXCEPTION 'Comanda inexistente ou encerrada.';END IF;
 SELECT * INTO i FROM private.rotisseria_itens WHERE empresa_id=e AND chave=key1;
 IF i.id IS NOT NULL THEN
  IF i.sessao_id<>s.id OR i.solicitacao_especial IS DISTINCT FROM p_dados THEN RAISE EXCEPTION 'Chave de lançamento já usada com outros dados.';END IF;
  RETURN jsonb_build_object('item_id',i.id,'repetido',true);
 END IF;
 IF key1 IS NULL OR v_quantidade IS NULL OR v_quantidade<=0 OR v_quantidade>999999999 OR v_quantidade<>round(v_quantidade,4) THEN RAISE EXCEPTION 'Informe uma quantidade positiva com até quatro casas decimais.';END IF;
 SELECT * INTO c FROM private.rotisseria_catalogo WHERE empresa_id=e AND produto_id=pid FOR SHARE;
 IF c.id IS NULL OR NOT c.ativo THEN RAISE EXCEPTION 'Combo ou composto indisponível.';END IF;
 IF (p_dados->>'catalogo_versao')::int IS DISTINCT FROM c.versao THEN RAISE EXCEPTION 'A composição mudou. Abra o produto novamente antes de lançar.';END IF;
 SELECT * INTO p FROM public.produtos WHERE empresa_id=e AND id=pid AND ativo FOR SHARE;
 IF p.id IS NULL OR (p_dados->>'preco')::numeric IS DISTINCT FROM p.preco_venda THEN RAISE EXCEPTION 'O produto ou preço mudou. Pesquise novamente.';END IF;
 IF NOT(p.venda_granel OR upper(coalesce(p.unidade_comercial,'')) IN ('KG','K','QUILO')) AND v_quantidade<>trunc(v_quantidade) THEN RAISE EXCEPTION 'Este título é vendido por unidade. Informe quantidade inteira.';END IF;
 IF c.tipo='combo' AND v_quantidade<>1 THEN RAISE EXCEPTION 'Confirme um combo por lançamento.';END IF;
 snapshot:=private.rotisseria_resolver_catalogo(e,pid,(p_dados->>'catalogo_versao')::int,escolhas,coalesce(p_dados->'acompanhamentos','[]'));
 baixas:=snapshot->'baixas';
 IF s.estoque_baixado THEN
  SELECT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false) INTO permitido;
  FOR r IN SELECT * FROM jsonb_to_recordset(baixas) x(produto_id uuid,quantidade numeric) ORDER BY produto_id LOOP
   SELECT quantidade_estoque,produtos.nome INTO saldo_estoque,nome FROM public.produtos WHERE empresa_id=e AND id=r.produto_id FOR UPDATE;
   IF NOT permitido AND saldo_estoque<r.quantidade*v_quantidade THEN RAISE EXCEPTION 'Estoque insuficiente de %.',nome;END IF;
   UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-r.quantidade*v_quantidade WHERE empresa_id=e AND id=r.produto_id;
  END LOOP;
 END IF;
 INSERT INTO private.rotisseria_itens(empresa_id,sessao_id,produto_id,nome,unidade,quantidade,preco,chave,criado_por,composicao,solicitacao_especial)
 VALUES(e,s.id,pid,p.nome,coalesce(p.unidade_comercial,'UN'),v_quantidade,p.preco_venda,key1,u,snapshot,p_dados) RETURNING id INTO itemid;
 UPDATE private.rotisseria_sessoes SET versao=versao+1 WHERE empresa_id=e AND id=s.id;
 INSERT INTO public.rotisseria_sinais(empresa_id) VALUES(e) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.rotisseria_sinais.revisao+1;
 RETURN jsonb_build_object('item_id',itemid);
END $$;
REVOKE ALL ON FUNCTION private.rotisseria_lancar_catalogo(jsonb) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.rotisseria_rpc(p_acao text, p_dados jsonb DEFAULT '{}'::jsonb, p_chave uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE
 e uuid:=private.exigir_empresa_ativa(); u uuid:=auth.uid(); cfg private.rotisseria_config; s private.rotisseria_sessoes;
 c public.caixas; prod public.produtos; it private.rotisseria_itens; r record; result jsonb; arr jsonb; n bigint; vid uuid; pid uuid;
 qtd numeric; total numeric; pago numeric; troco numeric:=0; forma text; cpf text; disponivel numeric; permitido boolean; dispositivo boolean; expected bigint; catalogo boolean;
BEGIN
 IF NOT private.empresa_tem_modulo('rotisseria') OR NOT private.perm('rotisseria_visualizar') THEN RAISE EXCEPTION 'Módulo Rotisseria não liberado para este usuário e empresa.' USING errcode='42501'; END IF;
 IF p_acao IN ('catalogo_listar','catalogo_obter','catalogo_venda','catalogo_base','catalogo_salvar','catalogo_ativar','foto_listar','foto_salvar') THEN RETURN private.rotisseria_catalogo_rpc(p_acao,p_dados);END IF;
 IF p_acao='lancar' AND EXISTS(SELECT 1 FROM private.rotisseria_catalogo WHERE empresa_id=e AND produto_id=(p_dados->>'produto_id')::uuid) THEN RETURN private.rotisseria_lancar_catalogo(p_dados);END IF;
 IF p_acao IN ('config_salvar','abrir_comanda') THEN PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':rotisseria-config',0)); END IF;
 SELECT * INTO cfg FROM private.rotisseria_config WHERE empresa_id=e;
 IF NOT FOUND THEN cfg.quantidade:=5;cfg.destaques:=10;cfg.produtos:='[]'; END IF;
 SELECT EXISTS(SELECT 1 FROM private.rotisseria_dispositivo d WHERE d.empresa_id=e AND d.token=p_chave AND d.usuario_id=u) INTO dispositivo;
 IF p_acao='contexto' THEN
  catalogo:=nullif(p_dados->>'config_em','')::timestamptz IS DISTINCT FROM cfg.atualizado_em OR cfg.atualizado_em IS NULL;
  SELECT coalesce(jsonb_agg(jsonb_build_object('numero',g.numero,'id',s.id,'versao',s.versao,'criado_em',s.criado_em,'total',coalesce(x.total,0),'itens',coalesce(x.itens,0),'saldo',greatest(0,coalesce(x.total,0)-coalesce(pay.valor,0))) ORDER BY g.numero),'[]') INTO arr
  FROM generate_series(1,cfg.quantidade) g(numero) LEFT JOIN private.rotisseria_sessoes s ON s.empresa_id=e AND s.numero=g.numero AND s.estado='aberta'
  LEFT JOIN LATERAL(SELECT sum(i.subtotal) total,count(*) itens FROM private.rotisseria_itens i WHERE i.empresa_id=e AND i.sessao_id=s.id AND NOT i.cancelado) x ON true
  LEFT JOIN LATERAL(SELECT sum(p.valor) valor FROM private.rotisseria_pagamentos p WHERE p.empresa_id=e AND p.sessao_id=s.id) pay ON true;
  SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' AND status='aberto';
  RETURN jsonb_build_object('empresa_id',e,'config',CASE WHEN catalogo THEN to_jsonb(cfg) ELSE to_jsonb(cfg)-'produtos' END,'comandas',arr,'caixa',CASE WHEN c.id IS NOT NULL THEN private.caixa_json(c) ELSE NULL END,'dispositivo_caixa',dispositivo,
   'permissoes',jsonb_build_object('lancar',private.perm('rotisseria_lancar'),'caixa',private.perm('rotisseria_caixa'),'configurar',private.perm('rotisseria_configurar')),
   'destaques',CASE WHEN catalogo THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nome',p.nome,'codigo',p.codigo,'gtin',p.gtin,'preco_venda',p.preco_venda,'unidade_comercial',p.unidade_comercial,'venda_granel',p.venda_granel,'foto',coalesce(f.foto,x->>'foto'),'tipo_item',c.tipo,'catalogo_id',c.id,'modelo',c.modelo,'catalogo_versao',c.versao) ORDER BY ord),'[]') FROM jsonb_array_elements(cfg.produtos) WITH ORDINALITY t(x,ord) JOIN public.produtos p ON p.id=(x->>'id')::uuid AND p.empresa_id=e AND p.ativo LEFT JOIN private.rotisseria_catalogo c ON c.empresa_id=e AND c.produto_id=p.id LEFT JOIN private.rotisseria_fotos f ON f.empresa_id=e AND f.produto_id=p.id WHERE ord<=cfg.destaques AND (c.id IS NULL OR c.ativo)) ELSE NULL END);
 ELSIF p_acao='buscar' THEN
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM (SELECT p.id,p.nome,p.codigo,p.gtin,p.unidade_comercial,p.venda_granel,p.preco_venda,p.quantidade_estoque,c.id catalogo_id,c.tipo tipo_item,c.modelo,c.versao catalogo_versao,coalesce(f.foto,'') foto FROM public.produtos p LEFT JOIN private.rotisseria_catalogo c ON c.empresa_id=p.empresa_id AND c.produto_id=p.id LEFT JOIN private.rotisseria_fotos f ON f.empresa_id=p.empresa_id AND f.produto_id=p.id WHERE p.empresa_id=e AND p.ativo AND (c.id IS NULL OR c.ativo) AND (p.nome ILIKE '%'||left(coalesce(p_dados->>'busca',''),100)||'%' OR p.codigo ILIKE '%'||left(p_dados->>'busca',100)||'%' OR p.gtin=p_dados->>'busca') ORDER BY p.nome,p.id LIMIT 40) x);
 ELSIF p_acao='clientes' THEN
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM (SELECT id,nome FROM public.clientes WHERE empresa_id=e AND nome ILIKE '%'||left(coalesce(p_dados->>'busca',''),100)||'%' ORDER BY nome,id LIMIT 30) x);
 ELSIF p_acao='config_dados' THEN
  IF NOT private.perm('rotisseria_configurar') THEN RAISE EXCEPTION 'Sem permissão para configurar.' USING errcode='42501'; END IF;
  RETURN jsonb_build_object('config',to_jsonb(cfg),'impressoras',(SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]') FROM public.impressoras p WHERE empresa_id=e AND ativa));
 ELSIF p_acao='config_salvar' THEN
  IF NOT private.perm('rotisseria_configurar') THEN RAISE EXCEPTION 'Sem permissão para configurar.' USING errcode='42501'; END IF;
  IF (p_dados->>'quantidade')::int NOT BETWEEN 1 AND 200 OR (p_dados->>'destaques')::int NOT BETWEEN 0 AND 20 OR p_dados->>'quantidade' IS NULL OR p_dados->>'destaques' IS NULL THEN RAISE EXCEPTION 'Informe de 1 a 200 comandas e de 0 a 20 destaques.'; END IF;
  IF EXISTS(SELECT 1 FROM private.rotisseria_sessoes WHERE empresa_id=e AND estado='aberta' AND numero>(p_dados->>'quantidade')::int) THEN RAISE EXCEPTION 'Finalize as comandas abertas antes de reduzir a quantidade.'; END IF;
  arr:=coalesce(p_dados->'produtos','[]');
  IF jsonb_typeof(arr)<>'array' OR jsonb_array_length(arr)>20 OR octet_length(arr::text)>2000000 THEN RAISE EXCEPTION 'Configuração de fotos inválida.'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(arr) x WHERE NOT EXISTS(SELECT 1 FROM public.produtos p WHERE p.id=(x->>'id')::uuid AND p.empresa_id=e AND p.ativo) OR (coalesce(x->>'foto','')<>'' AND (x->>'foto' NOT LIKE 'data:image/jpeg;base64,%' OR length(x->>'foto')>100000))) THEN RAISE EXCEPTION 'Produto ou foto inválido.'; END IF;
  INSERT INTO private.rotisseria_fotos(empresa_id,produto_id,foto) SELECT e,(x->>'id')::uuid,coalesce(x->>'foto','') FROM jsonb_array_elements(arr) x ON CONFLICT(empresa_id,produto_id) DO UPDATE SET foto=excluded.foto;
  IF (SELECT count(*)<>count(DISTINCT x->>'id') FROM jsonb_array_elements(arr) x) THEN RAISE EXCEPTION 'Produto repetido nos destaques.'; END IF;
  IF nullif(p_dados->>'impressora_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.impressoras WHERE empresa_id=e AND ativa AND id=(p_dados->>'impressora_id')::uuid) THEN RAISE EXCEPTION 'Impressora de outra empresa ou inexistente.'; END IF;
  INSERT INTO private.rotisseria_config(empresa_id,quantidade,destaques,produtos,impressora_id) VALUES(e,(p_dados->>'quantidade')::int,(p_dados->>'destaques')::int,arr,nullif(p_dados->>'impressora_id','')::uuid)
  ON CONFLICT(empresa_id) DO UPDATE SET quantidade=excluded.quantidade,destaques=excluded.destaques,produtos=excluded.produtos,impressora_id=excluded.impressora_id,atualizado_em=now();
 ELSIF p_acao='caixa_vincular' THEN
  IF NOT private.perm('rotisseria_caixa') OR p_chave IS NULL THEN RAISE EXCEPTION 'Sem permissão para definir dispositivo de caixa.' USING errcode='42501'; END IF;
  INSERT INTO private.rotisseria_dispositivo(empresa_id,token,usuario_id,nome) VALUES(e,p_chave,u,left(coalesce(nullif(btrim(p_dados->>'nome'),''),'Caixa Rotisseria'),80)) ON CONFLICT(empresa_id) DO UPDATE SET token=excluded.token,usuario_id=excluded.usuario_id,nome=excluded.nome,atualizado_em=now();
 ELSIF p_acao IN ('caixa_abrir','caixa_fechar','receber','fiscal') THEN
  IF NOT dispositivo OR NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Recebimentos e caixa são exclusivos do dispositivo definido como Caixa da Rotisseria.' USING errcode='42501'; END IF;
  IF p_acao='caixa_abrir' THEN RETURN public.caixa_abrir('ROTISSERIA',(p_dados->>'valor')::numeric); END IF;
  IF p_acao='caixa_fechar' THEN
   SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND id=(p_dados->>'id')::uuid AND tipo_caixa='ROTISSERIA';
   IF c.id IS NULL THEN RAISE EXCEPTION 'Caixa da Rotisseria não encontrado.'; END IF;
   RETURN public.caixa_fechar(c.id);
  END IF;
  IF p_acao='fiscal' THEN
   IF NOT EXISTS(SELECT 1 FROM private.rotisseria_sessoes WHERE empresa_id=e AND venda_id=(p_dados->>'venda_id')::uuid AND estado='concluida') THEN RAISE EXCEPTION 'Venda da Rotisseria não encontrada.'; END IF;
   IF NOT private.perm('fiscal') AND NOT private.perm('pdv') THEN RAISE EXCEPTION 'Libere a permissão Fiscal ao operador para emitir NFC-e.' USING errcode='42501'; END IF;
   RETURN (SELECT coalesce(jsonb_agg(to_jsonb(d)),'[]') FROM public.fiscal_emitir_nota((p_dados->>'venda_id')::uuid) d);
  END IF;
  RETURN private.rotisseria_receber(p_dados,p_chave);
 ELSIF p_acao='abrir_comanda' THEN
  IF NOT private.perm('rotisseria_lancar') THEN RAISE EXCEPTION 'Sem permissão para abrir comanda.' USING errcode='42501'; END IF;
  n:=(p_dados->>'numero')::int;
  IF n IS NULL OR n NOT BETWEEN 1 AND cfg.quantidade THEN RAISE EXCEPTION 'Número de comanda inválido.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':rotisseria:'||n::text,0));
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND numero=n AND estado='aberta';
  IF s.id IS NULL THEN INSERT INTO private.rotisseria_sessoes(empresa_id,numero,criado_por) VALUES(e,n,u) RETURNING * INTO s; END IF;
  result:=to_jsonb(s);
 ELSIF p_acao IN ('lancar','cancelar_item','fechar_vazia') THEN
  IF NOT private.perm('rotisseria_lancar') THEN RAISE EXCEPTION 'Sem permissão para lançar na comanda.' USING errcode='42501'; END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid FOR UPDATE;
  IF s.id IS NULL OR s.estado<>'aberta' THEN RAISE EXCEPTION 'Comanda encerrada ou inexistente. Abra novamente na grade.'; END IF;
  IF p_acao='lancar' THEN
   IF nullif(p_dados->>'chave','') IS NULL THEN RAISE EXCEPTION 'Chave do lançamento obrigatória.'; END IF;
   SELECT * INTO it FROM private.rotisseria_itens WHERE empresa_id=e AND chave=(p_dados->>'chave')::uuid;
   IF it.id IS NOT NULL THEN
    IF it.sessao_id<>s.id OR it.produto_id<>(p_dados->>'produto_id')::uuid OR it.quantidade<>(p_dados->>'quantidade')::numeric THEN RAISE EXCEPTION 'Chave já utilizada por outro lançamento.'; END IF;
    RETURN jsonb_build_object('item_id',it.id,'repetido',true);
   END IF;
   qtd:=(p_dados->>'quantidade')::numeric;
   IF qtd IS NULL OR qtd<=0 OR qtd>999999999 OR qtd<>round(qtd,4) THEN RAISE EXCEPTION 'Quantidade inválida, use até quatro casas decimais.'; END IF;
   SELECT * INTO prod FROM public.produtos WHERE empresa_id=e AND id=(p_dados->>'produto_id')::uuid AND ativo FOR UPDATE;
   IF prod.id IS NULL OR prod.tipo_fiscal='servico' THEN RAISE EXCEPTION 'Selecione um produto ativo para venda.'; END IF;
   IF NOT(prod.venda_granel OR upper(coalesce(prod.unidade_comercial,'')) IN ('KG','K','QUILO')) AND qtd<>trunc(qtd) THEN RAISE EXCEPTION 'Este produto é vendido por unidade. Informe uma quantidade inteira.'; END IF;
   IF (p_dados->>'preco')::numeric IS NULL OR (p_dados->>'preco')::numeric<>prod.preco_venda THEN RAISE EXCEPTION 'O preço do produto mudou. Pesquise novamente antes de lançar.'; END IF;
   IF s.estoque_baixado THEN
    SELECT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false) INTO permitido;
    IF NOT permitido AND prod.quantidade_estoque<qtd THEN RAISE EXCEPTION 'Estoque insuficiente de %.',prod.nome; END IF;
    UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-qtd WHERE empresa_id=e AND id=prod.id;
   END IF;
   INSERT INTO private.rotisseria_itens(empresa_id,sessao_id,produto_id,nome,unidade,quantidade,preco,chave,criado_por) VALUES(e,s.id,prod.id,prod.nome,coalesce(prod.unidade_comercial,'UN'),qtd,prod.preco_venda,(p_dados->>'chave')::uuid,u) RETURNING id INTO pid;
   result:=jsonb_build_object('item_id',pid);
  ELSIF p_acao='cancelar_item' THEN
   SELECT * INTO it FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND id=(p_dados->>'item_id')::uuid AND NOT cancelado;
   IF it.id IS NULL THEN RAISE EXCEPTION 'Item não encontrado ou já cancelado.'; END IF;
   IF it.subtotal>(private.rotisseria_saldo(s.id,e)->>'saldo')::numeric THEN RAISE EXCEPTION 'O cancelamento deixaria o consumo menor que o valor já pago.'; END IF;
   IF s.estoque_baixado THEN FOR r IN SELECT * FROM private.rotisseria_baixas(e,s.id,it.id) ORDER BY produto_id LOOP UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+r.qtd WHERE empresa_id=e AND id=r.produto_id; END LOOP;END IF;
   UPDATE private.rotisseria_itens SET cancelado=true WHERE empresa_id=e AND id=it.id;
   IF (private.rotisseria_saldo(s.id,e)->>'saldo')::numeric=0 AND s.estoque_baixado THEN result:=private.rotisseria_consolidar(s.id,e); END IF;
  ELSE
   IF EXISTS(SELECT 1 FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado) THEN RAISE EXCEPTION 'A comanda ainda possui itens.'; END IF;
   UPDATE private.rotisseria_sessoes SET estado='cancelada',finalizado_em=now() WHERE empresa_id=e AND id=s.id;
  END IF;
  UPDATE private.rotisseria_sessoes SET versao=versao+1 WHERE empresa_id=e AND id=s.id;
 ELSIF p_acao='detalhe' THEN
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
  RETURN to_jsonb(s)||private.rotisseria_saldo(s.id,e)||jsonb_build_object('itens',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY criado_em,id),'[]') FROM private.rotisseria_itens i WHERE empresa_id=e AND sessao_id=s.id),'total',(SELECT coalesce(sum(subtotal),0) FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado));
 ELSIF p_acao='imprimir_comanda' THEN
  IF NOT private.perm('rotisseria_lancar') AND NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Sem permissão para imprimir comanda.' USING errcode='42501'; END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid AND estado IN ('aberta','concluida') FOR SHARE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada nesta empresa.'; END IF;
  SELECT jsonb_agg(x.value ORDER BY i.criado_em,i.id,x.ord) INTO arr FROM private.rotisseria_itens i CROSS JOIN LATERAL private.rotisseria_item_impressao(i) WITH ORDINALITY x(value,ord) WHERE i.empresa_id=e AND i.sessao_id=s.id AND NOT i.cancelado;
  IF arr IS NULL THEN RAISE EXCEPTION 'A comanda não possui produtos para imprimir.'; END IF;
  result:=private.rotisseria_saldo(s.id,e);
  result:=jsonb_build_object('versao',1,'tipo','recibo','rotisseria_impressora_propria',true,'rotisseria_comanda_id',s.id,'numero_comanda',s.numero,
   'empresa_nome',(SELECT nome FROM public.empresas WHERE id=e),'empresa','COMANDA '||s.numero||' — '||(SELECT nome FROM public.empresas WHERE id=e),'setor','ROTISSERIA','data_hora',to_char(now() AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),
   'itens',arr,'total',(result->>'total')::numeric,'ja_pago',(result->>'total_pago')::numeric,'falta_pagar',(result->>'saldo')::numeric,
   'pagamentos',jsonb_build_array(jsonb_build_object('forma','Total já pago','valor',(result->>'total_pago')::numeric),jsonb_build_object('forma','Saldo pendente','valor',(result->>'saldo')::numeric)));
  IF p_dados->>'canal'='navegador' THEN RETURN result; END IF;
  IF p_dados->>'canal' IS DISTINCT FROM 'impressora' THEN RAISE EXCEPTION 'Escolha como imprimir a comanda.'; END IF;
  IF cfg.impressora_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.impressoras WHERE empresa_id=e AND id=cfg.impressora_id AND ativa) THEN RAISE EXCEPTION 'Selecione uma impressora ativa nas configurações da Rotisseria.'; END IF;
  IF jsonb_array_length(arr)>200 THEN RAISE EXCEPTION 'Para mais de 200 linhas, use Imprimir pelo navegador.'; END IF;
  IF nullif(p_dados->>'chave','') IS NULL THEN RAISE EXCEPTION 'Chave de impressão obrigatória.'; END IF;
  pid:=private.impressao_job_criar(e,'caixa','recibo','rotisseria:comanda:'||s.id||':'||(p_dados->>'chave')::uuid,'Comanda '||s.numero||' — Conferência de produtos',result,u);
  RETURN jsonb_build_object('job_id',pid);
 ELSIF p_acao='imprimir' THEN
  IF NOT dispositivo OR NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Imprima no dispositivo de caixa.' USING errcode='42501'; END IF;
  IF cfg.impressora_id IS NULL THEN RAISE EXCEPTION 'Selecione a impressora nas configurações da Rotisseria.'; END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND venda_id=(p_dados->>'venda_id')::uuid AND estado='concluida';
  IF s.id IS NULL OR nullif(p_dados->>'chave','') IS NULL THEN RAISE EXCEPTION 'Venda ou chave de impressão inválida.'; END IF;
  SELECT jsonb_agg(x.value ORDER BY i.criado_em,i.id,x.ord) INTO arr FROM private.rotisseria_itens i CROSS JOIN LATERAL private.rotisseria_item_impressao(i) WITH ORDINALITY x(value,ord) WHERE i.empresa_id=e AND i.sessao_id=s.id AND NOT i.cancelado;
  IF jsonb_array_length(arr)>200 THEN RAISE EXCEPTION 'Esta composição gera mais de 200 linhas. Use Imprimir comanda pelo navegador.';END IF;
  SELECT private.impressao_job_criar(e,'caixa','recibo','rotisseria:recibo:'||s.venda_id||':'||(p_dados->>'chave')::uuid,'Rotisseria — Comanda '||s.numero,
   jsonb_build_object('versao',1,'tipo','recibo','rotisseria_impressora_propria',true,'empresa',(SELECT nome FROM public.empresas WHERE id=e),'setor','ROTISSERIA','venda',(SELECT numero_venda FROM public.vendas WHERE empresa_id=e AND id=s.venda_id),'data_hora',to_char(s.finalizado_em AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),'itens',arr,'total',(SELECT total FROM public.vendas WHERE empresa_id=e AND id=s.venda_id),'pagamentos',(SELECT jsonb_agg(jsonb_build_object('forma',forma_pagamento,'valor',valor) ORDER BY ordem) FROM public.vendas_pagamentos WHERE empresa_id=e AND venda_id=s.venda_id)),u) INTO pid;
  RETURN jsonb_build_object('job_id',pid);
 ELSIF p_acao='historico' THEN
  IF NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Sem permissão para consultar vendas.' USING errcode='42501'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.criado_em DESC),'[]') FROM (SELECT v.*,s.numero comanda,s.id sessao_id,c.nome cliente_nome FROM public.vendas v JOIN private.rotisseria_sessoes s ON s.empresa_id=v.empresa_id AND s.venda_id=v.id LEFT JOIN public.clientes c ON c.empresa_id=v.empresa_id AND c.id=v.cliente_id WHERE v.empresa_id=e AND v.tipo='rotisseria' AND (nullif(p_dados->>'de','') IS NULL OR v.criado_em>=(p_dados->>'de')::date::timestamp AT TIME ZONE 'America/Sao_Paulo') AND (nullif(p_dados->>'ate','') IS NULL OR v.criado_em<((p_dados->>'ate')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo') ORDER BY v.criado_em DESC LIMIT 100 OFFSET greatest(0,coalesce((p_dados->>'pagina')::int,0))*100) x);
 ELSIF p_acao='caixa_dados' THEN
  IF NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Sem permissão para consultar caixa.' USING errcode='42501'; END IF;
  SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' AND status='aberto';
  RETURN jsonb_build_object('caixa',CASE WHEN c.id IS NOT NULL THEN private.caixa_json(c) ELSE NULL END,'resumo',CASE WHEN c.id IS NOT NULL THEN private.rotisseria_caixa_resumo(c) ELSE NULL END,
  'historico',CASE WHEN coalesce((p_dados->>'historico')::boolean,false) THEN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.aberto_em DESC),'[]') FROM (SELECT * FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' ORDER BY aberto_em DESC LIMIT 30) x) ELSE '[]'::jsonb END);
 ELSE RAISE EXCEPTION 'Ação da Rotisseria inválida.'; END IF;
 INSERT INTO public.rotisseria_sinais(empresa_id) VALUES(e) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.rotisseria_sinais.revisao+1;
 RETURN coalesce(result,'{}');
END $function$

;
CREATE OR REPLACE FUNCTION private.rotisseria_receber(p_dados jsonb, p_dispositivo uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
#variable_conflict use_column
DECLARE e uuid:=private.exigir_empresa_ativa();u uuid:=auth.uid();s private.rotisseria_sessoes;c public.caixas;p private.rotisseria_pagamentos;
 prod public.produtos;r record;consumo numeric;recebido numeric;restante numeric;credito numeric;entregue numeric;valor numeric;troco numeric:=0;
 forma text:=p_dados->>'forma';v_chave uuid;solicitacao jsonb:=p_dados-'chave';cliente uuid:=nullif(p_dados->>'cliente_id','')::uuid;
 cpf text:=nullif(regexp_replace(coalesce(p_dados->>'cpf',''),'[^0-9]','','g'),'');venc date:=nullif(p_dados->>'vencimento','')::date;
 saldo jsonb;v_resultado jsonb;permitido boolean;vid uuid;n bigint;titulo uuid;pid uuid;
BEGIN
 IF NOT private.empresa_tem_modulo('rotisseria') OR NOT private.perm('rotisseria_visualizar') OR NOT private.perm('rotisseria_caixa') OR NOT EXISTS(SELECT 1 FROM private.rotisseria_dispositivo d WHERE empresa_id=e AND token=p_dispositivo AND usuario_id=u) THEN RAISE EXCEPTION 'Recebimento disponível somente no caixa da Rotisseria.' USING errcode='42501'; END IF;
 SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' AND status='aberto' FOR SHARE;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Abra o caixa da Rotisseria antes de receber.'; END IF;
 SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid FOR UPDATE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
 v_chave:=coalesce(nullif(p_dados->>'chave','')::uuid,md5(s.id::text||coalesce(p_dados->>'versao','')||solicitacao::text)::uuid);
 SELECT * INTO p FROM private.rotisseria_pagamentos WHERE empresa_id=e AND rotisseria_pagamentos.chave=v_chave;
 IF p.id IS NOT NULL THEN
  IF p.sessao_id<>s.id OR p.solicitacao<>solicitacao THEN RAISE EXCEPTION 'Chave de recebimento já usada com outros dados.'; END IF;
  IF s.estado='concluida' THEN RETURN s.pagamento_resultado||jsonb_build_object('repetido',true,'finalizada',true,'troco',p.troco); END IF;
  RETURN p.resultado||private.rotisseria_saldo(s.id,e)||jsonb_build_object('repetido',true);
 END IF;
 IF s.estado='concluida' THEN RETURN s.pagamento_resultado||jsonb_build_object('ja_recebida',true,'finalizada',true); END IF;
 IF s.estado<>'aberta' OR (p_dados->>'versao')::bigint IS DISTINCT FROM s.versao THEN RAISE EXCEPTION 'A comanda mudou. Confira os itens e o saldo antes de receber.'; END IF;
 saldo:=private.rotisseria_saldo(s.id,e);consumo:=(saldo->>'total')::numeric;recebido:=(saldo->>'total_pago')::numeric;restante:=(saldo->>'saldo')::numeric;
 IF restante<=0 OR consumo<=0 THEN RAISE EXCEPTION 'A comanda não tem saldo para receber.'; END IF;
 IF forma IS NULL OR forma NOT IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito','Outros','Nota a Prazo') THEN RAISE EXCEPTION 'Escolha uma forma de pagamento.'; END IF;
 entregue:=round((p_dados->>'valor')::numeric,2);
 IF entregue IS NULL OR entregue<=0 OR entregue>99999999999.99 THEN RAISE EXCEPTION 'Informe um valor recebido válido.'; END IF;
 IF forma<>'Dinheiro' AND entregue>restante THEN RAISE EXCEPTION 'O valor supera o saldo da comanda.'; END IF;
 valor:=least(entregue,restante);troco:=entregue-valor;
 IF cliente IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.clientes WHERE empresa_id=e AND id=cliente) THEN RAISE EXCEPTION 'Cliente não encontrado nesta empresa.'; END IF;
 IF cpf IS NOT NULL AND NOT private.cpf_valido(cpf) THEN RAISE EXCEPTION 'CPF inválido.'; END IF;
 IF s.cliente_id IS NOT NULL AND cliente IS NOT NULL AND s.cliente_id<>cliente THEN RAISE EXCEPTION 'Mantenha o mesmo cliente dos recebimentos anteriores.'; END IF;
 cliente:=coalesce(cliente,s.cliente_id);cpf:=coalesce(cpf,s.cpf_nota);
 IF forma='Nota a Prazo' THEN
  IF cliente IS NULL OR venc IS NULL OR venc<(now() AT TIME ZONE 'America/Sao_Paulo')::date OR valor<>restante THEN RAISE EXCEPTION 'Nota a prazo exige cliente, vencimento válido e todo o saldo restante.'; END IF;
 END IF;
 -- Reserve stock once on the first payment. New items after that are deducted on launch.
 IF NOT s.estoque_baixado THEN
  SELECT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false) INTO permitido;
  PERFORM private.produtos_exigir_ativos(e,(SELECT array_agg(produto_id) FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado));
  FOR r IN SELECT * FROM private.rotisseria_baixas(e,s.id) ORDER BY produto_id LOOP
   SELECT * INTO prod FROM public.produtos WHERE empresa_id=e AND id=r.produto_id FOR UPDATE;
   IF NOT prod.ativo THEN RAISE EXCEPTION 'Produto inativo: %.',prod.nome; END IF;
   IF NOT permitido AND prod.quantidade_estoque<r.qtd THEN RAISE EXCEPTION 'Estoque insuficiente de %: disponível %, necessário %.',prod.nome,prod.quantidade_estoque,r.qtd; END IF;
   UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-r.qtd WHERE empresa_id=e AND id=r.produto_id;
  END LOOP;
 END IF;
 INSERT INTO private.rotisseria_pagamentos(empresa_id,sessao_id,caixa_id,chave,solicitacao,forma,valor,entregue,troco,metadados,criado_por)
 VALUES(e,s.id,c.id,v_chave,solicitacao,forma,valor,entregue,troco,coalesce(p_dados->'metadados','{}'),u) RETURNING id INTO pid;
 UPDATE private.rotisseria_sessoes SET estoque_baixado=true,cliente_id=cliente,cpf_nota=cpf,versao=versao+1 WHERE empresa_id=e AND id=s.id;
 v_resultado:=jsonb_build_object('finalizada',false,'total',consumo,'total_pago',recebido+CASE WHEN forma='Nota a Prazo' THEN 0 ELSE valor END,'saldo',restante-valor,'troco',troco,'pagamento_id',pid);
 IF valor=restante THEN
  v_resultado:=v_resultado||private.rotisseria_consolidar(s.id,e);
  UPDATE private.rotisseria_sessoes SET pagamento_resultado=v_resultado WHERE empresa_id=e AND id=s.id;
 END IF;
 UPDATE private.rotisseria_pagamentos SET resultado=v_resultado WHERE id=pid AND empresa_id=e;
 INSERT INTO public.rotisseria_sinais(empresa_id) VALUES(e) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.rotisseria_sinais.revisao+1;
 RETURN v_resultado;
END $function$

;
COMMIT;
