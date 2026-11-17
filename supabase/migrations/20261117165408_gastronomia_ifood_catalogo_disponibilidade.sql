-- Disponibilidade por períodos no fuso da loja (São Paulo), exclusiva do catálogo iFood.
CREATE FUNCTION private.gastronomia_ifood_disponivel(regras jsonb,momento timestamptz) RETURNS boolean LANGUAGE plpgsql IMMUTABLE SET search_path='' AS $fn$
DECLARE r jsonb;dia int:=extract(dow FROM momento AT TIME ZONE 'America/Sao_Paulo');data_local date:=(momento AT TIME ZONE 'America/Sao_Paulo')::date;hora text:=to_char(momento AT TIME ZONE 'America/Sao_Paulo','HH24:MI');aberto boolean:=false;BEGIN
 IF regras IS NULL OR regras='[]' THEN RETURN true;END IF;
 IF jsonb_typeof(regras)<>'array' OR jsonb_array_length(regras)>30 THEN RAISE EXCEPTION 'Horários iFood inválidos.';END IF;
 FOR r IN SELECT value FROM jsonb_array_elements(regras) LOOP
  IF jsonb_typeof(r->'dias') IS DISTINCT FROM 'array' OR jsonb_array_length(r->'dias') NOT BETWEEN 1 AND 7 OR EXISTS(SELECT 1 FROM jsonb_array_elements_text(r->'dias') d WHERE d !~ '^[0-6]$') OR coalesce(r->>'inicio','')!~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' OR coalesce(r->>'fim','')!~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' OR r->>'inicio'>=r->>'fim' THEN RAISE EXCEPTION 'Revise dias e horários do cardápio iFood.';END IF;
  IF r->>'de' IS NOT NULL AND r->>'ate' IS NOT NULL AND (r->>'de')::date>(r->>'ate')::date THEN RAISE EXCEPTION 'Período de datas iFood inválido.';END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements_text(r->'dias') d WHERE d::int=dia) AND hora>=r->>'inicio' AND hora<=r->>'fim' AND (r->>'de' IS NULL OR data_local>=(r->>'de')::date) AND (r->>'ate' IS NULL OR data_local<=(r->>'ate')::date) THEN aberto:=true;END IF;
 END LOOP;RETURN aberto;
END $fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_disponivel(jsonb,timestamptz) FROM PUBLIC,anon,authenticated;
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_catalogo_enfileirar(uuid)'::regprocedure);
IF strpos(src,'''ativo'',r.ativo AND coalesce((r.menu->>''ativo'')::boolean,false)')=0 THEN RAISE EXCEPTION 'Disponibilidade do catálogo divergente';END IF;
src:=replace(src,'''ativo'',r.ativo AND coalesce((r.menu->>''ativo'')::boolean,false)','''ativo'',r.ativo AND coalesce((r.menu->>''ativo'')::boolean,false) AND private.gastronomia_ifood_disponivel(r.menu->''ifood_horarios'',clock_timestamp())');EXECUTE src;
src:=pg_get_functiondef('public.gastronomia_ifood_catalogo_worker(text,uuid,jsonb)'::regprocedure);
src:=replace(src,'IF p_acao=''listar'' THEN',$more$IF p_acao='agendar' THEN
 IF EXISTS(SELECT 1 FROM public.gastronomia_configuracoes c CROSS JOIN LATERAL jsonb_array_elements(coalesce(c.opcoes#>'{cardapio,produtos}','[]')) p WHERE c.empresa_id=p_empresa AND coalesce(p->'ifood_horarios','[]')<>'[]') THEN
  PERFORM set_config('ifood.catalogo_disparado',p_empresa::text,true);PERFORM private.gastronomia_ifood_catalogo_enfileirar(p_empresa);
 END IF;RETURN '{}';
 ELSIF p_acao='listar' THEN$more$);EXECUTE src;
END $fix$;
-- Reserva e conclusão do lote em uma transação cada, sem 100 conexões/round-trips.
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('public.gastronomia_ifood_catalogo_worker(text,uuid,jsonb)'::regprocedure);
src:=replace(src,'DECLARE r private.gastronomia_ifood_catalogo;BEGIN','DECLARE r private.gastronomia_ifood_catalogo;lote jsonb;BEGIN');
src:=replace(src,'IF p_acao=''agendar'' THEN',$more$IF p_acao='reservar_lote' THEN
 WITH escolhidos AS (SELECT produto_id FROM private.gastronomia_ifood_catalogo WHERE empresa_id=p_empresa AND (estado='pendente' OR (estado='processando' AND lease_ate<now())) ORDER BY atualizado_em LIMIT 100 FOR UPDATE SKIP LOCKED),reservados AS (UPDATE private.gastronomia_ifood_catalogo q SET estado='processando',lease_ate=now()+interval '90 seconds' FROM escolhidos x WHERE q.empresa_id=p_empresa AND q.produto_id=x.produto_id RETURNING q.*) SELECT coalesce(jsonb_agg(to_jsonb(reservados)),'[]') INTO lote FROM reservados;RETURN lote;
 ELSIF p_acao='resultados' THEN
 IF jsonb_typeof(p_dados->'itens')<>'array' OR jsonb_array_length(p_dados->'itens')>100 THEN RAISE EXCEPTION 'Resultados de lote inválidos.';END IF;
 PERFORM public.gastronomia_ifood_catalogo_worker('resultado',p_empresa,x) FROM jsonb_array_elements(p_dados->'itens') x;RETURN '{}';
 ELSIF p_acao='agendar' THEN$more$);EXECUTE src;
END $fix$;
ALTER TABLE private.gastronomia_ifood_catalogo ADD COLUMN tentativas integer NOT NULL DEFAULT 0, ADD COLUMN proxima_tentativa timestamptz;
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('public.gastronomia_ifood_catalogo_worker(text,uuid,jsonb)'::regprocedure);
src:=replace(src,'(estado=''pendente'' OR (estado=''processando'' AND lease_ate<now()))','(estado=''pendente'' OR (estado=''processando'' AND lease_ate<now())) AND (proxima_tentativa IS NULL OR proxima_tentativa<=now())');
src:=replace(src,'SET estado=''processando'',lease_ate=now()+interval ''90 seconds''','SET estado=''processando'',tentativas=tentativas+1,lease_ate=now()+interval ''90 seconds''');
src:=replace(src,'SET estado=CASE WHEN coalesce((p_dados->>''aguardar'')::boolean,false)', 'SET proxima_tentativa=CASE WHEN coalesce((p_dados->>''retry_ms'')::numeric,0)>0 AND tentativas<5 THEN now()+least(300000,greatest(1000,(p_dados->>''retry_ms'')::numeric))*interval ''1 millisecond'' END,estado=CASE WHEN coalesce((p_dados->>''retry_ms'')::numeric,0)>0 AND tentativas<5 THEN ''pendente'' WHEN coalesce((p_dados->>''aguardar'')::boolean,false)');EXECUTE src;
src:=pg_get_functiondef('private.gastronomia_ifood_catalogo_enfileirar(uuid)'::regprocedure);src:=replace(src,'estado=''pendente'',erro=NULL','estado=''pendente'',tentativas=0,proxima_tentativa=NULL,erro=NULL');EXECUTE src;
END $fix$;
-- Rejeição de cancelamento não é CANCELLED nem conclusão; o atendimento segue ativo.
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_evento(uuid,uuid)'::regprocedure);
src:=replace(src,'novo:=CASE ev.codigo',$more$
 IF ev.codigo IN ('CANCELLATION_REQUESTED','CAR') THEN
  UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo='Cancelamento solicitado — aguardando a decisão do iFood.' WHERE empresa_id=p_e AND pedido_id=ev.pedido_id;RETURN;
 ELSIF ev.codigo IN ('CANCELLATION_REQUEST_FAILED','CARF') THEN
  UPDATE private.gastronomia_ifood_comandos SET estado='falha' WHERE empresa_id=p_e AND pedido_id=ev.pedido_id AND acao='solicitar_cancelamento' AND estado IN ('pendente','enviado','incerto');
  UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo='iFood recusou o cancelamento. Confira o motivo e acompanhe o pedido: '||left(coalesce(ev.payload#>>'{metadata,reason}',ev.payload#>>'{metadata,details}','consulte o iFood'),200) WHERE empresa_id=p_e AND pedido_id=ev.pedido_id;RETURN;
 END IF;
 novo:=CASE ev.codigo$more$);EXECUTE src;
END $fix$;
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('public.gastronomia_pedidos_data(date,uuid)'::regprocedure);src:=replace(src,'''acao'',ic.acao,''estado'',ic.estado','''acao'',ic.acao,''estado'',ic.estado,''payload'',jsonb_build_object(''disputeId'',ic.payload->>''disputeId'')');EXECUTE src;
END $fix$;
ALTER TABLE private.gastronomia_ifood_pedidos ADD COLUMN logistica jsonb;
DO $fix$ DECLARE src text;sig text;BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_evento(uuid,uuid)'::regprocedure);
src:=replace(src,'IF ev.codigo=''DELIVERY_DROP_CODE_REQUESTED'' THEN',$more$IF ev.codigo IN ('ASSIGN_DRIVER','ADR','GOING_TO_ORIGIN','GTO','ARRIVED_AT_ORIGIN','AAO','COLLECTED','CLT','ARRIVED_AT_DESTINATION','AAD','DELIVERY_RETURNING_TO_ORIGIN','DRGO','DELIVERY_RETURNED_TO_ORIGIN','DRDO','DELIVERY_DROP_CODE_REQUESTED') THEN
  UPDATE private.gastronomia_ifood_pedidos SET logistica=jsonb_build_object('codigo',ev.codigo,'ocorrido_em',ev.ocorrido_em) WHERE empresa_id=p_e AND pedido_id=ev.pedido_id AND (logistica IS NULL OR (logistica->>'ocorrido_em')::timestamptz<=ev.ocorrido_em);
$more$);
-- A ramificação já existente limpa o antigo aviso genérico e não fabrica mudança de status do pedido.
EXECUTE src;
FOREACH sig IN ARRAY ARRAY['private.gastronomia_ifood_painel(uuid)','public.gastronomia_pedidos_data(date,uuid)'] LOOP
src:=pg_get_functiondef(sig::regprocedure);IF sig LIKE 'private.%' THEN src:=replace(src,'p.normalizado,','p.normalizado,p.logistica,');ELSE src:=replace(src,'ip.normalizado,','ip.normalizado,ip.logistica,');END IF;EXECUTE src;END LOOP;
END $fix$;
