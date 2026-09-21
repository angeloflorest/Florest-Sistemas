-- ==========================================================
-- 003_politicas_rls.sql
-- PetGestor / ERP PETSHOP — Políticas RLS (Supabase)
--
-- Reconstrução fiel das 31 policies atualmente existentes, extraídas
-- diretamente do Supabase em produção. O arquivo 001_estrutura_banco.sql
-- já habilita RLS nas tabelas; este arquivo cuida somente das policies.
--
-- Não inclui tabelas, funções/RPCs, triggers, cron jobs ou dados.
-- ==========================================================


-- ---------- agendamentos ----------
drop policy if exists "Empresa cria os proprios agendamentos" on public.agendamentos;
create policy "Empresa cria os proprios agendamentos"
on public.agendamentos
as permissive
for INSERT
to authenticated
with check (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa edita os proprios agendamentos" on public.agendamentos;
create policy "Empresa edita os proprios agendamentos"
on public.agendamentos
as permissive
for UPDATE
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa ve os proprios agendamentos" on public.agendamentos;
create policy "Empresa ve os proprios agendamentos"
on public.agendamentos
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- clientes ----------
drop policy if exists "Empresa cria os proprios clientes" on public.clientes;
create policy "Empresa cria os proprios clientes"
on public.clientes
as permissive
for INSERT
to authenticated
with check (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa edita os proprios clientes" on public.clientes;
create policy "Empresa edita os proprios clientes"
on public.clientes
as permissive
for UPDATE
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa ve os proprios clientes" on public.clientes;
create policy "Empresa ve os proprios clientes"
on public.clientes
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- configuracoes_fiscais ----------
drop policy if exists "Empresa cria as proprias configuracoes fiscais" on public.configuracoes_fiscais;
create policy "Empresa cria as proprias configuracoes fiscais"
on public.configuracoes_fiscais
as permissive
for INSERT
to authenticated
with check (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa edita as proprias configuracoes fiscais" on public.configuracoes_fiscais;
create policy "Empresa edita as proprias configuracoes fiscais"
on public.configuracoes_fiscais
as permissive
for UPDATE
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa ve as proprias configuracoes fiscais" on public.configuracoes_fiscais;
create policy "Empresa ve as proprias configuracoes fiscais"
on public.configuracoes_fiscais
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- contadores_fiscais ----------
drop policy if exists "Empresa ve os proprios contadores fiscais" on public.contadores_fiscais;
create policy "Empresa ve os proprios contadores fiscais"
on public.contadores_fiscais
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- despesas ----------
drop policy if exists "Empresa apaga as proprias despesas" on public.despesas;
create policy "Empresa apaga as proprias despesas"
on public.despesas
as permissive
for DELETE
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa cria as proprias despesas" on public.despesas;
create policy "Empresa cria as proprias despesas"
on public.despesas
as permissive
for INSERT
to authenticated
with check (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa ve as proprias despesas" on public.despesas;
create policy "Empresa ve as proprias despesas"
on public.despesas
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- documentos_fiscais ----------
drop policy if exists "Empresa atualiza os proprios documentos fiscais" on public.documentos_fiscais;
create policy "Empresa atualiza os proprios documentos fiscais"
on public.documentos_fiscais
as permissive
for UPDATE
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa ve os proprios documentos fiscais" on public.documentos_fiscais;
create policy "Empresa ve os proprios documentos fiscais"
on public.documentos_fiscais
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- documentos_fiscais_eventos ----------
drop policy if exists "Empresa ve os proprios eventos fiscais" on public.documentos_fiscais_eventos;
create policy "Empresa ve os proprios eventos fiscais"
on public.documentos_fiscais_eventos
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- empresas ----------
drop policy if exists "Ver apenas a propria empresa" on public.empresas;
create policy "Ver apenas a propria empresa"
on public.empresas
as permissive
for SELECT
to authenticated
using (
  (id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- fornecedores ----------
drop policy if exists "Empresa ve os proprios fornecedores" on public.fornecedores;
create policy "Empresa ve os proprios fornecedores"
on public.fornecedores
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- itens_venda ----------
drop policy if exists "Empresa ve os proprios itens de venda" on public.itens_venda;
create policy "Empresa ve os proprios itens de venda"
on public.itens_venda
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- notas_entrada ----------
drop policy if exists "Empresa ve as proprias notas de entrada" on public.notas_entrada;
create policy "Empresa ve as proprias notas de entrada"
on public.notas_entrada
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- notas_entrada_itens ----------
drop policy if exists "Empresa ve os proprios itens de nota de entrada" on public.notas_entrada_itens;
create policy "Empresa ve os proprios itens de nota de entrada"
on public.notas_entrada_itens
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- pacote_usos ----------
drop policy if exists "Empresa ve os proprios usos de pacote" on public.pacote_usos;
create policy "Empresa ve os proprios usos de pacote"
on public.pacote_usos
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- pacotes_clientes ----------
drop policy if exists "Empresa ve os proprios pacotes" on public.pacotes_clientes;
create policy "Empresa ve os proprios pacotes"
on public.pacotes_clientes
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- perfis ----------
drop policy if exists "Ver o proprio perfil" on public.perfis;
create policy "Ver o proprio perfil"
on public.perfis
as permissive
for SELECT
to authenticated
using (
  (id = auth.uid())
);


-- ---------- pets ----------
drop policy if exists "Empresa cria os proprios pets" on public.pets;
create policy "Empresa cria os proprios pets"
on public.pets
as permissive
for INSERT
to authenticated
with check (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa edita os proprios pets" on public.pets;
create policy "Empresa edita os proprios pets"
on public.pets
as permissive
for UPDATE
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa ve os proprios pets" on public.pets;
create policy "Empresa ve os proprios pets"
on public.pets
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- produtos ----------
drop policy if exists "Empresa cria os proprios produtos" on public.produtos;
create policy "Empresa cria os proprios produtos"
on public.produtos
as permissive
for INSERT
to authenticated
with check (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa edita os proprios produtos" on public.produtos;
create policy "Empresa edita os proprios produtos"
on public.produtos
as permissive
for UPDATE
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);

drop policy if exists "Empresa ve os proprios produtos" on public.produtos;
create policy "Empresa ve os proprios produtos"
on public.produtos
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);


-- ---------- vendas ----------
drop policy if exists "Empresa ve as proprias vendas" on public.vendas;
create policy "Empresa ve as proprias vendas"
on public.vendas
as permissive
for SELECT
to authenticated
using (
  (empresa_id IN ( SELECT perfis.empresa_id
   FROM perfis
  WHERE (perfis.id = auth.uid())))
);
