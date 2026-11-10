-- Corrige somente o envio de fotos do Gastronomia, sem conceder acesso a empresa_modulos.
CREATE FUNCTION private.gastronomia_foto_pode_inserir(p_nome text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_configurar');
BEGIN
 RETURN split_part(p_nome,'/',1)=e::text
  AND EXISTS(SELECT 1 FROM public.produtos p WHERE p.empresa_id=e AND p.id::text=split_part(p_nome,'/',2) AND p.ativo);
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_foto_pode_inserir(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.gastronomia_foto_pode_inserir(text) TO authenticated;
ALTER POLICY gastronomia_fotos_inserir_empresa ON storage.objects TO authenticated
 WITH CHECK(bucket_id='gastronomia-fotos' AND private.gastronomia_foto_pode_inserir(name));
