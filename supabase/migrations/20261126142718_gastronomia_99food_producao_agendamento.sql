-- Somente conexões de produção explicitamente autorizadas e habilitadas.
CREATE FUNCTION private.gastronomia_99food_producao_disparar() RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE instante text:=floor(extract(epoch FROM clock_timestamp()))::bigint::text;corpo text:=jsonb_build_object('acao','worker')::text;assinatura text;req bigint;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM private.gastronomia_99food_conexoes WHERE habilitada) THEN RETURN NULL;END IF;
 SELECT encode(extensions.hmac(instante||'.'||corpo,worker_segredo,'sha256'),'hex') INTO assinatura FROM private.gastronomia_99food_sandbox_runtime WHERE id;
 SELECT net.http_post(url:='https://etulhyboogqhyyevpnlo.supabase.co/functions/v1/gastronomia-99food',body:=corpo::jsonb,headers:=jsonb_build_object('Content-Type','application/json','x-99food-momento',instante,'x-99food-assinatura',assinatura),timeout_milliseconds:=55000) INTO req;
 RETURN req;
END $$;
REVOKE ALL ON FUNCTION private.gastronomia_99food_producao_disparar() FROM PUBLIC,anon,authenticated,service_role;
SELECT cron.schedule('gastronomia-99food-producao-worker','30 seconds',$job$SELECT private.gastronomia_99food_producao_disparar();$job$);
