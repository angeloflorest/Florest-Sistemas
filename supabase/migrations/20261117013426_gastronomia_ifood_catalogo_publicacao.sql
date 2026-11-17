-- Catálogo privado por empresa. Apenas itens gerenciados pela Florest são publicados/pausados.
CREATE TABLE private.gastronomia_ifood_catalogo (
 empresa_id uuid NOT NULL REFERENCES public.empresas(id),produto_id uuid NOT NULL REFERENCES public.produtos(id),
 item_id uuid NOT NULL,payload jsonb NOT NULL,hash text NOT NULL,estado text NOT NULL DEFAULT 'pendente' CHECK(estado IN ('pendente','processando','publicado','erro')),
 erro text,remoto jsonb,atualizado_em timestamptz NOT NULL DEFAULT now(),processado_em timestamptz,lease_ate timestamptz,
 PRIMARY KEY(empresa_id,produto_id),UNIQUE(empresa_id,item_id)
);
ALTER TABLE private.gastronomia_ifood_catalogo ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_ifood_catalogo FROM PUBLIC,anon,authenticated;
CREATE INDEX gastronomia_ifood_catalogo_fila ON private.gastronomia_ifood_catalogo(empresa_id,estado,atualizado_em);
CREATE FUNCTION private.gastronomia_ifood_catalogo_enfileirar(p_empresa uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE c jsonb;r record;doc jsonb;grp jsonb;cat text;catname text;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.gastronomia_ifood_config WHERE empresa_id=p_empresa AND habilitada AND ambiente='teste' AND empresa_id='773dfacb-c0e7-4bd9-8eb4-5208818b1848' AND merchant_id='9dc78f12-d874-4d66-a454-40268effa19d') THEN RETURN;END IF;
 SELECT opcoes->'cardapio' INTO c FROM public.gastronomia_configuracoes WHERE empresa_id=p_empresa;
 FOR r IN SELECT p.*,m.value menu,bp.id operacional_id FROM public.produtos p
 LEFT JOIN LATERAL (SELECT value FROM jsonb_array_elements(coalesce(c->'produtos','[]')) WHERE value->>'id'=p.id::text LIMIT 1) m ON true
 LEFT JOIN private.gastronomia_produtos_operacionais bp ON bp.produto_id=p.id AND bp.empresa_id=p_empresa
 WHERE p.empresa_id=p_empresa AND coalesce(p.codigo,'') NOT LIKE 'IFTEST-%' AND (coalesce((m.value->>'ativo')::boolean,false) OR EXISTS(SELECT 1 FROM private.gastronomia_ifood_catalogo q WHERE q.empresa_id=p_empresa AND q.produto_id=p.id)) LOOP
 cat:=coalesce(r.menu->>'categoria','sem-categoria');
 SELECT coalesce((SELECT parent.value->>'nome' FROM jsonb_array_elements(coalesce(c->'categorias','[]')) parent WHERE parent.value->>'id'=x.value->>'pai')||' / ','')||(x.value->>'nome') INTO catname FROM jsonb_array_elements(coalesce(c->'categorias','[]')) x WHERE x.value->>'id'=cat;
 SELECT coalesce(jsonb_agg(jsonb_build_object('id',g.id,'nome',g.nome,'minimo',coalesce((c#>>ARRAY['regras_grupos',g.id::text,'minimo'])::int,g.quantidade_escolhas),'maximo',coalesce((c#>>ARRAY['regras_grupos',g.id::text,'maximo'])::int,g.quantidade_escolhas),'opcoes',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',o.id,'produto_id',p.id,'nome',p.nome,'ativo',p.ativo) ORDER BY o.ordem),'[]') FROM private.gastronomia_opcoes_operacionais o JOIN public.produtos p ON p.id=o.produto_id AND p.empresa_id=p_empresa WHERE o.empresa_id=p_empresa AND o.grupo_id=g.id)) ORDER BY g.ordem),'[]') INTO grp FROM private.gastronomia_grupos_operacionais g WHERE g.empresa_id=p_empresa AND g.bar_produto_id=r.operacional_id;
 doc:=jsonb_build_object('id',r.id,'nome',r.nome,'preco',r.preco_venda,'foto',coalesce(r.menu->>'foto',''),'ativo',r.ativo AND coalesce((r.menu->>'ativo')::boolean,false),'categoria',cat,'categoria_nome',coalesce(catname,'Cardápio'),'grupos',grp);
 INSERT INTO private.gastronomia_ifood_catalogo(empresa_id,produto_id,item_id,payload,hash) VALUES(p_empresa,r.id,md5('florest-ifood-item:'||p_empresa::text||':'||r.id::text)::uuid,doc,md5(doc::text))
 ON CONFLICT(empresa_id,produto_id) DO UPDATE SET payload=excluded.payload,hash=excluded.hash,estado='pendente',erro=NULL,atualizado_em=now(),lease_ate=NULL WHERE gastronomia_ifood_catalogo.hash<>excluded.hash;
 END LOOP;
END $fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_catalogo_enfileirar(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.gastronomia_ifood_catalogo_config_trigger() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$ BEGIN IF (OLD.opcoes->'cardapio') IS DISTINCT FROM (NEW.opcoes->'cardapio') THEN PERFORM private.gastronomia_ifood_catalogo_enfileirar(NEW.empresa_id);END IF;RETURN NEW;END $fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_catalogo_config_trigger() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER gastronomia_ifood_catalogo_config AFTER UPDATE OF opcoes ON public.gastronomia_configuracoes FOR EACH ROW EXECUTE FUNCTION private.gastronomia_ifood_catalogo_config_trigger();
CREATE FUNCTION public.gastronomia_ifood_catalogo_estado(p_empresa uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_configurar');BEGIN
 IF p_empresa IS DISTINCT FROM e THEN RAISE EXCEPTION 'Empresa inválida.' USING ERRCODE='42501';END IF;
 RETURN jsonb_build_object('empresa_id',e,'resumo',(SELECT coalesce(jsonb_agg(to_jsonb(z)),'[]') FROM (SELECT estado,count(*) total FROM private.gastronomia_ifood_catalogo WHERE empresa_id=e GROUP BY estado) z),'falhas',(SELECT coalesce(jsonb_agg(jsonb_build_object('produto',payload->>'nome','erro',erro)),'[]') FROM private.gastronomia_ifood_catalogo WHERE empresa_id=e AND estado='erro'),'avisos',(SELECT coalesce(jsonb_agg(jsonb_build_object('produto',payload->>'nome','aviso',remoto->>'aviso')),'[]') FROM private.gastronomia_ifood_catalogo WHERE empresa_id=e AND remoto->>'aviso' IS NOT NULL));END $fn$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_catalogo_estado(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_catalogo_estado(uuid) TO authenticated;
CREATE FUNCTION public.gastronomia_ifood_catalogo_worker(p_acao text,p_empresa uuid,p_dados jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE r private.gastronomia_ifood_catalogo;BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.gastronomia_ifood_config WHERE empresa_id=p_empresa AND habilitada AND ambiente='teste' AND empresa_id='773dfacb-c0e7-4bd9-8eb4-5208818b1848' AND merchant_id='9dc78f12-d874-4d66-a454-40268effa19d') THEN RETURN '[]';END IF;
 IF p_acao='listar' THEN RETURN (SELECT coalesce(jsonb_agg(to_jsonb(z)),'[]') FROM (SELECT produto_id FROM private.gastronomia_ifood_catalogo WHERE empresa_id=p_empresa AND (estado='pendente' OR (estado='processando' AND lease_ate<now())) ORDER BY atualizado_em LIMIT 30) z);
 ELSIF p_acao='reservar' THEN
 UPDATE private.gastronomia_ifood_catalogo SET estado='processando',lease_ate=now()+interval '90 seconds' WHERE empresa_id=p_empresa AND produto_id=(p_dados->>'produto_id')::uuid AND (estado='pendente' OR (estado='processando' AND lease_ate<now())) RETURNING * INTO r;RETURN CASE WHEN r.produto_id IS NULL THEN NULL ELSE to_jsonb(r) END;
 ELSIF p_acao='resultado' THEN
 UPDATE private.gastronomia_ifood_catalogo SET estado=CASE WHEN coalesce((p_dados->>'ok')::boolean,false) THEN 'publicado' ELSE 'erro' END,erro=left(p_dados->>'erro',500),remoto=p_dados->'remoto',lease_ate=NULL,processado_em=now() WHERE empresa_id=p_empresa AND produto_id=(p_dados->>'produto_id')::uuid AND hash=p_dados->>'hash' AND estado='processando';
 IF coalesce((p_dados->>'ok')::boolean,false) THEN
 FOR r IN SELECT * FROM private.gastronomia_ifood_catalogo WHERE empresa_id=p_empresa AND produto_id=(p_dados->>'produto_id')::uuid AND hash=p_dados->>'hash' LOOP
 INSERT INTO private.gastronomia_ifood_vinculos(empresa_id,tipo,codigo_externo,produto_id) VALUES(p_empresa,'produto','GS-'||r.produto_id::text,r.produto_id) ON CONFLICT(empresa_id,tipo,codigo_externo) DO UPDATE SET produto_id=excluded.produto_id,ativo=true;
 INSERT INTO private.gastronomia_ifood_vinculos(empresa_id,tipo,codigo_externo,produto_id) SELECT p_empresa,'adicional','GSO-'||(op->>'id'),(op->>'produto_id')::uuid FROM jsonb_array_elements(r.payload->'grupos') g CROSS JOIN LATERAL jsonb_array_elements(g->'opcoes') op ON CONFLICT(empresa_id,tipo,codigo_externo) DO UPDATE SET produto_id=excluded.produto_id,ativo=true;
 END LOOP;END IF;
 ELSE RAISE EXCEPTION 'Ação inválida.';END IF;RETURN '{}';END $fn$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_catalogo_worker(text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_catalogo_worker(text,uuid,jsonb) TO service_role;
-- Mudança de preço/nome/ativação atualiza somente o catálogo habilitado, sem observar estoque.
CREATE FUNCTION private.gastronomia_ifood_catalogo_produto_trigger() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$ BEGIN
 IF (OLD.nome,OLD.preco_venda,OLD.ativo) IS DISTINCT FROM (NEW.nome,NEW.preco_venda,NEW.ativo) THEN PERFORM private.gastronomia_ifood_catalogo_enfileirar(NEW.empresa_id);END IF;RETURN NEW;END $fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_catalogo_produto_trigger() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER gastronomia_ifood_catalogo_produto AFTER UPDATE OF nome,preco_venda,ativo ON public.produtos FOR EACH ROW EXECUTE FUNCTION private.gastronomia_ifood_catalogo_produto_trigger();
