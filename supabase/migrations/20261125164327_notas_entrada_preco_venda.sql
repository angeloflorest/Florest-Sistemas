-- Atualiza o preço de venda dentro da mesma transação de confirmação da nota.
DO $patch$
DECLARE
  definition text;
  previous_update constant text :=
    'update public.produtos set quantidade_estoque = v_nova, preco_custo = v_custo_estoque where id = v_pid and empresa_id = v_empresa;';
BEGIN
  definition := pg_get_functiondef('private.notas_entrada_confirmar(jsonb)'::regprocedure);
  IF strpos(definition, previous_update) = 0 THEN
    RAISE EXCEPTION 'A confirmação da nota mudou. Revise a atualização do produto.';
  END IF;
  EXECUTE replace(definition, previous_update, $replacement$
    v_pv := nullif(v_it->>'preco_venda_atualizado', '')::numeric;
    IF v_pv IS NOT NULL THEN
      IF nullif(v_it->>'produto_id', '')::uuid IS DISTINCT FROM v_pid THEN
        RAISE EXCEPTION 'Vincule o produto antes de editar o preço de venda.';
      END IF;
      IF NOT coalesce(private.perm_alguma(ARRAY['produtos','estoque']), false) THEN
        RAISE EXCEPTION 'Sem permissão para editar o preço de venda.' USING ERRCODE = '42501';
      END IF;
      IF v_pv < 0 OR v_pv > 999999999999.99 OR v_pv <> round(v_pv, 2) THEN
        RAISE EXCEPTION 'Preço de venda inválido para "%".', v_desc;
      END IF;
      UPDATE public.produtos
         SET quantidade_estoque = v_nova, preco_custo = v_custo_estoque, preco_venda = v_pv
       WHERE id = v_pid AND empresa_id = v_empresa;
    ELSE
      UPDATE public.produtos
         SET quantidade_estoque = v_nova, preco_custo = v_custo_estoque
       WHERE id = v_pid AND empresa_id = v_empresa;
    END IF;
$replacement$);
END $patch$;
