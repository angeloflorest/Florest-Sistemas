import os,json,urllib.request
q="""BEGIN;
GRANT USAGE ON SCHEMA realtime,supabase_migrations,extensions TO florest_reserva_repl;
GRANT SELECT ON ALL TABLES IN SCHEMA realtime,supabase_migrations TO florest_reserva_repl;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA realtime,supabase_migrations TO florest_reserva_repl;
DO $x$ BEGIN
 IF EXISTS(SELECT FROM pg_publication WHERE pubname='florest_reserva_publication_20261108')THEN
  IF obj_description((SELECT oid FROM pg_publication WHERE pubname='florest_reserva_publication_20261108'),'pg_publication')IS DISTINCT FROM 'Florest reserve managed 20261108'THEN RAISE EXCEPTION 'Publicação existente sem autoria';END IF;
 ELSE
  CREATE PUBLICATION florest_reserva_publication_20261108 FOR TABLES IN SCHEMA public,private,auth,storage;
  COMMENT ON PUBLICATION florest_reserva_publication_20261108 IS 'Florest reserve managed 20261108';
 END IF;
END $x$;
COMMIT;"""
req=urllib.request.Request('https://api.supabase.com/v1/projects/etulhyboogqhyyevpnlo/database/query',data=json.dumps({'query':q,'read_only':False}).encode(),headers={'Authorization':'Bearer '+os.environ['SUPABASE_ACCESS_TOKEN'],'Content-Type':'application/json'})
with urllib.request.urlopen(req,timeout=45)as r:json.load(r)
print('Publicação exclusiva criada; não altera vendas, usuários ou políticas do ERP.')
