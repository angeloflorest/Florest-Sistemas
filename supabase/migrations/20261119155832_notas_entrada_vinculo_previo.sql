-- Expõe na conferência o mesmo vínculo fornecedor/código usado na confirmação.
-- Somente leitura: não dá entrada, não muda unidades ou fatores de produtos.
CREATE FUNCTION public.notas_entrada_produtos_vinculados(p_fornecedor uuid,p_codigos text[]) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $fn$
DECLARE e uuid:=private.empresa_id_ativa();result jsonb;
BEGIN
 IF e IS NULL OR NOT coalesce(private.perm('notas_entrada'),false) THEN RAISE EXCEPTION 'Sem permissão para vincular itens de Notas de Entrada.' USING ERRCODE='42501';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.fornecedores WHERE id=p_fornecedor AND empresa_id=e) THEN RAISE EXCEPTION 'Fornecedor não encontrado nesta empresa.' USING ERRCODE='42501';END IF;
 IF p_codigos IS NULL OR cardinality(p_codigos)>100 OR EXISTS(SELECT 1 FROM unnest(p_codigos) c WHERE c IS NULL OR length(c)>200 OR btrim(c)='') THEN RAISE EXCEPTION 'Lote de códigos do fornecedor inválido (até 100).';END IF;
 SELECT coalesce(jsonb_agg(jsonb_build_object('codigo_fornecedor',pf.codigo_produto_fornecedor,'produto',jsonb_build_object('id',p.id,'nome',p.nome,'codigo',p.codigo,'gtin',p.gtin,'unidade_comercial',p.unidade_comercial,'quantidade_estoque',p.quantidade_estoque,'preco_venda',p.preco_venda,'ativo',p.ativo)) ORDER BY pf.codigo_produto_fornecedor),'[]') INTO result
 FROM public.produto_fornecedor pf JOIN public.produtos p ON p.id=pf.produto_id AND p.empresa_id=e
 WHERE pf.empresa_id=e AND pf.fornecedor_id=p_fornecedor AND pf.codigo_produto_fornecedor=ANY(p_codigos);
 RETURN jsonb_build_object('versao','ne_vinculos_20261119_v1','vinculos',result);
END $fn$;
REVOKE ALL ON FUNCTION public.notas_entrada_produtos_vinculados(uuid,text[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.notas_entrada_produtos_vinculados(uuid,text[]) TO authenticated;
-- Mantém a rejeição de unidade divergente e identifica o item para permitir revisão.
DO $patch$
DECLARE src text;old text:=$old$RAISE EXCEPTION 'A unidade de estoque não corresponde ao produto vinculado.';$old$;
BEGIN
 src:=pg_get_functiondef('private.notas_entrada_confirmar(jsonb)'::regprocedure);
 IF strpos(src,old)=0 THEN RAISE EXCEPTION 'Validação de unidade mudou; revisar a função antes de aplicar.';END IF;
 src:=replace(src,old,$new$RAISE EXCEPTION 'A unidade de estoque do item "%" não corresponde ao produto vinculado "%". Unidade cadastrada: %. Unidade enviada: %. Reabra a conferência e revise o vínculo e a conversão.',v_desc,v_prod.nome,v_un_estoque,upper(btrim(v_it->>'unidade_estoque'));$new$);
 EXECUTE src;
END $patch$;
