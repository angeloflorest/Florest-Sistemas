-- Ajustes apenas nas funções novas do iFood: visibilidade de falhas e negociação após entrega.
DO $$ DECLARE d text; old text; BEGIN
 SELECT pg_get_functiondef('public.gastronomia_ifood_worker(text,uuid,jsonb)'::regprocedure) INTO d;
 old:='AND p.estado_ifood IN (''cancelado'',''concluido'')) RETURNING * INTO cmd;';
 IF position(old IN d)=0 THEN RAISE EXCEPTION 'Base do worker iFood alterada.'; END IF;
 d:=replace(d,old,'AND p.estado_ifood IN (''cancelado'',''concluido'') AND gastronomia_ifood_comandos.acao NOT IN (''aceitar_negociacao'',''recusar_negociacao'')) RETURNING * INTO cmd;');
 EXECUTE d;
 SELECT pg_get_functiondef('private.gastronomia_ifood_admin(text,jsonb)'::regprocedure) INTO d;
 old:='AND estado IN (''pendente'',''enviado'',''incerto'',''confirmado'')) THEN RETURN';
 IF position(old IN d)=0 THEN RAISE EXCEPTION 'Base de comandos iFood alterada.'; END IF;
 d:=replace(d,old,'AND estado IN (''pendente'',''enviado'',''incerto'',''confirmado'') AND (ac NOT IN (''aceitar_negociacao'',''recusar_negociacao'') OR payload->>''disputeId''=d#>>''{payload,disputeId}'')) THEN RETURN');
 EXECUTE d;
END $$;
CREATE OR REPLACE FUNCTION private.gastronomia_ifood_painel(p_e uuid) RETURNS jsonb LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT jsonb_build_object('empresa_id',p_e,'conectado',coalesce((SELECT habilitada FROM private.gastronomia_ifood_config WHERE empresa_id=p_e),false),
 'falhas',(SELECT coalesce(jsonb_agg(to_jsonb(z)),'[]') FROM (SELECT pedido_id,codigo,erro,tentativas FROM private.gastronomia_ifood_eventos WHERE empresa_id=p_e AND estado='falha' ORDER BY recebido_em DESC LIMIT 20) z),
 'pedidos',(SELECT coalesce(jsonb_agg(to_jsonb(z) ORDER BY z.criado_em DESC),'[]') FROM (
 SELECT p.pedido_id,p.atendimento_id,p.estado_ifood,p.normalizado,p.revisao_motivo,p.negociacao,p.criado_em,
 (SELECT coalesce(jsonb_agg(jsonb_build_object('acao',acao,'estado',estado)),'[]') FROM private.gastronomia_ifood_comandos WHERE empresa_id=p_e AND pedido_id=p.pedido_id) comandos,
 (SELECT string_agg(erro,'; ') FROM private.gastronomia_ifood_eventos WHERE empresa_id=p_e AND pedido_id=p.pedido_id AND estado='falha') erro
 FROM private.gastronomia_ifood_pedidos p WHERE empresa_id=p_e ORDER BY criado_em DESC LIMIT 100) z))
$$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_painel(uuid) FROM PUBLIC,anon,authenticated;
