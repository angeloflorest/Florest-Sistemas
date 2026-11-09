-- Conferência exclusiva do Gastronomia; reutiliza permissões e bloqueio do caixa existente.
CREATE OR REPLACE FUNCTION public.gastronomia_caixa_fechar(p_caixa_id uuid,p_valor_contado numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
 e uuid:=private.exigir_empresa_ativa();
 c public.caixas%rowtype;
 result jsonb;
 resumo jsonb;
 contado numeric;
 esperado numeric;
BEGIN
 IF NOT private.caixa_pode_operar('GASTRONOMIA') THEN
  RAISE EXCEPTION 'Sem permissão para fechar o caixa da Gastronomia.' USING ERRCODE='42501';
 END IF;
 IF p_valor_contado IS NULL OR p_valor_contado::text IN ('NaN','Infinity','-Infinity') OR p_valor_contado<0 OR p_valor_contado>99999999999.99 THEN
  RAISE EXCEPTION 'Informe um valor contado válido, zero ou maior.' USING ERRCODE='22023';
 END IF;
 SELECT * INTO c FROM public.caixas WHERE id=p_caixa_id AND empresa_id=e AND tipo_caixa='GASTRONOMIA' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Caixa da Gastronomia não encontrado.'; END IF;
 -- O fechamento original revalida permissões/status e calcula os valores sob o mesmo bloqueio.
 result:=public.caixa_fechar(c.id);
 resumo:=result->'resumo';
 contado:=round(p_valor_contado,2);
 esperado:=(resumo->>'saldo_dinheiro_esperado')::numeric;
 resumo:=resumo||jsonb_build_object('conferencia_dinheiro',jsonb_build_object('valor_contado',contado,'valor_esperado',esperado,'diferenca',contado-esperado));
 UPDATE public.caixas SET fechamento_resumo=resumo WHERE id=c.id AND empresa_id=e;
 RETURN result||jsonb_build_object('resumo',resumo);
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_caixa_fechar(uuid,numeric) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_caixa_fechar(uuid,numeric) TO authenticated;

-- Os leitores existentes recebem o resumo congelado do Gastronomia após o fechamento.
DO $migration$
DECLARE definition text;
BEGIN
 definition:=pg_get_functiondef('private.gastronomia_caixa_calcular(public.caixas)'::regprocedure);
 IF position('p_caixa.fechamento_resumo' in definition)=0 THEN
  definition:=replace(definition,'BEGIN','BEGIN IF p_caixa.status=''fechado'' AND p_caixa.fechamento_resumo IS NOT NULL THEN RETURN p_caixa.fechamento_resumo; END IF;');
  EXECUTE definition;
 END IF;
END $migration$;
NOTIFY pgrst,'reload schema';
