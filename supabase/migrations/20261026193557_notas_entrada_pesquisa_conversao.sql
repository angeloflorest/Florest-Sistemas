-- PROPOSTA: somente Notas de Entrada. Não aplicada em produção.
-- Base real conferida em leitura. Não remover as guardas nem reinstalar migrations antigas.
BEGIN;
DO $$ BEGIN
 IF to_regprocedure('private.notas_entrada_confirmar(jsonb)') IS NULL OR to_regprocedure('public.notas_entrada_confirmar(jsonb)') IS NULL THEN RAISE EXCEPTION 'Base de Notas de Entrada ausente.'; END IF;
 IF md5(replace(pg_get_functiondef('private.notas_entrada_confirmar(jsonb)'::regprocedure),chr(13),''))<>'1b5fc5b8015a3d5117be7489a4deb1bf'
 OR md5(replace(pg_get_functiondef('public.notas_entrada_confirmar(jsonb)'::regprocedure),chr(13),''))<>'de46b94731b8a8aaa79010286300be77' THEN RAISE EXCEPTION 'Notas de Entrada mudou desde a conferência. Reavaliar; não remover esta guarda.'; END IF;
 IF EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.notas_entrada_itens'::regclass AND attname='fator_conversao' AND NOT attisdropped)
 OR to_regprocedure('public.notas_entrada_produtos_buscar(text,integer,text[])') IS NOT NULL THEN RAISE EXCEPTION 'Correção já aplicada ou base parcialmente alterada. Conferir histórico.'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_index WHERE indrelid='public.notas_entrada'::regclass AND indisunique AND pg_get_indexdef(indexrelid) LIKE '%(empresa_id, chave_acesso)%') THEN RAISE EXCEPTION 'Garantia única por empresa/chave ausente. Não prosseguir.'; END IF;
END $$;
ALTER TABLE public.notas_entrada_itens
 ADD COLUMN quantidade_recebida numeric(14,4), ADD COLUMN unidade_compra text,
 ADD COLUMN fator_conversao numeric(18,6), ADD COLUMN unidade_estoque text,
 ADD COLUMN quantidade_estoque_entrada numeric(14,4), ADD COLUMN custo_unitario_estoque numeric(14,4),
 ADD CONSTRAINT ne_conversao_positiva CHECK(fator_conversao IS NULL OR (fator_conversao>0 AND quantidade_recebida>0 AND quantidade_estoque_entrada>0 AND custo_unitario_estoque>=0));
-- Colunas novas são nulas nas notas anteriores; não há reprocessamento de estoque.
CREATE OR REPLACE FUNCTION private.notas_entrada_confirmar(p_nota jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_empresa   uuid := private.exigir_empresa_ativa();
  v_chave     text;
  v_numero    text;
  v_forn      uuid;
  v_forn_nome text;
  v_fj        jsonb;
  v_cnpj      text;
  v_forma     text;
  v_total     numeric;
  v_nota      uuid;
  v_emissao   date;
  v_txt       text;
  v_itens     jsonb;
  v_it        jsonb;
  v_pid       uuid;
  v_prod      record;
  v_qtd       numeric;
  v_vu        numeric;
  v_vt        numeric;
  v_gtin      text;
  v_un_xml    text;
  v_desc      text;
  v_pv        numeric;
  v_ant       numeric;
  v_nova      numeric;
  v_criados   uuid[] := '{}';
  v_pag       jsonb;
  v_parcelas  jsonb;
  v_pc        jsonb;
  v_soma      numeric := 0;
  v_venc      date;
  v_valor     numeric;
  v_n         integer;
  v_i         integer := 0;
  v_dt_pag    date;
  v_cod_forn  text;
  v_recebida numeric;
  v_fator numeric;
  v_qtd_estoque numeric;
  v_custo_estoque numeric;
  v_un_compra text;
  v_un_estoque text;
begin
  if p_nota is null or jsonb_typeof(p_nota) <> 'object' then
    raise exception 'Dados da nota inválidos.';
  end if;

  -- chave de acesso: 44 dígitos, sem duplicidade por empresa
  v_chave := btrim(coalesce(p_nota->>'chave_acesso', ''));
  if v_chave !~ '^[0-9]{44}$' then
    raise exception 'Não foi possível identificar uma chave de acesso válida de 44 dígitos.';
  end if;
  if exists (select 1 from public.notas_entrada n where n.empresa_id = v_empresa and n.chave_acesso = v_chave) then
    raise exception 'Esta Nota Fiscal já foi lançada.';
  end if;

  v_numero := nullif(btrim(coalesce(p_nota->>'numero', '')), '');
  v_total  := coalesce(nullif(p_nota->>'valor_total', '')::numeric, 0);
  if v_total < 0 then raise exception 'Valor total da nota inválido.'; end if;

  v_txt := nullif(p_nota->>'data_emissao', '');
  if v_txt is not null and v_txt ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then
    v_emissao := left(v_txt, 10)::date;     -- data local do emitente (sem deslocar por fuso)
  end if;

  v_forma := coalesce(p_nota->>'forma_pagamento', '');
  if v_forma not in ('a_vista', 'a_prazo') then
    raise exception 'Forma de pagamento da nota inválida.';
  end if;

  v_itens := p_nota->'itens';
  if v_itens is null or jsonb_typeof(v_itens) <> 'array' or jsonb_array_length(v_itens) = 0 then
    raise exception 'A nota não possui itens.';
  end if;
  if jsonb_array_length(v_itens) > 1000 then
    raise exception 'Itens demais na nota (máximo 1000).';
  end if;

  -- pagamento: soma precisa bater com o total (tolerância de 1 centavo)
  v_pag := p_nota->'pagamento';
  if v_pag is null or jsonb_typeof(v_pag) <> 'object' then
    raise exception 'Informe o pagamento da nota.';
  end if;
  if v_forma = 'a_vista' then
    v_soma := coalesce(nullif(v_pag->>'valor', '')::numeric, 0);
  else
    v_parcelas := v_pag->'parcelas';
    if v_parcelas is null or jsonb_typeof(v_parcelas) <> 'array' or jsonb_array_length(v_parcelas) = 0 then
      raise exception 'Informe ao menos uma parcela.';
    end if;
    for v_pc in select value from jsonb_array_elements(v_parcelas) loop
      if nullif(v_pc->>'vencimento', '') is null or coalesce(nullif(v_pc->>'valor', '')::numeric, 0) <= 0 then
        raise exception 'Parcela inválida (vencimento e valor são obrigatórios).';
      end if;
      v_soma := v_soma + (v_pc->>'valor')::numeric;
    end loop;
  end if;
  if abs(v_soma - v_total) > 0.01 then
    raise exception 'O pagamento informado (%) não confere com o valor total da nota (%).', v_soma, v_total;
  end if;

  -- Fornecedor: usa o informado (id, da própria empresa) ou acha/cria pelo CNPJ. NOVO (Etapa
  -- 10): em QUALQUER dos dois casos em que o fornecedor já existia (por id OU por CNPJ),
  -- complementa campos objetivos vazios com o que veio do XML — nunca sobrescreve o que já
  -- estava preenchido (regra 6). Se o item do payload trouxer só {id}, o COALESCE não muda
  -- nada (não há dado novo pra complementar) — inofensivo.
  v_fj := p_nota->'fornecedor';
  if v_fj is null or jsonb_typeof(v_fj) <> 'object' then
    raise exception 'Fornecedor da nota não informado.';
  end if;

  if nullif(v_fj->>'id', '') is not null then
    select f.id, f.razao_social into v_forn, v_forn_nome
      from public.fornecedores f
     where f.id = (v_fj->>'id')::uuid and f.empresa_id = v_empresa;
    if not found then raise exception 'Fornecedor não encontrado.'; end if;

    update public.fornecedores f set
      nome_fantasia         = coalesce(f.nome_fantasia, nullif(btrim(v_fj->>'nome_fantasia'), '')),
      inscricao_estadual    = coalesce(f.inscricao_estadual, nullif(btrim(v_fj->>'inscricao_estadual'), '')),
      telefone              = coalesce(f.telefone, nullif(btrim(v_fj->>'telefone'), '')),
      cep                   = coalesce(f.cep, nullif(btrim(v_fj->>'cep'), '')),
      endereco              = coalesce(f.endereco, nullif(btrim(v_fj->>'endereco'), '')),
      numero                = coalesce(f.numero, nullif(btrim(v_fj->>'numero'), '')),
      complemento           = coalesce(f.complemento, nullif(btrim(v_fj->>'complemento'), '')),
      bairro                = coalesce(f.bairro, nullif(btrim(v_fj->>'bairro'), '')),
      municipio             = coalesce(f.municipio, nullif(btrim(v_fj->>'municipio'), '')),
      uf                    = coalesce(f.uf, nullif(upper(btrim(v_fj->>'uf')), '')),
      codigo_ibge_municipio = coalesce(f.codigo_ibge_municipio, nullif(btrim(v_fj->>'codigo_ibge_municipio'), ''))
    where f.id = v_forn and f.empresa_id = v_empresa;
  else
    v_cnpj := regexp_replace(coalesce(v_fj->>'cnpj', ''), '[^0-9]', '', 'g');
    if length(v_cnpj) not in (11, 14) then
      raise exception 'CNPJ do fornecedor inválido.';
    end if;

    select f.id, f.razao_social into v_forn, v_forn_nome
      from public.fornecedores f where f.empresa_id = v_empresa and f.cnpj = v_cnpj;

    if not found then
      v_forn_nome := btrim(coalesce(v_fj->>'razao_social', ''));
      if v_forn_nome = '' then raise exception 'Informe a razão social do fornecedor.'; end if;

      insert into public.fornecedores (empresa_id, cnpj, razao_social, nome_fantasia, inscricao_estadual, telefone,
                                       cep, endereco, numero, complemento, bairro, municipio, uf, codigo_ibge_municipio)
      values (v_empresa, v_cnpj, v_forn_nome, nullif(btrim(v_fj->>'nome_fantasia'), ''),
              nullif(btrim(v_fj->>'inscricao_estadual'), ''), nullif(btrim(v_fj->>'telefone'), ''),
              nullif(btrim(v_fj->>'cep'), ''), nullif(btrim(v_fj->>'endereco'), ''), nullif(btrim(v_fj->>'numero'), ''),
              nullif(btrim(v_fj->>'complemento'), ''), nullif(btrim(v_fj->>'bairro'), ''),
              nullif(btrim(v_fj->>'municipio'), ''), nullif(upper(btrim(v_fj->>'uf')), ''),
              nullif(btrim(v_fj->>'codigo_ibge_municipio'), ''))
      returning id into v_forn;
    else
      update public.fornecedores f set
        nome_fantasia         = coalesce(f.nome_fantasia, nullif(btrim(v_fj->>'nome_fantasia'), '')),
        inscricao_estadual    = coalesce(f.inscricao_estadual, nullif(btrim(v_fj->>'inscricao_estadual'), '')),
        telefone              = coalesce(f.telefone, nullif(btrim(v_fj->>'telefone'), '')),
        cep                   = coalesce(f.cep, nullif(btrim(v_fj->>'cep'), '')),
        endereco              = coalesce(f.endereco, nullif(btrim(v_fj->>'endereco'), '')),
        numero                = coalesce(f.numero, nullif(btrim(v_fj->>'numero'), '')),
        complemento           = coalesce(f.complemento, nullif(btrim(v_fj->>'complemento'), '')),
        bairro                = coalesce(f.bairro, nullif(btrim(v_fj->>'bairro'), '')),
        municipio             = coalesce(f.municipio, nullif(btrim(v_fj->>'municipio'), '')),
        uf                    = coalesce(f.uf, nullif(upper(btrim(v_fj->>'uf')), '')),
        codigo_ibge_municipio = coalesce(f.codigo_ibge_municipio, nullif(btrim(v_fj->>'codigo_ibge_municipio'), ''))
      where f.id = v_forn and f.empresa_id = v_empresa;
    end if;
  end if;

  -- cabeçalho da nota (a unique (empresa_id, chave_acesso) é a garantia final contra duplicidade)
  insert into public.notas_entrada (empresa_id, fornecedor_id, chave_acesso, numero, serie, data_emissao,
                                    valor_produtos, valor_desconto, valor_frete, valor_outras_despesas, valor_total,
                                    forma_pagamento, status, xml_conteudo, criado_por)
  values (v_empresa, v_forn, v_chave, v_numero, nullif(btrim(coalesce(p_nota->>'serie', '')), ''), v_emissao,
          coalesce(nullif(p_nota->>'valor_produtos', '')::numeric, 0),
          coalesce(nullif(p_nota->>'valor_desconto', '')::numeric, 0),
          coalesce(nullif(p_nota->>'valor_frete', '')::numeric, 0),
          coalesce(nullif(p_nota->>'valor_outras_despesas', '')::numeric, 0),
          v_total, v_forma, 'confirmada', p_nota->>'xml_conteudo', (select auth.uid()))
  returning id into v_nota;

  -- itens: vincula/cria produto e dá entrada no estoque (quantidade decimal, sem arredondar para inteiro)
  for v_it in select value from jsonb_array_elements(v_itens) loop
    v_desc     := btrim(coalesce(v_it->>'descricao', ''));
    v_qtd      := coalesce(nullif(v_it->>'quantidade', '')::numeric, 0);
    v_vu       := coalesce(nullif(v_it->>'valor_unitario', '')::numeric, 0);
    v_vt       := coalesce(nullif(v_it->>'valor_total', '')::numeric, 0);
    v_un_xml   := nullif(btrim(coalesce(v_it->>'unidade_comercial', '')), '');
    v_gtin     := nullif(regexp_replace(coalesce(v_it->>'gtin', ''), '[^0-9]', '', 'g'), '');
    v_cod_forn := nullif(btrim(coalesce(v_it->>'codigo_fornecedor', '')), '');

    if v_desc = '' or v_qtd <= 0 or v_vu < 0 or v_vt < 0 then
      raise exception 'Item da nota inválido (descrição e quantidade maior que zero são obrigatórias).';
    end if;

    -- Quantidade e valores fiscais acima continuam exatamente como no XML.
    v_recebida:=coalesce(nullif(v_it->>'quantidade_recebida','')::numeric,v_qtd);
    v_fator:=coalesce(nullif(v_it->>'fator_conversao','')::numeric,1);
    v_un_compra:=upper(nullif(btrim(coalesce(v_it->>'unidade_compra',v_un_xml)),''));
    v_un_estoque:=upper(nullif(btrim(coalesce(v_it->>'unidade_estoque',v_un_xml)),''));
    IF v_recebida<=0 OR v_recebida>9999999999.9999 OR v_recebida<>round(v_recebida,4)
       OR v_fator<=0 OR v_fator>1000000 OR v_fator<>round(v_fator,6) THEN
      RAISE EXCEPTION 'Quantidade recebida ou fator de conversão inválido.';
    END IF;
    v_qtd_estoque:=v_recebida*v_fator;
    IF v_qtd_estoque<=0 OR v_qtd_estoque>9999999999.9999 OR v_qtd_estoque<>round(v_qtd_estoque,4) THEN
      RAISE EXCEPTION 'Quantidade final de estoque inválida: até quatro casas decimais.';
    END IF;
    IF v_it ? 'quantidade_estoque_entrada' AND (v_it->>'quantidade_estoque_entrada')::numeric IS DISTINCT FROM v_qtd_estoque THEN
      RAISE EXCEPTION 'A prévia de estoque mudou. Confira a quantidade e o fator.';
    END IF;
    v_custo_estoque:=round(v_vt/v_qtd_estoque,4);
    IF v_custo_estoque::text IN ('NaN','Infinity','-Infinity') OR v_custo_estoque<0 OR v_custo_estoque>9999999999.9999 THEN
      RAISE EXCEPTION 'Custo unitário de estoque fora do limite.';
    END IF;
    v_pid := null;

    -- Prioridade 1: produto_id explícito do front, ou GTIN válido e existente (mesma regra de
    -- hoje: se o front marcou "novo" mas o GTIN já existe em outro produto, bloqueia e pede
    -- vínculo manual em vez de decidir sozinho).
    if nullif(v_it->>'produto_id', '') is not null then
      v_pid := (v_it->>'produto_id')::uuid;
    elsif v_gtin is not null then
      select p.id into v_pid from public.produtos p
       where p.empresa_id = v_empresa and nullif(ltrim(p.gtin, '0'), '') = nullif(ltrim(v_gtin, '0'), '');
      if v_pid is not null and not (v_pid = any (v_criados)) then
        raise exception 'Já existe um produto com o código de barras % nesta empresa. Vincule o item "%" a esse produto.', v_gtin, v_desc;
      end if;
    end if;

    -- Prioridade 2 (NOVO): sem produto_id explícito nem GTIN resolvido — tenta o vínculo
    -- produto_fornecedor (fornecedor + código do fornecedor). Seguro porque a unique parcial
    -- em produto_fornecedor garante que esse par nunca aponta para dois produtos.
    if v_pid is null and v_cod_forn is not null then
      select pf.produto_id into v_pid
        from public.produto_fornecedor pf
       where pf.empresa_id = v_empresa and pf.fornecedor_id = v_forn and pf.codigo_produto_fornecedor = v_cod_forn;
    end if;

    if v_pid is null then
      -- Prioridade 3: produto novo. Só dados OBJETIVOS extraídos do XML — NENHUMA tributação de
      -- saída é copiada (cfop/cst_csosn/aliquota_icms/cst_pis/cst_cofins ficam null; revisão
      -- manual posterior, sem coluna de status dedicada nesta etapa). codigo NÃO é definido
      -- aqui — o trigger produtos_gerar_codigo cuida disso automaticamente no INSERT.
      v_pv := coalesce(nullif(v_it->>'preco_venda', '')::numeric, v_custo_estoque);
      if v_pv < 0 then raise exception 'Preço de venda inválido para "%".', v_desc; end if;

      insert into public.produtos (empresa_id, nome, gtin, unidade_comercial, preco_venda, preco_custo,
                                   quantidade_estoque, tipo_fiscal, ncm, cest, origem_mercadoria)
      values (v_empresa, left(v_desc, 200), v_gtin, v_un_estoque, v_pv, v_custo_estoque, 0, 'produto',
              nullif(btrim(v_it->>'ncm'), ''), nullif(btrim(v_it->>'cest'), ''), nullif(btrim(v_it->>'origem_mercadoria'), ''))
      returning id into v_pid;

      v_criados := v_criados || v_pid;
    end if;

    select p.nome, p.quantidade_estoque, p.unidade_comercial into v_prod
      from public.produtos p
     where p.id = v_pid and p.empresa_id = v_empresa
       for update;

    if not found then
      raise exception 'Produto vinculado não encontrado nesta empresa.';
    end if;
    perform private.produto_exigir_ativo(v_empresa, v_pid);   -- [046:notas_entrada]

    -- Unidade do produto existente não é alterada. Conversão exige confirmação explícita.
    v_un_estoque:=coalesce(upper(nullif(btrim(v_prod.unidade_comercial),'')),v_un_estoque);
    IF nullif(btrim(v_it->>'unidade_estoque'),'') IS NOT NULL AND upper(btrim(v_it->>'unidade_estoque')) IS DISTINCT FROM v_un_estoque THEN
      RAISE EXCEPTION 'A unidade de estoque não corresponde ao produto vinculado.';
    END IF;
    IF v_un_compra IS NULL OR v_un_estoque IS NULL OR length(v_un_compra)>10 OR length(v_un_estoque)>10 THEN
      RAISE EXCEPTION 'Informe unidades de compra e estoque válidas.';
    END IF;
    IF (v_un_compra<>v_un_estoque OR v_fator<>1 OR v_recebida<>v_qtd)
       AND NOT coalesce((v_it->>'conversao_confirmada')::boolean,false) THEN
      RAISE EXCEPTION 'Confira e confirme a conversão de embalagem antes de lançar a entrada.';
    END IF;

    v_ant  := v_prod.quantidade_estoque;
    v_nova := v_ant + v_qtd_estoque;
    update public.produtos set quantidade_estoque = v_nova, preco_custo = v_custo_estoque where id = v_pid and empresa_id = v_empresa;

    -- NOVO (Etapa 10): mantém/atualiza o vínculo produto_fornecedor — preço e data da última
    -- compra sempre atualizados; código/descrição do fornecedor só complementados (nunca
    -- sobrescritos por um valor diferente já gravado).
    insert into public.produto_fornecedor (empresa_id, produto_id, fornecedor_id, codigo_produto_fornecedor,
                                           descricao_fornecedor, ultimo_preco_compra, ultima_compra_em)
    values (v_empresa, v_pid, v_forn, v_cod_forn, left(v_desc, 500), v_vu, coalesce(v_emissao, (now() at time zone 'America/Sao_Paulo')::date))
    on conflict (empresa_id, produto_id, fornecedor_id) do update set
      codigo_produto_fornecedor = coalesce(produto_fornecedor.codigo_produto_fornecedor, excluded.codigo_produto_fornecedor),
      descricao_fornecedor      = coalesce(produto_fornecedor.descricao_fornecedor, excluded.descricao_fornecedor),
      ultimo_preco_compra       = excluded.ultimo_preco_compra,
      ultima_compra_em          = excluded.ultima_compra_em;

    -- histórico da entrada — exatamente as mesmas colunas de hoje, nenhuma nova.
    insert into public.notas_entrada_itens (empresa_id, nota_entrada_id, produto_id, codigo_fornecedor, gtin, descricao,
                                            ncm, cest, cfop, unidade_comercial, quantidade, valor_unitario, valor_total,
                                            origem_mercadoria, cst_csosn, cst_pis, cst_cofins,
                                            quantidade_estoque_anterior, quantidade_estoque_nova,
                                            quantidade_recebida, unidade_compra, fator_conversao, unidade_estoque, quantidade_estoque_entrada, custo_unitario_estoque)
    values (v_empresa, v_nota, v_pid, v_cod_forn, v_gtin, left(v_desc, 500),
            nullif(btrim(v_it->>'ncm'), ''), nullif(btrim(v_it->>'cest'), ''), nullif(btrim(v_it->>'cfop'), ''),
            v_un_xml, v_qtd, v_vu, v_vt,
            nullif(btrim(v_it->>'origem_mercadoria'), ''), nullif(btrim(v_it->>'cst_csosn'), ''),
            nullif(btrim(v_it->>'cst_pis'), ''), nullif(btrim(v_it->>'cst_cofins'), ''),
            v_ant, v_nova, v_recebida, v_un_compra, v_fator, v_un_estoque, v_qtd_estoque, v_custo_estoque);
  end loop;

  -- contas a pagar (despesas ligadas à nota). data = quando o dinheiro sai (vencimento / pagamento).
  if v_forma = 'a_vista' then
    v_dt_pag := coalesce(nullif(v_pag->>'data', '')::date, (now() at time zone 'America/Sao_Paulo')::date);
    insert into public.despesas (empresa_id, descricao, categoria, valor, data, vencimento, status, pago_em, nota_entrada_id)
    values (v_empresa, left('NF ' || coalesce(v_numero, 's/n') || ' — ' || v_forn_nome, 200), 'Compra de mercadorias',
            v_soma, v_dt_pag, v_dt_pag, 'pago', v_dt_pag, v_nota);
  else
    v_n := jsonb_array_length(v_parcelas);
    for v_pc in select value from jsonb_array_elements(v_parcelas) loop
      v_i := v_i + 1;
      v_venc  := (v_pc->>'vencimento')::date;
      v_valor := (v_pc->>'valor')::numeric;
      insert into public.despesas (empresa_id, descricao, categoria, valor, data, vencimento, status, nota_entrada_id)
      values (v_empresa,
              left('NF ' || coalesce(v_numero, 's/n') || ' — ' || v_forn_nome || ' (parcela ' || v_i || '/' || v_n || ')', 200),
              'Compra de mercadorias', v_valor, v_venc, v_venc, 'pendente', v_nota);
    end loop;
  end if;

  return v_nota;
end;
$function$
;

CREATE FUNCTION public.notas_entrada_produtos_buscar(p_termo text DEFAULT '',p_pagina integer DEFAULT 0,p_gtins text[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path='' AS $$
DECLARE e uuid:=private.empresa_id_ativa(); term text:=btrim(coalesce(p_termo,'')); pattern text; prefix text; gtins text[]; size integer:=20; result jsonb;
BEGIN
 IF e IS NULL OR NOT private.perm('notas_entrada') THEN RAISE EXCEPTION 'Sem permissão para vincular itens de Notas de Entrada.' USING ERRCODE='42501'; END IF;
 IF p_pagina IS NULL OR p_pagina<0 OR length(term)>120 THEN RAISE EXCEPTION 'Pesquisa ou página inválida.'; END IF;
 IF p_gtins IS NOT NULL THEN
  IF cardinality(p_gtins)>100 OR EXISTS(SELECT 1 FROM unnest(p_gtins) g WHERE g IS NULL OR g !~ '^[0-9]{8,14}$') THEN RAISE EXCEPTION 'Lote de GTIN inválido (até 100).'; END IF;
  SELECT array_agg(DISTINCT nullif(ltrim(g,'0'),'')) INTO gtins FROM unnest(p_gtins) g; size:=100;
 ELSIF term='' THEN RETURN jsonb_build_object('versao','ne_20261026_v1','produtos','[]'::jsonb,'pagina',p_pagina,'tem_mais',false); END IF;
 pattern:='%'||replace(replace(replace(term,chr(92),chr(92)||chr(92)),'%',chr(92)||'%'),'_',chr(92)||'_')||'%';
 prefix:=substr(pattern,2);
 WITH hits AS MATERIALIZED (
  SELECT p.id,p.nome,p.codigo,p.gtin,p.unidade_comercial,p.quantidade_estoque,p.preco_venda,p.ativo,
    CASE WHEN nullif(ltrim(p.gtin,'0'),'')=nullif(ltrim(term,'0'),'') THEN 0 WHEN lower(p.codigo)=lower(term) THEN 1 WHEN p.nome ILIKE prefix THEN 2 ELSE 3 END AS prioridade
  FROM public.produtos p
  WHERE p.empresa_id=e AND CASE WHEN p_gtins IS NOT NULL THEN p.gtin IS NOT NULL AND nullif(ltrim(p.gtin,'0'),'')=ANY(gtins)
    ELSE p.ativo AND (p.nome ILIKE pattern OR p.codigo ILIKE prefix OR (p.gtin IS NOT NULL AND nullif(ltrim(p.gtin,'0'),'')=nullif(ltrim(term,'0'),''))) END
  ORDER BY prioridade,lower(p.nome),p.id LIMIT size+1 OFFSET CASE WHEN p_gtins IS NULL THEN p_pagina::bigint*size ELSE 0 END
 ), numbered AS (SELECT h.*,row_number() OVER(ORDER BY prioridade,lower(nome),id) AS rn FROM hits h)
 SELECT jsonb_build_object('versao','ne_20261026_v1','produtos',coalesce(jsonb_agg(to_jsonb(h)-'prioridade'-'rn' ORDER BY h.rn) FILTER(WHERE h.rn<=size),'[]'::jsonb),'pagina',p_pagina,'tem_mais',coalesce(max(h.rn)>size,false)) INTO result FROM numbered h;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.notas_entrada_produtos_buscar(text,integer,text[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.notas_entrada_produtos_buscar(text,integer,text[]) TO authenticated;
-- SECURITY INVOKER: RLS e permissões de produtos continuam sendo aplicadas.
COMMIT;
