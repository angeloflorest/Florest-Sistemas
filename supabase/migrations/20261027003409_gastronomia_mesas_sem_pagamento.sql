-- Aplicação autorizada pelo proprietário em 26/10/2026.
-- Finalidade única: dispensar forma de pagamento nos tokens vinculados a mesa.
-- Entrega/retirada mantêm a validação atual. Não cria tabelas, não registra pagamentos.
-- Migration incremental: compatibilidade conferida com a definição real instalada.
BEGIN;
DO $correcao$
DECLARE original text; atualizado text;
BEGIN
 IF to_regprocedure('public.gastronomia_cardapio_publico(text,text,jsonb,uuid)') IS NULL THEN
  RAISE EXCEPTION 'RPC do Cardápio Digital ausente. Não aplicar parcialmente.';
 END IF;
 original:=pg_get_functiondef('public.gastronomia_cardapio_publico(text,text,jsonb,uuid)'::regprocedure);
 IF md5(original)<>'562cdee31390ac0307bf2571690c7e49' THEN
  RAISE EXCEPTION 'RPC público mudou desde a base da Central. Conferir compatibilidade; não remover a guarda.';
 END IF;
 atualizado:=replace(original,$antes$IF d->>'forma' IS NULL OR d->>'forma' NOT IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito') THEN RAISE EXCEPTION 'Escolha a forma de pagamento.'; END IF;$antes$,$depois$IF l.mesa_id IS NULL AND (d->>'forma' IS NULL OR d->>'forma' NOT IN ('Dinheiro','Pix','Cartão de Débito','Cartão de Crédito')) THEN RAISE EXCEPTION 'Escolha a forma de pagamento.'; END IF;$depois$);
 IF atualizado=original THEN RAISE EXCEPTION 'Validação esperada não encontrada. Interrompendo sem alterações.'; END IF;
 EXECUTE atualizado;
 -- CREATE OR REPLACE preserva proprietário e ACL. Nenhuma guarda, trigger ou rotina é removida.
END $correcao$;
COMMIT;
