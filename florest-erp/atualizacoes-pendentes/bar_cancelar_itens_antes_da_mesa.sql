-- Proposta aprovada para versionamento; NÃO aplicada no Supabase.
BEGIN;
SET LOCAL lock_timeout='5s';
DO $guard$
BEGIN
 IF md5(pg_get_functiondef('public.florest_bar_cancelar(uuid,text,uuid,text)'::regprocedure)) <> '3da408d6357fb17080f81c046a89ee5b' THEN
  RAISE EXCEPTION 'A função foi alterada desde a preparação. Compare novamente antes de aplicar.';
 END IF;
END $guard$;
CREATE OR REPLACE FUNCTION public.florest_bar_cancelar(p_token uuid, p_operacao text, p_alvo uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a private.florest_autorizacoes; c public.bar_comandas; item public.bar_pedidos_itens; m uuid; r record; v_resultado jsonb; antes jsonb;
begin
 a:=private.florest_autorizacao_consumir(p_token,auth.uid(),p_operacao,p_alvo,jsonb_build_object('motivo',p_motivo));
 if a.resultado is not null then return a.resultado; end if;
 if a.consumida_em is not null and a.transacao<>txid_current() then raise exception 'Autorização já utilizada.'; end if;
 begin
  if p_operacao='bar_item_cancelar' then
   select * into item from public.bar_pedidos_itens where id=p_alvo and empresa_id=a.empresa_id;
   select * into c from public.bar_comandas where id=item.comanda_id and empresa_id=a.empresa_id;
  elsif p_operacao='bar_pedido_cancelar' then
   select co.* into c from public.bar_pedidos pe join public.bar_comandas co on co.id=pe.comanda_id and co.empresa_id=pe.empresa_id where pe.id=p_alvo and pe.empresa_id=a.empresa_id;
  elsif p_operacao='bar_comanda_cancelar' then select * into c from public.bar_comandas where id=p_alvo and empresa_id=a.empresa_id;
  elsif p_operacao='bar_mesa_cancelar' then select co.* into c from public.bar_mesas me join public.bar_comandas co on co.id=me.comanda_atual_id and co.empresa_id=me.empresa_id where me.id=p_alvo and me.empresa_id=a.empresa_id;
  else raise exception 'Operação inválida.'; end if;
  if c.id is null then raise exception 'Operação não encontrada.'; end if;
  perform 1 from public.bar_mesas where id=c.mesa_id and empresa_id=a.empresa_id for update;
  select * into c from public.bar_comandas where id=c.id and empresa_id=a.empresa_id for update;
  if c.status<>'aberta' then raise exception 'Comanda não está aberta.'; end if;
  if exists(select 1 from public.documentos_fiscais where empresa_id=a.empresa_id and venda_id=c.venda_id and status in ('processando','autorizada')) then raise exception 'Documento fiscal impede cancelamento operacional. Utilize o procedimento fiscal separado.'; end if;
  antes:=jsonb_build_object('mesa_id',c.mesa_id,'comanda_id',c.id,'itens',(select jsonb_agg(to_jsonb(i)) from public.bar_pedidos_itens i where i.comanda_id=c.id and i.empresa_id=a.empresa_id and not i.estornado and (p_operacao not in ('bar_item_cancelar','bar_pedido_cancelar') or i.id=p_alvo or i.pedido_id=p_alvo)));
  if p_operacao='bar_item_cancelar' then perform public.bar_pedido_item_cancelar(p_alvo,p_motivo);
  else
   if p_operacao in ('bar_mesa_cancelar','bar_comanda_cancelar') and exists(select 1 from public.bar_pagamentos where comanda_id=c.id and empresa_id=a.empresa_id) then raise exception 'Há histórico de pagamento; use o fluxo financeiro próprio.'; end if;
   if p_operacao in ('bar_mesa_cancelar','bar_comanda_cancelar') and exists(
    select 1 from public.bar_pedidos_itens i where i.comanda_id=c.id and i.empresa_id=a.empresa_id and not i.estornado
   ) then raise exception 'Cancele os itens da comanda antes de cancelar a mesa ou comanda.'; end if;
   for r in select id from public.bar_pedidos_itens where comanda_id=c.id and empresa_id=a.empresa_id and not estornado and p_operacao='bar_pedido_cancelar' and pedido_id=p_alvo order by id loop
    perform public.bar_pedido_item_cancelar(r.id,p_motivo);
   end loop;
   if p_operacao in ('bar_mesa_cancelar','bar_comanda_cancelar') then perform public.bar_mesa_cancelar(c.mesa_id,p_motivo); end if;
  end if;
  v_resultado:=jsonb_build_object('ok',true,'mesa_id',c.mesa_id,'comanda_id',c.id);
  insert into public.florest_auditoria_operacoes(empresa_id,solicitante_id,autorizador_id,operacao,alvo_id,motivo,antes,depois,resultado)
  values(a.empresa_id,auth.uid(),a.autorizador_id,p_operacao,p_alvo,p_motivo,antes,v_resultado,'sucesso');
 exception when others then
  v_resultado:=jsonb_build_object('ok',false,'mensagem',sqlerrm);
  insert into public.florest_auditoria_operacoes(empresa_id,solicitante_id,autorizador_id,operacao,alvo_id,motivo,resultado)
  values(a.empresa_id,auth.uid(),a.autorizador_id,p_operacao,p_alvo,p_motivo,'erro: '||sqlerrm);
 end;
 update private.florest_autorizacoes set resultado=v_resultado where token=p_token;
 return v_resultado;
end $function$;

COMMIT;
