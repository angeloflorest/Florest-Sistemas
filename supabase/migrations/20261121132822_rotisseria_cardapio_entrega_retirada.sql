-- Somente pedidos públicos da Rotisseria; sem alterar pedidos anteriores ou demais módulos.
DO $migration$
DECLARE definition text;
BEGIN
 definition:=pg_get_functiondef('private.rotisseria_cardapio_publico(text,text,jsonb,uuid,text)'::regprocedure);
 IF md5(definition)<>'9b2c0af045baa67bb2e457fbfd49f2b3' THEN RAISE EXCEPTION 'Fluxo do cardápio da Rotisseria mudou. Recompare antes de aplicar.'; END IF;
 definition:=replace(definition,$old$ -- Validate all quantities, prices and recipes before allocating the sequential order.$old$,$new$ IF coalesce(p_dados->>'modalidade','retirada') NOT IN ('retirada','entrega') THEN RAISE EXCEPTION 'Escolha retirada ou entrega.';END IF;
 IF length(coalesce(p_dados->>'endereco',''))>500 OR (p_dados->>'modalidade'='entrega' AND length(btrim(coalesce(p_dados->>'endereco',''))) NOT BETWEEN 5 AND 500) THEN RAISE EXCEPTION 'Informe o endereço completo para entrega, até 500 caracteres.';END IF;
 -- Validate all quantities, prices and recipes before allocating the sequential order.$new$);
 definition:=replace(definition,$old$jsonb_build_object('nome',nome,'telefone',fone,'observacao',coalesce(p_dados->>'observacao',''))$old$,$new$jsonb_build_object('nome',nome,'telefone',fone,'observacao',coalesce(p_dados->>'observacao',''),'modalidade',coalesce(p_dados->>'modalidade','retirada'),'endereco',CASE WHEN p_dados->>'modalidade'='entrega' THEN btrim(p_dados->>'endereco') ELSE '' END)$new$);
 EXECUTE definition;
END $migration$;
