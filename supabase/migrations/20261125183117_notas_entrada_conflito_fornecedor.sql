-- Mantém um código por fornecedor e registra a seleção excepcional no histórico da nota.
DO $patch$
DECLARE
  definition text;
  old_decl constant text := 'v_cod_forn  text;';
  old_values constant text := 'values (v_empresa, v_pid, v_forn, v_cod_forn, left(v_desc, 500), v_vu, coalesce(v_emissao, (now() at time zone ''America/Sao_Paulo'')::date))';
  old_insert constant text := 'insert into public.produto_fornecedor (empresa_id, produto_id, fornecedor_id, codigo_produto_fornecedor,';
BEGIN
  definition := pg_get_functiondef('private.notas_entrada_confirmar(jsonb)'::regprocedure);
  IF strpos(definition, old_decl) = 0 OR strpos(definition, old_values) = 0 OR strpos(definition, old_insert) = 0 THEN
    RAISE EXCEPTION 'A rotina de vínculo da nota mudou. Revise a migração.';
  END IF;
  definition := replace(definition, old_decl, old_decl || E'\n  v_vinculo_conflitante uuid;');
  definition := replace(definition, old_insert, $new$
    SELECT pf.produto_id INTO v_vinculo_conflitante
      FROM public.produto_fornecedor pf
     WHERE pf.empresa_id = v_empresa AND pf.fornecedor_id = v_forn
       AND pf.codigo_produto_fornecedor = v_cod_forn AND pf.produto_id <> v_pid;

    IF v_vinculo_conflitante IS DISTINCT FROM nullif(v_it->>'preservar_vinculo_fornecedor_id','')::uuid
       OR (v_vinculo_conflitante IS NOT NULL AND nullif(v_it->>'produto_id','')::uuid IS DISTINCT FROM v_pid) THEN
      RAISE EXCEPTION 'Confira o vínculo do item "%" (código % deste fornecedor) e confirme o produto a usar nesta nota.', v_desc, v_cod_forn;
    END IF;

    insert into public.produto_fornecedor (empresa_id, produto_id, fornecedor_id, codigo_produto_fornecedor,$new$);
  definition := replace(definition, old_values, $new$
    values (v_empresa, v_pid, v_forn,
            CASE WHEN v_vinculo_conflitante IS NULL THEN v_cod_forn END,
            CASE WHEN v_vinculo_conflitante IS NULL THEN left(v_desc, 500) END,
            v_vu, coalesce(v_emissao, (now() at time zone 'America/Sao_Paulo')::date))$new$);
  EXECUTE definition;
END $patch$;
