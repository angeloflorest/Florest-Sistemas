BEGIN;
DO $g$ BEGIN IF md5(replace(pg_get_functiondef('private.rotisseria_rpc(text,jsonb,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'58e34b92b70d1c3b34a0896f235fe9ad' THEN RAISE EXCEPTION 'Base alterada: private.rotisseria_rpc(text,jsonb,uuid). Recompare antes de aplicar.'; END IF; END $g$;
DO $g$ BEGIN IF md5(replace(pg_get_functiondef('private.rotisseria_caixa_resumo(public.caixas)'::regprocedure),chr(13)||chr(10),chr(10)))<>'46cf058c516dba651c05d801d4635100' THEN RAISE EXCEPTION 'Base alterada: private.rotisseria_caixa_resumo(public.caixas). Recompare antes de aplicar.'; END IF; END $g$;
DO $g$ BEGIN IF md5(replace(pg_get_functiondef('private.contas_receber_tipo_caixa(uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10)))<>'ef07a6dc679e25a703786f77739e9bba' THEN RAISE EXCEPTION 'Base alterada: private.contas_receber_tipo_caixa(uuid,uuid). Recompare antes de aplicar.'; END IF; END $g$;
ALTER TABLE private.rotisseria_sessoes ADD COLUMN estoque_baixado boolean NOT NULL DEFAULT false, ADD COLUMN cliente_id uuid, ADD COLUMN cpf_nota text;
CREATE TABLE private.rotisseria_pagamentos(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),empresa_id uuid NOT NULL,sessao_id uuid NOT NULL,caixa_id uuid NOT NULL,
 chave uuid NOT NULL,solicitacao jsonb NOT NULL,forma text NOT NULL CHECK(forma IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito','Outros','Nota a Prazo')),
 valor numeric(14,2) NOT NULL CHECK(valor>0),entregue numeric(14,2) NOT NULL CHECK(entregue>=valor),troco numeric(14,2) NOT NULL DEFAULT 0 CHECK(troco>=0),
 metadados jsonb NOT NULL DEFAULT '{}',resultado jsonb NOT NULL DEFAULT '{}',criado_em timestamptz NOT NULL DEFAULT now(),criado_por uuid NOT NULL REFERENCES public.perfis(id),
 UNIQUE(empresa_id,chave),FOREIGN KEY(empresa_id,sessao_id) REFERENCES private.rotisseria_sessoes(empresa_id,id),FOREIGN KEY(empresa_id,caixa_id) REFERENCES public.caixas(empresa_id,id));
CREATE INDEX rotisseria_pagamentos_sessao ON private.rotisseria_pagamentos(empresa_id,sessao_id);
CREATE INDEX rotisseria_pagamentos_caixa ON private.rotisseria_pagamentos(empresa_id,caixa_id);
ALTER TABLE private.rotisseria_pagamentos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.rotisseria_pagamentos FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.rotisseria_saldo(p_sessao uuid,p_empresa uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 WITH consumo AS(SELECT coalesce(sum(subtotal),0) total FROM private.rotisseria_itens WHERE empresa_id=p_empresa AND sessao_id=p_sessao AND NOT cancelado),
 recebimentos AS(SELECT coalesce(sum(valor) FILTER(WHERE forma<>'Nota a Prazo'),0) pago,coalesce(sum(valor) FILTER(WHERE forma='Nota a Prazo'),0) prazo FROM private.rotisseria_pagamentos WHERE empresa_id=p_empresa AND sessao_id=p_sessao)
 SELECT jsonb_build_object('total',c.total,'total_pago',CASE WHEN s.estado='concluida' AND NOT EXISTS(SELECT 1 FROM private.rotisseria_pagamentos WHERE empresa_id=p_empresa AND sessao_id=p_sessao) THEN coalesce((SELECT sum(valor) FROM public.vendas_pagamentos WHERE empresa_id=p_empresa AND venda_id=s.venda_id),0) ELSE r.pago END,'total_a_prazo',r.prazo,'saldo',CASE WHEN s.estado='concluida' THEN 0 ELSE greatest(0,c.total-r.pago-r.prazo) END,
 'pagamentos',(SELECT coalesce(jsonb_agg(jsonb_build_object('id',p.id,'forma',p.forma,'valor',p.valor,'troco',p.troco,'criado_em',p.criado_em) ORDER BY p.criado_em,p.id),'[]') FROM private.rotisseria_pagamentos p WHERE empresa_id=p_empresa AND sessao_id=p_sessao)) FROM consumo c CROSS JOIN recebimentos r JOIN private.rotisseria_sessoes s ON s.empresa_id=p_empresa AND s.id=p_sessao
$$;
REVOKE ALL ON FUNCTION private.rotisseria_saldo(uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.rotisseria_receber(p_dados jsonb,p_dispositivo uuid) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
#variable_conflict use_column
DECLARE e uuid:=private.exigir_empresa_ativa();u uuid:=auth.uid();s private.rotisseria_sessoes;c public.caixas;p private.rotisseria_pagamentos;
 prod public.produtos;r record;consumo numeric;recebido numeric;restante numeric;credito numeric;entregue numeric;valor numeric;troco numeric:=0;
 forma text:=p_dados->>'forma';v_chave uuid;solicitacao jsonb:=p_dados-'chave';cliente uuid:=nullif(p_dados->>'cliente_id','')::uuid;
 cpf text:=nullif(regexp_replace(coalesce(p_dados->>'cpf',''),'[^0-9]','','g'),'');venc date:=nullif(p_dados->>'vencimento','')::date;
 saldo jsonb;v_resultado jsonb;permitido boolean;vid uuid;n bigint;titulo uuid;pid uuid;
BEGIN
 IF NOT private.empresa_tem_modulo('rotisseria') OR NOT private.perm('rotisseria_visualizar') OR NOT private.perm('rotisseria_caixa') OR NOT EXISTS(SELECT 1 FROM private.rotisseria_dispositivo d WHERE empresa_id=e AND token=p_dispositivo AND usuario_id=u) THEN RAISE EXCEPTION 'Recebimento disponível somente no caixa da Rotisseria.' USING errcode='42501'; END IF;
 SELECT * INTO c FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' AND status='aberto' FOR SHARE;
 IF c.id IS NULL THEN RAISE EXCEPTION 'Abra o caixa da Rotisseria antes de receber.'; END IF;
 SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid FOR UPDATE;
 IF s.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
 v_chave:=coalesce(nullif(p_dados->>'chave','')::uuid,md5(s.id::text||coalesce(p_dados->>'versao','')||solicitacao::text)::uuid);
 SELECT * INTO p FROM private.rotisseria_pagamentos WHERE empresa_id=e AND rotisseria_pagamentos.chave=v_chave;
 IF p.id IS NOT NULL THEN
  IF p.sessao_id<>s.id OR p.solicitacao<>solicitacao THEN RAISE EXCEPTION 'Chave de recebimento já usada com outros dados.'; END IF;
  IF s.estado='concluida' THEN RETURN s.pagamento_resultado||jsonb_build_object('repetido',true,'finalizada',true,'troco',p.troco); END IF;
  RETURN p.resultado||private.rotisseria_saldo(s.id,e)||jsonb_build_object('repetido',true);
 END IF;
 IF s.estado='concluida' THEN RETURN s.pagamento_resultado||jsonb_build_object('ja_recebida',true,'finalizada',true); END IF;
 IF s.estado<>'aberta' OR (p_dados->>'versao')::bigint IS DISTINCT FROM s.versao THEN RAISE EXCEPTION 'A comanda mudou. Confira os itens e o saldo antes de receber.'; END IF;
 saldo:=private.rotisseria_saldo(s.id,e);consumo:=(saldo->>'total')::numeric;recebido:=(saldo->>'total_pago')::numeric;restante:=(saldo->>'saldo')::numeric;
 IF restante<=0 OR consumo<=0 THEN RAISE EXCEPTION 'A comanda não tem saldo para receber.'; END IF;
 IF forma IS NULL OR forma NOT IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito','Outros','Nota a Prazo') THEN RAISE EXCEPTION 'Escolha uma forma de pagamento.'; END IF;
 entregue:=round((p_dados->>'valor')::numeric,2);
 IF entregue IS NULL OR entregue<=0 OR entregue>99999999999.99 THEN RAISE EXCEPTION 'Informe um valor recebido válido.'; END IF;
 IF forma<>'Dinheiro' AND entregue>restante THEN RAISE EXCEPTION 'O valor supera o saldo da comanda.'; END IF;
 valor:=least(entregue,restante);troco:=entregue-valor;
 IF cliente IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.clientes WHERE empresa_id=e AND id=cliente) THEN RAISE EXCEPTION 'Cliente não encontrado nesta empresa.'; END IF;
 IF cpf IS NOT NULL AND NOT private.cpf_valido(cpf) THEN RAISE EXCEPTION 'CPF inválido.'; END IF;
 IF s.cliente_id IS NOT NULL AND cliente IS NOT NULL AND s.cliente_id<>cliente THEN RAISE EXCEPTION 'Mantenha o mesmo cliente dos recebimentos anteriores.'; END IF;
 cliente:=coalesce(cliente,s.cliente_id);cpf:=coalesce(cpf,s.cpf_nota);
 IF forma='Nota a Prazo' THEN
  IF cliente IS NULL OR venc IS NULL OR venc<(now() AT TIME ZONE 'America/Sao_Paulo')::date OR valor<>restante THEN RAISE EXCEPTION 'Nota a prazo exige cliente, vencimento válido e todo o saldo restante.'; END IF;
 END IF;
 -- Reserve stock once on the first payment. New items after that are deducted on launch.
 IF NOT s.estoque_baixado THEN
  SELECT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false) INTO permitido;
  FOR r IN SELECT produto_id,sum(quantidade) qtd FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado GROUP BY produto_id ORDER BY produto_id LOOP
   SELECT * INTO prod FROM public.produtos WHERE empresa_id=e AND id=r.produto_id FOR UPDATE;
   IF NOT prod.ativo THEN RAISE EXCEPTION 'Produto inativo: %.',prod.nome; END IF;
   IF NOT permitido AND prod.quantidade_estoque<r.qtd THEN RAISE EXCEPTION 'Estoque insuficiente de %: disponível %, necessário %.',prod.nome,prod.quantidade_estoque,r.qtd; END IF;
   UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-r.qtd WHERE empresa_id=e AND id=r.produto_id;
  END LOOP;
 END IF;
 INSERT INTO private.rotisseria_pagamentos(empresa_id,sessao_id,caixa_id,chave,solicitacao,forma,valor,entregue,troco,metadados,criado_por)
 VALUES(e,s.id,c.id,v_chave,solicitacao,forma,valor,entregue,troco,coalesce(p_dados->'metadados','{}'),u) RETURNING id INTO pid;
 UPDATE private.rotisseria_sessoes SET estoque_baixado=true,cliente_id=cliente,cpf_nota=cpf,versao=versao+1 WHERE empresa_id=e AND id=s.id;
 v_resultado:=jsonb_build_object('finalizada',false,'total',consumo,'total_pago',recebido+CASE WHEN forma='Nota a Prazo' THEN 0 ELSE valor END,'saldo',restante-valor,'troco',troco,'pagamento_id',pid);
 IF valor=restante THEN
  INSERT INTO public.contadores_venda AS cv(empresa_id,ultimo_numero) VALUES(e,1) ON CONFLICT(empresa_id) DO UPDATE SET ultimo_numero=cv.ultimo_numero+1 RETURNING ultimo_numero INTO n;
  -- Operational ledger retains each receipt's actual shift. The core sale can span shifts.
  INSERT INTO public.vendas(empresa_id,numero_venda,cliente_id,forma_pagamento,total,tipo,criado_por,cpf_nota)
  VALUES(e,n,cliente,CASE WHEN (SELECT count(DISTINCT x.forma) FROM private.rotisseria_pagamentos x WHERE empresa_id=e AND sessao_id=s.id)>1 THEN 'dividido' ELSE forma END,consumo,'rotisseria',u,cpf) RETURNING id INTO vid;
  INSERT INTO public.itens_venda(empresa_id,venda_id,produto_id,quantidade,preco_unitario) SELECT e,vid,produto_id,quantidade,preco FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado ORDER BY criado_em,id;
  INSERT INTO public.vendas_pagamentos(id,empresa_id,venda_id,forma_pagamento,valor,ordem,criado_por,criado_em)
  SELECT x.id,e,vid,x.forma,x.valor,row_number() OVER(ORDER BY x.criado_em,x.id),x.criado_por,x.criado_em FROM private.rotisseria_pagamentos x WHERE empresa_id=e AND sessao_id=s.id AND forma<>'Nota a Prazo';
  FOR r IN SELECT x.id,x.metadados FROM private.rotisseria_pagamentos x WHERE empresa_id=e AND sessao_id=s.id AND forma<>'Nota a Prazo' LOOP PERFORM private.taxas_registrar('pdv',r.id,r.metadados); END LOOP;
  IF forma='Nota a Prazo' THEN
   INSERT INTO public.contas_receber(empresa_id,cliente_id,venda_id,origem,valor_original,saldo_aberto,vencimento,criado_por) VALUES(e,cliente,vid,'nota_prazo',valor,valor,venc,u) RETURNING id INTO titulo;
  END IF;
  v_resultado:=v_resultado||jsonb_build_object('finalizada',true,'venda_id',vid,'numero_venda',n,'titulo_id',titulo,'valor_a_receber',CASE WHEN forma='Nota a Prazo' THEN valor ELSE 0 END);
  UPDATE private.rotisseria_sessoes SET estado='concluida',finalizado_em=now(),venda_id=vid,caixa_id=c.id,pagamento_resultado=v_resultado WHERE empresa_id=e AND id=s.id;
 END IF;
 UPDATE private.rotisseria_pagamentos SET resultado=v_resultado WHERE id=pid AND empresa_id=e;
 INSERT INTO public.rotisseria_sinais(empresa_id) VALUES(e) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.rotisseria_sinais.revisao+1;
 RETURN v_resultado;
END $$;
REVOKE ALL ON FUNCTION private.rotisseria_receber(jsonb,uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.rotisseria_rpc(p_acao text, p_dados jsonb DEFAULT '{}'::jsonb, p_chave uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  SELECT coalesce(jsonb_agg(jsonb_build_object('numero',g.numero,'id',s.id,'versao',s.versao,'criado_em',s.criado_em,'total',coalesce(x.total,0),'itens',coalesce(x.itens,0),'saldo',greatest(0,coalesce(x.total,0)-coalesce(pay.valor,0))) ORDER BY g.numero),'[]') INTO arr
  FROM generate_series(1,cfg.quantidade) g(numero) LEFT JOIN private.rotisseria_sessoes s ON s.empresa_id=e AND s.numero=g.numero AND s.estado='aberta'
  LEFT JOIN LATERAL(SELECT sum(i.subtotal) total,count(*) itens FROM private.rotisseria_itens i WHERE i.empresa_id=e AND i.sessao_id=s.id AND NOT i.cancelado) x ON true
  LEFT JOIN LATERAL(SELECT sum(p.valor) valor FROM private.rotisseria_pagamentos p WHERE p.empresa_id=e AND p.sessao_id=s.id) pay ON true;
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
  RETURN private.rotisseria_receber(p_dados,p_chave);
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
   SELECT * INTO prod FROM public.produtos WHERE empresa_id=e AND id=(p_dados->>'produto_id')::uuid AND ativo FOR UPDATE;
   IF prod.id IS NULL OR prod.tipo_fiscal='servico' THEN RAISE EXCEPTION 'Selecione um produto ativo para venda.'; END IF;
   IF NOT(prod.venda_granel OR upper(coalesce(prod.unidade_comercial,'')) IN ('KG','K','QUILO')) AND qtd<>trunc(qtd) THEN RAISE EXCEPTION 'Este produto é vendido por unidade. Informe uma quantidade inteira.'; END IF;
   IF (p_dados->>'preco')::numeric IS NULL OR (p_dados->>'preco')::numeric<>prod.preco_venda THEN RAISE EXCEPTION 'O preço do produto mudou. Pesquise novamente antes de lançar.'; END IF;
   IF s.estoque_baixado THEN
    SELECT coalesce((SELECT permitir_venda_sem_estoque FROM public.configuracoes_empresa WHERE empresa_id=e),false) INTO permitido;
    IF NOT permitido AND prod.quantidade_estoque<qtd THEN RAISE EXCEPTION 'Estoque insuficiente de %.',prod.nome; END IF;
    UPDATE public.produtos SET quantidade_estoque=quantidade_estoque-qtd WHERE empresa_id=e AND id=prod.id;
   END IF;
   INSERT INTO private.rotisseria_itens(empresa_id,sessao_id,produto_id,nome,unidade,quantidade,preco,chave,criado_por) VALUES(e,s.id,prod.id,prod.nome,coalesce(prod.unidade_comercial,'UN'),qtd,prod.preco_venda,(p_dados->>'chave')::uuid,u) RETURNING id INTO pid;
   result:=jsonb_build_object('item_id',pid);
  ELSIF p_acao='cancelar_item' THEN
   SELECT * INTO it FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND id=(p_dados->>'item_id')::uuid AND NOT cancelado;
   IF it.id IS NULL THEN RAISE EXCEPTION 'Item não encontrado ou já cancelado.'; END IF;
   IF it.subtotal>(private.rotisseria_saldo(s.id,e)->>'saldo')::numeric THEN RAISE EXCEPTION 'O cancelamento deixaria o consumo menor que o valor já pago.'; END IF;
   IF s.estoque_baixado THEN UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+it.quantidade WHERE empresa_id=e AND id=it.produto_id; END IF;
   UPDATE private.rotisseria_itens SET cancelado=true WHERE empresa_id=e AND id=it.id;
  ELSE
   IF EXISTS(SELECT 1 FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado) THEN RAISE EXCEPTION 'A comanda ainda possui itens.'; END IF;
   UPDATE private.rotisseria_sessoes SET estado='cancelada',finalizado_em=now() WHERE empresa_id=e AND id=s.id;
  END IF;
  UPDATE private.rotisseria_sessoes SET versao=versao+1 WHERE empresa_id=e AND id=s.id;
 ELSIF p_acao='detalhe' THEN
  SELECT * INTO s FROM private.rotisseria_sessoes WHERE empresa_id=e AND id=(p_dados->>'id')::uuid;
  IF s.id IS NULL THEN RAISE EXCEPTION 'Comanda não encontrada.'; END IF;
  RETURN to_jsonb(s)||private.rotisseria_saldo(s.id,e)||jsonb_build_object('itens',(SELECT coalesce(jsonb_agg(to_jsonb(i) ORDER BY criado_em,id),'[]') FROM private.rotisseria_itens i WHERE empresa_id=e AND sessao_id=s.id),'total',(SELECT coalesce(sum(subtotal),0) FROM private.rotisseria_itens WHERE empresa_id=e AND sessao_id=s.id AND NOT cancelado));
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
  'historico',CASE WHEN coalesce((p_dados->>'historico')::boolean,false) THEN (SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.aberto_em DESC),'[]') FROM (SELECT * FROM public.caixas WHERE empresa_id=e AND tipo_caixa='ROTISSERIA' ORDER BY aberto_em DESC LIMIT 30) x) ELSE '[]'::jsonb END);
 ELSE RAISE EXCEPTION 'Ação da Rotisseria inválida.'; END IF;
 INSERT INTO public.rotisseria_sinais(empresa_id) VALUES(e) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.rotisseria_sinais.revisao+1;
 RETURN coalesce(result,'{}');
END $function$
;
CREATE OR REPLACE FUNCTION private.rotisseria_caixa_resumo(p_caixa public.caixas) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 WITH movimentos AS (
 SELECT p.forma,p.valor FROM private.rotisseria_pagamentos p WHERE p.empresa_id=p_caixa.empresa_id AND p.caixa_id=p_caixa.id AND p.forma<>'Nota a Prazo'
 UNION ALL
 SELECT vp.forma_pagamento,vp.valor FROM public.vendas_pagamentos vp JOIN public.vendas v ON v.id=vp.venda_id AND v.empresa_id=vp.empresa_id WHERE vp.empresa_id=p_caixa.empresa_id AND vp.caixa_id=p_caixa.id AND v.tipo='rotisseria' AND v.cancelada_em IS NULL AND NOT EXISTS(SELECT 1 FROM private.rotisseria_pagamentos p WHERE p.empresa_id=v.empresa_id AND p.id=vp.id)
 UNION ALL
 SELECT f.forma_pagamento,f.valor FROM public.contas_receber_recebimentos r JOIN public.contas_receber_recebimentos_formas f ON f.empresa_id=r.empresa_id AND f.recebimento_id=r.id WHERE r.empresa_id=p_caixa.empresa_id AND r.caixa_id=p_caixa.id
 ), agrupado AS(SELECT forma,sum(valor) total,count(*) qtd FROM movimentos GROUP BY forma)
 SELECT jsonb_build_object('tipo_caixa','ROTISSERIA','valor_inicial',p_caixa.valor_inicial,'total_recebido',coalesce(sum(total),0),'por_forma',coalesce(jsonb_agg(jsonb_build_object('forma',forma,'total',total,'qtd',qtd)),'[]'),'saldo_dinheiro_esperado',p_caixa.valor_inicial+coalesce(sum(total) FILTER(WHERE forma='Dinheiro'),0),'qtd_operacoes',coalesce(sum(qtd),0),
 'total_a_prazo',(SELECT coalesce(sum(valor),0) FROM private.rotisseria_pagamentos WHERE empresa_id=p_caixa.empresa_id AND caixa_id=p_caixa.id AND forma='Nota a Prazo')) FROM agrupado;
$$;

CREATE OR REPLACE FUNCTION private.contas_receber_tipo_caixa(p_titulo uuid, p_empresa uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  SELECT CASE WHEN count(DISTINCT origem.tipo) = 1 THEN min(origem.tipo) END
  FROM public.contas_receber cr
  JOIN public.vendas v ON v.id = cr.venda_id AND v.empresa_id = cr.empresa_id
  LEFT JOIN public.caixas cx ON cx.id = v.caixa_id AND cx.empresa_id = v.empresa_id
  CROSS JOIN LATERAL unnest(ARRAY[
    CASE WHEN v.pdv_prazo_chave IS NOT NULL OR EXISTS (
      SELECT 1 FROM public.pdv_comandas_sessoes s WHERE s.venda_id = v.id AND s.empresa_id = p_empresa
    ) THEN 'PDV'::text END,
    CASE WHEN v.tipo = 'bar' OR EXISTS (
      SELECT 1 FROM public.bar_comandas b WHERE b.venda_id = v.id AND b.empresa_id = p_empresa
    ) THEN 'BAR'::text END,
    CASE WHEN v.tipo='rotisseria' THEN 'ROTISSERIA'::text END,
    CASE WHEN cx.tipo_caixa IN ('PDV','BAR') THEN cx.tipo_caixa END
  ]) AS origem(tipo)
  WHERE cr.id = p_titulo AND cr.empresa_id = p_empresa;
$function$
;
COMMIT;
