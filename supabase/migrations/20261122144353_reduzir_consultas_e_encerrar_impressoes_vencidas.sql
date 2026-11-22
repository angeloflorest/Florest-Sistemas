-- Uma autorização e uma viagem HTTP por lote, preservando o cálculo financeiro oficial.
CREATE OR REPLACE FUNCTION public.bar_comandas_resumos(p_comanda_ids uuid[])
RETURNS TABLE(comanda_id uuid, subtotal_aberto numeric, total_pago numeric,
 total_consumido numeric, itens_em_aberto integer, desconto numeric,
 acrescimo numeric, taxa_servico numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE e uuid := private.exigir_empresa_ativa();
BEGIN
 IF NOT private.empresa_tem_modulo('bar') OR NOT private.perm_alguma(
   ARRAY['bar_visualizar','bar_mesas','bar_pedidos','bar_caixa','bar_configurar']::text[]) THEN
   RAISE EXCEPTION 'Você não tem permissão para consultar o saldo de comandas do bar.' USING ERRCODE='42501';
 END IF;
 IF coalesce(cardinality(p_comanda_ids),0)>200 THEN
   RAISE EXCEPTION 'Consulte até 200 comandas por lote.' USING ERRCODE='22023';
 END IF;
 RETURN QUERY SELECT c.id,greatest(s.saldo,0),s.total_pago,s.total_final,
   s.itens_em_aberto,s.desconto,s.acrescimo,s.taxa_servico
 FROM public.bar_comandas c
 CROSS JOIN LATERAL private.bar_comanda_saldo_calcular(c.id,e) s
 WHERE c.empresa_id=e AND c.id=ANY(p_comanda_ids);
END;
$function$;
REVOKE ALL ON FUNCTION public.bar_comandas_resumos(uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.bar_comandas_resumos(uuid[]) TO authenticated;

-- Não depende de um agente online para encerrar cupons cujo prazo já venceu.
-- Não reenfileira, não reimprime e não remove o histórico.
CREATE OR REPLACE FUNCTION private.impressao_encerrar_vencidos()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
DECLARE n integer;
BEGIN
 UPDATE public.impressao_jobs j SET status='falhou',erro_codigo='expirado',
   erro_mensagem='O prazo de impressão venceu sem confirmação. Nenhuma reimpressão automática será feita.'
 WHERE j.id IN (SELECT x.id FROM public.impressao_jobs x
   WHERE x.status='pendente' AND x.expira_em<=now()
   ORDER BY x.expira_em LIMIT 500 FOR UPDATE SKIP LOCKED);
 GET DIAGNOSTICS n=ROW_COUNT;
 RETURN n;
END;
$function$;
REVOKE ALL ON FUNCTION private.impressao_encerrar_vencidos() FROM PUBLIC,anon,authenticated;
SELECT private.impressao_encerrar_vencidos();
SELECT cron.schedule('impressao-encerrar-vencidos','*/10 * * * *',
 'SELECT private.impressao_encerrar_vencidos()');
