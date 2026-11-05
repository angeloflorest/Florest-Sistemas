-- Manual rollback only when the integration has NEVER recorded an operation/session.
-- Refuses to destroy audit, cash or sale data. Do not run after manual tests start.
begin;
set local lock_timeout='5s';
do $$ begin
 if exists(select 1 from public.pdv_movel_caixas) or exists(select 1 from private.pdv_movel_operacoes) or exists(select 1 from public.vendas where pdv_movel_caixa_id is not null) then raise exception 'Rollback recusado: existem operações móveis; preservar dados e preparar correção aditiva.'; end if;
end $$;
CREATE OR REPLACE FUNCTION public.pdv_historico_detalhar(p_venda uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e uuid:=private.exigir_empresa_ativa(); v public.vendas; c public.caixas; editavel boolean;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão' using errcode='42501'; end if;
 select * into v from public.vendas where id=p_venda and empresa_id=e and tipo is null;
 if not found then raise exception 'Venda não encontrada'; end if;
 select * into c from public.caixas where id=v.caixa_id and empresa_id=e and tipo_caixa='PDV';
 editavel:=v.cancelada_em is null and c.status='aberto'
 and not exists(select 1 from public.documentos_fiscais d where d.empresa_id=e and d.venda_id=v.id and (d.status is distinct from 'cancelado' or d.chave_acesso is not null))
 and not exists(select 1 from public.contas_receber cr where cr.empresa_id=e and cr.venda_id=v.id)
 and not exists(select 1 from public.itens_venda i where i.empresa_id=e and i.venda_id=v.id and i.pacote_cliente_id is not null)
 and not exists(select 1 from private.taxas_pagamentos tp where tp.empresa_id=e and tp.venda_id=v.id);
 return jsonb_build_object('venda',to_jsonb(v),'editavel',editavel,
 'cliente_nome',(select nome from public.clientes where id=v.cliente_id and empresa_id=e),
 'itens',(select coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('nome',p.nome) order by i.id),'[]'::jsonb) from public.itens_venda i join public.produtos p on p.id=i.produto_id and p.empresa_id=e where i.empresa_id=e and i.venda_id=v.id),
 'pagamentos',(select coalesce(jsonb_agg(to_jsonb(pa) order by pa.ordem),'[]'::jsonb) from public.vendas_pagamentos pa where pa.empresa_id=e and pa.venda_id=v.id));
end $function$
;
CREATE OR REPLACE FUNCTION public.pdv_historico_listar(p_busca text DEFAULT NULL::text, p_limite integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare e uuid:=private.exigir_empresa_ativa(); r jsonb;
begin
 if not private.perm('pdv') then raise exception 'Sem permissão para o PDV' using errcode='42501'; end if;
 select coalesce(jsonb_agg(to_jsonb(x) order by x.criado_em desc,x.numero_venda desc),'[]'::jsonb) into r from (
 select v.id,v.numero_venda,v.criado_em,v.total,v.forma_pagamento,v.cancelada_em,v.cliente_id,
 coalesce(cl.nome,'Consumidor') cliente_nome,c.status caixa_status,
 (v.cancelada_em is null and c.status='aberto' and c.tipo_caixa='PDV'
 and not exists(select 1 from public.documentos_fiscais d where d.empresa_id=e and d.venda_id=v.id and (d.status is distinct from 'cancelado' or d.chave_acesso is not null))
 and not exists(select 1 from public.contas_receber cr where cr.empresa_id=e and cr.venda_id=v.id)
 and not exists(select 1 from public.itens_venda i where i.empresa_id=e and i.venda_id=v.id and i.pacote_cliente_id is not null)
 and not exists(select 1 from private.taxas_pagamentos tp where tp.empresa_id=e and tp.venda_id=v.id)
 ) editavel
 from public.vendas v left join public.caixas c on c.id=v.caixa_id and c.empresa_id=e
 left join public.clientes cl on cl.id=v.cliente_id and cl.empresa_id=e
 where v.empresa_id=e and v.tipo is null and (p_busca is null or btrim(p_busca)='' or
 v.numero_venda::text ilike '%'||btrim(p_busca)||'%' or cl.nome ilike '%'||btrim(p_busca)||'%' or
 v.forma_pagamento ilike '%'||btrim(p_busca)||'%' or v.total::text ilike '%'||btrim(p_busca)||'%' or
 v.criado_em::date::text ilike '%'||btrim(p_busca)||'%')
 order by v.criado_em desc,v.numero_venda desc limit least(greatest(coalesce(p_limite,100),1),200) offset greatest(coalesce(p_offset,0),0)
 ) x;
 return r;
end $function$
;
drop function public.pdv_movel_venda_detalhar(uuid),public.pdv_movel_vendas_listar(jsonb,integer,integer),public.pdv_movel_caixas_listar(uuid,uuid),public.pdv_movel_operar(uuid,text,uuid,jsonb),public.pdv_movel_operacao_consultar(uuid,text,uuid),public.pdv_movel_contexto(uuid),private.pdv_movel_resumo(uuid);
alter table public.vendas drop constraint vendas_caixas_independentes_ck, drop constraint vendas_pdv_movel_caixa_fk;
alter table public.vendas drop column pdv_movel_ajustes,drop column pdv_movel_caixa_id;
drop table public.pdv_movel_caixas,private.pdv_movel_operacoes;
notify pgrst,'reload schema';
commit;
