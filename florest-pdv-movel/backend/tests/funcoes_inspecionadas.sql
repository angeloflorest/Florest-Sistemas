-- Read-only snapshot of the scoped functions used to validate the orchestration locally.
CREATE OR REPLACE FUNCTION public.pdv_historico_detalhar(p_venda uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e uuid:=private.exigir_empresa_ativa(); v public.vendas; c public.caixas; editavel boolean;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão' using errcode='42501'; end if;
 select * into v from public.vendas where id=p_venda and empresa_id=e and tipo is null;
 if not found then raise exception 'Venda não encontrada'; end if;
 select * into c from public.caixas where id=v.caixa_id and empresa_id=e and tipo_caixa='PDV';
 editavel:=v.cancelada_em is null and c.status='aberto'
 and not exists(select 1 from public.documentos_fiscais d where d.empresa_id=e and d.venda_id=v.id and (d.status is distinct from 'cancelado' or d.chave_acesso is not null))
 and not exists(select 1 from public.contas_receber cr where cr.empresa_id=e and cr.venda_id=v.id)
 and not exists(select 1 from public.itens_venda i where i.empresa_id=e and i.venda_id=v.id and i.pacote_cliente_id is not null)
 and not exists(select 1 from private.taxas_pagamentos tp where tp.empresa_id=e and tp.venda_id=v.id);
 return jsonb_build_object('venda',to_jsonb(v),'editavel',editavel,
 'cliente_nome',(select nome from public.clientes where id=v.cliente_id and empresa_id=e),
 'itens',(select coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('nome',p.nome) order by i.id),'[]'::jsonb) from public.itens_venda i join public.produtos p on p.id=i.produto_id and p.empresa_id=e where i.empresa_id=e and i.venda_id=v.id),
 'pagamentos',(select coalesce(jsonb_agg(to_jsonb(pa) order by pa.ordem),'[]'::jsonb) from public.vendas_pagamentos pa where pa.empresa_id=e and pa.venda_id=v.id));
end $function$
;
CREATE OR REPLACE FUNCTION public.pdv_historico_listar(p_busca text DEFAULT NULL::text, p_limite integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e uuid:=private.exigir_empresa_ativa(); r jsonb;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão para o PDV' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.criado_em desc,x.numero_venda desc),'[]'::jsonb) into r from (
 select v.id,v.numero_venda,v.criado_em,v.total,v.forma_pagamento,v.cancelada_em,v.cliente_id,
 coalesce(cl.nome,'Consumidor') cliente_nome,c.status caixa_status,
 (v.cancelada_em is null and c.status='aberto' and c.tipo_caixa='PDV'
 and not exists(select 1 from public.documentos_fiscais d where d.empresa_id=e and d.venda_id=v.id and (d.status is distinct from 'cancelado' or d.chave_acesso is not null))
 and not exists(select 1 from public.contas_receber cr where cr.empresa_id=e and cr.venda_id=v.id)
 and not exists(select 1 from public.itens_venda i where i.empresa_id=e and i.venda_id=v.id and i.pacote_cliente_id is not null)
 and not exists(select 1 from private.taxas_pagamentos tp where tp.empresa_id=e and tp.venda_id=v.id)
 ) editavel
 from public.vendas v left join public.caixas c on c.id=v.caixa_id and c.empresa_id=e
 left join public.clientes cl on cl.id=v.cliente_id and cl.empresa_id=e
 where v.empresa_id=e and v.tipo is null and (p_busca is null or btrim(p_busca)='' or
 v.numero_venda::text ilike '%'||btrim(p_busca)||'%' or cl.nome ilike '%'||btrim(p_busca)||'%' or
 v.forma_pagamento ilike '%'||btrim(p_busca)||'%' or v.total::text ilike '%'||btrim(p_busca)||'%' or
 v.criado_em::date::text ilike '%'||btrim(p_busca)||'%')
 order by v.criado_em desc,v.numero_venda desc limit least(greatest(coalesce(p_limite,100),1),200) offset greatest(coalesce(p_offset,0),0)
 ) x;
 return r;
end $function$
;
CREATE OR REPLACE FUNCTION public.registrar_venda(p_cliente_id uuid, p_forma_pagamento text, p_itens jsonb, p_cpf_nota text DEFAULT NULL::text)
 RETURNS TABLE(venda_id uuid, numero_venda bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  v_empresa      uuid := private.exigir_empresa_ativa();
  v_forma        text := btrim(coalesce(p_forma_pagamento, ''));
  v_venda        uuid;
  v_numero       bigint;
  v_invalido     boolean;
  v_tem_pacote   boolean;
  r              record;
  v_nome         text;
  v_estoque      numeric;
  v_sem_estoque  boolean;
  v_pacote       public.pacotes_clientes%rowtype;
  v_cpf_nota     text;  -- NOVO (Migration 025)
begin
  -- permissão de módulo (proprietário sempre pode; funcionário precisa de PDV) — inalterado
  if not private.perm('pdv') then
    raise exception 'Você não tem permissão para registrar vendas.' using errcode = '42501';
  end if;
  -- configuração POR EMPRESA (sem linha = desligado = comportamento antigo) — inalterado
  select coalesce((select c.permitir_venda_sem_estoque from public.configuracoes_empresa c where c.empresa_id = v_empresa), false)
    into v_sem_estoque;
  if v_forma = '' or length(v_forma) > 40 then
    raise exception 'Forma de pagamento inválida.';
  end if;
  if p_itens is null or jsonb_typeof(p_itens) <> 'array' or jsonb_array_length(p_itens) = 0 then
    raise exception 'A venda precisa ter pelo menos um item.';
  end if;
  if jsonb_array_length(p_itens) > 500 then
    raise exception 'Itens demais em uma única venda (máximo 500).';
  end if;
  if p_cliente_id is not null and not exists (
       select 1 from public.clientes c where c.id = p_cliente_id and c.empresa_id = v_empresa) then
    raise exception 'Cliente não encontrado.';
  end if;

  -- NOVO (Migration 025): "CPF na nota" — totalmente opcional. Normaliza para somente dígitos
  -- (string vazia/só pontuação vira NULL) e valida o dígito verificador no servidor, nunca
  -- confiando apenas na validação feita no navegador. Nenhum CPF informado = comportamento
  -- idêntico a antes desta migration.
  v_cpf_nota := nullif(regexp_replace(coalesce(p_cpf_nota, ''), '[^0-9]', '', 'g'), '');
  if v_cpf_nota is not null and not private.cpf_valido(v_cpf_nota) then
    raise exception 'CPF informado na nota é inválido.';
  end if;

  -- valida os itens (tipos, quantidade > 0, preço >= 0) — inalterado; pacote_cliente_id,
  -- quando vier, é validado à parte mais abaixo, só quando presente
  begin
    select exists (
      select 1 from jsonb_to_recordset(p_itens) as x(produto_id uuid, quantidade numeric, preco_unitario numeric)
       where x.produto_id is null or x.quantidade is null or x.quantidade <= 0
          or x.preco_unitario is null or x.preco_unitario < 0
    ) into v_invalido;
  exception when others then
    v_invalido := true;
  end;
  if v_invalido then
    raise exception 'Item da venda inválido (produto, quantidade maior que zero e preço são obrigatórios).';
  end if;

  -- RAMO NOVO, OPCIONAL: só entra aqui se algum item trouxer pacote_cliente_id. Uma venda
  -- comum (nenhum item com pacote_cliente_id) nunca passa por este bloco — continua igual
  -- para QUALQUER empresa, com ou sem o módulo Pet.
  select exists (
    select 1 from jsonb_to_recordset(p_itens) as x(produto_id uuid, quantidade numeric, preco_unitario numeric, pacote_cliente_id uuid)
     where x.pacote_cliente_id is not null
  ) into v_tem_pacote;

  if v_tem_pacote then
    if not private.empresa_tem_modulo('pet') then
      raise exception 'Este recurso exige o módulo Pet ativo para esta empresa.' using errcode = '42501';
    end if;
    if not private.perm('pacotes') then
      raise exception 'Você não tem permissão para consumir sessões de pacote.' using errcode = '42501';
    end if;
  end if;

  -- trava os produtos (ordem fixa = sem deadlock), confere estoque e dá baixa — inalterado;
  -- itens ligados a pacote passam por aqui igual a qualquer outro item (o controle de estoque
  -- não muda de comportamento para eles)
  -- [046:registrar_venda] produto inativo não entra em venda nova (consumo de sessão de pacote já pago continua permitido)
  perform private.produtos_exigir_ativos(v_empresa, (
    select array_agg(x.produto_id)
      from jsonb_to_recordset(p_itens) as x(produto_id uuid, pacote_cliente_id uuid)
     where x.pacote_cliente_id is null));
  for r in
    select x.produto_id, sum(round(x.quantidade, 4)) as qtd
      from jsonb_to_recordset(p_itens) as x(produto_id uuid, quantidade numeric, preco_unitario numeric)
     group by x.produto_id
     order by x.produto_id
  loop
    select p.nome, p.quantidade_estoque into v_nome, v_estoque
      from public.produtos p
     where p.id = r.produto_id and p.empresa_id = v_empresa
       for update;
    if not found then
      raise exception 'Produto não encontrado.';
    end if;
    if v_estoque < r.qtd and not v_sem_estoque then
      raise exception 'Estoque insuficiente para "%": disponível %, solicitado %.', v_nome, v_estoque, r.qtd;
    end if;
    update public.produtos set quantidade_estoque = quantidade_estoque - r.qtd
     where id = r.produto_id and empresa_id = v_empresa;
  end loop;

  -- NOVO: consumo de sessão de pacote, um item por vez (permite redimir mais de uma sessão do
  -- mesmo pacote na mesma venda). Ordem fixa (por pacote_cliente_id) = sem deadlock, mesma
  -- lógica do loop de estoque acima. Cada item aqui:
  --   * precisa ter quantidade = 1 (uma sessão por linha, mesmo padrão de usar_sessao_pacote);
  --   * o produto do item precisa ser o mesmo produto do pacote;
  --   * não pode exceder sessoes_totais (checado sob FOR UPDATE: trava a mesma linha que
  --     usar_sessao_pacote trava, então as duas vias nunca estouram o pacote por concorrência);
  --   * fica registrado em pacote_usos, igual a usar_sessao_pacote.
  if v_tem_pacote then
    for r in
      select x.produto_id, x.quantidade, x.pacote_cliente_id
        from jsonb_to_recordset(p_itens) as x(produto_id uuid, quantidade numeric, preco_unitario numeric, pacote_cliente_id uuid)
       where x.pacote_cliente_id is not null
       order by x.pacote_cliente_id
    loop
      if round(r.quantidade, 4) <> 1 then
        raise exception 'Cada item de consumo de sessão de pacote deve ter quantidade igual a 1.';
      end if;

      select * into v_pacote from public.pacotes_clientes pc
       where pc.id = r.pacote_cliente_id and pc.empresa_id = v_empresa
         for update;
      if not found then
        raise exception 'Pacote não encontrado.';
      end if;
      if v_pacote.produto_id <> r.produto_id then
        raise exception 'O produto do item não corresponde ao produto do pacote informado.';
      end if;
      if v_pacote.sessoes_usadas >= v_pacote.sessoes_totais then
        raise exception 'Este pacote já está concluído.';
      end if;

      update public.pacotes_clientes
         set sessoes_usadas = sessoes_usadas + 1
       where id = r.pacote_cliente_id and empresa_id = v_empresa;

      insert into public.pacote_usos (empresa_id, pacote_id)
      values (v_empresa, r.pacote_cliente_id);
    end loop;
  end if;

  -- número sequencial por empresa (a linha do contador serializa vendas simultâneas) — inalterado
  insert into public.contadores_venda as c (empresa_id, ultimo_numero)
  values (v_empresa, 1)
  on conflict (empresa_id) do update set ultimo_numero = c.ultimo_numero + 1
  returning c.ultimo_numero into v_numero;

  -- NOVO (Migration 025): grava cpf_nota (já normalizado/validado acima, ou NULL) junto com a
  -- venda. Todas as demais colunas inalteradas.
  insert into public.vendas (empresa_id, numero_venda, cliente_id, forma_pagamento, total, criado_por, cpf_nota)
  values (v_empresa, v_numero, p_cliente_id, v_forma, 0, (select auth.uid()), v_cpf_nota)
  returning id into v_venda;

  -- item ligado a pacote nunca é cobrado de novo (preco_unitario forçado a 0): o valor já foi
  -- pago na compra do pacote (vender_pacote_produto). O total da venda soma o subtotal
  -- (gerado automaticamente), então esses itens naturalmente não somam nada ao total.
  insert into public.itens_venda (empresa_id, venda_id, produto_id, quantidade, preco_unitario, pacote_cliente_id)
  select v_empresa, v_venda, x.produto_id, round(x.quantidade, 4),
         case when x.pacote_cliente_id is not null then 0 else round(x.preco_unitario, 2) end,
         x.pacote_cliente_id
    from rows from (jsonb_to_recordset(p_itens) as (produto_id uuid, quantidade numeric, preco_unitario numeric, pacote_cliente_id uuid))
         with ordinality as x(produto_id, quantidade, preco_unitario, pacote_cliente_id, ordem)
   order by x.ordem;

  update public.vendas v
     set total = (select coalesce(sum(i.subtotal), 0) from public.itens_venda i where i.venda_id = v_venda)
   where v.id = v_venda;

  venda_id := v_venda;
  numero_venda := v_numero;
  return next;
end;
$function$
;
CREATE OR REPLACE FUNCTION private.caixa_vinculo_validar()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caixa public.caixas%rowtype;
  v_tipo text := tg_argv[0];
begin
  IF tg_table_name='vendas' AND to_jsonb(new)->>'tipo'='bar' THEN v_tipo:='BAR'; END IF;
  if tg_op = 'UPDATE' then
    if old.caixa_id is not null and new.caixa_id is distinct from old.caixa_id then
      raise exception 'O vínculo do movimento com o caixa não pode ser alterado.';
    end if;
    if new.caixa_id is not distinct from old.caixa_id then
      return new;
    end if;
  end if;

  -- o pagamento de uma venda do PDV acompanha SEMPRE o caixa da venda (inclusive "sem caixa" nas antigas)
  if tg_op = 'INSERT' and tg_argv[1] = 'venda' then
    if not exists (select 1 from public.vendas v
                    where v.empresa_id = new.empresa_id and v.id = new.venda_id
                      and v.caixa_id is not distinct from new.caixa_id) then
      raise exception 'O pagamento precisa estar no mesmo caixa da venda.';
    end if;
  end if;

  if new.caixa_id is null then
    return new;
  end if;

  select * into v_caixa
    from public.caixas c
   where c.id = new.caixa_id and c.empresa_id = new.empresa_id
     for share;
  if not found then
    raise exception 'Caixa não encontrado para esta empresa.';
  end if;
  if v_caixa.tipo_caixa <> v_tipo then
    raise exception 'Caixa de tipo incompatível: este movimento só pode ser ligado a um Caixa %.', v_tipo;
  end if;
  if v_caixa.status <> 'aberto' then
    raise exception 'O caixa informado já está fechado.' using errcode = 'CX001';
  end if;

  return new;
end;
$function$
;
CREATE OR REPLACE FUNCTION private.venda_mista_validar_pagamentos(p_pagamentos jsonb)
 RETURNS TABLE(ordem integer, forma_pagamento text, valor numeric)
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  c_formas constant text[] := array['Dinheiro', 'Pix', 'Cartão de Débito', 'Cartão de Crédito', 'Outros'];
  v_item   jsonb;
  v_ord    integer;
  v_forma  text;
  v_valor  numeric;
begin
  if p_pagamentos is null or jsonb_typeof(p_pagamentos) <> 'array' then
    raise exception 'Informe os pagamentos da venda (lista de formas de pagamento).';
  end if;
  if jsonb_array_length(p_pagamentos) < 1 then
    raise exception 'Informe ao menos uma forma de pagamento.';
  end if;
  if jsonb_array_length(p_pagamentos) > 10 then
    raise exception 'Formas de pagamento demais em uma única venda (máximo 10).';
  end if;

  for v_item, v_ord in
    select e.item, e.ord::integer
      from jsonb_array_elements(p_pagamentos) with ordinality as e(item, ord)
     order by e.ord
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception 'Pagamento % inválido.', v_ord;
    end if;

    if jsonb_typeof(v_item -> 'forma_pagamento') is distinct from 'string' then
      raise exception 'Pagamento %: forma de pagamento não informada.', v_ord;
    end if;
    v_forma := normalize(btrim(v_item ->> 'forma_pagamento'), NFC);
    if not (v_forma = any (c_formas)) then
      raise exception 'Pagamento %: forma de pagamento inválida (%). Use: Dinheiro, Pix, Cartão de Débito, Cartão de Crédito ou Outros.', v_ord, v_forma;
    end if;

    if jsonb_typeof(v_item -> 'valor') is distinct from 'number' then
      raise exception 'Pagamento %: o valor deve ser um número.', v_ord;
    end if;
    v_valor := (v_item ->> 'valor')::numeric;
    if v_valor <= 0 then
      raise exception 'Pagamento %: o valor deve ser maior que zero.', v_ord;
    end if;
    if v_valor <> round(v_valor, 2) then
      raise exception 'Pagamento %: o valor deve ter no máximo duas casas decimais.', v_ord;
    end if;
    if v_valor > 99999999999.99 then
      raise exception 'Pagamento %: valor acima do limite permitido.', v_ord;
    end if;

    ordem := v_ord;
    forma_pagamento := v_forma;
    valor := v_valor;
    return next;
  end loop;
end;
$function$
;
CREATE OR REPLACE FUNCTION private.perm(p_modulo text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce((
    select p.ativo and (p.papel = 'proprietario' or p_modulo = any (p.permissoes))
      from public.perfis p
     where p.id = (select auth.uid())), false);
$function$
;
CREATE OR REPLACE FUNCTION private.exigir_empresa_ativa()
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid    uuid := (select auth.uid());
  v_emp    uuid;
  v_status text;
  v_bloq   boolean;
  v_ativo  boolean;
begin
  if v_uid is null then
    raise exception 'Sessão expirada. Faça login novamente.' using errcode = '28000';
  end if;
  select e.id, e.status_conta, e.bloqueado, p.ativo into v_emp, v_status, v_bloq, v_ativo
    from public.perfis p join public.empresas e on e.id = p.empresa_id
   where p.id = v_uid;
  if v_emp is null then
    raise exception 'Usuário sem empresa vinculada.' using errcode = '42501';
  end if;
  if v_status = 'pendente' then
    raise exception 'Sua conta ainda está em análise.' using errcode = '42501';
  end if;
  if v_status <> 'aprovado' or v_bloq then
    raise exception 'Seu acesso está bloqueado. Entre em contato com seu revendedor.' using errcode = '42501';
  end if;
  if not v_ativo then
    raise exception 'Seu usuário está desativado. Fale com o administrador da empresa.' using errcode = '42501';
  end if;
  return v_emp;
end;
$function$
;
CREATE TRIGGER caixa_vinculo_vendas BEFORE INSERT OR UPDATE OF caixa_id ON public.vendas FOR EACH ROW EXECUTE FUNCTION private.caixa_vinculo_validar('PDV');
CREATE TRIGGER caixa_vinculo_vendas_pagamentos BEFORE INSERT OR UPDATE OF caixa_id ON public.vendas_pagamentos FOR EACH ROW EXECUTE FUNCTION private.caixa_vinculo_validar('PDV','venda');