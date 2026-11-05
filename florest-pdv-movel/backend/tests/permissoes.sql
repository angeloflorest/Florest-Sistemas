-- Synthetic fixture DB only. Exercise public RPC grants/RLS under a non-owner role.
set role authenticated;
set request.jwt.claim.sub='20000000-0000-0000-0000-000000000002';
do $$begin
 if (select count(*) from public.pdv_movel_caixas)<>0 then raise exception 'RLS vazou caixa de outra empresa'; end if;
 begin insert into public.pdv_movel_caixas(empresa_id,dispositivo_id,dispositivo_nome,numero,aberto_por,aberto_por_nome,valor_inicial) values('10000000-0000-0000-0000-000000000002',gen_random_uuid(),'Bypass',999,auth.uid(),'Bypass',0); raise exception 'Escrita direta permitida'; exception when insufficient_privilege then null; end;
end $$;
set request.jwt.claim.sub='20000000-0000-0000-0000-000000000001';
do $$begin if (select count(*) from public.pdv_movel_caixas)<>2 then raise exception 'Proprietário não consulta seus caixas'; end if;end $$;
set request.jwt.claim.sub='20000000-0000-0000-0000-000000000004';
do $$begin
 begin perform public.pdv_movel_contexto('50000000-0000-0000-0000-000000000001');raise exception 'Sem permissão acessou contexto';exception when insufficient_privilege then null;end;
end $$;
reset role;
