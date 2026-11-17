-- Homologação iFood: token protegido, cadência efetiva e encerramento da origem iFood.
ALTER TABLE private.gastronomia_ifood_config ADD COLUMN ultimo_poll_enviado timestamptz;
CREATE TABLE private.gastronomia_ifood_tokens (
 empresa_id uuid PRIMARY KEY REFERENCES public.empresas(id),credencial_hash text,segredo_id uuid,expira_em timestamptz,reserva_ate timestamptz,atualizado_em timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE private.gastronomia_ifood_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON private.gastronomia_ifood_tokens FROM PUBLIC,anon,authenticated;
CREATE FUNCTION private.gastronomia_ifood_encerrar(p_empresa uuid,p_pedido uuid) RETURNS boolean LANGUAGE plpgsql SET search_path='' AS $fn$
DECLARE ip private.gastronomia_ifood_pedidos;a public.gastronomia_atendimentos;v uuid;total numeric;pago numeric;
BEGIN
 SELECT * INTO ip FROM private.gastronomia_ifood_pedidos WHERE empresa_id=p_empresa AND pedido_id=p_pedido FOR UPDATE;
 IF ip.estado_ifood<>'concluido' OR ip.atendimento_id IS NULL THEN RETURN false;END IF;
 SELECT * INTO a FROM public.gastronomia_atendimentos WHERE empresa_id=p_empresa AND id=ip.atendimento_id AND origem='ifood' FOR UPDATE;
 IF a.id IS NULL OR a.estado='cancelado' THEN RETURN false;END IF;
 IF a.estado='finalizado' AND a.venda_id IS NOT NULL THEN RETURN true;END IF;
 IF ip.negociacao->>'status' IN ('ACCEPTED','ALTERNATIVE_REPLIED') AND ip.negociacao->>'action' IN ('PARTIAL_CANCELLATION','PROPOSED_AMOUNT_REFUND') THEN
  UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo='Conciliação de cancelamento parcial ou reembolso necessária antes de fechar a venda.' WHERE empresa_id=p_empresa AND pedido_id=p_pedido;RETURN false;
 END IF;
 total:=private.gastronomia_total(a.id,p_empresa);pago:=private.gastronomia_pago(a.id,p_empresa);
 IF total<=0 OR total<>pago THEN
  UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo='Pedido concluído no iFood. Registre o recebimento presencial ou confira a diferença de valores antes do fechamento.' WHERE empresa_id=p_empresa AND pedido_id=p_pedido;RETURN false;
 END IF;
 v:=private.gastronomia_venda(a.id,p_empresa);IF v IS NULL THEN RAISE EXCEPTION 'Venda iFood não confirmada.';END IF;
 UPDATE public.gastronomia_atendimentos SET estado='finalizado',finalizado_em=coalesce(finalizado_em,ip.ultimo_evento_em,now()),versao=versao+1,atualizado_em=now() WHERE empresa_id=p_empresa AND id=a.id;
 UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo=CASE WHEN revisao_motivo LIKE 'Pedido concluído no iFood.%' OR revisao_motivo LIKE '%DELIVERY_DROP_CODE_REQUESTED%' THEN NULL ELSE revisao_motivo END WHERE empresa_id=p_empresa AND pedido_id=p_pedido;
 INSERT INTO public.gastronomia_eventos(empresa_id,atendimento_id,tipo,detalhes) VALUES(p_empresa,a.id,'ifood_evento',jsonb_build_object('acao','concluir','pedido_id',p_pedido,'venda_id',v));
 INSERT INTO public.gastronomia_sinais(empresa_id,revisao) VALUES(p_empresa,1) ON CONFLICT(empresa_id) DO UPDATE SET revisao=public.gastronomia_sinais.revisao+1;
 RETURN true;
END $fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_encerrar(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.gastronomia_ifood_homologacao_worker(p_acao text,p_empresa uuid,p_dados jsonb DEFAULT '{}') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE c private.gastronomia_ifood_config;t private.gastronomia_ifood_tokens;fingerprint text;access_token text;remaining numeric;r record;done int:=0;
BEGIN
 SELECT * INTO c FROM private.gastronomia_ifood_config WHERE empresa_id=p_empresa FOR UPDATE;
 IF c.empresa_id IS DISTINCT FROM '773dfacb-c0e7-4bd9-8eb4-5208818b1848'::uuid OR c.merchant_id IS DISTINCT FROM '9dc78f12-d874-4d66-a454-40268effa19d'::uuid OR c.ambiente<>'teste' OR c.credencial_id IS NULL THEN RAISE EXCEPTION 'Loja fora da liberação iFood.' USING ERRCODE='42501';END IF;
 PERFORM public.gastronomia_ifood_worker('config',p_empresa);
 IF p_acao IN ('token_obter','token_reservar','token_salvar','token_invalidar','token_liberar') THEN
  SELECT md5(decrypted_secret) INTO fingerprint FROM vault.decrypted_secrets WHERE id=c.credencial_id;
  INSERT INTO private.gastronomia_ifood_tokens(empresa_id) VALUES(p_empresa) ON CONFLICT DO NOTHING;
  SELECT * INTO t FROM private.gastronomia_ifood_tokens WHERE empresa_id=p_empresa FOR UPDATE;
  IF p_acao='token_obter' THEN
   IF t.credencial_hash=fingerprint AND t.expira_em>clock_timestamp() THEN SELECT decrypted_secret INTO access_token FROM vault.decrypted_secrets WHERE id=t.segredo_id;RETURN jsonb_build_object('accessToken',access_token,'expiresAt',extract(epoch FROM t.expira_em)*1000);END IF;RETURN NULL;
  ELSIF p_acao='token_reservar' THEN
   IF t.credencial_hash=fingerprint AND t.expira_em>clock_timestamp() THEN RETURN 'false';END IF;
   IF t.reserva_ate>clock_timestamp() THEN RETURN 'false';END IF;
   UPDATE private.gastronomia_ifood_tokens SET reserva_ate=clock_timestamp()+interval '30 seconds',credencial_hash=fingerprint,expira_em=NULL WHERE empresa_id=p_empresa;RETURN 'true';
  ELSIF p_acao='token_salvar' THEN
   IF t.credencial_hash IS DISTINCT FROM fingerprint OR t.reserva_ate IS NULL OR t.reserva_ate<clock_timestamp() THEN RAISE EXCEPTION 'Reserva do token expirada ou credencial alterada.';END IF;
   IF length(p_dados->>'accessToken') NOT BETWEEN 20 AND 20000 OR (p_dados->>'expiresAt')::numeric<=extract(epoch FROM clock_timestamp())*1000 OR (p_dados->>'expiresAt')::numeric>extract(epoch FROM clock_timestamp()+interval '7 days')*1000 THEN RAISE EXCEPTION 'Token ou validade inválidos.';END IF;
   IF t.segredo_id IS NULL THEN SELECT vault.create_secret(p_dados->>'accessToken','gastronomia_ifood_token_'||p_empresa::text) INTO t.segredo_id;ELSE PERFORM vault.update_secret(t.segredo_id,p_dados->>'accessToken');END IF;
   UPDATE private.gastronomia_ifood_tokens SET segredo_id=t.segredo_id,credencial_hash=fingerprint,expira_em=to_timestamp((p_dados->>'expiresAt')::numeric/1000),reserva_ate=NULL,atualizado_em=now() WHERE empresa_id=p_empresa;
  ELSIF p_acao='token_invalidar' THEN
   IF EXISTS(SELECT 1 FROM vault.decrypted_secrets WHERE id=t.segredo_id AND decrypted_secret=p_dados->>'accessToken') THEN UPDATE private.gastronomia_ifood_tokens SET expira_em=NULL,reserva_ate=NULL WHERE empresa_id=p_empresa;END IF;
  ELSE UPDATE private.gastronomia_ifood_tokens SET reserva_ate=NULL WHERE empresa_id=p_empresa;END IF;
 ELSIF p_acao='espera_poll' THEN
  IF NOT c.habilitada OR c.lease_ate>clock_timestamp() THEN RETURN '0';END IF;
  RETURN to_jsonb(greatest(0,ceil(extract(epoch FROM (c.proximo_poll-clock_timestamp()))*1000)));
 ELSIF p_acao='marcar_poll' THEN
  IF NOT c.habilitada THEN RAISE EXCEPTION 'Conexão pausada.';END IF;
  remaining:=greatest(0,ceil(extract(epoch FROM (c.ultimo_poll_enviado+interval '30 seconds'-clock_timestamp()))*1000));
  IF remaining>0 THEN RETURN to_jsonb(remaining);END IF;
  UPDATE private.gastronomia_ifood_config SET ultimo_poll_enviado=clock_timestamp(),proximo_poll=clock_timestamp()+interval '30 seconds' WHERE empresa_id=p_empresa;RETURN '0';
 ELSIF p_acao='concluir' THEN
  FOR r IN SELECT ip.pedido_id FROM private.gastronomia_ifood_pedidos ip JOIN public.gastronomia_atendimentos a ON a.id=ip.atendimento_id AND a.empresa_id=ip.empresa_id WHERE ip.empresa_id=p_empresa AND ip.estado_ifood='concluido' AND a.estado NOT IN ('finalizado','cancelado') ORDER BY ip.criado_em LIMIT 20 LOOP
   BEGIN IF private.gastronomia_ifood_encerrar(p_empresa,r.pedido_id) THEN done:=done+1;END IF;EXCEPTION WHEN OTHERS THEN UPDATE private.gastronomia_ifood_pedidos SET revisao_motivo='Fechamento iFood pendente: '||left(SQLERRM,250) WHERE empresa_id=p_empresa AND pedido_id=r.pedido_id;END;
  END LOOP;RETURN jsonb_build_object('concluidos',done);
 ELSE RAISE EXCEPTION 'Operação iFood inválida.';END IF;RETURN '{}';
END $fn$;
REVOKE ALL ON FUNCTION public.gastronomia_ifood_homologacao_worker(text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.gastronomia_ifood_homologacao_worker(text,uuid,jsonb) TO service_role;
-- A reserva protege a execução; o relógio do polling é atualizado imediatamente antes da chamada à API.
DO $fix$ DECLARE src text;old_sql text:='SET proximo_poll=clock_timestamp()+interval ''30 seconds'',lease_ate=clock_timestamp()+interval ''90 seconds''';BEGIN
src:=pg_get_functiondef('public.gastronomia_ifood_worker(text,uuid,jsonb)'::regprocedure);IF strpos(src,old_sql)=0 THEN RAISE EXCEPTION 'Reserva iFood divergente';END IF;EXECUTE replace(src,old_sql,'SET lease_ate=clock_timestamp()+interval ''90 seconds''');END $fix$;
