CREATE FUNCTION public.gastronomia_ifood_catalogo_repetir(p_empresa uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_configurar');BEGIN
IF p_empresa IS DISTINCT FROM e THEN RAISE EXCEPTION 'Empresa inválida.' USING ERRCODE='42501';END IF;
UPDATE private.gastronomia_ifood_catalogo SET estado='pendente',erro=NULL,lease_ate=NULL,remoto=coalesce(remoto,'{}')-'verificar'-'verificacoes' WHERE empresa_id=e AND estado='erro';
RETURN public.gastronomia_ifood_catalogo_estado(e);END $fn$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_catalogo_repetir(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_catalogo_repetir(uuid) TO authenticated;
