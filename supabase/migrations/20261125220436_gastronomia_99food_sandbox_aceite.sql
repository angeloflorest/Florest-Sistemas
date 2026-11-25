ALTER TABLE public.gastronomia_99food_sandbox_recebimentos
  ADD COLUMN estado text NOT NULL DEFAULT 'recebido' CHECK (estado IN ('recebido','aceito','encerrado')),
  ADD COLUMN aceite_reservado_ate timestamptz,
  ADD COLUMN atualizado_em timestamptz;
GRANT UPDATE (estado, aceite_reservado_ate, atualizado_em)
  ON public.gastronomia_99food_sandbox_recebimentos TO service_role;

CREATE FUNCTION private.gastronomia_99food_sandbox_pedidos(p_empresa uuid, p_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE empresa uuid := private.empresa_id_ativa();
BEGIN
  IF auth.uid() IS NULL OR empresa IS DISTINCT FROM p_empresa
     OR empresa IS DISTINCT FROM '773dfacb-c0e7-4bd9-8eb4-5208818b1848'::uuid THEN
    RETURN '[]'::jsonb;
  END IF;
  PERFORM private.gastronomia_exigir('gastronomia_pedidos');
  RETURN (
    SELECT coalesce(jsonb_agg(to_jsonb(pedido) ORDER BY recebido_em DESC),'[]'::jsonb)
    FROM (
      SELECT order_id, order_index, recebido_em, estado
      FROM public.gastronomia_99food_sandbox_recebimentos
      WHERE app_shop_id='florest-gastronomia-teste-01'
        AND (p_order_id IS NULL OR order_id=p_order_id)
      ORDER BY recebido_em DESC LIMIT 30
    ) pedido
  );
END $$;

CREATE FUNCTION public.gastronomia_99food_sandbox_pedidos(p_empresa uuid, p_order_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
  SELECT private.gastronomia_99food_sandbox_pedidos(p_empresa,p_order_id);
$$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_sandbox_pedidos(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.gastronomia_99food_sandbox_pedidos(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.gastronomia_99food_sandbox_pedidos(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.gastronomia_99food_sandbox_pedidos(uuid,text) TO authenticated;
NOTIFY pgrst, 'reload schema';
