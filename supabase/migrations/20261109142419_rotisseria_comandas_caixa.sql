BEGIN;
DO $guard$ BEGIN IF md5(pg_get_functiondef('public.admin_configurar_modulo(uuid,text,boolean)'::regprocedure)) <> 'a0337002179094b67e3dccfe2c90326d' THEN RAISE EXCEPTION 'Base alterada: admin_configurar_modulo. Recompare a integração.'; END IF; END $guard$;
CREATE OR REPLACE FUNCTION public.admin_configurar_modulo(p_empresa_id uuid, p_modulo text, p_ativo boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
 IF NOT public.florest_eh_admin() THEN RAISE EXCEPTION 'Acesso negado.'; END IF;
 IF NOT EXISTS (SELECT 1 FROM public.empresas WHERE id=p_empresa_id) THEN RAISE EXCEPTION 'Empresa não encontrada.'; END IF;
 IF p_modulo NOT IN ('pet','bar','gastronomia','rotisseria') THEN RAISE EXCEPTION 'Módulo inválido.'; END IF;
 IF p_ativo AND p_modulo IN ('bar','gastronomia')
    AND p_empresa_id <> '8b48baee-bb29-45ac-8e4d-b9432c603f38'::uuid
    AND EXISTS(SELECT 1 FROM public.empresa_modulos em WHERE em.empresa_id=p_empresa_id AND em.modulo=CASE WHEN p_modulo='bar' THEN 'gastronomia' ELSE 'bar' END AND em.ativo)
 THEN RAISE EXCEPTION 'Uma empresa pode contratar Bar ou Gastronomia, não ambos.'; END IF;
 INSERT INTO public.empresa_modulos(empresa_id,modulo,ativo) VALUES(p_empresa_id,p_modulo,p_ativo)
 ON CONFLICT(empresa_id,modulo) DO UPDATE SET ativo=excluded.ativo;
END $function$
;
DO $guard$ BEGIN IF md5(pg_get_functiondef('private.usuarios_modulos()'::regprocedure)) <> '9d3bd406f12a155d1285010a408c908e' THEN RAISE EXCEPTION 'Base alterada: usuarios_modulos. Recompare a integração.'; END IF; END $guard$;
CREATE OR REPLACE FUNCTION private.usuarios_modulos()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  SELECT ARRAY[
    'rotisseria_visualizar','rotisseria_lancar','rotisseria_caixa','rotisseria_configurar',
    'dashboard','clientes','produtos','estoque','pdv','fornecedores',
    'notas_entrada','financeiro','fiscal','relatorios','configuracoes','usuarios',
    'pets','agenda','pacotes',
    'bar_visualizar','bar_mesas','bar_pedidos','bar_caixa','bar_portaria',
    'bar_configurar','bar_cancelar_pedido','bar_corrigir_pessoas',
    'bar_estornar_pagamento','bar_historico_consultar','bar_historico_detalhar',
    'bar_venda_editar','bar_venda_cancelar','bar_venda_refazer',
    'maria_acessar','gastronomia_visualizar','gastronomia_mesas','gastronomia_pedidos','gastronomia_producao','gastronomia_expedicao','gastronomia_caixa','gastronomia_configurar','gastronomia_cancelar','gastronomia_estornar'
  ]::text[];
$function$
;
ALTER TABLE public.perfis DROP CONSTRAINT perfis_permissoes_ck; ALTER TABLE public.perfis ADD CONSTRAINT perfis_permissoes_ck CHECK (permissoes <@ private.usuarios_modulos());
DO $guard$ BEGIN IF md5(pg_get_functiondef('private.caixa_tipo_validar(text)'::regprocedure)) <> '9f31aa4011b0110a9c1aeba25b310656' THEN RAISE EXCEPTION 'Base alterada: caixa_tipo_validar. Recompare a integração.'; END IF; END $guard$;
CREATE OR REPLACE FUNCTION private.caixa_tipo_validar(p_tipo text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare v text := upper(btrim(coalesce(p_tipo, '')));
begin
  if v not in ('PDV', 'BAR', 'GASTRONOMIA', 'ROTISSERIA') then
    raise exception 'Tipo de caixa inválido (use PDV, BAR ou GASTRONOMIA).';
  end if;
  return v;
end;
$function$
;
DO $guard$ BEGIN IF md5(pg_get_functiondef('private.caixa_pode_operar(text)'::regprocedure)) <> '75d5e860fcaa63380f597ee942d074a0' THEN RAISE EXCEPTION 'Base alterada: caixa_pode_operar. Recompare a integração.'; END IF; END $guard$;
CREATE OR REPLACE FUNCTION private.caixa_pode_operar(p_tipo text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select case upper(btrim(coalesce(p_tipo, '')))
    when 'ROTISSERIA' then private.empresa_tem_modulo('rotisseria') and private.perm('rotisseria_caixa')
    when 'PDV' then private.perm('pdv')
    when 'GASTRONOMIA' then private.empresa_tem_modulo('gastronomia') and private.perm('gastronomia_caixa')
    when 'BAR' then private.empresa_tem_modulo('bar') and private.perm('bar_caixa')
    else false
  end;
$function$
;
ALTER TABLE public.caixas DROP CONSTRAINT caixas_tipo_ck; ALTER TABLE public.caixas ADD CONSTRAINT caixas_tipo_ck CHECK(tipo_caixa IN ('PDV','BAR','GASTRONOMIA','ROTISSERIA'));
DO $g$ BEGIN IF md5(pg_get_functiondef('private.caixa_vinculo_validar()'::regprocedure)) <> 'bf81f490235ed9a17e0f3a8bcbe0ed5d' THEN RAISE EXCEPTION 'Base de vínculo de caixa alterada.'; END IF; END $g$;
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
  IF tg_table_name='vendas' AND to_jsonb(new)->>'tipo'='rotisseria' THEN v_tipo:='ROTISSERIA'; END IF;
  IF tg_table_name='vendas_pagamentos' AND EXISTS(SELECT 1 FROM public.vendas v WHERE v.id=(to_jsonb(new)->>'venda_id')::uuid AND v.empresa_id=new.empresa_id AND v.tipo='rotisseria') THEN v_tipo:='ROTISSERIA'; END IF;
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
-- Rotisseria: products/stock/sales/fiscal belong to the ERP; operational data are isolated.
CREATE TABLE private.rotisseria_config (
 empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id), quantidade integer NOT NULL DEFAULT 5 CHECK(quantidade BETWEEN 1 AND 200),
 destaques integer NOT NULL DEFAULT 10 CHECK(destaques BETWEEN 0 AND 20), produtos jsonb NOT NULL DEFAULT '[]',
 impressora_id uuid, atualizado_em timestamptz NOT NULL DEFAULT now(),
 CHECK(jsonb_typeof(produtos)='array' AND jsonb_array_length(produtos)<=20 AND octet_length(produtos::text)<=2000000)
);
CREATE TABLE private.rotisseria_dispositivo (
 empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id), token uuid NOT NULL, usuario_id uuid NOT NULL REFERENCES public.perfis(id),
 nome text NOT NULL CHECK(length(nome) BETWEEN 1 AND 80), atualizado_em timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE private.rotisseria_sessoes (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), empresa_id uuid NOT NULL REFERENCES public.empresas(id), numero integer NOT NULL CHECK(numero BETWEEN 1 AND 200),
 estado text NOT NULL DEFAULT 'aberta' CHECK(estado IN ('aberta','concluida','cancelada')), versao bigint NOT NULL DEFAULT 1,
 criado_por uuid NOT NULL REFERENCES public.perfis(id), criado_em timestamptz NOT NULL DEFAULT now(), finalizado_em timestamptz,
 venda_id uuid, caixa_id uuid, pagamento_resultado jsonb, UNIQUE(empresa_id,id),
 FOREIGN KEY(empresa_id,venda_id) REFERENCES public.vendas(empresa_id,id), FOREIGN KEY(empresa_id,caixa_id) REFERENCES public.caixas(empresa_id,id)
);
CREATE UNIQUE INDEX rotisseria_comanda_aberta ON private.rotisseria_sessoes(empresa_id,numero) WHERE estado='aberta';
CREATE INDEX rotisseria_sessoes_historico ON private.rotisseria_sessoes(empresa_id,criado_em DESC);
CREATE TABLE private.rotisseria_itens (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), empresa_id uuid NOT NULL, sessao_id uuid NOT NULL, produto_id uuid NOT NULL,
 nome text NOT NULL, unidade text NOT NULL, quantidade numeric(14,4) NOT NULL CHECK(quantidade>0), preco numeric(14,2) NOT NULL CHECK(preco>=0),
 subtotal numeric(14,2) GENERATED ALWAYS AS(round(quantidade*preco,2)) STORED,
 chave uuid NOT NULL, cancelado boolean NOT NULL DEFAULT false, criado_por uuid NOT NULL REFERENCES public.perfis(id), criado_em timestamptz NOT NULL DEFAULT now(),
 UNIQUE(empresa_id,chave), FOREIGN KEY(empresa_id,sessao_id) REFERENCES private.rotisseria_sessoes(empresa_id,id),
 FOREIGN KEY(empresa_id,produto_id) REFERENCES public.produtos(empresa_id,id)
);
CREATE INDEX rotisseria_itens_sessao ON private.rotisseria_itens(empresa_id,sessao_id);
ALTER TABLE private.rotisseria_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.rotisseria_dispositivo ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.rotisseria_sessoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.rotisseria_itens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.rotisseria_config,private.rotisseria_dispositivo,private.rotisseria_sessoes,private.rotisseria_itens FROM PUBLIC,anon,authenticated;
CREATE TABLE public.rotisseria_sinais(empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id), revisao bigint NOT NULL DEFAULT 1);
ALTER TABLE public.rotisseria_sinais ENABLE ROW LEVEL SECURITY;
CREATE POLICY rotisseria_sinais_ler ON public.rotisseria_sinais FOR SELECT TO authenticated
 USING(empresa_id=(select private.empresa_id_ativa()) AND (select private.empresa_tem_modulo('rotisseria')) AND (select private.perm('rotisseria_visualizar')));
REVOKE ALL ON public.rotisseria_sinais FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.rotisseria_sinais TO authenticated;
ALTER PUBLICATION supabase_realtime ADD TABLE public.rotisseria_sinais;

CREATE FUNCTION private.rotisseria_caixa_resumo(p_caixa public.caixas) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 WITH mov AS (SELECT p.forma_pagamento forma,sum(p.valor) total,count(*) qtd FROM public.vendas_pagamentos p JOIN public.vendas v ON v.empresa_id=p.empresa_id AND v.id=p.venda_id
 WHERE p.empresa_id=p_caixa.empresa_id AND p.caixa_id=p_caixa.id AND v.tipo='rotisseria' AND v.cancelada_em IS NULL GROUP BY p.forma_pagamento)
 SELECT jsonb_build_object('tipo_caixa','ROTISSERIA','valor_inicial',p_caixa.valor_inicial,'total_recebido',coalesce(sum(total),0),
 'por_forma',coalesce(jsonb_agg(jsonb_build_object('forma',forma,'total',total,'qtd',qtd)),'[]'),
 'qtd_operacoes',(SELECT count(*) FROM public.vendas v WHERE v.empresa_id=p_caixa.empresa_id AND v.caixa_id=p_caixa.id AND v.tipo='rotisseria' AND v.cancelada_em IS NULL),
 'saldo_dinheiro_esperado',p_caixa.valor_inicial+coalesce(sum(total) FILTER(WHERE forma='Dinheiro'),0)) FROM mov
$$;
REVOKE ALL ON FUNCTION private.rotisseria_caixa_resumo(public.caixas) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.rotisseria_rpc(p_acao text,p_dados jsonb DEFAULT '{}',p_chave uuid DEFAULT NULL) RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
#variable_conflict use_column
DECLARE
 e uuid:=private.exigir_empresa_ativa(); u uuid:=auth.uid(); cfg private.rotisseria_config; s private.rotisseria_sessoes;
 c public.caixas; prod public.produtos; it private.rotisseria_itens; r record; result jsonb; arr jsonb; n bigint; vid uuid; pid uuid;
 qtd numeric; total numeric; pago numeric; troco numeric:=0; forma text; cpf text; disponivel numeric; permitido boolean; dispositivo boolean; expected bigint; catalogo boolean;
BEGIN
 IF NOT private.empresa_tem_modulo('rotisseria') OR NOT private.perm('rotisseria_visualizar') THEN RAISE EXCEPTION 'Módulo Rotisseria não liberado para este usuário e empresa.' USING errcode='42501'; END IF;
 IF p_acao IN ('config_salvar','abrir_comanda') THEN PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':rotisseria-config',0)); END IF;
 SELECT * INTO cfg FROM private.rotisseria_config WHERE empresa_id=e;
 IF NOT FOUND THEN cfg.quantidade:=5;cfg.destaques:=10;cfg.produtos:='[]'; END IF;
 SELECT EXISTS(SELECT 1 FROM private.rotisseria_dispositivo d WHERE d.empresa_id=e AND d.token=p_chave AND d.usuario_id=u) INTO dispositivo;
 IF p_acao='contexto' THEN
  catalogo:=nullif(p_dados->>'config_em','')::timestamptz IS DISTINCT FROM cfg.atualizado_em OR cfg.atualizado_em IS NULL;
  SELECT coalesce(jsonb_agg(jsonb_build_object('numero',g.numero,'id',s.id,'versao',s.versao,'criado_em',s.criado_em,'total',coalesce(x.total,0),'itens',coalesce(x.itens,0)) ORDER BY g.numero),'[]') INTO arr
  FROM generate_series(1,cfg.quantidade) g(numero) LEFT JOIN private.rotisseria_sessoes s ON s.empresa_id=e AND s.numero=g.numero AND s.estado='aberta'
  LEFT JOIN LATERAL(SELECT sum(i.subtotal) total,count(*) itens FROM private.rotisseria_itens i WHERE i.empresa_id=e AND i.sessao_id=s.id AND NOT i.cancelado) x ON true;
  SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' AND status='aberto';
  RETURN jsonb_build_object('empresa_id',e,'config',CASE WHEN catalogo THEN to_jsonb(cfg) ELSE to_jsonb(cfg)-'produtos' END,'comandas',arr,'caixa',CASE WHEN c.id IS NOT NULL THEN private.caixa_json(c) ELSE NULL END,'dispositivo_caixa',dispositivo,
   'permissoes',jsonb_build_object('lancar',private.perm('rotisseria_lancar'),'caixa',private.perm('rotisseria_caixa'),'configurar',private.perm('rotisseria_configurar')),
   'destaques',CASE WHEN catalogo THEN (SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'nome',p.nome,'codigo',p.codigo,'gtin',p.gtin,'preco_venda',p.preco_venda,'unidade_comercial',p.unidade_comercial,'venda_granel',p.venda_granel,'foto',x->>'foto') ORDER BY ord),'[]') FROM jsonb_array_elements(cfg.produtos) WITH ORDINALITY t(x,ord) JOIN public.produtos p ON p.id=(x->>'id')::uuid AND p.empresa_id=e AND p.ativo WHERE ord<=cfg.destaques) ELSE NULL END);
 ELSIF p_acao='buscar' THEN
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM (SELECT id,nome,codigo,gtin,unidade_comercial,venda_granel,preco_venda,quantidade_estoque FROM public.produtos WHERE empresa_id=e AND ativo AND (nome ILIKE '%'||left(coalesce(p_dados->>'busca',''),100)||'%' OR codigo ILIKE '%'||left(p_dados->>'busca',100)||'%' OR gtin= p_dados->>'busca') ORDER BY nome,id LIMIT 40) x);
 ELSIF p_acao='clientes' THEN
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x)),'[]') FROM (SELECT id,nome FROM public.clientes WHERE empresa_id=e AND nome ILIKE '%'||left(coalesce(p_dados->>'busca',''),100)||'%' ORDER BY nome,id LIMIT 30) x);
 ELSIF p_acao='config_dados' THEN
  IF NOT private.perm('rotisseria_configurar') THEN RAISE EXCEPTION 'Sem permissão para configurar.' USING errcode='42501'; END IF;
  RETURN jsonb_build_object('config',to_jsonb(cfg),'impressoras',(SELECT coalesce(jsonb_agg(to_jsonb(p)),'[]') FROM public.impressoras p WHERE empresa_id=e AND ativa));
 ELSIF p_acao='config_salvar' THEN
  IF NOT private.perm('rotisseria_configurar') THEN RAISE EXCEPTION 'Sem permissão para configurar.' USING errcode='42501'; END IF;
  IF (p_dados->>'quantidade')::int NOT BETWEEN 1 AND 200 OR (p_dados->>'destaques')::int NOT BETWEEN 0 AND 20 OR p_dados->>'quantidade' IS NULL OR p_dados->>'destaques' IS NULL THEN RAISE EXCEPTION 'Informe de 1 a 200 comandas e de 0 a 20 destaques.'; END IF;
  IF EXISTS(SELECT 1 FROM private.rotisseria_sessoes WHERE empresa_id=e AND estado='aberta' AND numero>(p_dados->>'quantidade')::int) THEN RAISE EXCEPTION 'Finalize as comandas abertas antes de reduzir a quantidade.'; END IF;
  arr:=coalesce(p_dados->'produtos','[]');
  IF jsonb_typeof(arr)<>'array' OR jsonb_array_length(arr)>20 OR octet_length(arr::text)>2000000 THEN RAISE EXCEPTION 'Configuração de fotos inválida.'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(arr) x WHERE NOT EXISTS(SELECT 1 FROM public.produtos p WHERE p.id=(x->>'id')::uuid AND p.empresa_id=e AND p.ativo) OR (coalesce(x->>'foto','')<>'' AND (x->>'foto' NOT LIKE 'data:image/jpeg;base64,%' OR length(x->>'foto')>100000))) THEN RAISE EXCEPTION 'Produto ou foto inválido.'; END IF;
  IF (SELECT count(*)<>count(DISTINCT x->>'id') FROM jsonb_array_elements(arr) x) THEN RAISE EXCEPTION 'Produto repetido nos destaques.'; END IF;
  IF nullif(p_dados->>'impressora_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.impressoras WHERE empresa_id=e AND ativa AND id=(p_dados->>'impressora_id')::uuid) THEN RAISE EXCEPTION 'Impressora de outra empresa ou inexistente.'; END IF;
  INSERT INTO private.rotisseria_config(empresa_id,quantidade,destaques,produtos,impressora_id) VALUES(e,(p_dados->>'quantidade')::int,(p_dados->>'destaques')::int,arr,nullif(p_dados->>'impressora_id','')::uuid)
  ON CONFLICT(empresa_id) DO UPDATE SET quantidade=excluded.quantidade,destaques=excluded.destaques,produtos=excluded.produtos,impressora_id=excluded.impressora_id,atualizado_em=now();
 ELSIF p_acao='caixa_vincular' THEN
  IF NOT private.perm('rotisseria_caixa') OR p_chave IS NULL THEN RAISE EXCEPTION 'Sem permissão para definir dispositivo de caixa.' USING errcode='42501'; END IF;
  INSERT INTO private.rotisseria_dispositivo(empresa_id,token,usuario_id,nome) VALUES(e,p_chave,u,left(coalesce(nullif(btrim(p_dados->>'nome'),''),'Caixa Rotisseria'),80)) ON CONFLICT(empresa_id) DO UPDATE SET token=excluded.token,usuario_id=excluded.usuario_id,nome=excluded.nome,atualizado_em=now();
 ELSIF p_acao IN ('caixa_abrir','caixa_fechar','receber','fiscal') THEN
  IF NOT dispositivo OR NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Recebimentos e caixa são exclusivos do dispositivo definido como Caixa da Rotisseria.' USING errcode='42501'; END IF;
  IF p_acao='caixa_abrir' THEN RETURN public.caixa_abrir('ROTISSERIA',(p_dados->>'valor')::numeric); END IF;
  IF p_acao='caixa_fechar' THEN
   SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND id=(p_dados->>'id')::uuid AND tipo_caixa='ROTISSERIA';
   IF c.id IS NULL THEN RAISE EXCEPTION 'Caixa da Rotisseria não encontrado.'; END IF;
   RETURN public.caixa_fechar(c.id);
  END IF;
  IF p_acao='fiscal' THEN
   IF NOT EXISTS(SELECT 1 FROM private.rotisseria_sessoes WHERE empresa_id=e AND venda_id=(p_dados->>'venda_id')::uuid AND estado='concluida') THEN RAISE EXCEPTION 'Venda da Rotisseria não encontrada.'; END IF;
   IF NOT private.perm('fiscal') AND NOT private.perm('pdv') THEN RAISE EXCEPTION 'Libere a permissão Fiscal ao operador para emitir NFC-e.' USING errcode='42501'; END IF;
   RETURN (SELECT coalesce(jsonb_agg(to_jsonb(d)),'[]') FROM public.fiscal_emitir_nota((p_dados->>'venda_id')::uuid) d);
  END IF;
  -- Lock cashier before the comanda; closing cannot pass an in-flight payment.
  SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' AND status='aberto' FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'Abra o caixa da Rotisseria para receber.'; END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid FOR UPDATE;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
  IF s.estado='concluida' THEN RETURN s.pagamento_resultado||jsonb_build_object('ja_recebida',true); END IF;
  expected:=(p_dados->>'versao')::bigint;
  IF s.estado<>'aberta' OR expected IS NULL OR expected<>s.versao THEN RAISE EXCEPTION 'A comanda mudou. Atualize e confira os itens antes de receber.'; END IF;
  SELECT sum(subtotal) INTO total FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado;
  IF coalesce(total,0)<=0 THEN RAISE EXCEPTION 'A comanda precisa ter itens com valor para receber.'; END IF;
  forma:=p_dados->>'forma'; IF forma NOT IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito','Outros') OR forma IS NULL THEN RAISE EXCEPTION 'Forma de pagamento inválida.'; END IF;
  pago:=round((p_dados->>'valor')::numeric,2);
  IF pago IS NULL OR pago<total OR pago>99999999999.99 OR (forma<>'Dinheiro' AND pago<>total) THEN RAISE EXCEPTION 'Confira o valor recebido. Troco é permitido apenas em dinheiro.'; END IF;
  troco:=pago-total;
  IF nullif(p_dados->>'cliente_id','') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.clientes WHERE empresa_id=e AND id=(p_dados->>'cliente_id')::uuid) THEN RAISE EXCEPTION 'Cliente de outra empresa ou inexistente.'; END IF;
  cpf:=nullif(regexp_replace(coalesce(p_dados->>'cpf',''),'[^0-9]','','g'),'');
  IF cpf IS NOT NULL AND NOT private.cpf_valido(cpf) THEN RAISE EXCEPTION 'CPF inválido.'; END IF;
  SELECT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false) INTO permitido;
  FOR r IN SELECT produto_id,sum(quantidade) quantidade FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado GROUP BY produto_id ORDER BY produto_id LOOP
   SELECT * INTO prod FROM public.produtos WHERE empresa_id=e AND id=r.produto_id FOR UPDATE;
   IF NOT prod.ativo THEN RAISE EXCEPTION 'Produto inativo: %.',prod.nome; END IF;
   IF NOT permitido AND prod.quantidade_estoque<r.quantidade THEN RAISE EXCEPTION 'Estoque insuficiente de %: disponível %, necessário %.',prod.nome,prod.quantidade_estoque,r.quantidade; END IF;
   UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-r.quantidade WHERE empresa_id=e AND id=r.produto_id;
  END LOOP;
  INSERT INTO public.contadores_venda AS cv(empresa_id,ultimo_numero) VALUES(e,1) ON CONFLICT(empresa_id) DO UPDATE SET ultimo_numero=cv.ultimo_numero+1 RETURNING ultimo_numero INTO n;
  INSERT INTO public.vendas(empresa_id,numero_venda,cliente_id,forma_pagamento,total,tipo,criado_por,cpf_nota,caixa_id) VALUES(e,n,nullif(p_dados->>'cliente_id','')::uuid,forma,total,'rotisseria',u,cpf,c.id) RETURNING id INTO vid;
  INSERT INTO public.itens_venda(empresa_id,venda_id,produto_id,quantidade,preco_unitario) SELECT e,vid,produto_id,quantidade,preco FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado ORDER BY criado_em,id;
  INSERT INTO public.vendas_pagamentos(empresa_id,venda_id,forma_pagamento,valor,ordem,criado_por,caixa_id) VALUES(e,vid,forma,total,1,u,c.id) RETURNING id INTO pid;
  PERFORM private.taxas_registrar('pdv',pid,coalesce(p_dados->'metadados','{}'));
  UPDATE private.rotisseria_sessoes SET estado='concluida',versao=versao+1,venda_id=vid,caixa_id=c.id,pagamento_resultado=jsonb_build_object('venda_id',vid,'numero_venda',n,'total',total,'troco',troco),finalizado_em=now() WHERE id=s.id AND empresa_id=e;
  result:=jsonb_build_object('venda_id',vid,'numero_venda',n,'total',total,'troco',troco);
 ELSIF p_acao='abrir_comanda' THEN
  IF NOT private.perm('rotisseria_lancar') THEN RAISE EXCEPTION 'Sem permissão para abrir comanda.' USING errcode='42501'; END IF;
  n:=(p_dados->>'numero')::int;
  IF n IS NULL OR n NOT BETWEEN 1 AND cfg.quantidade THEN RAISE EXCEPTION 'Número de comanda inválido.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(e::text||':rotisseria:'||n::text,0));
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND numero=n AND estado='aberta';
  IF s.id IS NULL THEN INSERT INTO private.rotisseria_sessoes(empresa_id,numero,criado_por) VALUES(e,n,u) RETURNING * INTO s; END IF;
  result:=to_jsonb(s);
 ELSIF p_acao IN ('lancar','cancelar_item','fechar_vazia') THEN
  IF NOT private.perm('rotisseria_lancar') THEN RAISE EXCEPTION 'Sem permissão para lançar na comanda.' USING errcode='42501'; END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid FOR UPDATE;
  IF s.id IS NULL OR s.estado<>'aberta' THEN RAISE EXCEPTION 'Comanda encerrada ou inexistente. Abra novamente na grade.'; END IF;
  IF p_acao='lancar' THEN
   IF nullif(p_dados->>'chave','') IS NULL THEN RAISE EXCEPTION 'Chave do lançamento obrigatória.'; END IF;
   SELECT * INTO it FROM private.rotisseria_itens WHERE empresa_id=e AND chave=(p_dados->>'chave')::uuid;
   IF it.id IS NOT NULL THEN
    IF it.sessao_id<>s.id OR it.produto_id<>(p_dados->>'produto_id')::uuid OR it.quantidade<>(p_dados->>'quantidade')::numeric THEN RAISE EXCEPTION 'Chave já utilizada por outro lançamento.'; END IF;
    RETURN jsonb_build_object('item_id',it.id,'repetido',true);
   END IF;
   qtd:=(p_dados->>'quantidade')::numeric;
   IF qtd IS NULL OR qtd<=0 OR qtd>999999999 OR qtd<>round(qtd,4) THEN RAISE EXCEPTION 'Quantidade inválida, use até quatro casas decimais.'; END IF;
   SELECT * INTO prod FROM public.produtos WHERE empresa_id=e AND id=(p_dados->>'produto_id')::uuid AND ativo;
   IF prod.id IS NULL OR prod.tipo_fiscal='servico' THEN RAISE EXCEPTION 'Selecione um produto ativo para venda.'; END IF;
   IF NOT(prod.venda_granel OR upper(coalesce(prod.unidade_comercial,'')) IN ('KG','K','QUILO')) AND qtd<>trunc(qtd) THEN RAISE EXCEPTION 'Este produto é vendido por unidade. Informe uma quantidade inteira.'; END IF;
   IF (p_dados->>'preco')::numeric IS NULL OR (p_dados->>'preco')::numeric<>prod.preco_venda THEN RAISE EXCEPTION 'O preço do produto mudou. Pesquise novamente antes de lançar.'; END IF;
   INSERT INTO private.rotisseria_itens(empresa_id,sessao_id,produto_id,nome,unidade,quantidade,preco,chave,criado_por) VALUES(e,s.id,prod.id,prod.nome,coalesce(prod.unidade_comercial,'UN'),qtd,prod.preco_venda,(p_dados->>'chave')::uuid,u) RETURNING id INTO pid;
   result:=jsonb_build_object('item_id',pid);
  ELSIF p_acao='cancelar_item' THEN
   UPDATE private.rotisseria_itens SET cancelado=true WHERE empresa_id=e AND sessao_id=s.id AND id=(p_dados->>'item_id')::uuid AND NOT cancelado;
   IF NOT FOUND THEN RAISE EXCEPTION 'Item não encontrado ou já cancelado.'; END IF;
  ELSE
   IF EXISTS(SELECT 1 FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado) THEN RAISE EXCEPTION 'A comanda ainda possui itens.'; END IF;
   UPDATE private.rotisseria_sessoes SET estado='cancelada',finalizado_em=now() WHERE empresa_id=e AND id=s.id;
  END IF;
  UPDATE private.rotisseria_sessoes SET versao=versao+1 WHERE empresa_id=e AND id=s.id;
 ELSIF p_acao='detalhe' THEN
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
  RETURN to_jsonb(s)||jsonb_build_object('itens',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY criado_em,id),'[]') FROM private.rotisseria_itens i WHERE empresa_id=e AND sessao_id=s.id),'total',(SELECT coalesce(sum(subtotal),0) FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado));
 ELSIF p_acao='imprimir' THEN
  IF NOT dispositivo OR NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Imprima no dispositivo de caixa.' USING errcode='42501'; END IF;
  IF cfg.impressora_id IS NULL THEN RAISE EXCEPTION 'Selecione a impressora nas configurações da Rotisseria.'; END IF;
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND venda_id=(p_dados->>'venda_id')::uuid AND estado='concluida';
  IF s.id IS NULL OR nullif(p_dados->>'chave','') IS NULL THEN RAISE EXCEPTION 'Venda ou chave de impressão inválida.'; END IF;
  SELECT jsonb_agg(jsonb_build_object('nome',i.nome,'quantidade',trim_scale(i.quantidade),'preco_unitario',i.preco,'subtotal',i.subtotal) ORDER BY i.criado_em,i.id) INTO arr FROM private.rotisseria_itens i WHERE i.empresa_id=e AND i.sessao_id=s.id AND NOT i.cancelado;
  SELECT private.impressao_job_criar(e,'caixa','recibo','rotisseria:recibo:'||s.venda_id||':'||(p_dados->>'chave')::uuid,'Rotisseria — Comanda '||s.numero,
   jsonb_build_object('versao',1,'tipo','recibo','rotisseria_impressora_propria',true,'empresa',(SELECT nome FROM public.empresas WHERE id=e),'setor','ROTISSERIA','venda',(SELECT numero_venda FROM public.vendas WHERE empresa_id=e AND id=s.venda_id),'data_hora',to_char(s.finalizado_em AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),'itens',arr,'total',(SELECT total FROM public.vendas WHERE empresa_id=e AND id=s.venda_id),'pagamentos',(SELECT jsonb_agg(jsonb_build_object('forma',forma_pagamento,'valor',valor) ORDER BY ordem) FROM public.vendas_pagamentos WHERE empresa_id=e AND venda_id=s.venda_id)),u) INTO pid;
  RETURN jsonb_build_object('job_id',pid);
 ELSIF p_acao='historico' THEN
  IF NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Sem permissão para consultar vendas.' USING errcode='42501'; END IF;
  RETURN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.criado_em DESC),'[]') FROM (SELECT v.*,s.numero comanda,s.id sessao_id,c.nome cliente_nome FROM public.vendas v JOIN private.rotisseria_sessoes s ON s.empresa_id=v.empresa_id AND s.venda_id=v.id LEFT JOIN public.clientes c ON c.empresa_id=v.empresa_id AND c.id=v.cliente_id WHERE v.empresa_id=e AND v.tipo='rotisseria' AND (nullif(p_dados->>'de','') IS NULL OR v.criado_em>=(p_dados->>'de')::date::timestamp AT TIME ZONE 'America/Sao_Paulo') AND (nullif(p_dados->>'ate','') IS NULL OR v.criado_em<((p_dados->>'ate')::date+1)::timestamp AT TIME ZONE 'America/Sao_Paulo') ORDER BY v.criado_em DESC LIMIT 100 OFFSET greatest(0,coalesce((p_dados->>'pagina')::int,0))*100) x);
 ELSIF p_acao='caixa_dados' THEN
  IF NOT private.perm('rotisseria_caixa') THEN RAISE EXCEPTION 'Sem permissão para consultar caixa.' USING errcode='42501'; END IF;
  SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' AND status='aberto';
  RETURN jsonb_build_object('caixa',CASE WHEN c.id IS NOT NULL THEN private.caixa_json(c) ELSE NULL END,'resumo',CASE WHEN c.id IS NOT NULL THEN private.rotisseria_caixa_resumo(c) ELSE NULL END,
  'historico',(SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.aberto_em DESC),'[]') FROM (SELECT * FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' ORDER BY aberto_em DESC LIMIT 30) x));
 ELSE RAISE EXCEPTION 'Ação da Rotisseria inválida.'; END IF;
 INSERT INTO public.rotisseria_sinais(empresa_id) VALUES(e) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.rotisseria_sinais.revisao+1;
 RETURN coalesce(result,'{}');
END $$;
REVOKE ALL ON FUNCTION private.rotisseria_rpc(text,jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION private.rotisseria_rpc(text,jsonb,uuid) TO authenticated;
CREATE FUNCTION public.rotisseria_rpc(p_acao text,p_dados jsonb DEFAULT '{}',p_chave uuid DEFAULT NULL) RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.rotisseria_rpc(p_acao,p_dados,p_chave) $$;
REVOKE ALL ON FUNCTION public.rotisseria_rpc(text,jsonb,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.rotisseria_rpc(text,jsonb,uuid) TO authenticated;
CREATE FUNCTION public.admin_listar_rotisseria_modulos() RETURNS TABLE(empresa_id uuid,ativo boolean) LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN IF NOT public.florest_eh_admin() THEN RAISE EXCEPTION 'Acesso negado.' USING errcode='42501'; END IF; RETURN QUERY SELECT m.empresa_id,m.ativo FROM public.empresa_modulos m WHERE m.modulo='rotisseria'; END $$;
REVOKE ALL ON FUNCTION public.admin_listar_rotisseria_modulos() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_listar_rotisseria_modulos() TO authenticated;

DO $g$ BEGIN IF md5(pg_get_functiondef('private.caixa_calcular(public.caixas)'::regprocedure))<>'44dc3d45c20c3a84341b781372362fef' THEN RAISE EXCEPTION 'Base de resumo de caixa alterada.'; END IF; END $g$;
CREATE OR REPLACE FUNCTION private.caixa_calcular(p_caixa caixas)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_formas      jsonb;
  v_cp_total numeric := 0; v_cp_dinheiro numeric := 0; v_cp_qtd integer := 0; v_cp_formas jsonb; v_cp_itens jsonb;
  v_recebido    numeric(14,2) := 0;
  v_dinheiro    numeric(14,2) := 0;
  v_qtd_oper    integer := 0;
  v_prazo_qtd   integer := 0;
  v_prazo_total numeric(14,2) := 0;
  v_canc_qtd    integer := 0;
  v_canc_total  numeric(14,2) := 0;
  v_est_qtd     integer := 0;
  v_est_total   numeric(14,2) := 0;
  v_suprimentos numeric(14,2) := 0;   -- reservado (suprimento ainda não implementado)
  v_cr_total numeric(14,2) := 0;
  v_cr_qtd integer := 0;
  v_sangrias    numeric(14,2) := 0;   -- reservado (sangria ainda não implementada)
begin
 if p_caixa.tipo_caixa='ROTISSERIA' then return private.rotisseria_caixa_resumo(p_caixa); end if;
 if p_caixa.tipo_caixa='GASTRONOMIA' then return private.gastronomia_caixa_calcular(p_caixa); end if;

  -- por forma de pagamento: as 5 conhecidas sempre (Outros só no PDV) + qualquer outro nome presente
  with base(forma, ord) as (
    values ('Dinheiro', 1), ('Pix', 2), ('Cartão de Débito', 3), ('Cartão de Crédito', 4), ('Outros', 5)
  ), mov as (
    select vp.forma_pagamento as forma_raw, vp.valor
      from public.vendas_pagamentos vp
      join public.vendas v on v.empresa_id = vp.empresa_id and v.id = vp.venda_id
     where p_caixa.tipo_caixa = 'PDV'
       and vp.empresa_id = p_caixa.empresa_id and vp.caixa_id = p_caixa.id
       and v.cancelada_em is null
    union all
    select f.forma_pagamento, f.valor
      from public.bar_pagamentos_formas f
      join public.bar_pagamentos p on p.empresa_id = f.empresa_id and p.id = f.pagamento_id
     where p_caixa.tipo_caixa = 'BAR'
       and p.empresa_id = p_caixa.empresa_id and p.caixa_id = p_caixa.id
       and not p.estornado
    union all
    select f.forma_pagamento, f.valor
      from public.contas_receber_recebimentos_formas f
      join public.contas_receber_recebimentos r on r.id=f.recebimento_id and r.empresa_id=f.empresa_id
     where r.empresa_id=p_caixa.empresa_id and r.caixa_id=p_caixa.id
  ), norm as (
    select coalesce((select b.forma from base b where lower(b.forma) = lower(btrim(m.forma_raw))), btrim(m.forma_raw)) as forma,
           m.valor
      from mov m
  ), agg as (
    select n.forma, sum(n.valor) as total, count(*) as qtd from norm n group by n.forma
  ), todas as (
    select coalesce(b.forma, a.forma) as forma, coalesce(b.ord, 99) as ord,
           coalesce(a.total, 0) as total, coalesce(a.qtd, 0) as qtd
      from base b
      full join agg a on a.forma = b.forma
     where b.forma is null or p_caixa.tipo_caixa = 'PDV' or b.forma <> 'Outros' or a.forma is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object('forma', t.forma, 'total', t.total, 'qtd', t.qtd)
                            order by t.ord, t.forma), '[]'::jsonb),
         coalesce(sum(t.total), 0),
         coalesce(sum(t.total) filter (where t.forma = 'Dinheiro'), 0)
    into v_formas, v_recebido, v_dinheiro
    from todas t;

  if p_caixa.tipo_caixa = 'PDV' then
    select count(*) filter (where v.cancelada_em is null),
           count(*) filter (where v.cancelada_em is null and v.forma_pagamento = 'Nota a Prazo'),
           coalesce(sum(v.total) filter (where v.cancelada_em is null and v.forma_pagamento = 'Nota a Prazo'), 0),
           count(*) filter (where v.cancelada_em is not null),
           coalesce(sum(v.total) filter (where v.cancelada_em is not null), 0)
      into v_qtd_oper, v_prazo_qtd, v_prazo_total, v_canc_qtd, v_canc_total
      from public.vendas v
     where v.empresa_id = p_caixa.empresa_id and v.caixa_id = p_caixa.id;
  else
    select count(*) filter (where not p.estornado),
           count(*) filter (where p.estornado),
           coalesce(sum(p.total) filter (where p.estornado), 0)
      into v_qtd_oper, v_est_qtd, v_est_total
      from public.bar_pagamentos p
     where p.empresa_id = p_caixa.empresa_id and p.caixa_id = p_caixa.id;
  end if;

  select count(*),coalesce(sum(r.valor_total),0) into v_cr_qtd,v_cr_total
    from public.contas_receber_recebimentos r where r.empresa_id=p_caixa.empresa_id and r.caixa_id=p_caixa.id;
  if p_caixa.tipo_caixa='BAR' then
    select count(*),coalesce(sum(v.total),0) into v_prazo_qtd,v_prazo_total
      from public.vendas v where v.empresa_id=p_caixa.empresa_id and v.caixa_id=p_caixa.id
        and v.forma_pagamento='Nota a Prazo' and v.cancelada_em is null;
  end if;
  -- Saídas separadas das entradas: só Dinheiro reduz o saldo físico.
  SELECT count(*),coalesce(sum(p.valor),0) INTO v_cp_qtd,v_cp_total
    FROM public.despesas_pagamentos p WHERE p.empresa_id=p_caixa.empresa_id AND p.caixa_id=p_caixa.id;
  SELECT coalesce(sum(f.valor) FILTER (WHERE f.forma_pagamento='Dinheiro'),0) INTO v_cp_dinheiro
    FROM public.despesas_pagamentos_formas f JOIN public.despesas_pagamentos p ON p.empresa_id=f.empresa_id AND p.id=f.pagamento_id
    WHERE p.empresa_id=p_caixa.empresa_id AND p.caixa_id=p_caixa.id;
  SELECT coalesce(jsonb_agg(jsonb_build_object('forma',x.forma_pagamento,'qtd',x.qtd,'total',x.total) ORDER BY x.forma_pagamento),'[]'::jsonb)
    INTO v_cp_formas FROM (SELECT f.forma_pagamento,count(*) qtd,sum(f.valor) total
      FROM public.despesas_pagamentos_formas f JOIN public.despesas_pagamentos p ON p.empresa_id=f.empresa_id AND p.id=f.pagamento_id
      WHERE p.empresa_id=p_caixa.empresa_id AND p.caixa_id=p_caixa.id GROUP BY f.forma_pagamento) x;
  -- Despesas efetivamente pagas neste caixa, discriminadas por descrição.
  SELECT coalesce(jsonb_agg(jsonb_build_object('descricao', x.descricao, 'valor', x.valor)
      ORDER BY x.descricao), '[]'::jsonb) INTO v_cp_itens
  FROM (
    SELECT d.descricao, sum(p.valor) AS valor
    FROM public.despesas_pagamentos p
    JOIN public.despesas d ON d.empresa_id=p.empresa_id AND d.id=p.despesa_id
    WHERE p.empresa_id=p_caixa.empresa_id AND p.caixa_id=p_caixa.id
    GROUP BY d.descricao
  ) x;
  return jsonb_build_object(
    'saidas_contas_pagar',jsonb_build_object('qtd',v_cp_qtd,'total',v_cp_total,'dinheiro',v_cp_dinheiro,'por_forma',v_cp_formas,'itens',v_cp_itens),
    'saldo_apos_despesas',v_recebido-v_cp_total,
    'tipo_caixa', p_caixa.tipo_caixa,
    'valor_inicial', p_caixa.valor_inicial,
    'por_forma', v_formas,
    'total_recebido', v_recebido,
    'qtd_operacoes', v_qtd_oper + v_cr_qtd,
    'vendas_recebidas', v_recebido - v_cr_total,
    'recebimentos_titulos', jsonb_build_object('qtd',v_cr_qtd,'total',v_cr_total),
    'a_prazo', jsonb_build_object('qtd', v_prazo_qtd, 'total', v_prazo_total),
    'canceladas', jsonb_build_object('qtd', v_canc_qtd, 'total', v_canc_total),
    'estornos', jsonb_build_object('qtd', v_est_qtd, 'total', v_est_total),
    'dinheiro', v_dinheiro,
    'suprimentos', v_suprimentos,
    'sangrias', v_sangrias,
    'saldo_dinheiro_esperado', p_caixa.valor_inicial + v_dinheiro + v_suprimentos - v_sangrias - v_cp_dinheiro
  );
end;
$function$
;
DO $g$ BEGIN IF md5(pg_get_functiondef('public.impressao_agente_jobs_reservar(uuid,text,text,integer,inet)'::regprocedure))<>'6bbc401f511a20c5c3387cc4ee2b1cef' THEN RAISE EXCEPTION 'Base da fila de impressão alterada.'; END IF; END $g$;
CREATE OR REPLACE FUNCTION public.impressao_agente_jobs_reservar(p_agente_id uuid, p_credencial_hash text, p_instalacao text, p_limite integer DEFAULT 3, p_ip inet DEFAULT NULL::inet)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_v      record;
  v_lim    integer := least(greatest(coalesce(p_limite, 3), 1), private.impressao_job_param('lote_max'));
  v_jobs   jsonb;
  v_lease  integer := private.impressao_job_param('reserva_segundos');
begin
  select * into v_v from private.impressao_agente_validar(p_agente_id, p_credencial_hash, p_instalacao, p_ip, false);
  if not v_v.r_ok then
    return jsonb_build_object('ok', false, 'erro', v_v.r_erro);
  end if;

  perform private.impressao_job_reciclar(v_v.r_empresa_id);

  with candidatos as (
    select j.id, a.impressora_id
      from public.impressao_jobs j
      join lateral (
        SELECT j.empresa_id, (c.opcoes#>>'{cardapio,impressora_id}')::uuid impressora_id FROM public.gastronomia_configuracoes c WHERE c.empresa_id=j.empresa_id AND j.payload->>'gastronomia_impressora_propria'='true' AND j.payload ? 'gastronomia_atendimento_id'
        UNION ALL
        SELECT c.empresa_id,c.impressora_id FROM private.rotisseria_config c WHERE c.empresa_id=j.empresa_id AND j.payload->>'rotisseria_impressora_propria'='true'
        UNION ALL
        SELECT m.empresa_id,m.impressora_id FROM public.impressao_destino_impressora m WHERE m.empresa_id=j.empresa_id AND m.destino_codigo=j.destino_codigo AND coalesce(j.payload->>'rotisseria_impressora_propria','false')<>'true' AND NOT (coalesce(j.payload->>'gastronomia_impressora_propria','false')='true' AND j.payload ? 'gastronomia_atendimento_id')
      ) a ON true
      join public.impressoras i
        on i.empresa_id = a.empresa_id and i.id = a.impressora_id
     where j.empresa_id = v_v.r_empresa_id          -- empresa do AGENTE (do banco), nunca do cliente
       and i.estacao_id = v_v.r_estacao_id          -- só impressoras da estação deste agente
       and j.status = 'pendente'
       and j.proxima_tentativa_em <= now()
       and j.expira_em > now()
       and j.tentativas < j.max_tentativas
     order by j.criado_em, j.id
     limit v_lim
       for update of j skip locked
  ),
  reservados as (
    update public.impressao_jobs j
       set status = 'processando',
           tentativas = j.tentativas + 1,
           agente_id = v_v.r_agente_id,
           estacao_id = v_v.r_estacao_id,
           impressora_id = c.impressora_id,
           reservado_em = now(),
           reserva_expira_em = now() + make_interval(secs => v_lease)
      from candidatos c
     where j.id = c.id and j.empresa_id = v_v.r_empresa_id
    returning j.*
  )
  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id',               r.id,
             'destino',          r.destino_codigo,
             'tipo',             r.tipo,
             'titulo',           r.titulo,
             'tentativa',        r.tentativas,
             'max_tentativas',   r.max_tentativas,
             'criado_em',        r.criado_em,
             'reserva_segundos', v_lease,
             'payload',          r.payload,
             'impressora', jsonb_build_object(
                'id',            i.id,
                'nome',          i.nome,
                'identificador', i.identificador_agente,
                'conexao',       i.conexao,
                'porta_windows', i.porta_windows)
           ) order by r.criado_em, r.id), '[]'::jsonb)
    into v_jobs
    from reservados r
    join public.impressoras i on i.empresa_id = r.empresa_id and i.id = r.impressora_id;

  return jsonb_build_object('ok', true, 'jobs', v_jobs, 'hora_servidor', now());
end;
$function$
;
COMMIT;
