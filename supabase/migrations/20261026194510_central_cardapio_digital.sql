-- PROPOSTA SEPARADA. NÃO EXECUTADA EM PRODUÇÃO.
-- Validar em homologação e registrar como nova migration antes da aplicação autorizada.
-- Não substitui o RPC público, não toca impressão, estoque, pagamentos ou fiscal.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('public.gastronomia_cardapio_publico(text,text,jsonb,uuid)') IS NULL
 OR to_regprocedure('private.gastronomia_exigir(text)') IS NULL
 OR to_regclass('private.gastronomia_pedidos_publicos') IS NULL
 OR to_regclass('public.clientes') IS NULL THEN
  RAISE EXCEPTION 'Base incompatível: exige Cardápio e Pedidos instalado. Não remover esta guarda.';
 END IF;
 IF md5(pg_get_functiondef('public.gastronomia_cardapio_publico(text,text,jsonb,uuid)'::regprocedure))<>'562cdee31390ac0307bf2571690c7e49' THEN
  RAISE EXCEPTION 'RPC público mudou desde a base conferida. Reavaliar compatibilidade; não remover a guarda.';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.gastronomia_atendimentos'::regclass AND attname='cliente_id' AND NOT attisdropped)
 OR NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.clientes'::regclass AND attname='telefone' AND NOT attisdropped) THEN
  RAISE EXCEPTION 'Base incompatível: conferir clientes e atendimentos antes de prosseguir.';
 END IF;
 IF to_regclass('private.gastronomia_central_config') IS NOT NULL
 OR EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='gastronomia_consumidor_confirmado' AND tgrelid='private.gastronomia_pedidos_publicos'::regclass) THEN
  RAISE EXCEPTION 'A Central já existe ou foi parcialmente instalada. Conferir histórico; não reinstalar.';
 END IF;
END $$;

CREATE TABLE private.gastronomia_central_config (
 empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id),
 composicao jsonb NOT NULL DEFAULT '{}',
 atualizado_em timestamptz NOT NULL DEFAULT now(),
 CHECK(jsonb_typeof(composicao)='object' AND octet_length(composicao::text)<=4000000)
);
ALTER TABLE private.gastronomia_central_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_central_config FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.gastronomia_central_artes(p_salvar jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_configurar'); v jsonb; k text;
BEGIN
 IF p_salvar IS NOT NULL THEN
  IF jsonb_typeof(p_salvar)<>'object' OR octet_length(p_salvar::text)>4000000 THEN RAISE EXCEPTION 'Composição inválida ou imagem muito grande.'; END IF;
  IF coalesce((p_salvar->>'template')::int,-1) NOT BETWEEN 0 AND 5
  OR length(coalesce(p_salvar->>'name','')) NOT BETWEEN 1 AND 160 THEN RAISE EXCEPTION 'Escolha arte e nome válidos.'; END IF;
  FOREACH k IN ARRAY ARRAY['background','logo'] LOOP
   IF coalesce(p_salvar->>k,'')<>'' AND (p_salvar->>k !~ '^data:image/(png|jpeg);base64,[A-Za-z0-9+/=]+$' OR length(p_salvar->>k)>3500000) THEN RAISE EXCEPTION 'Imagem inválida: use PNG ou JPG.'; END IF;
  END LOOP;
  IF (p_salvar->>'template')::int=5 AND coalesce(p_salvar->>'background','')='' THEN RAISE EXCEPTION 'Envie a arte personalizada.'; END IF;
  FOREACH k IN ARRAY ARRAY['qrX','qrY','qrSize','tableX','tableY'] LOOP
   IF NOT p_salvar ? k OR (p_salvar->>k)::numeric NOT BETWEEN 0 AND 100 THEN RAISE EXCEPTION 'Posição da composição inválida.'; END IF;
  END LOOP;
  IF (p_salvar->>'qrSize')::numeric<30 OR (p_salvar->>'qrX')::numeric+(p_salvar->>'qrSize')::numeric>100 THEN RAISE EXCEPTION 'QR Code fora da composição ou pequeno demais.'; END IF;
  v:=jsonb_build_object('template',(p_salvar->>'template')::int,'name',p_salvar->>'name','background',coalesce(p_salvar->>'background',''),'logo',coalesce(p_salvar->>'logo',''),'qrX',(p_salvar->>'qrX')::numeric,'qrY',(p_salvar->>'qrY')::numeric,'qrSize',(p_salvar->>'qrSize')::numeric,'tableX',(p_salvar->>'tableX')::numeric,'tableY',(p_salvar->>'tableY')::numeric);
  IF coalesce(p_salvar->>'format','10 × 15 cm') NOT IN ('10 × 15 cm','A6','A4') OR coalesce(p_salvar->>'paper','A4') NOT IN ('10 × 15 cm','A6','A4') THEN RAISE EXCEPTION 'Formato de arte ou papel inválido.'; END IF;
  v:=v||jsonb_build_object('format',coalesce(p_salvar->>'format','10 × 15 cm'),'paper',coalesce(p_salvar->>'paper','A4'));
  INSERT INTO private.gastronomia_central_config(empresa_id,composicao) VALUES(e,v)
  ON CONFLICT(empresa_id) DO UPDATE SET composicao=excluded.composicao,atualizado_em=now();
 END IF;
 RETURN coalesce((SELECT composicao FROM private.gastronomia_central_config WHERE empresa_id=e),'{}'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.gastronomia_central_artes(jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_central_artes(jsonb) TO authenticated;

-- Telefone brasileiro canônico sem prefixo 55. Não modifica cadastros anteriores.
CREATE FUNCTION private.gastronomia_telefone_canonico(p_telefone text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path='' AS $$
 SELECT CASE WHEN length(t) IN (12,13) AND left(t,2)='55' THEN substr(t,3) ELSE t END
 FROM (SELECT regexp_replace(coalesce(p_telefone,''),'[^0-9]','','g') t) s
$$;
REVOKE ALL ON FUNCTION private.gastronomia_telefone_canonico(text) FROM PUBLIC,anon,authenticated;

ALTER TABLE private.gastronomia_pedidos_publicos ADD COLUMN consumidor_id uuid REFERENCES public.clientes(id);

CREATE FUNCTION private.gastronomia_consumidor_confirmado()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_telefone text:=private.gastronomia_telefone_canonico(NEW.dados->>'telefone'); cliente uuid; qtd int;
BEGIN
 -- O link, a empresa e a mesa já foram validados pelo RPC; conferir o vínculo novamente.
 IF NOT EXISTS(SELECT 1 FROM private.gastronomia_links l JOIN public.gastronomia_atendimentos a ON a.id=NEW.atendimento_id AND a.empresa_id=l.empresa_id WHERE l.id=NEW.link_id AND l.empresa_id=NEW.empresa_id AND l.mesa_id IS NOT DISTINCT FROM a.mesa_id) THEN RAISE EXCEPTION 'Vínculo de empresa ou mesa inválido.' USING ERRCODE='42501'; END IF;
 IF v_telefone !~ '^[1-9][0-9]{9,10}$' OR length(btrim(coalesce(NEW.dados->>'nome','')))<2 THEN RAISE EXCEPTION 'Informe nome e telefone com DDD válidos.'; END IF;
 -- Serializa cadastros concorrentes pelo mesmo telefone na mesma empresa.
 PERFORM pg_advisory_xact_lock(hashtextextended(NEW.empresa_id::text||':consumidor:'||v_telefone,0));
 SELECT c.id INTO cliente FROM public.clientes c WHERE c.empresa_id=NEW.empresa_id AND private.gastronomia_telefone_canonico(c.telefone)=v_telefone ORDER BY c.criado_em,c.id LIMIT 1;
 IF cliente IS NULL THEN
  -- Limite adicional de novos cadastros. Mesmo pedido repetido não dispara o trigger novamente.
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.empresa_id::text||':consumidor:limite',0));
  SELECT count(*) INTO qtd FROM private.gastronomia_pedidos_publicos p WHERE p.empresa_id=NEW.empresa_id AND p.consumidor_id IS NOT NULL AND p.criado_em>now()-interval '1 minute';
  IF qtd>=60 THEN RAISE EXCEPTION 'Limite temporário de cadastros. Aguarde ou chame o atendimento.'; END IF;
  INSERT INTO public.clientes(empresa_id,nome,telefone) VALUES(NEW.empresa_id,btrim(NEW.dados->>'nome'),v_telefone) RETURNING id INTO cliente;
 END IF;
 UPDATE private.gastronomia_pedidos_publicos SET consumidor_id=cliente WHERE empresa_id=NEW.empresa_id AND chave=NEW.chave;
 -- Mesa compartilhada: manter o primeiro responsável; o consumidor de cada pedido fica separado.
 UPDATE public.gastronomia_atendimentos SET cliente_id=cliente WHERE id=NEW.atendimento_id AND empresa_id=NEW.empresa_id AND cliente_id IS NULL;
 UPDATE public.gastronomia_itens SET snapshot=snapshot||jsonb_build_object('consumidor_id',cliente)
 WHERE empresa_id=NEW.empresa_id AND atendimento_id=NEW.atendimento_id AND snapshot->>'lote'=NEW.chave::text;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_consumidor_confirmado() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER gastronomia_consumidor_confirmado AFTER INSERT ON private.gastronomia_pedidos_publicos
FOR EACH ROW EXECUTE FUNCTION private.gastronomia_consumidor_confirmado();
COMMIT;
