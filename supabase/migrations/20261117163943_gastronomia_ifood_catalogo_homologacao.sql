-- Ajuste dos nomes oficiais das opções de prazo do Handshake.
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_resposta(jsonb,text,jsonb)'::regprocedure);
src:=replace(src,'alt#>''{metadata,additionalTimeInMinutes}''','alt#>''{metadata,allowedsAdditionalTimeInMinutes}''');src:=replace(src,'alt#>''{metadata,reasons}''','alt#>''{metadata,allowedsAdditionalTimeReasons}''');EXECUTE src;
END $fix$;
-- Uma solicitação assinada por transação/empresa, enviada pelo pg_net após o commit.
-- Este acionamento não consulta eventos nem altera o intervalo de polling.
CREATE FUNCTION private.gastronomia_ifood_catalogo_disparar(e uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $fn$
DECLARE segredo text;momento text;corpo jsonb;assinatura text;BEGIN
 IF e<>'773dfacb-c0e7-4bd9-8eb4-5208818b1848' OR NOT EXISTS(SELECT 1 FROM private.gastronomia_ifood_config WHERE empresa_id=e AND habilitada AND ambiente='teste' AND merchant_id='9dc78f12-d874-4d66-a454-40268effa19d') OR NOT EXISTS(SELECT 1 FROM private.gastronomia_ifood_catalogo WHERE empresa_id=e AND estado='pendente') OR current_setting('ifood.catalogo_disparado',true)=e::text THEN RETURN;END IF;
 SELECT decrypted_secret INTO segredo FROM vault.decrypted_secrets WHERE name='gastronomia_ifood_cron';IF segredo IS NULL THEN RETURN;END IF;
 PERFORM set_config('ifood.catalogo_disparado',e::text,true);
 corpo:=jsonb_build_object('acao','cron','catalogo_empresa',e);momento:=floor(extract(epoch FROM clock_timestamp()))::bigint::text;assinatura:=encode(extensions.hmac(momento||':'||corpo::text,segredo,'sha256'),'hex');
 PERFORM net.http_post(url:='https://etulhyboogqhyyevpnlo.supabase.co/functions/v1/gastronomia-ifood',headers:=jsonb_build_object('Content-Type','application/json','x-ifood-worker',assinatura,'x-ifood-momento',momento),body:=corpo,timeout_milliseconds:=90000);
END $fn$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_catalogo_disparar(uuid) FROM PUBLIC,anon,authenticated;
DO $fix$ DECLARE src text;BEGIN
src:=pg_get_functiondef('private.gastronomia_ifood_catalogo_enfileirar(uuid)'::regprocedure);
IF strpos(src,'''nome'',r.nome,''preco''')=0 THEN RAISE EXCEPTION 'Payload de catálogo divergente';END IF;
src:=replace(src,'''nome'',r.nome,''preco''','''nome'',r.nome,''descricao'',coalesce(r.menu->>''descricao'',''''),''contextos'',coalesce(r.menu->''ifood_contextos'',''[]''),''preco''');
src:=replace(src,'END LOOP;','END LOOP; PERFORM private.gastronomia_ifood_catalogo_disparar(p_empresa);');EXECUTE src;
src:=pg_get_functiondef('public.gastronomia_ifood_catalogo_worker(text,uuid,jsonb)'::regprocedure);IF strpos(src,'LIMIT 30')=0 THEN RAISE EXCEPTION 'Limite da fila divergente';END IF;EXECUTE replace(src,'LIMIT 30','LIMIT 100');
END $fix$;
-- Snapshot somente dos itens já confirmados, sem republicar nem mudar seleção/preço.
UPDATE private.gastronomia_ifood_catalogo SET remoto=coalesce(remoto,'{}')||jsonb_build_object('fonte',payload) WHERE empresa_id='773dfacb-c0e7-4bd9-8eb4-5208818b1848' AND estado='publicado';
DO $fix$ DECLARE src text;sig text;BEGIN
FOREACH sig IN ARRAY ARRAY['private.gastronomia_ifood_painel(uuid)','public.gastronomia_pedidos_data(date,uuid)'] LOOP
src:=pg_get_functiondef(sig::regprocedure);src:=replace(src,'''acao'',acao,''estado'',estado','''acao'',acao,''estado'',estado,''payload'',jsonb_build_object(''disputeId'',payload->>''disputeId'')');EXECUTE src;END LOOP;
END $fix$;
