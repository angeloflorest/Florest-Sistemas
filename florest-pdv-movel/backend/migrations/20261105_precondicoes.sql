do $guard$ begin
if md5(pg_get_functiondef('public.pdv_historico_detalhar(uuid)'::regprocedure))<>'a5393a9dd6ac0ff094547918ec82bc8d' then raise exception 'Contrato mudou: public.pdv_historico_detalhar. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('public.pdv_historico_listar(text, integer, integer)'::regprocedure))<>'e29b2d895bd8d86032835c42dc7f1858' then raise exception 'Contrato mudou: public.pdv_historico_listar. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('public.registrar_venda(uuid, text, jsonb, text)'::regprocedure))<>'800ee142b19c43a0e904b4095a4ec93b' then raise exception 'Contrato mudou: public.registrar_venda. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('private.taxas_registrar(text, uuid, jsonb)'::regprocedure))<>'159a4a84912f986004f4207c80323918' then raise exception 'Contrato mudou: private.taxas_registrar. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('private.caixa_vinculo_validar()'::regprocedure))<>'bf81f490235ed9a17e0f3a8bcbe0ed5d' then raise exception 'Contrato mudou: private.caixa_vinculo_validar. Reinspecione antes de aplicar.'; end if;
if md5(pg_get_functiondef('private.venda_mista_validar_pagamentos(jsonb)'::regprocedure))<>'1f5ac778e57c8f40ca399dce871e6e73' then raise exception 'Contrato mudou: private.venda_mista_validar_pagamentos. Reinspecione antes de aplicar.'; end if;
if to_regclass('public.pdv_movel_caixas') is not null or to_regclass('private.pdv_movel_operacoes') is not null then raise exception 'Objetos móveis já existem; verificar estado antes de reaplicar.'; end if;
end $guard$;
