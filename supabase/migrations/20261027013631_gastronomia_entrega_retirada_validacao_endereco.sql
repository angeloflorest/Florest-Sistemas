-- Correção autorizada do link geral. Não altera o ramo de mesas.
BEGIN;
DO $correcao$
DECLARE original text; atualizado text;
BEGIN
 original:=pg_get_functiondef('public.gastronomia_cardapio_publico(text,text,jsonb,uuid)'::regprocedure);
 IF md5(original)<>'be4209b434e587d15b25c6885491dda1' THEN RAISE EXCEPTION 'RPC público mudou. Recomparar sem remover a guarda.'; END IF;
 atualizado:=replace(original,$antes$IF d->>'tipo'='entrega' AND (length(btrim(coalesce(d->>'endereco','')))<8 OR length(d->>'endereco')>500) THEN RAISE EXCEPTION 'Informe o endereço completo.'; END IF;$antes$,$depois$IF regexp_replace(coalesce(d->>'telefone',''),'[^0-9]','','g') !~ '^(55)?[1-9][0-9][0-9]{8,9}$' THEN RAISE EXCEPTION 'Informe um telefone válido com DDD.'; END IF;
  IF d->>'tipo'='entrega' THEN
   IF jsonb_typeof(d->'rua') IS DISTINCT FROM 'string' OR length(btrim(coalesce(d->>'rua',''))) NOT BETWEEN 2 AND 200 THEN RAISE EXCEPTION 'Informe a rua ou avenida da entrega.'; END IF;
   IF jsonb_typeof(d->'numero_endereco') IS DISTINCT FROM 'string' OR length(btrim(coalesce(d->>'numero_endereco',''))) NOT BETWEEN 1 AND 20 OR btrim(d->>'numero_endereco') !~* '^([0-9]+[A-Za-z0-9 /.-]*|S[[:space:]]*/?[[:space:]]*N)$' THEN RAISE EXCEPTION 'Informe o número da entrega ou S/N quando não houver número.'; END IF;
   IF jsonb_typeof(d->'bairro') IS DISTINCT FROM 'string' OR length(btrim(coalesce(d->>'bairro',''))) NOT BETWEEN 2 AND 120 THEN RAISE EXCEPTION 'Informe o bairro da entrega.'; END IF;
   IF d->>'endereco' IS DISTINCT FROM btrim(d->>'rua')||', '||btrim(d->>'numero_endereco')||' — '||btrim(d->>'bairro') THEN RAISE EXCEPTION 'Confira rua, número e bairro da entrega.'; END IF;
  END IF;$depois$);
 IF atualizado=original THEN RAISE EXCEPTION 'Validação esperada ausente. Nenhuma alteração aplicada.'; END IF;
 EXECUTE atualizado;
END $correcao$;
COMMIT;
