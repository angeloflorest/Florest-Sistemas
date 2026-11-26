-- Conexões de produção ficam inativas até validar credenciais e autorização na API.
CREATE TABLE private.gastronomia_99food_conexoes (
 empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id), app_id text NOT NULL CHECK(app_id ~ '^[1-9][0-9]{0,18}$'),
 app_shop_id text NOT NULL CHECK(length(app_shop_id) BETWEEN 1 AND 100), shop_id text NOT NULL CHECK(shop_id ~ '^[1-9][0-9]{0,18}$'),
 ambiente text NOT NULL DEFAULT 'producao' CHECK(ambiente IN ('teste','producao')), segredo_id uuid NOT NULL,
 habilitada boolean NOT NULL DEFAULT false, nome_loja text NOT NULL DEFAULT '',
 auth_token text,token_expira_em timestamptz,token_consultar_apos timestamptz NOT NULL DEFAULT '-infinity',token_renovar_apos timestamptz NOT NULL DEFAULT '-infinity',token_erro text,
 ultima_autenticacao timestamptz,worker_reserva uuid,worker_ate timestamptz,worker_proxima timestamptz,ultima_execucao timestamptz,ultimo_erro text,
 atualizado_em timestamptz NOT NULL DEFAULT now(), atualizado_por uuid,
 UNIQUE(app_id,app_shop_id),UNIQUE(ambiente,shop_id)
);
CREATE TABLE private.gastronomia_99food_operacao_pedidos (
 empresa_id uuid NOT NULL REFERENCES private.gastronomia_99food_conexoes(empresa_id),order_id text NOT NULL CHECK(order_id ~ '^[1-9][0-9]{0,18}$'),order_index integer,
 recebido_em timestamptz NOT NULL DEFAULT now(),estado text NOT NULL DEFAULT 'recebido' CHECK(estado IN ('recebido','aceito','encerrado')),
 detalhe jsonb,status_99food integer,pronto boolean NOT NULL DEFAULT false,normalizado jsonb,
 atendimento_id uuid REFERENCES public.gastronomia_atendimentos(id),impresso_em timestamptz,importado_em timestamptz,
 atualizado_em timestamptz,ultima_consulta timestamptz,ultimo_erro text,revisao_motivo text,
 PRIMARY KEY(empresa_id,order_id)
);
CREATE TABLE private.gastronomia_99food_operacao_eventos (
 empresa_id uuid NOT NULL REFERENCES private.gastronomia_99food_conexoes(empresa_id),id text NOT NULL CHECK(length(id)=64),tipo text NOT NULL,order_id text,payload jsonb NOT NULL,
 recebido_em timestamptz NOT NULL DEFAULT now(),processado_em timestamptz,tentativas integer NOT NULL DEFAULT 0,tentar_apos timestamptz NOT NULL DEFAULT now(),erro text,
 PRIMARY KEY(empresa_id,id)
);
CREATE INDEX gastronomia_99food_operacao_eventos_fila ON private.gastronomia_99food_operacao_eventos(empresa_id,tentar_apos,recebido_em) WHERE processado_em IS NULL;
CREATE INDEX gastronomia_99food_operacao_eventos_pedido ON private.gastronomia_99food_operacao_eventos(empresa_id,order_id,recebido_em DESC);
CREATE TABLE private.gastronomia_99food_operacao_comandos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),empresa_id uuid NOT NULL,order_id text NOT NULL,chave uuid NOT NULL,
 acao text NOT NULL CHECK(acao IN ('confirmar','pronto','despachar','entregue','retirada','concluir','cancelar','responder_cancelamento','responder_reembolso','confirmar_dinheiro')),
 payload jsonb NOT NULL DEFAULT '{}',estado text NOT NULL DEFAULT 'pendente' CHECK(estado IN ('pendente','enviando','enviado','confirmado','incerto','falha')),
 criado_em timestamptz NOT NULL DEFAULT now(),criado_por uuid NOT NULL,atualizado_em timestamptz NOT NULL DEFAULT now(),erro text,request_id text,
 FOREIGN KEY(empresa_id,order_id) REFERENCES private.gastronomia_99food_operacao_pedidos(empresa_id,order_id),UNIQUE(empresa_id,chave)
);
CREATE UNIQUE INDEX gastronomia_99food_operacao_comando_ativo ON private.gastronomia_99food_operacao_comandos(empresa_id,order_id) WHERE estado IN ('pendente','enviando','enviado','incerto');
CREATE TABLE private.gastronomia_99food_creditos (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),empresa_id uuid NOT NULL,order_id text NOT NULL,valor_centavos bigint NOT NULL CHECK(valor_centavos>=0),ativo boolean NOT NULL DEFAULT true,
 FOREIGN KEY(empresa_id,order_id) REFERENCES private.gastronomia_99food_operacao_pedidos(empresa_id,order_id),UNIQUE(empresa_id,order_id)
);
ALTER TABLE private.gastronomia_99food_conexoes ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_99food_operacao_pedidos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_99food_operacao_eventos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_99food_operacao_comandos ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.gastronomia_99food_creditos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_99food_conexoes,private.gastronomia_99food_operacao_pedidos,private.gastronomia_99food_operacao_eventos,private.gastronomia_99food_operacao_comandos,private.gastronomia_99food_creditos FROM PUBLIC,anon,authenticated;

ALTER TABLE public.gastronomia_atendimentos DROP CONSTRAINT gastronomia_atendimentos_origem_check;
ALTER TABLE public.gastronomia_atendimentos ADD CONSTRAINT gastronomia_atendimentos_origem_check CHECK(origem IN ('manual','telefone','whatsapp','site','ifood','99food'));
ALTER TABLE public.gastronomia_atendimentos DROP CONSTRAINT gastronomia_autor_publico_check;
ALTER TABLE public.gastronomia_atendimentos ADD CONSTRAINT gastronomia_autor_publico_check CHECK(criado_por IS NOT NULL OR origem IN ('site','ifood','99food'));

-- O mesmo resolvedor de receitas/complementos/estoque, com funções exclusivas 99Food.
DO $copy$ DECLARE src text; BEGIN
 src:=pg_get_functiondef('private.gastronomia_ifood_payload(uuid,jsonb)'::regprocedure);
 EXECUTE replace(replace(src,'gastronomia_ifood_payload','gastronomia_99food_payload'),'iFood','99Food');
END $copy$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_payload(uuid,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.gastronomia_99food_vincular_normalizado(e uuid,n jsonb) RETURNS jsonb LANGUAGE plpgsql SET search_path='' AS $$
DECLARE item jsonb;addon jsonb;product uuid;items jsonb:='[]';addons jsonb;
BEGIN
 FOR item IN SELECT value FROM jsonb_array_elements(n->'itens') LOOP
  SELECT produto_id INTO product FROM private.gastronomia_99food_vinculos WHERE empresa_id=e AND tipo='produto' AND codigo_externo=item->>'codigo_externo' AND ativo;
  IF product IS NULL THEN RAISE EXCEPTION 'Vincule o produto 99Food % (%).',item->>'nome',item->>'codigo_externo'; END IF;
  item:=item||jsonb_build_object('produto_id',product);addons:='[]';
  FOR addon IN SELECT value FROM jsonb_array_elements(item->'adicionais') LOOP
   SELECT produto_id INTO product FROM private.gastronomia_99food_vinculos WHERE empresa_id=e AND tipo='adicional' AND codigo_externo=addon->>'codigo_externo' AND ativo;
   IF product IS NULL THEN RAISE EXCEPTION 'Vincule o complemento 99Food % (%).',addon->>'nome',addon->>'codigo_externo'; END IF;
   addons:=addons||jsonb_build_array(addon||jsonb_build_object('produto_id',product));
  END LOOP;
  items:=items||jsonb_build_array(item||jsonb_build_object('adicionais',addons));
 END LOOP;
 RETURN n||jsonb_build_object('itens',items);
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_vincular_normalizado(uuid,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION private.gastronomia_99food_impressao_pronta(e uuid) RETURNS boolean LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT EXISTS(SELECT 1 FROM public.gastronomia_configuracoes c JOIN public.impressoras p ON p.id::text=c.opcoes#>>'{cardapio,impressora_id}' AND p.empresa_id=c.empresa_id AND p.ativa JOIN public.impressao_agentes a ON a.empresa_id=p.empresa_id AND a.estacao_id=p.estacao_id AND a.status='ativo' WHERE c.empresa_id=e AND c.imprimir)
$$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_impressao_pronta(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.gastronomia_99food_imprimir(e uuid,pedido text,reimprimir boolean DEFAULT false,chave uuid DEFAULT NULL) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE p private.gastronomia_99food_operacao_pedidos;n jsonb;item jsonb;addon jsonb;itens jsonb:='[]';filhos jsonb;via text;emp text;key text;
BEGIN
 SELECT * INTO p FROM private.gastronomia_99food_operacao_pedidos WHERE empresa_id=e AND order_id=pedido FOR UPDATE;
 IF p.normalizado IS NULL OR p.status_99food<200 OR p.status_99food>=900 OR (p.impresso_em IS NOT NULL AND NOT reimprimir) THEN RETURN; END IF;
 IF NOT private.gastronomia_99food_impressao_pronta(e) THEN IF reimprimir THEN RAISE EXCEPTION 'Selecione a impressora da Gastronomia e conecte o Print Agent.';END IF;UPDATE private.gastronomia_99food_operacao_pedidos SET revisao_motivo='Impressora da Gastronomia ou Print Agent não configurados.' WHERE empresa_id=e AND order_id=pedido;RETURN;END IF;
 IF NOT coalesce((SELECT imprimir FROM public.gastronomia_configuracoes WHERE empresa_id=e),false) THEN RETURN; END IF;
 n:=p.normalizado;SELECT nome INTO emp FROM public.empresas WHERE id=e;
 FOR item IN SELECT value FROM jsonb_array_elements(n->'itens') LOOP
  filhos:='[]';FOR addon IN SELECT value FROM jsonb_array_elements(item->'adicionais') LOOP filhos:=filhos||jsonb_build_array(jsonb_build_object('nome',addon->>'nome','quantidade',addon->'quantidade'));END LOOP;
  itens:=itens||jsonb_build_array(jsonb_build_object('nome',item->>'nome','quantidade',item->'quantidade','preco_unitario',round((item->>'total')::numeric/100/(item->>'quantidade')::numeric,2),'subtotal',(item->>'total')::numeric/100,'observacao',item->>'observacao','filhos',filhos));
 END LOOP;
 itens:=itens||jsonb_build_array(jsonb_build_object('nome','99FOOD #'||coalesce(p.order_index::text,'')||' — ID '||pedido),jsonb_build_object('nome',concat_ws(' · ',n->>'cliente',n->>'telefone',n->>'endereco',n->>'complemento',n->>'referencia')),jsonb_build_object('nome','Observação: '||coalesce(n->>'observacao','')));
 -- Linhas de preço separadas, sem descontar o cupom duas vezes.
 itens:=itens||jsonb_build_array(jsonb_build_object('nome','Itens: R$ '||to_char((n#>>'{precos,itens}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Desconto dos itens: R$ '||to_char((n#>>'{precos,desconto_itens}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Entrega: R$ '||to_char((n#>>'{precos,entrega}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Taxa de serviço: R$ '||to_char((n#>>'{precos,servico}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Total cliente: R$ '||coalesce(to_char((n#>>'{precos,total_cliente}')::numeric/100,'FM999999990.00'),'não informado pela 99Food')),jsonb_build_object('nome','Total informado para a loja: R$ '||to_char((n#>>'{precos,total_loja}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Pago/repasse pela plataforma: R$ '||to_char((n->>'pago_online')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','A conferir presencialmente: R$ '||to_char((n->>'a_cobrar')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','PEDIDO NÃO FISCAL — recebimento presencial depende da confirmação do caixa'));
 FOR item IN SELECT jsonb_build_object('nome',v.rotulo||': R$ '||to_char((n#>>ARRAY['precos',v.campo])::numeric/100,'FM999999990.00')) FROM (VALUES ('desconto_entrega','Desconto de entrega'),('entrega_original','Entrega antes dos descontos'),('pedido_minimo','Taxa de pedido mínimo'),('complemento_minimo','Complemento de pedido mínimo'),('gorjeta','Gorjeta'),('cupom','Cupom (já incluído nos descontos)'),('subsidio_loja','Promoção custeada pela loja'),('reembolso','Reembolso'),('cancelamento_parcial','Cancelamento parcial'))v(campo,rotulo) WHERE coalesce((n#>>ARRAY['precos',v.campo])::numeric,0)>0 LOOP itens:=itens||jsonb_build_array(item);END LOOP;
 itens:=itens||jsonb_build_array(jsonb_build_object('nome','Canal de pagamento 99Food: '||coalesce(n->>'pay_channel','não informado')));
 FOREACH via IN ARRAY ARRAY['COZINHA','CONFERÊNCIA CAIXA'] LOOP
  key:='gastronomia:99food:'||pedido||':'||via||CASE WHEN reimprimir THEN ':'||chave::text ELSE '' END;
  PERFORM private.impressao_job_criar(e,'caixa','pedido_bar',key,(CASE WHEN reimprimir THEN 'REIMPRESSÃO · ' ELSE '' END)||'99FOOD '||via||' #'||p.order_index,
   jsonb_build_object('gastronomia_atendimento_id',p.atendimento_id,'gastronomia_impressora_propria',true,'versao',1,'tipo','pedido_bar','empresa',emp||' — 99FOOD #'||p.order_index,'setor',via,'data_hora',to_char(now() AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),'itens',itens),auth.uid());
 END LOOP;
 UPDATE private.gastronomia_99food_operacao_pedidos SET impresso_em=coalesce(impresso_em,now()) WHERE empresa_id=e AND order_id=pedido;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_imprimir(uuid,text,boolean,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.gastronomia_99food_importar(e uuid,pedido text) RETURNS uuid LANGUAGE plpgsql SET search_path='' AS $$
DECLARE p private.gastronomia_99food_operacao_pedidos;c private.gastronomia_99food_conexoes;n jsonb;dados jsonb;resolvido jsonb;x jsonb;i jsonb;ord int:=0;atendimento uuid;iid uuid;num bigint;subtotal numeric:=0;delta numeric;dest text;
BEGIN
 SELECT * INTO c FROM private.gastronomia_99food_conexoes WHERE empresa_id=e;
 SELECT * INTO p FROM private.gastronomia_99food_operacao_pedidos WHERE empresa_id=e AND order_id=pedido FOR UPDATE;
 IF p.atendimento_id IS NOT NULL THEN RETURN p.atendimento_id; END IF;
 IF c.ambiente<>'producao' OR NOT c.habilitada OR p.status_99food NOT IN (200,400,500,600) THEN RETURN NULL; END IF;
 IF jsonb_array_length(coalesce(p.normalizado->'avisos','[]'))>0 THEN RAISE EXCEPTION 'Confira produtos, descontos ou cancelamentos parciais antes de importar.'; END IF;
 n:=private.gastronomia_99food_vincular_normalizado(e,p.normalizado);
 dados:=private.gastronomia_99food_payload(e,n);resolvido:=private.gastronomia_resolver(dados,e);
 UPDATE public.gastronomia_configuracoes SET ultimo_numero=ultimo_numero+1 WHERE empresa_id=e RETURNING ultimo_numero INTO num;
 IF num IS NULL THEN RAISE EXCEPTION 'Configure a Gastronomia desta empresa.'; END IF;
 INSERT INTO public.gastronomia_atendimentos(empresa_id,numero,tipo,origem,cliente_nome,telefone,endereco,referencia,servico_regra,servico_percentual)
 VALUES(e,num,n->>'tipo','99food',left(coalesce(nullif(btrim(n->>'cliente'),''),'Cliente 99Food'),160),left(coalesce(nullif(btrim(n->>'telefone'),''),'Contato pela 99Food'),100),left(coalesce(nullif(btrim(concat_ws(' · ',n->>'endereco',n->>'complemento')),''),'Endereço disponível na 99Food'),500),left(n->>'referencia',300),'percentual_v1',0) RETURNING public.gastronomia_atendimentos.id INTO atendimento;
 FOR x IN SELECT value FROM jsonb_array_elements(resolvido) LOOP
  i:=dados->ord;ord:=ord+1;
  x:=x||jsonb_build_object('lote',pedido,'autor_publico','99Food','99food_pedido_id',pedido,'preco_venda',round((i->>'ifood_total')::numeric/(i->>'quantidade')::numeric,2));
  INSERT INTO public.gastronomia_itens(empresa_id,atendimento_id,produto_id,quantidade,preco_unitario,snapshot) VALUES(e,atendimento,(x->>'produto_id')::uuid,(x->>'quantidade')::numeric,(x->>'preco_venda')::numeric,x) RETURNING public.gastronomia_itens.id INTO iid;
  subtotal:=subtotal+round((x->>'quantidade')::numeric*(x->>'preco_venda')::numeric,2);
  FOR dest IN SELECT DISTINCT z FROM(SELECT x->>'destino_operacional' z UNION SELECT v->>'destino_operacional' FROM jsonb_array_elements(x->'escolhas_resolvidas') v)t WHERE z IN ('bar','cozinha') LOOP INSERT INTO public.gastronomia_preparo(empresa_id,item_id,setor) VALUES(e,iid,dest);END LOOP;
 END LOOP;
 delta:=(n->>'total')::numeric/100-subtotal;
 UPDATE public.gastronomia_atendimentos SET desconto=greatest(-delta,0),acrescimo=greatest(delta,0) WHERE empresa_id=e AND public.gastronomia_atendimentos.id=atendimento;
 UPDATE private.gastronomia_99food_operacao_pedidos SET atendimento_id=atendimento,importado_em=now(),normalizado=n,revisao_motivo=NULL WHERE empresa_id=e AND order_id=pedido;
 INSERT INTO private.gastronomia_99food_creditos(empresa_id,order_id,valor_centavos) VALUES(e,pedido,(n->>'pago_online')::bigint) ON CONFLICT(empresa_id,order_id) DO NOTHING;
 INSERT INTO public.gastronomia_eventos(empresa_id,atendimento_id,tipo,detalhes) VALUES(e,atendimento,'99food_importar',jsonb_build_object('pedido_id',pedido));
 PERFORM private.gastronomia_99food_imprimir(e,pedido);
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
 RETURN atendimento;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_importar(uuid,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION private.gastronomia_pago(p_id uuid,p_e uuid) RETURNS numeric LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT coalesce((SELECT sum(valor-CASE WHEN a.origem='ifood' THEN coalesce((pg.metadados->>'ifood_taxa_plataforma')::numeric,0) WHEN a.origem='99food' THEN coalesce((pg.metadados->>'99food_taxa_plataforma')::numeric,0) ELSE 0 END) FROM public.gastronomia_pagamentos pg JOIN public.gastronomia_atendimentos a ON a.id=pg.atendimento_id AND a.empresa_id=pg.empresa_id WHERE pg.atendimento_id=p_id AND pg.empresa_id=p_e AND NOT pg.estornado),0)
 +coalesce((SELECT sum(coalesce(ip.valor_empresa_centavos,ip.valor_centavos))::numeric/100 FROM private.gastronomia_ifood_pagamentos ip JOIN private.gastronomia_ifood_pedidos p ON p.empresa_id=ip.empresa_id AND p.pedido_id=ip.pedido_id WHERE p.empresa_id=p_e AND p.atendimento_id=p_id AND ip.tipo='ONLINE' AND ip.ativo AND p.estado_ifood<>'cancelado'),0)
 +coalesce((SELECT sum(c.valor_centavos)::numeric/100 FROM private.gastronomia_99food_creditos c JOIN private.gastronomia_99food_operacao_pedidos p ON p.empresa_id=c.empresa_id AND p.order_id=c.order_id WHERE p.empresa_id=p_e AND p.atendimento_id=p_id AND c.ativo AND p.status_99food<900),0)
$$;
DO $venda$ DECLARE src text; old text:='WHEN a.origem=''ifood'' THEN coalesce((p.metadados->>''ifood_taxa_plataforma'')::numeric,0) ELSE 0 END'; BEGIN
 src:=pg_get_functiondef('private.gastronomia_venda(uuid,uuid)'::regprocedure);
 IF strpos(src,old)=0 OR strpos(src,'RETURN v;')=0 THEN RAISE EXCEPTION 'Venda Gastronomia divergente.';END IF;
 src:=replace(src,old,'WHEN a.origem=''ifood'' THEN coalesce((p.metadados->>''ifood_taxa_plataforma'')::numeric,0) WHEN a.origem=''99food'' THEN coalesce((p.metadados->>''99food_taxa_plataforma'')::numeric,0) ELSE 0 END');
 src:=replace(src,'RETURN v;',$add$
 IF a.origem='99food' THEN
  INSERT INTO public.vendas_pagamentos(id,empresa_id,venda_id,forma_pagamento,valor,ordem,criado_por)
   SELECT c.id,p_e,v,'Outros',c.valor_centavos::numeric/100,1000,NULL FROM private.gastronomia_99food_creditos c JOIN private.gastronomia_99food_operacao_pedidos p ON p.empresa_id=c.empresa_id AND p.order_id=c.order_id WHERE p.empresa_id=p_e AND p.atendimento_id=p_id AND c.ativo AND c.valor_centavos>0 AND p.status_99food<900 ON CONFLICT(id) DO NOTHING;
 END IF;
 RETURN v;
$add$);EXECUTE src;
END $venda$;

CREATE FUNCTION private.gastronomia_99food_consolidar(e uuid,pedido text) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE p private.gastronomia_99food_operacao_pedidos; a public.gastronomia_atendimentos;v uuid;rec record;
BEGIN
 SELECT * INTO p FROM private.gastronomia_99food_operacao_pedidos WHERE empresa_id=e AND order_id=pedido FOR UPDATE;
 IF p.atendimento_id IS NULL THEN RETURN; END IF;
 SELECT * INTO a FROM public.gastronomia_atendimentos WHERE empresa_id=e AND id=p.atendimento_id FOR UPDATE;
 IF p.status_99food>=900 THEN
  IF a.venda_id IS NOT NULL OR EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE empresa_id=e AND atendimento_id=a.id AND NOT estornado) THEN UPDATE private.gastronomia_99food_operacao_pedidos SET revisao_motivo='Cancelamento após recebimento/venda: concilie estorno e documento fiscal.' WHERE empresa_id=e AND order_id=pedido;RETURN;END IF;
  IF NOT EXISTS(SELECT 1 FROM public.gastronomia_preparo z JOIN public.gastronomia_itens i ON i.id=z.item_id AND i.empresa_id=e WHERE i.atendimento_id=a.id AND z.estado<>'pendente') THEN
   FOR rec IN SELECT (b->>'produto_baixa_id')::uuid produto,sum((b->>'quantidade')::numeric) quantidade FROM public.gastronomia_itens i CROSS JOIN LATERAL jsonb_array_elements(i.snapshot->'baixas') b WHERE i.empresa_id=e AND i.atendimento_id=a.id AND NOT i.cancelado GROUP BY 1 ORDER BY 1 LOOP UPDATE public.produtos SET quantidade_estoque=quantidade_estoque+rec.quantidade WHERE empresa_id=e AND id=rec.produto;END LOOP;
  END IF;
  UPDATE public.gastronomia_itens SET cancelado=true WHERE empresa_id=e AND atendimento_id=a.id;
  UPDATE private.gastronomia_99food_creditos SET ativo=false WHERE empresa_id=e AND order_id=pedido;
  UPDATE public.gastronomia_atendimentos SET estado='cancelado',finalizado_em=now(),versao=versao+1 WHERE empresa_id=e AND id=a.id;
 ELSIF p.status_99food=600 THEN
  IF p.revisao_motivo LIKE 'Pedido alterado%' OR jsonb_array_length(coalesce(p.normalizado->'avisos','[]'))>0 OR coalesce((p.normalizado->>'aguardando_valor_presencial')::boolean,false) OR a.venda_id IS NOT NULL THEN RETURN;END IF;
  IF private.gastronomia_pago(a.id,e)<>private.gastronomia_total(a.id,e) THEN UPDATE private.gastronomia_99food_operacao_pedidos SET revisao_motivo='Concluído na 99Food; registre o recebimento presencial ou confira os valores.' WHERE empresa_id=e AND order_id=pedido;RETURN;END IF;
  v:=private.gastronomia_venda(a.id,e);IF v IS NULL THEN RETURN;END IF;
  UPDATE public.gastronomia_atendimentos SET estado='finalizado',finalizado_em=coalesce(finalizado_em,now()),versao=versao+1 WHERE empresa_id=e AND id=a.id;
 ELSE
  UPDATE public.gastronomia_atendimentos SET expedicao=CASE WHEN p.status_99food IN (400,500) THEN 'saiu_entrega' WHEN p.pronto THEN CASE WHEN tipo='entrega' THEN 'aguardando_despacho' ELSE 'aguardando_retirada' END ELSE expedicao END WHERE empresa_id=e AND id=a.id;
 END IF;
 IF p.pronto OR p.status_99food IN (400,500,600) THEN UPDATE public.gastronomia_preparo z SET estado='pronto',alterado_em=now() FROM public.gastronomia_itens i WHERE z.item_id=i.id AND z.empresa_id=e AND i.empresa_id=e AND i.atendimento_id=a.id AND NOT i.cancelado;END IF;
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_consolidar(uuid,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.gastronomia_99food_operacao_worker(p_empresa uuid,p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE c private.gastronomia_99food_conexoes;d jsonb:=coalesce(p_dados,'{}');x jsonb;o private.gastronomia_99food_operacao_pedidos;lease uuid;sid uuid;n integer;
BEGIN
 IF p_acao='listar' THEN RETURN(SELECT coalesce(jsonb_agg(t.empresa_id),'[]') FROM (SELECT empresa_id FROM private.gastronomia_99food_conexoes WHERE habilitada ORDER BY ultima_execucao NULLS FIRST,empresa_id LIMIT 1)t);END IF;
 IF p_acao='resolver' THEN RETURN(SELECT jsonb_build_object('empresa_id',conn.empresa_id,'segredo',s.decrypted_secret) FROM private.gastronomia_99food_conexoes conn JOIN vault.decrypted_secrets s ON s.id=conn.segredo_id WHERE app_id=d->>'app_id' AND app_shop_id=d->>'app_shop_id' AND habilitada);END IF;
 IF p_acao='configurar' THEN
  IF coalesce(d->>'app_id','') !~ '^[1-9][0-9]{0,18}$' OR coalesce(d->>'shop_id','') !~ '^[1-9][0-9]{0,18}$' OR length(coalesce(d->>'app_shop_id','')) NOT BETWEEN 1 AND 100 OR length(coalesce(d->>'segredo','')) NOT BETWEEN 16 AND 256 THEN RAISE EXCEPTION 'Confira as credenciais e os identificadores.';END IF;
  IF d->>'app_id'='5764607791191296200' THEN RAISE EXCEPTION 'O aplicativo atual de homologação permanece na conexão de teste. Informe o aplicativo de produção.';END IF;
  SELECT * INTO c FROM private.gastronomia_99food_conexoes WHERE empresa_id=p_empresa FOR UPDATE;
  IF c.habilitada THEN RAISE EXCEPTION 'Desconecte antes de alterar as credenciais.';END IF;
  SELECT vault.create_secret(d->>'segredo') INTO sid;
  INSERT INTO private.gastronomia_99food_conexoes(empresa_id,app_id,app_shop_id,shop_id,segredo_id,atualizado_por) VALUES(p_empresa,d->>'app_id',d->>'app_shop_id',d->>'shop_id',sid,(d->>'usuario')::uuid)
   ON CONFLICT(empresa_id) DO UPDATE SET app_id=excluded.app_id,app_shop_id=excluded.app_shop_id,shop_id=excluded.shop_id,segredo_id=excluded.segredo_id,auth_token=NULL,token_expira_em=NULL,token_erro=NULL,atualizado_em=now(),atualizado_por=excluded.atualizado_por;
  IF c.segredo_id IS NOT NULL THEN DELETE FROM vault.secrets WHERE id=c.segredo_id;END IF;
  RETURN 'true';
 END IF;
 SELECT * INTO c FROM private.gastronomia_99food_conexoes WHERE empresa_id=p_empresa;
 IF NOT FOUND THEN RETURN 'null';END IF;
 IF p_acao='config' THEN RETURN to_jsonb(c)-'auth_token'-'segredo_id'||jsonb_build_object('segredo',(SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id=c.segredo_id));
 ELSIF p_acao='conectar' THEN UPDATE private.gastronomia_99food_conexoes SET habilitada=true,nome_loja=left(d->>'nome_loja',120),ultimo_erro=NULL WHERE empresa_id=p_empresa;RETURN 'true';
 ELSIF p_acao='reservar' THEN lease:=gen_random_uuid();UPDATE private.gastronomia_99food_conexoes SET worker_reserva=lease,worker_ate=now()+interval '90 seconds',worker_proxima=now()+interval '10 seconds' WHERE empresa_id=p_empresa AND habilitada AND (worker_ate IS NULL OR worker_ate<now()) AND (worker_proxima IS NULL OR worker_proxima<=now());IF NOT FOUND THEN RETURN 'null';END IF;RETURN to_jsonb(lease);
 ELSIF p_acao='liberar' THEN UPDATE private.gastronomia_99food_conexoes SET worker_reserva=NULL,worker_ate=NULL,ultima_execucao=now(),ultimo_erro=nullif(left(d->>'erro',500),'') WHERE empresa_id=p_empresa AND worker_reserva=(d->>'reserva')::uuid;RETURN 'true';
 ELSIF p_acao='token' THEN RETURN jsonb_build_object('token',c.auth_token,'expira_em',c.token_expira_em);
 ELSIF p_acao='token_reservar' THEN UPDATE private.gastronomia_99food_conexoes SET token_consultar_apos=now()+interval '30 seconds' WHERE empresa_id=p_empresa AND token_consultar_apos<=now();RETURN to_jsonb(FOUND);
 ELSIF p_acao='token_renovar' THEN UPDATE private.gastronomia_99food_conexoes SET token_renovar_apos=now()+interval '2 minutes' WHERE empresa_id=p_empresa AND token_renovar_apos<=now();RETURN to_jsonb(FOUND);
 ELSIF p_acao='token_salvar' THEN IF length(coalesce(d->>'token','')) NOT BETWEEN 1 AND 4096 OR (d->>'expira_em')::timestamptz<=now() THEN RAISE EXCEPTION 'Token inválido.';END IF;UPDATE private.gastronomia_99food_conexoes SET auth_token=d->>'token',token_expira_em=(d->>'expira_em')::timestamptz,ultima_autenticacao=now(),token_erro=NULL WHERE empresa_id=p_empresa;RETURN 'true';
 ELSIF p_acao='token_erro' THEN UPDATE private.gastronomia_99food_conexoes SET token_erro=left(d->>'erro',500),auth_token=NULL,token_expira_em=NULL WHERE empresa_id=p_empresa;RETURN 'true';
 ELSIF p_acao='evento' THEN
  x:=d->'payload';IF x->>'app_id' IS DISTINCT FROM c.app_id OR x->>'app_shop_id' IS DISTINCT FROM c.app_shop_id OR coalesce(x->>'type','')='' OR (x#>>'{data,order_info,shop,shop_id}' IS NOT NULL AND x#>>'{data,order_info,shop,shop_id}'<>c.shop_id) THEN RAISE EXCEPTION 'Vínculo inválido.';END IF;
  IF coalesce(d->>'order_id','')<>'' AND (d->>'order_id') !~ '^[1-9][0-9]{0,18}$' THEN RAISE EXCEPTION 'Pedido inválido.';END IF;
  INSERT INTO private.gastronomia_99food_operacao_eventos(empresa_id,id,tipo,order_id,payload,processado_em) VALUES(p_empresa,d->>'id',x->>'type',nullif(d->>'order_id',''),x,CASE WHEN coalesce(d->>'order_id','')='' THEN now() END) ON CONFLICT DO NOTHING;
  IF coalesce(d->>'order_id','')<>'' THEN INSERT INTO private.gastronomia_99food_operacao_pedidos(empresa_id,order_id,detalhe) VALUES(p_empresa,d->>'order_id',x#>'{data,order_info}') ON CONFLICT DO NOTHING;IF x->>'type'='orderReady' THEN UPDATE private.gastronomia_99food_operacao_pedidos SET pronto=true WHERE empresa_id=p_empresa AND order_id=d->>'order_id';END IF;END IF;
  RETURN 'true';
 ELSIF p_acao='fila' THEN RETURN jsonb_build_object('eventos',(SELECT coalesce(jsonb_agg(to_jsonb(t)),'[]') FROM(SELECT id,order_id,tipo FROM private.gastronomia_99food_operacao_eventos WHERE empresa_id=p_empresa AND processado_em IS NULL AND tentar_apos<=now() AND tentativas<10 ORDER BY recebido_em LIMIT 3)t),'comando',(SELECT to_jsonb(t) FROM(SELECT id,order_id,acao,payload,estado FROM private.gastronomia_99food_operacao_comandos WHERE empresa_id=p_empresa AND estado IN ('pendente','enviando','enviado','incerto') ORDER BY CASE WHEN estado='pendente' THEN 0 ELSE 1 END,atualizado_em LIMIT 1)t),'reconciliar',(SELECT coalesce(jsonb_agg(order_id),'[]') FROM(SELECT order_id FROM private.gastronomia_99food_operacao_pedidos WHERE empresa_id=p_empresa AND (ultima_consulta IS NULL OR ultima_consulta<now()-interval '2 minutes') AND recebido_em>now()-interval '3 days' AND (status_99food IS NULL OR status_99food<600 OR (status_99food=600 AND atendimento_id IS NULL)) ORDER BY ultima_consulta NULLS FIRST LIMIT 1)t));
 ELSIF p_acao='evento_resultado' THEN UPDATE private.gastronomia_99food_operacao_eventos SET tentativas=tentativas+1,erro=nullif(left(d->>'erro',500),''),processado_em=CASE WHEN coalesce(d->>'erro','')='' THEN now() END,tentar_apos=now()+least(interval '15 minutes',interval '30 seconds'*power(2,least(tentativas,5))) WHERE empresa_id=p_empresa AND id=d->>'id';RETURN 'true';
 ELSIF p_acao='pedido' THEN SELECT * INTO o FROM private.gastronomia_99food_operacao_pedidos WHERE empresa_id=p_empresa AND order_id=d->>'order_id';RETURN to_jsonb(o)||jsonb_build_object('recebimento_confirmado',EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE empresa_id=p_empresa AND atendimento_id=o.atendimento_id AND NOT estornado),'solicitacoes',(SELECT coalesce(jsonb_agg((payload->'data')||jsonb_build_object('tipo',tipo)),'[]') FROM private.gastronomia_99food_operacao_eventos WHERE empresa_id=p_empresa AND order_id=o.order_id AND tipo IN ('orderCancelApply','orderRefundApply')));
 ELSIF p_acao='detalhe' THEN
  x:=d->'detalhe';n:=(x->>'status')::int;IF x->>'order_id' IS DISTINCT FROM d->>'order_id' OR coalesce(x#>>'{shop,shop_id}',x->>'shop_id') IS DISTINCT FROM c.shop_id OR d#>>'{normalizado,order_id}' IS DISTINCT FROM d->>'order_id' THEN RAISE EXCEPTION 'Detalhes divergentes.';END IF;
  SELECT * INTO o FROM private.gastronomia_99food_operacao_pedidos WHERE empresa_id=p_empresa AND order_id=d->>'order_id' FOR UPDATE;
  IF (o.status_99food=600 OR o.status_99food>=900) AND n<600 THEN RETURN to_jsonb(o);END IF;
  IF o.atendimento_id IS NOT NULL AND ((o.detalhe->'order_items' IS DISTINCT FROM x->'order_items') OR ((o.detalhe->'price')-'shop_paid_money' IS DISTINCT FROM (x->'price')-'shop_paid_money') OR o.detalhe->>'pay_type' IS DISTINCT FROM x->>'pay_type') THEN UPDATE private.gastronomia_99food_operacao_pedidos SET revisao_motivo='Pedido alterado após importação: concilie itens e valores antes de fechar a venda.' WHERE empresa_id=p_empresa AND order_id=d->>'order_id';END IF;
  UPDATE private.gastronomia_99food_operacao_pedidos SET detalhe=x,normalizado=d->'normalizado',status_99food=n,order_index=(x->>'order_index')::int,estado=CASE WHEN n>=600 THEN 'encerrado' WHEN n>=200 THEN 'aceito' ELSE 'recebido' END,ultima_consulta=now(),atualizado_em=now(),ultimo_erro=NULL WHERE empresa_id=p_empresa AND order_id=d->>'order_id';
  BEGIN PERFORM private.gastronomia_99food_importar(p_empresa,d->>'order_id');EXCEPTION WHEN OTHERS THEN UPDATE private.gastronomia_99food_operacao_pedidos SET revisao_motivo=left(SQLERRM,500) WHERE empresa_id=p_empresa AND order_id=d->>'order_id';END;
  IF o.atendimento_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE empresa_id=p_empresa AND atendimento_id=o.atendimento_id AND NOT estornado) THEN UPDATE private.gastronomia_99food_creditos SET valor_centavos=(d#>>'{normalizado,pago_online}')::bigint WHERE empresa_id=p_empresa AND order_id=d->>'order_id';END IF;
  PERFORM private.gastronomia_99food_imprimir(p_empresa,d->>'order_id');PERFORM private.gastronomia_99food_consolidar(p_empresa,d->>'order_id');
  RETURN(SELECT to_jsonb(t) FROM private.gastronomia_99food_operacao_pedidos t WHERE empresa_id=p_empresa AND order_id=d->>'order_id');
 ELSIF p_acao='pedido_erro' THEN UPDATE private.gastronomia_99food_operacao_pedidos SET ultimo_erro=left(d->>'erro',500),ultima_consulta=now() WHERE empresa_id=p_empresa AND order_id=d->>'order_id';RETURN 'true';
 ELSIF p_acao='comando_resultado' THEN UPDATE private.gastronomia_99food_operacao_comandos SET estado=d->>'estado',erro=nullif(left(d->>'erro',500),''),request_id=coalesce(nullif(d->>'request_id',''),request_id),atualizado_em=now() WHERE empresa_id=p_empresa AND id=(d->>'id')::uuid;RETURN 'true';
 END IF;
 RAISE EXCEPTION 'Ação interna inválida.';
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_operacao_worker(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.gastronomia_99food_operacao_worker(p_empresa uuid,p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.gastronomia_99food_operacao_worker(p_empresa,p_acao,p_dados)$$;
REVOKE ALL ON FUNCTION public.gastronomia_99food_operacao_worker(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION private.gastronomia_99food_operacao_worker(uuid,text,jsonb),public.gastronomia_99food_operacao_worker(uuid,text,jsonb) TO service_role;
CREATE FUNCTION private.gastronomia_99food_operacao_admin(p_empresa uuid,p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE e uuid:=private.empresa_id_ativa();d jsonb:=coalesce(p_dados,'{}');o private.gastronomia_99food_operacao_pedidos;c private.gastronomia_99food_conexoes;cmd private.gastronomia_99food_operacao_comandos;cx uuid;fee numeric;amount numeric;
BEGIN
 IF auth.uid() IS NULL OR e IS DISTINCT FROM p_empresa THEN RAISE EXCEPTION 'Empresa da sessão mudou.' USING ERRCODE='42501';END IF;
 IF p_acao IN ('estado','desconectar') THEN PERFORM private.gastronomia_exigir('gastronomia_configurar');ELSE PERFORM private.gastronomia_exigir('gastronomia_pedidos');END IF;
 SELECT * INTO c FROM private.gastronomia_99food_conexoes WHERE empresa_id=e;
 IF p_acao='estado' THEN RETURN jsonb_build_object('empresa_id',e,'configurada',c.empresa_id IS NOT NULL,'habilitada',coalesce(c.habilitada,false),'app_id',c.app_id,'app_shop_id',c.app_shop_id,'shop_id',c.shop_id,'ambiente',c.ambiente,'nome_loja',c.nome_loja,'token_valido',c.auth_token IS NOT NULL AND c.token_expira_em>now(),'erro',coalesce(c.token_erro,c.ultimo_erro),'usuario',auth.uid());
 ELSIF p_acao='desconectar' THEN UPDATE private.gastronomia_99food_conexoes SET habilitada=false,atualizado_por=auth.uid(),atualizado_em=now() WHERE empresa_id=e;RETURN 'true';
 ELSIF p_acao='pedidos' THEN RETURN(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY recebido_em DESC),'[]') FROM(
  SELECT p.order_id,p.order_index,p.recebido_em,p.estado,p.status_99food,p.pronto,p.detalhe,p.normalizado,p.atendimento_id,p.ultimo_erro,p.revisao_motivo,c.ambiente,
   (SELECT coalesce(jsonb_agg(to_jsonb(j)),'[]') FROM(SELECT status,erro_mensagem erro,impresso_em FROM public.impressao_jobs WHERE empresa_id=e AND chave_unica LIKE 'gastronomia:99food:'||p.order_id||':%' ORDER BY criado_em DESC LIMIT 10)j) impressao,
   (SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY criado_em DESC),'[]') FROM(SELECT id,acao,estado,criado_em,erro,request_id FROM private.gastronomia_99food_operacao_comandos WHERE empresa_id=e AND order_id=p.order_id ORDER BY criado_em DESC LIMIT 20)q) comandos,
   (SELECT coalesce(jsonb_agg(jsonb_build_object('tipo',ev.tipo,'recebido_em',ev.recebido_em,'erro',ev.erro,'dados',CASE WHEN tipo IN ('orderCancelApply','orderRefundApply') THEN ev.payload->'data' END) ORDER BY recebido_em DESC),'[]') FROM(SELECT * FROM private.gastronomia_99food_operacao_eventos WHERE empresa_id=e AND order_id=p.order_id ORDER BY recebido_em DESC LIMIT 20)ev) eventos,
   EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE empresa_id=e AND atendimento_id=p.atendimento_id AND NOT estornado) recebimento_confirmado
  FROM private.gastronomia_99food_operacao_pedidos p WHERE empresa_id=e AND (d->>'data' IS NULL OR (coalesce(to_timestamp((p.detalhe->>'create_time')::double precision),p.recebido_em) AT TIME ZONE 'America/Sao_Paulo')::date=(d->>'data')::date) ORDER BY recebido_em DESC LIMIT 500)t);
 END IF;
 SELECT * INTO o FROM private.gastronomia_99food_operacao_pedidos WHERE empresa_id=e AND order_id=d->>'order_id' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Pedido desta empresa não encontrado.';END IF;
 IF p_acao='reimprimir' THEN IF (d->>'chave') IS NULL THEN RAISE EXCEPTION 'Chave obrigatória.';END IF;PERFORM private.gastronomia_99food_imprimir(e,o.order_id,true,(d->>'chave')::uuid);RETURN 'true';END IF;
 IF p_acao='receber' THEN
  PERFORM private.gastronomia_exigir('gastronomia_caixa');
  IF o.atendimento_id IS NULL OR c.ambiente<>'producao' OR o.status_99food>=900 OR d->>'confirmado' IS DISTINCT FROM 'true' OR coalesce((o.normalizado->>'aguardando_valor_presencial')::boolean,true) THEN RAISE EXCEPTION 'Recebimento indisponível.';END IF;
  IF EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE id=(d->>'chave')::uuid AND empresa_id=e AND atendimento_id=o.atendimento_id) THEN RETURN 'true';END IF;
  IF EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE empresa_id=e AND atendimento_id=o.atendimento_id AND NOT estornado) THEN RAISE EXCEPTION 'Recebimento já registrado.';END IF;
  amount:=(o.normalizado->>'a_cobrar')::numeric/100;fee:=(o.normalizado->>'taxa_presencial_plataforma')::numeric/100;
  IF amount<=0 OR (d->>'valor')::numeric IS DISTINCT FROM amount OR d->>'forma' IS NULL OR d->>'forma' NOT IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito') THEN RAISE EXCEPTION 'Confira valor e forma do recebimento.';END IF;
  IF fee<0 OR fee>amount THEN RAISE EXCEPTION 'Taxas presenciais inválidas.';END IF;
  cx:=private.caixa_exigir_aberto('GASTRONOMIA');
  INSERT INTO public.gastronomia_pagamentos(id,empresa_id,atendimento_id,caixa_id,forma,valor,criado_por,metadados) VALUES((d->>'chave')::uuid,e,o.atendimento_id,cx,d->>'forma',amount,auth.uid(),jsonb_build_object('99food_pedido_id',o.order_id,'99food_taxa_plataforma',fee,'confirmado_pelo_operador',true));
  IF o.detalhe->>'delivery_type'='1' AND o.detalhe->>'pay_type'='2' THEN INSERT INTO private.gastronomia_99food_operacao_comandos(empresa_id,order_id,chave,acao,criado_por) VALUES(e,o.order_id,(d->>'chave')::uuid,'confirmar_dinheiro',auth.uid());END IF;
  PERFORM private.gastronomia_99food_consolidar(e,o.order_id);RETURN 'true';
 END IF;
 IF p_acao NOT IN ('confirmar','pronto','despachar','entregue','retirada','concluir','cancelar','responder_cancelamento','responder_reembolso') OR p_acao IS NULL THEN RAISE EXCEPTION 'Ação inválida.';END IF;
 IF NOT c.habilitada THEN RAISE EXCEPTION 'Conecte a loja primeiro.';END IF;
 IF p_acao IN ('cancelar','responder_cancelamento','responder_reembolso') THEN PERFORM private.gastronomia_exigir('gastronomia_cancelar');END IF;
 SELECT * INTO cmd FROM private.gastronomia_99food_operacao_comandos WHERE empresa_id=e AND chave=(d->>'chave')::uuid;
 IF FOUND THEN IF cmd.order_id<>o.order_id OR cmd.acao<>p_acao OR cmd.criado_por<>auth.uid() OR cmd.payload<>coalesce(d->'payload','{}') THEN RAISE EXCEPTION 'Chave reutilizada.';END IF;RETURN jsonb_build_object('id',cmd.id,'estado',cmd.estado);END IF;
 IF o.status_99food>=600 AND p_acao<>'responder_reembolso' THEN RAISE EXCEPTION 'Pedido encerrado.';END IF;
 IF length(coalesce(d->'payload','{}')::text)>8000 THEN RAISE EXCEPTION 'Dados excessivos.';END IF;
 IF p_acao IN ('responder_cancelamento','responder_reembolso') AND EXISTS(SELECT 1 FROM private.gastronomia_99food_operacao_comandos WHERE empresa_id=e AND order_id=o.order_id AND acao=p_acao AND payload->>'apply_id'=d#>>'{payload,apply_id}' AND estado IN ('confirmado','enviado','incerto')) THEN RAISE EXCEPTION 'Solicitação já respondida ou aguardando retorno.';END IF;
 INSERT INTO private.gastronomia_99food_operacao_comandos(empresa_id,order_id,chave,acao,payload,criado_por) VALUES(e,o.order_id,(d->>'chave')::uuid,p_acao,coalesce(d->'payload','{}'),auth.uid()) RETURNING * INTO cmd;
 RETURN jsonb_build_object('id',cmd.id,'estado',cmd.estado);
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_operacao_admin(uuid,text,jsonb) FROM PUBLIC,anon;
CREATE FUNCTION public.gastronomia_99food_operacao_admin(p_empresa uuid,p_acao text,p_dados jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$SELECT private.gastronomia_99food_operacao_admin(p_empresa,p_acao,p_dados)$$;
REVOKE ALL ON FUNCTION public.gastronomia_99food_operacao_admin(uuid,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_99food_operacao_admin(uuid,text,jsonb),private.gastronomia_99food_operacao_admin(uuid,text,jsonb) TO authenticated;

-- Bloqueia alterações locais que precisem de confirmação do marketplace.
CREATE FUNCTION private.gastronomia_99food_proteger() RETURNS trigger LANGUAGE plpgsql SET search_path='' AS $$
BEGIN
 IF auth.uid() IS NOT NULL AND (NEW.cliente_nome IS DISTINCT FROM OLD.cliente_nome OR NEW.tipo IS DISTINCT FROM OLD.tipo OR NEW.desconto IS DISTINCT FROM OLD.desconto OR NEW.acrescimo IS DISTINCT FROM OLD.acrescimo OR NEW.taxa_entrega IS DISTINCT FROM OLD.taxa_entrega OR NEW.expedicao IS DISTINCT FROM OLD.expedicao OR NEW.estado='cancelado') THEN RAISE EXCEPTION 'Use as ações da 99Food na aba Pedidos.';END IF;RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_proteger() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER gastronomia_99food_proteger BEFORE UPDATE ON public.gastronomia_atendimentos FOR EACH ROW WHEN(OLD.origem='99food') EXECUTE FUNCTION private.gastronomia_99food_proteger();
DO $rpc$ DECLARE src text;old text:='IF a.origem=''ifood'' AND p_acao IN (';BEGIN
 src:=pg_get_functiondef('public.gastronomia_rpc(text,jsonb,uuid)'::regprocedure);IF strpos(src,old)=0 THEN RAISE EXCEPTION 'RPC Gastronomia divergente.';END IF;EXECUTE replace(src,old,'IF a.origem IN (''ifood'',''99food'') AND p_acao IN (');
END $rpc$;
NOTIFY pgrst,'reload schema';
-- Reimpressão do fluxo genérico preserva a origem e a chave do pedido 99Food.
DO $print$ DECLARE src text; BEGIN
 src:=pg_get_functiondef('private.gastronomia_duas_vias(uuid,uuid,uuid,boolean)'::regprocedure);
 IF strpos(src,'IF a.origem=''ifood'' THEN')=0 THEN RAISE EXCEPTION 'Roteamento de impressão divergente.';END IF;
 src:=replace(src,'IF a.origem=''ifood'' THEN',$branch$IF a.origem='99food' THEN
  PERFORM private.gastronomia_99food_imprimir(p_e,(SELECT order_id FROM private.gastronomia_99food_operacao_pedidos WHERE empresa_id=p_e AND atendimento_id=p_id),p_reimpressao,p_lote);RETURN;
 END IF;
 IF a.origem='ifood' THEN$branch$);EXECUTE src;
END $print$;
-- Todo atendimento 99Food usa o próprio painel na grade, evitando duplicar o card local.
-- O filtro é feito no cliente; dados e relatórios do atendimento continuam disponíveis.
CREATE FUNCTION private.gastronomia_99food_sandbox_imprimir(e uuid,pedido text,p_normalizado jsonb,chave uuid) RETURNS void LANGUAGE plpgsql SET search_path='' AS $$
DECLARE p public.gastronomia_99food_sandbox_recebimentos;n jsonb;reimprimir boolean:=true;item jsonb;addon jsonb;itens jsonb:='[]';filhos jsonb;via text;emp text;key text;
BEGIN
 SELECT * INTO p FROM public.gastronomia_99food_sandbox_recebimentos WHERE app_shop_id='florest-gastronomia-teste-01' AND order_id=pedido FOR UPDATE;
 IF e<>'773dfacb-c0e7-4bd9-8eb4-5208818b1848'::uuid OR p.order_id IS NULL OR p_normalizado->>'order_id' IS DISTINCT FROM pedido OR NOT private.gastronomia_99food_impressao_pronta(e) THEN RAISE EXCEPTION 'Selecione a impressora da Gastronomia e conecte o Print Agent.';END IF;
 n:=p_normalizado;SELECT nome INTO emp FROM public.empresas WHERE id=e;
 FOR item IN SELECT value FROM jsonb_array_elements(n->'itens') LOOP
  filhos:='[]';FOR addon IN SELECT value FROM jsonb_array_elements(item->'adicionais') LOOP filhos:=filhos||jsonb_build_array(jsonb_build_object('nome',addon->>'nome','quantidade',addon->'quantidade'));END LOOP;
  itens:=itens||jsonb_build_array(jsonb_build_object('nome',item->>'nome','quantidade',item->'quantidade','preco_unitario',round((item->>'total')::numeric/100/(item->>'quantidade')::numeric,2),'subtotal',(item->>'total')::numeric/100,'observacao',item->>'observacao','filhos',filhos));
 END LOOP;
 itens:=itens||jsonb_build_array(jsonb_build_object('nome','99FOOD #'||coalesce(p.order_index::text,'')||' — ID '||pedido),jsonb_build_object('nome',concat_ws(' · ',n->>'cliente',n->>'telefone',n->>'endereco',n->>'complemento',n->>'referencia')),jsonb_build_object('nome','Observação: '||coalesce(n->>'observacao','')));
 -- Linhas de preço separadas, sem descontar o cupom duas vezes.
 itens:=itens||jsonb_build_array(jsonb_build_object('nome','Itens: R$ '||to_char((n#>>'{precos,itens}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Desconto dos itens: R$ '||to_char((n#>>'{precos,desconto_itens}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Entrega: R$ '||to_char((n#>>'{precos,entrega}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Taxa de serviço: R$ '||to_char((n#>>'{precos,servico}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Total cliente: R$ '||coalesce(to_char((n#>>'{precos,total_cliente}')::numeric/100,'FM999999990.00'),'não informado pela 99Food')),jsonb_build_object('nome','Total informado para a loja: R$ '||to_char((n#>>'{precos,total_loja}')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','Pago/repasse pela plataforma: R$ '||to_char((n->>'pago_online')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','A conferir presencialmente: R$ '||to_char((n->>'a_cobrar')::numeric/100,'FM999999990.00')),jsonb_build_object('nome','PEDIDO NÃO FISCAL — recebimento presencial depende da confirmação do caixa'));
 FOR item IN SELECT jsonb_build_object('nome',v.rotulo||': R$ '||to_char((n#>>ARRAY['precos',v.campo])::numeric/100,'FM999999990.00')) FROM (VALUES ('desconto_entrega','Desconto de entrega'),('entrega_original','Entrega antes dos descontos'),('pedido_minimo','Taxa de pedido mínimo'),('complemento_minimo','Complemento de pedido mínimo'),('gorjeta','Gorjeta'),('cupom','Cupom (já incluído nos descontos)'),('subsidio_loja','Promoção custeada pela loja'),('reembolso','Reembolso'),('cancelamento_parcial','Cancelamento parcial'))v(campo,rotulo) WHERE coalesce((n#>>ARRAY['precos',v.campo])::numeric,0)>0 LOOP itens:=itens||jsonb_build_array(item);END LOOP;
 itens:=itens||jsonb_build_array(jsonb_build_object('nome','Canal de pagamento 99Food: '||coalesce(n->>'pay_channel','não informado')));
 FOREACH via IN ARRAY ARRAY['COZINHA','CONFERÊNCIA CAIXA'] LOOP
  key:='gastronomia:99food:teste:'||pedido||':'||via||CASE WHEN reimprimir THEN ':'||chave::text ELSE '' END;
  PERFORM private.impressao_job_criar(e,'caixa','pedido_bar',key,(CASE WHEN reimprimir THEN 'REIMPRESSÃO · ' ELSE '' END)||'99FOOD TESTE '||via||' #'||p.order_index,
   jsonb_build_object('gastronomia_atendimento_id',NULL,'gastronomia_impressora_propria',true,'versao',1,'tipo','pedido_bar','empresa',emp||' — 99FOOD TESTE #'||p.order_index,'setor',via,'data_hora',to_char(now() AT TIME ZONE 'America/Sao_Paulo','DD/MM/YYYY HH24:MI'),'itens',itens),auth.uid());
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_sandbox_imprimir(uuid,text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.gastronomia_99food_sandbox_imprimir(p_empresa uuid,p_pedido text,p_normalizado jsonb,p_chave uuid) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$BEGIN PERFORM private.gastronomia_99food_sandbox_imprimir(p_empresa,p_pedido,p_normalizado,p_chave);RETURN true;END$$;
REVOKE ALL ON FUNCTION public.gastronomia_99food_sandbox_imprimir(uuid,text,jsonb,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.gastronomia_99food_sandbox_imprimir(uuid,text,jsonb,uuid) TO service_role;
