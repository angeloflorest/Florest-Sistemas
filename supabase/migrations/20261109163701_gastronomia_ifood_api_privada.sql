-- Autorização privilegiada somente em função privada; API pública executa como chamador.
DO $migration$
DECLARE definition text;
BEGIN
 definition:=pg_get_functiondef('public.gastronomia_ifood_admin(text,jsonb)'::regprocedure);
 definition:=replace(definition,'FUNCTION public.gastronomia_ifood_admin','FUNCTION private.gastronomia_ifood_admin');
 EXECUTE definition;
END $migration$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_admin(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.gastronomia_ifood_admin(text,jsonb) TO authenticated;
CREATE OR REPLACE FUNCTION public.gastronomia_ifood_admin(p_acao text,p_dados jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$
 SELECT private.gastronomia_ifood_admin(p_acao,p_dados);
$$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_admin(text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_admin(text,jsonb) TO authenticated;
NOTIFY pgrst,'reload schema';
