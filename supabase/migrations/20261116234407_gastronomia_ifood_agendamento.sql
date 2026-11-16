-- Credencial interna gerada no servidor, nunca exposta ao navegador ou ao Git.
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM vault.secrets WHERE name='gastronomia_ifood_cron') THEN
  PERFORM vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),'gastronomia_ifood_cron');
 END IF;
END $$;
CREATE FUNCTION private.gastronomia_ifood_tick() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE segredo text;momento text;corpo jsonb:='{"acao":"cron"}'::jsonb;assinatura text;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.gastronomia_ifood_config WHERE habilitada AND ambiente='teste') THEN RETURN; END IF;
 SELECT decrypted_secret INTO segredo FROM vault.decrypted_secrets WHERE name='gastronomia_ifood_cron';
 momento:=floor(extract(epoch FROM clock_timestamp()))::bigint::text;
 assinatura:=encode(extensions.hmac(momento||':'||corpo::text,segredo,'sha256'),'hex');
 PERFORM net.http_post(url:='https://etulhyboogqhyyevpnlo.supabase.co/functions/v1/gastronomia-ifood',headers:=jsonb_build_object('Content-Type','application/json','x-ifood-worker',assinatura,'x-ifood-momento',momento),body:=corpo,timeout_milliseconds:=90000);
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_ifood_tick() FROM PUBLIC,anon,authenticated;
SELECT cron.schedule('gastronomia-ifood-poll','30 seconds','SELECT private.gastronomia_ifood_tick()');
NOTIFY pgrst,'reload schema';
