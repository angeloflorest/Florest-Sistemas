\set ON_ERROR_STOP on
CREATE SCHEMA auth; CREATE SCHEMA private;
CREATE TABLE private.florest_autorizacoes(token uuid PRIMARY KEY,empresa_id uuid,autorizador_id uuid,resultado jsonb,consumida_em timestamptz,transacao bigint);
CREATE TABLE public.bar_comandas(id uuid PRIMARY KEY,mesa_id uuid,empresa_id uuid,venda_id uuid,status text);
CREATE TABLE public.bar_mesas(id uuid PRIMARY KEY,empresa_id uuid,comanda_atual_id uuid);
CREATE TABLE public.bar_pedidos(id uuid PRIMARY KEY,empresa_id uuid,comanda_id uuid);
CREATE TABLE public.bar_pedidos_itens(id uuid PRIMARY KEY,empresa_id uuid,comanda_id uuid,pedido_id uuid,estornado boolean DEFAULT false);
CREATE TABLE public.documentos_fiscais(empresa_id uuid,venda_id uuid,status text);
CREATE TABLE public.bar_pagamentos(empresa_id uuid,comanda_id uuid);
CREATE TABLE public.florest_auditoria_operacoes(empresa_id uuid,solicitante_id uuid,autorizador_id uuid,operacao text,alvo_id uuid,motivo text,antes jsonb,depois jsonb,resultado text);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$SELECT '00000000-0000-0000-0000-000000000001'::uuid$$;
CREATE FUNCTION private.florest_autorizacao_consumir(uuid,uuid,text,uuid,jsonb) RETURNS private.florest_autorizacoes LANGUAGE sql AS $$SELECT * FROM private.florest_autorizacoes WHERE token=$1$$;
CREATE FUNCTION public.bar_pedido_item_cancelar(uuid,text) RETURNS void LANGUAGE sql AS $$UPDATE public.bar_pedidos_itens SET estornado=true WHERE id=$1$$;
CREATE FUNCTION public.bar_mesa_cancelar(uuid,text) RETURNS void LANGUAGE sql AS $$UPDATE public.bar_comandas SET status='cancelada' WHERE mesa_id=$1$$;
INSERT INTO private.florest_autorizacoes(token,empresa_id,autorizador_id) VALUES('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001');
INSERT INTO public.bar_comandas VALUES('00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000006','aberta');
INSERT INTO public.bar_mesas VALUES('00000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000004');
INSERT INTO public.bar_pedidos VALUES('00000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000004');
INSERT INTO public.bar_pedidos_itens VALUES('00000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000007',false);

