-- PREPARADA LOCALMENTE. Não aplicar sem autorização de alteração em produção.
-- Não altera funções NFC-e, vendas, estoque, financeiro ou relatórios.
begin;
create table public.fiscal_nfe55_emissoes (
 id uuid primary key default gen_random_uuid(),
 empresa_id uuid not null references public.empresas(id),
 venda_id uuid not null,
 numero bigint not null check(numero between 1 and 999999999),
 serie text not null check(serie ~ '^[1-9][0-9]{0,2}$'),
 tp_amb text not null default '1' check(tp_amb='1'),
 status text not null default 'reservada' check(status in ('reservada','processando','pendente','autorizada','rejeitada')),
 c_nf text not null check(c_nf ~ '^[0-9]{8}$'),
 dh_emissao timestamptz not null default now(),
 usuario_id uuid not null,
 snapshot jsonb not null,
 revisao jsonb not null,
 payload jsonb,
 c_stat text,
 mensagem text,
 id_dfe text,
 chave_acesso text,
 protocolo text,
 criado_em timestamptz not null default now(),
 atualizado_em timestamptz not null default now(),
 foreign key(empresa_id,venda_id) references public.vendas(empresa_id,id),
 unique(empresa_id,venda_id),
 unique(empresa_id,serie,numero)
);
alter table public.fiscal_nfe55_emissoes enable row level security;
revoke all on public.fiscal_nfe55_emissoes from anon,authenticated;
grant select on public.fiscal_nfe55_emissoes to authenticated;
grant all on public.fiscal_nfe55_emissoes to service_role;
create policy nfe55_empresa_leitura on public.fiscal_nfe55_emissoes for select to authenticated
 using(empresa_id=private.empresa_id_ativa() and private.perm_alguma(array['fiscal']));

-- Campos próprios no cadastro fiscal; nenhuma configuração NFC-e é regravada.
alter table public.configuracoes_fiscais
 add column nfe_serie text not null default '1' check(nfe_serie ~ '^[1-9][0-9]{0,2}$'),
 add column nfe_ultimo_numero bigint check(nfe_ultimo_numero between 0 and 999999999),
 add column nfe_numeracao_confirmada_em timestamptz,
 add column nfe_numeracao_confirmada_por uuid;

create function private.nfe55_config_proteger() returns trigger
language plpgsql set search_path='' as $$
begin
 if tg_op='INSERT' then
  if current_user in ('authenticated','anon') and (new.nfe_serie<>'1' or new.nfe_ultimo_numero is not null or new.nfe_numeracao_confirmada_em is not null or new.nfe_numeracao_confirmada_por is not null) then raise exception 'Use a configuração exclusiva da numeração NF-e.';end if;
  return new;
 end if;
 if current_user in ('authenticated','anon') and
  row(new.nfe_serie,new.nfe_ultimo_numero,new.nfe_numeracao_confirmada_em,new.nfe_numeracao_confirmada_por)
  is distinct from row(old.nfe_serie,old.nfe_ultimo_numero,old.nfe_numeracao_confirmada_em,old.nfe_numeracao_confirmada_por) then
  raise exception 'Use a configuração exclusiva da numeração NF-e.';
 end if;
 return new;
end;$$;
revoke all on function private.nfe55_config_proteger() from public,anon,authenticated;
create trigger nfe55_config_proteger before insert or update on public.configuracoes_fiscais
 for each row execute function private.nfe55_config_proteger();

create function private.nfe55_maior_numero(p_empresa uuid,p_serie text) returns bigint
language sql stable set search_path='' as $$
 select greatest(
  coalesce((select max(ultimo_numero) from public.contadores_fiscais where empresa_id=p_empresa and tipo_documento='nfe' and case when serie ~ '^[0-9]{1,3}$' then serie::integer end=p_serie::integer),0),
  coalesce((select max(case when numero ~ '^[0-9]{1,9}$' then numero::bigint end) from public.documentos_fiscais where empresa_id=p_empresa and tipo_documento='nfe' and case when serie ~ '^[0-9]{1,3}$' then serie::integer end=p_serie::integer),0),
  coalesce((select max(numero) from public.fiscal_nfe55_emissoes where empresa_id=p_empresa and serie=p_serie),0),
  coalesce((select nfe_ultimo_numero from public.configuracoes_fiscais where empresa_id=p_empresa and nfe_serie=p_serie),0));
$$;
revoke all on function private.nfe55_maior_numero(uuid,text) from public,anon,authenticated;

create function public.fiscal_nfe55_numeracao_obter(p_serie text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa();c public.configuracoes_fiscais;s text;n bigint;
begin
 if not private.perm_alguma(array['configuracoes','fiscal']) then raise exception 'Permissão fiscal ou configurações necessária.' using errcode='42501';end if;
 select * into c from public.configuracoes_fiscais where empresa_id=e;
 if not found then raise exception 'Salve o cadastro fiscal desta empresa antes de configurar a NF-e.';end if;
 s:=coalesce(p_serie,c.nfe_serie);
 if s is null or s !~ '^[1-9][0-9]{0,2}$' then raise exception 'Série NF-e deve estar entre 1 e 999, sem zeros à esquerda.';end if;
 n:=private.nfe55_maior_numero(e,s);
 return jsonb_build_object('empresa_id',e,'serie',s,'ultimo_numero',n,'proximo_numero',case when n<999999999 then n+1 end,'confirmada',c.nfe_serie=s and c.nfe_numeracao_confirmada_em is not null,'confirmada_em',case when c.nfe_serie=s then c.nfe_numeracao_confirmada_em end,'serie_ativa',c.nfe_serie);
end;$$;
revoke all on function public.fiscal_nfe55_numeracao_obter(text) from public,anon;
grant execute on function public.fiscal_nfe55_numeracao_obter(text) to authenticated;

create function public.fiscal_nfe55_numeracao_salvar(p_serie text,p_ultimo_numero bigint,p_confirmado boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa();c public.configuracoes_fiscais;n bigint;
begin
 if not private.perm_alguma(array['configuracoes']) then raise exception 'Somente responsável com permissão de configurações pode confirmar a numeração.' using errcode='42501';end if;
 if p_confirmado is distinct from true then raise exception 'Confira e confirme a numeração inicial da NF-e.';end if;
 if p_serie is null or p_serie !~ '^[1-9][0-9]{0,2}$' then raise exception 'Série NF-e deve estar entre 1 e 999, sem zeros à esquerda.';end if;
 if p_ultimo_numero is null or p_ultimo_numero<0 or p_ultimo_numero>999999998 then raise exception 'Último número deve estar entre 0 e 999999998.';end if;
 select * into c from public.configuracoes_fiscais where empresa_id=e for update;
 if not found then raise exception 'Salve o cadastro fiscal desta empresa antes de configurar a NF-e.';end if;
 -- Configuração e reserva travam a mesma linha antes de tocar no contador.
 perform 1 from public.contadores_fiscais where empresa_id=e and tipo_documento='nfe' and serie=p_serie for update;
 n:=private.nfe55_maior_numero(e,p_serie);
 if p_ultimo_numero<n then raise exception 'Não é permitido diminuir a sequência NF-e: há número emitido ou reservado maior (%). Recarregue a numeração.',n;end if;
 insert into public.contadores_fiscais(empresa_id,tipo_documento,serie,ultimo_numero)
 values(e,'nfe',p_serie,p_ultimo_numero)
 on conflict(empresa_id,tipo_documento,serie) do update
 set ultimo_numero=greatest(public.contadores_fiscais.ultimo_numero,excluded.ultimo_numero),atualizado_em=now();
 update public.configuracoes_fiscais set nfe_serie=p_serie,nfe_ultimo_numero=p_ultimo_numero,nfe_numeracao_confirmada_em=clock_timestamp(),nfe_numeracao_confirmada_por=auth.uid()
 where empresa_id=e;
 return public.fiscal_nfe55_numeracao_obter(p_serie);
end;$$;
revoke all on function public.fiscal_nfe55_numeracao_salvar(text,bigint,boolean) from public,anon;
grant execute on function public.fiscal_nfe55_numeracao_salvar(text,bigint,boolean) to authenticated;

create function public.fiscal_nfe55_clientes_pesquisar(p_busca text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa();b text:=btrim(coalesce(p_busca,''));d text;result jsonb;
begin
 if not private.perm_alguma(array['fiscal']) then raise exception 'Permissão fiscal necessária.' using errcode='42501';end if;
 if char_length(b)<2 or char_length(b)>80 then raise exception 'Informe de 2 a 80 caracteres para pesquisar destinatários.';end if;
 d:=regexp_replace(b,'[^0-9]','','g');
 select coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) into result from (
  select cl.id,cl.empresa_id,cl.nome,cl.cpf,cl.logradouro,cl.numero,cl.bairro,cl.cidade,cl.uf,cl.cep
  from public.clientes cl where cl.empresa_id=e and (strpos(lower(cl.nome),lower(b))>0 or (length(d)>=3 and strpos(regexp_replace(coalesce(cl.cpf,''),'[^0-9]','','g'),d)>0))
  order by cl.nome,cl.id limit 20
 ) c;
 return jsonb_build_object('empresa_id',e,'clientes',result,'limite',20);
end;$$;
revoke all on function public.fiscal_nfe55_clientes_pesquisar(text) from public,anon;
grant execute on function public.fiscal_nfe55_clientes_pesquisar(text) to authenticated;

create function public.fiscal_nfe55_contexto(p_venda_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa();s jsonb;c jsonb;i jsonb;
begin
 if not private.perm_alguma(array['fiscal']) then raise exception 'Permissão fiscal necessária.' using errcode='42501';end if;
 select jsonb_build_object('id',v.id,'empresa_id',v.empresa_id,'numero_venda',v.numero_venda,'total',v.total,'forma_pagamento',v.forma_pagamento,'cancelada_em',v.cancelada_em,'cliente',jsonb_build_object('nome',cl.nome,'cpf',cl.cpf,'logradouro',cl.logradouro,'numero',cl.numero,'bairro',cl.bairro,'cidade',cl.cidade,'uf',cl.uf,'cep',cl.cep)) into s
 from public.vendas v left join public.clientes cl on cl.id=v.cliente_id and cl.empresa_id=v.empresa_id where v.id=p_venda_id and v.empresa_id=e;
 if s is null then raise exception 'Venda não encontrada.';end if;
 select jsonb_build_object('cnpj',f.cnpj,'razao_social',f.razao_social,'nome_fantasia',f.nome_fantasia,'inscricao_estadual',f.inscricao_estadual,'crt',f.crt,'regime_tributario',f.regime_tributario,'nfe_serie',f.nfe_serie,'nfe_numeracao_confirmada_em',f.nfe_numeracao_confirmada_em,'endereco',f.endereco,'numero',f.numero,'bairro',f.bairro,'municipio',f.municipio,'codigo_ibge',f.codigo_ibge,'uf',f.uf,'cep',f.cep,'telefone',f.telefone,'emitente_registrado',f.emitente_registrado,'certificado_validade',f.certificado_validade) into c from public.configuracoes_fiscais f where f.empresa_id=e;
 select coalesce(jsonb_agg(jsonb_build_object('id',iv.id,'quantidade',iv.quantidade,'preco_unitario',iv.preco_unitario,'subtotal',iv.subtotal,'produto',jsonb_build_object('id',p.id,'codigo',p.codigo,'nome',p.nome,'gtin',p.gtin,'ncm',p.ncm,'cest',p.cest,'cfop',p.cfop,'unidade_comercial',p.unidade_comercial,'tipo_fiscal',p.tipo_fiscal,'origem_mercadoria',p.origem_mercadoria,'cst_csosn',p.cst_csosn,'cst_pis',p.cst_pis,'cst_cofins',p.cst_cofins,'aliquota_icms',p.aliquota_icms)) order by iv.id),'[]'::jsonb) into i from public.itens_venda iv join public.produtos p on p.id=iv.produto_id and p.empresa_id=iv.empresa_id where iv.venda_id=p_venda_id and iv.empresa_id=e;
 return jsonb_build_object('venda',s,'emitente',c,'itens',i);
end;$$;
revoke all on function public.fiscal_nfe55_contexto(uuid) from public,anon;
grant execute on function public.fiscal_nfe55_contexto(uuid) to authenticated;

create function public.fiscal_nfe55_reservar(p_venda_id uuid,p_snapshot jsonb,p_revisao jsonb) returns public.fiscal_nfe55_emissoes
language plpgsql security definer set search_path='' as $$
declare e uuid:=private.exigir_empresa_ativa();n bigint;r public.fiscal_nfe55_emissoes;atual jsonb;c public.configuracoes_fiscais;
begin
 if not private.perm_alguma(array['fiscal']) then raise exception 'Permissão fiscal necessária.' using errcode='42501';end if;
 -- Mesmo lock da proteção NFC-e abaixo, em ambos os sentidos.
 perform pg_advisory_xact_lock(hashtextextended(e::text||p_venda_id::text,55));
 perform 1 from public.vendas where empresa_id=e and id=p_venda_id and cancelada_em is null for update;
 if not found then raise exception 'Venda indisponível ou cancelada.';end if;
 if exists(select 1 from public.fiscal_nfe55_emissoes where empresa_id=e and venda_id=p_venda_id) then raise exception 'Esta venda já tem uma tentativa NF-e. Consulte o resultado; não retransmita.';end if;
 if exists(select 1 from public.documentos_fiscais where empresa_id=e and venda_id=p_venda_id and tipo_documento in ('nfce','nfe') and status not in ('cancelada','rejeitada')) then raise exception 'Venda já vinculada a documento fiscal ativo.';end if;
 -- Rejeição não é prova de que outra tentativa remota inexiste: bloquear também identidade anterior.
 if exists(select 1 from public.documentos_fiscais where empresa_id=e and venda_id=p_venda_id and tipo_documento in ('nfce','nfe') and (numero is not null or chave_acesso is not null)) then raise exception 'Documento anterior numerado requer conciliação fiscal antes da NF-e.';end if;
 if octet_length(p_revisao::text)>300000 then raise exception 'Conferência excede o limite permitido.';end if;
 atual:=public.fiscal_nfe55_contexto(p_venda_id);
 if atual is distinct from p_snapshot then raise exception 'Venda ou cadastro mudou. Recarregue a conferência.';end if;
 select * into c from public.configuracoes_fiscais where empresa_id=e for update;
 if not found or c.nfe_numeracao_confirmada_em is null then raise exception 'Responsável deve conferir e salvar a numeração NF-e nas Configurações antes de emitir.';end if;
 -- Configuração pode ter mudado enquanto aguardava o lock.
 atual:=public.fiscal_nfe55_contexto(p_venda_id);
 if atual is distinct from p_snapshot then raise exception 'Venda ou configuração NF-e mudou. Recarregue a conferência.';end if;
 perform 1 from public.contadores_fiscais where empresa_id=e and tipo_documento='nfe' and serie=c.nfe_serie for update;
 if not found then raise exception 'Contador NF-e ausente. Confirme novamente a numeração nas Configurações.';end if;
 n:=private.nfe55_maior_numero(e,c.nfe_serie)+1;
 if n>999999999 then raise exception 'Numeração esgotada.';end if;
 update public.contadores_fiscais set ultimo_numero=n,atualizado_em=now() where empresa_id=e and tipo_documento='nfe' and serie=c.nfe_serie;
 update public.configuracoes_fiscais set nfe_ultimo_numero=n where empresa_id=e;
 insert into public.fiscal_nfe55_emissoes(empresa_id,venda_id,numero,serie,c_nf,usuario_id,snapshot,revisao)
 values(e,p_venda_id,n,c.nfe_serie,lpad(floor(random()*100000000)::bigint::text,8,'0'),auth.uid(),atual,p_revisao) returning * into r;
 return r;
end;$$;
revoke all on function public.fiscal_nfe55_reservar(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.fiscal_nfe55_reservar(uuid,jsonb,jsonb) to authenticated;

-- Exclusivo NF-e: reutiliza credenciais existentes sem gravar/rotacionar o token da NFC-e.
create function public.fiscal_nfe55_credencial(p_empresa_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.fiscal_credenciais;s text;
begin
 select * into r from public.fiscal_credenciais where empresa_id=p_empresa_id;
 if not found then raise exception 'Credencial fiscal não cadastrada.';end if;
 if r.dadosjah_token is not null and r.dadosjah_token_expires_at>now()+interval '2 minutes' then
  return jsonb_build_object('token',r.dadosjah_token);
 end if;
 select decrypted_secret into s from vault.decrypted_secrets where id=r.dadosjah_password_secret_id;
 if s is null or r.dadosjah_email is null then raise exception 'Credencial fiscal incompleta.';end if;
 return jsonb_build_object('email',r.dadosjah_email,'password',s);
end;$$;
revoke all on function public.fiscal_nfe55_credencial(uuid) from public,anon,authenticated;
grant execute on function public.fiscal_nfe55_credencial(uuid) to service_role;

create function private.nfe55_proteger_operacao() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.tipo_documento not in ('nfce','nfe') or new.status in ('cancelada','rejeitada') then return new;end if;
 perform pg_advisory_xact_lock(hashtextextended(new.empresa_id::text||new.venda_id::text,55));
 if exists(select 1 from public.fiscal_nfe55_emissoes where empresa_id=new.empresa_id and venda_id=new.venda_id) then
  raise exception 'Venda reservada para NF-e modelo 55. Consulte o Fiscal; outro documento não será emitido.';
 end if;
 return new;
end;$$;
revoke all on function private.nfe55_proteger_operacao() from public,anon,authenticated;
-- Não substitui nenhum trigger/função existente. Sem NF-e vinculada, retorna NEW sem modificações.
create trigger nfe55_proteger_operacao before insert or update of status on public.documentos_fiscais
for each row execute function private.nfe55_proteger_operacao();
create function private.nfe55_preservar_identidade() returns trigger
language plpgsql set search_path='' as $$
begin
 if row(new.id,new.empresa_id,new.venda_id,new.numero,new.serie,new.tp_amb,new.c_nf,new.dh_emissao,new.usuario_id,new.snapshot,new.revisao)
  is distinct from row(old.id,old.empresa_id,old.venda_id,old.numero,old.serie,old.tp_amb,old.c_nf,old.dh_emissao,old.usuario_id,old.snapshot,old.revisao) then
  raise exception 'Identidade e conferência NF-e são imutáveis.';
 end if;
 if old.payload is not null and new.payload is distinct from old.payload then raise exception 'Requisição NF-e original é imutável.';end if;
 if old.status='autorizada' and (new.status<>'autorizada' or new.chave_acesso is distinct from old.chave_acesso or new.protocolo is distinct from old.protocolo) then raise exception 'Autorização NF-e não pode ser rebaixada ou substituída.';end if;
 return new;
end;$$;
revoke all on function private.nfe55_preservar_identidade() from public,anon,authenticated;
create trigger nfe55_preservar_identidade before update on public.fiscal_nfe55_emissoes
for each row execute function private.nfe55_preservar_identidade();
commit;
