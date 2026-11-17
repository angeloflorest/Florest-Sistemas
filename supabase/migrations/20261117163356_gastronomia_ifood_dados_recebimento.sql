-- Dados operacionais do pedido sem credenciais; leitura sempre pelo escopo da empresa.
CREATE FUNCTION private.gastronomia_ifood_dados(d jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path='' AS $fn$
SELECT jsonb_build_object('endereco',left(coalesce(nullif(d#>>'{delivery,deliveryAddress,formattedAddress}',''),concat_ws(', ',d#>>'{delivery,deliveryAddress,streetName}',d#>>'{delivery,deliveryAddress,streetNumber}')),350),'bairro',d#>>'{delivery,deliveryAddress,neighborhood}','cidade',d#>>'{delivery,deliveryAddress,city}','uf',d#>>'{delivery,deliveryAddress,state}','cep',d#>>'{delivery,deliveryAddress,postalCode}','complemento',d#>>'{delivery,deliveryAddress,complement}','referencia',d#>>'{delivery,deliveryAddress,reference}','instrucoes',left(coalesce(d#>>'{delivery,observations}',d#>>'{takeout,observations}',d->>'extraInfo',''),1024),'observacoes',left(d->>'observations',1024),'codigo_coleta',d#>>'{delivery,pickupCode}','telefone',d#>>'{customer,phone,number}','localizador',d#>>'{customer,phone,localizer}','documento',coalesce(d#>>'{customer,documentNumber}',d#>>'{customer,taxPayerIdentificationNumber}',d#>>'{additionalInfo,taxPayerIdentificationNumber}'),'pagamentos',coalesce(d#>'{payments,methods}','[]'),'beneficios',coalesce(d->'benefits','[]'))
$fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_dados(jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.gastronomia_ifood_local(e uuid,pedido uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $fn$
SELECT jsonb_build_object('saldo',greatest(0,private.gastronomia_total(a.id,e)-private.gastronomia_pago(a.id,e)),'estado',a.estado,'atendimento_id',a.id,'venda_id',a.venda_id,'recebido_presencial',(SELECT coalesce(sum(pg.valor),0) FROM public.gastronomia_pagamentos pg WHERE pg.empresa_id=e AND pg.atendimento_id=a.id AND NOT pg.estornado),'impressao',(SELECT coalesce(jsonb_agg(jsonb_build_object('status',j.status,'erro',j.erro_mensagem,'impresso_em',j.impresso_em)),'[]') FROM public.impressao_jobs j WHERE j.empresa_id=e AND j.chave_unica LIKE 'gastronomia:ifood:'||pedido::text||':%'))
FROM private.gastronomia_ifood_pedidos ip JOIN public.gastronomia_atendimentos a ON a.id=ip.atendimento_id AND a.empresa_id=e WHERE ip.empresa_id=e AND ip.pedido_id=pedido
$fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_local(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.gastronomia_ifood_linhas(d jsonb,via text) RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path='' AS $fn$
WITH info AS (SELECT private.gastronomia_ifood_dados(d) i),lines AS (
SELECT 1 ordem,'Endereço: '||concat_ws(' · ',nullif(i->>'endereco',''),nullif(i->>'bairro',''),nullif(i->>'cidade',''),nullif(i->>'uf','')) texto FROM info WHERE coalesce(i->>'endereco','')<>''
UNION ALL SELECT 2,'Complemento: '||(i->>'complemento') FROM info WHERE coalesce(i->>'complemento','')<>''
UNION ALL SELECT 3,'Referência: '||(i->>'referencia') FROM info WHERE coalesce(i->>'referencia','')<>''
UNION ALL SELECT 4,'Instruções: '||(i->>'instrucoes') FROM info WHERE coalesce(i->>'instrucoes','')<>''
UNION ALL SELECT 5,'Código de coleta: '||(i->>'codigo_coleta') FROM info WHERE coalesce(i->>'codigo_coleta','')<>''
UNION ALL SELECT 6,'Contato iFood: '||concat_ws(' · ',i->>'telefone',i->>'localizador') FROM info WHERE coalesce(i->>'telefone','')<>''
UNION ALL SELECT 7,'CPF/CNPJ informado para documento fiscal: '||(i->>'documento') FROM info WHERE via LIKE '%CAIXA%' AND coalesce(i->>'documento','')<>''
UNION ALL SELECT 8,CASE WHEN m->>'type'='ONLINE' THEN 'Pago online: ' ELSE 'Cobrar presencialmente: ' END||concat_ws(' · ',m->>'method',m#>>'{card,brand}','R$ '||coalesce(m->>'value','0'),CASE WHEN coalesce((m#>>'{cash,changeFor}')::numeric,0)>0 THEN 'Troco para R$ '||(m#>>'{cash,changeFor}') END) FROM info CROSS JOIN LATERAL jsonb_array_elements(i->'pagamentos') m
UNION ALL SELECT 9,'Cupom — '||(s->>'name')||': R$ '||(s->>'value') FROM info CROSS JOIN LATERAL jsonb_array_elements(i->'beneficios') b CROSS JOIN LATERAL jsonb_array_elements(coalesce(b->'sponsorshipValues','[]')) s WHERE coalesce((s->>'value')::numeric,0)>0
) SELECT coalesce(jsonb_agg(jsonb_build_object('nome',regexp_replace(texto,'[[:cntrl:]]',' ','g')) ORDER BY ordem),'[]') FROM lines
$fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_linhas(jsonb,text) FROM PUBLIC,anon,authenticated;
-- Amplia exclusivamente o comprovante iFood e conserva a observação completa recebida.
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_imprimir(uuid,uuid,uuid,boolean)'::regprocedure);
IF strpos(src,'''itens'',itens||jsonb_build_array(')=0 THEN RAISE EXCEPTION 'Impressão iFood divergente';END IF;
src:=replace(src,'''itens'',itens||jsonb_build_array(','''itens'',itens||private.gastronomia_ifood_linhas(p.detalhe,via)||jsonb_build_array(');
src:=replace(src,'''observacao'',i.snapshot->>''observacao''','''observacao'',coalesce(i.snapshot->>''ifood_observacao'',i.snapshot->>''observacao'')');EXECUTE src;
src:=pg_get_functiondef('private.gastronomia_ifood_importar(uuid,uuid)'::regprocedure);
IF strpos(src,'x:=x||jsonb_build_object(''lote'',p.pedido_id,')=0 THEN RAISE EXCEPTION 'Importação iFood divergente';END IF;
src:=replace(src,'x:=x||jsonb_build_object(''lote'',p.pedido_id,','x:=x||jsonb_build_object(''ifood_observacao'',i->>''observacao'',''lote'',p.pedido_id,');EXECUTE src;
END $fix$;
-- O caixa físico guarda o recebido bruto; somente a parcela da loja quita a venda.
DO $fix$ DECLARE src text;BEGIN
src:=replace(pg_get_functiondef('private.gastronomia_pago(uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10));
IF md5(src)<>'ffc32bd80bc16d8ecff3f4c313c686e8' THEN RAISE EXCEPTION 'Saldo pago compartilhado alterado';END IF;
src:=replace(src,'sum(valor) FROM public.gastronomia_pagamentos','sum(valor-CASE WHEN EXISTS(SELECT 1 FROM public.gastronomia_atendimentos a WHERE a.id=p_id AND a.empresa_id=p_e AND a.origem=''ifood'') THEN coalesce((metadados->>''ifood_taxa_plataforma'')::numeric,0) ELSE 0 END) FROM public.gastronomia_pagamentos');EXECUTE src;
src:=replace(pg_get_functiondef('private.gastronomia_venda(uuid,uuid)'::regprocedure),chr(13)||chr(10),chr(10));
IF md5(src)<>'3799d13c6501304913c3cce32aca5e58' THEN RAISE EXCEPTION 'Venda compartilhada alterada';END IF;
src:=replace(src,'p.forma,p.valor,row_number()','p.forma,p.valor-CASE WHEN a.origem=''ifood'' THEN coalesce((p.metadados->>''ifood_taxa_plataforma'')::numeric,0) ELSE 0 END,row_number()');
src:=replace(src,'AND NOT p.estornado ON CONFLICT(id)','AND NOT p.estornado AND (p.valor-CASE WHEN a.origem=''ifood'' THEN coalesce((p.metadados->>''ifood_taxa_plataforma'')::numeric,0) ELSE 0 END)>0 ON CONFLICT(id)');EXECUTE src;
END $fix$;
CREATE FUNCTION public.gastronomia_ifood_receber(p_empresa uuid,p_pedido uuid,p_valor numeric,p_forma text,p_chave uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE e uuid:=private.gastronomia_exigir('gastronomia_caixa');ip private.gastronomia_ifood_pedidos;a public.gastronomia_atendimentos;cx uuid;fee numeric;
BEGIN
 IF p_empresa IS DISTINCT FROM e OR p_chave IS NULL THEN RAISE EXCEPTION 'Empresa ou chave inválida.' USING ERRCODE='42501';END IF;
 PERFORM private.gastronomia_exigir('gastronomia_pedidos');
 SELECT * INTO ip FROM private.gastronomia_ifood_pedidos WHERE empresa_id=e AND pedido_id=p_pedido FOR UPDATE;
 IF ip.atendimento_id IS NULL OR ip.estado_ifood IN ('recebido','cancelado') THEN RAISE EXCEPTION 'Pedido indisponível para recebimento.';END IF;
 SELECT * INTO a FROM public.gastronomia_atendimentos WHERE empresa_id=e AND id=ip.atendimento_id AND origem='ifood' FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE id=p_chave AND empresa_id=e AND atendimento_id=a.id) THEN RETURN private.gastronomia_ifood_local(e,p_pedido);END IF;
 IF a.estado IN ('cancelado','finalizado') OR ip.a_cobrar_centavos<=0 OR p_valor IS DISTINCT FROM round(ip.a_cobrar_centavos::numeric/100,2) OR EXISTS(SELECT 1 FROM public.gastronomia_pagamentos WHERE empresa_id=e AND atendimento_id=a.id AND NOT estornado) THEN RAISE EXCEPTION 'Recebimento já registrado ou valor diferente do saldo presencial iFood.';END IF;
 IF p_forma NOT IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito') OR p_forma IS NULL THEN RAISE EXCEPTION 'Forma de recebimento inválida.';END IF;
 fee:=coalesce((ip.normalizado->>'taxas_offline')::numeric,0)/100;IF fee<0 OR fee>p_valor THEN RAISE EXCEPTION 'Confira as taxas presenciais do pedido.';END IF;
 cx:=private.caixa_exigir_aberto('GASTRONOMIA');
 INSERT INTO public.gastronomia_pagamentos(id,empresa_id,atendimento_id,caixa_id,forma,valor,criado_por,metadados) VALUES(p_chave,e,a.id,cx,p_forma,p_valor,auth.uid(),jsonb_build_object('ifood_pedido_id',p_pedido,'ifood_taxa_plataforma',fee,'confirmado_pelo_operador',true));
 INSERT INTO public.gastronomia_eventos(empresa_id,atendimento_id,tipo,autor,detalhes) VALUES(e,a.id,'ifood_evento',auth.uid(),jsonb_build_object('acao','receber_presencial','valor',p_valor,'taxa_plataforma',fee,'pagamento_id',p_chave));
 PERFORM private.gastronomia_ifood_encerrar(e,p_pedido);
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(e,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
 RETURN private.gastronomia_ifood_local(e,p_pedido);
END $fn$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_receber(uuid,uuid,numeric,text,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_receber(uuid,uuid,numeric,text,uuid) TO authenticated;
-- Dados operacionais também estão disponíveis nos pedidos históricos, sem reenviar impressões.
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_painel(uuid)'::regprocedure);
src:=replace(src,'p.normalizado,p.revisao_motivo','p.normalizado,private.gastronomia_ifood_dados(p.detalhe) informacoes,private.gastronomia_ifood_local(p_e,p.pedido_id) "local",p.revisao_motivo');EXECUTE src;
src:=pg_get_functiondef('public.gastronomia_pedidos_data(date,uuid)'::regprocedure);
src:=replace(src,'ip.normalizado,ip.revisao_motivo','ip.normalizado,private.gastronomia_ifood_dados(ip.detalhe) informacoes,private.gastronomia_ifood_local(e,ip.pedido_id) "local",ip.revisao_motivo');EXECUTE src;
END $fix$;
-- Recebimentos iFood usam o fluxo que separa a taxa da plataforma do valor da venda.
DO $fix$ DECLARE src text;old_sql text:='IF a.origem=''ifood'' AND p_acao IN (';BEGIN
src:=pg_get_functiondef('public.gastronomia_rpc(text,jsonb,uuid)'::regprocedure);IF strpos(src,old_sql)=0 THEN RAISE EXCEPTION 'Proteção iFood divergente';END IF;EXECUTE replace(src,old_sql,'IF a.origem=''ifood'' AND p_acao IN (''receber'',');END $fix$;
