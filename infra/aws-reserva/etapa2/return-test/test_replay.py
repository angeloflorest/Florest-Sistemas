"""Ensaios de transação, precisão, repetição e conflito em dados sintéticos privados."""
import json,uuid,pathlib,sys
sys.path.insert(0,'/var/lib/florest-reserva/return-test')
from replay import Replayer,ReplayError,BeforeImageConflict,SOURCE,TARGET
def main():
 r=Replayer();checks=[]
 def check(name,ok):
  checks.append({'test':name,'passed':bool(ok)})
  if not ok:raise RuntimeError('Falha no ensaio: '+name)
 ddl="CREATE TABLE IF NOT EXISTS contingencia_journal.fixture(id uuid PRIMARY KEY,quantity numeric(18,6),amount numeric(30,8),payload jsonb,tags text[],occurred_at timestamptz,raw bytea,note text);"
 for db in [SOURCE,TARGET]:r.query(ddl,db)
 r.query("DO $$BEGIN IF NOT EXISTS(SELECT FROM pg_trigger WHERE tgrelid='contingencia_journal.fixture'::regclass AND tgname='fixture_journal')THEN CREATE TRIGGER fixture_journal AFTER INSERT OR UPDATE OR DELETE ON contingencia_journal.fixture FOR EACH ROW EXECUTE FUNCTION contingencia_journal.capture();END IF;END$$;")
 a,b,rolled=[str(uuid.uuid4())for _ in range(3)]
 r.query("BEGIN;INSERT INTO contingencia_journal.fixture(id,note)VALUES('"+rolled+"','rollback');ROLLBACK;")
 check('Transação desfeita não deixa evento para retransmitir',r.query("SELECT count(*)FROM contingencia_journal.event WHERE new_row->>'id'='"+rolled+"';")=='0')
 value='1234567890123456789012.12345678'
 r.query("BEGIN;INSERT INTO contingencia_journal.fixture(id,quantity,amount,payload,tags,occurred_at,raw,note)VALUES('"+a+"',1.234567,"+value+",'{\"texto\":\"ação com apóstrofo: d’água\",\"vazio\":null}',ARRAY['a','b,c'],'2026-11-08T14:00:00Z',decode('00ff01','hex'),'initial'),('"+b+"',2.000001,9.99,'{}',ARRAY[]::text[],now(),decode('aabb','hex'),'initial');COMMIT;")
 first=r.run();check('Eventos confirmados são transferidos para o retorno isolado',first['pending_transactions']==0 and first['changed_rows']>=2)
 check('NUMERIC de 30 dígitos preservado sem conversão para ponto flutuante',r.query("SELECT amount::text FROM contingencia_journal.fixture WHERE id='"+a+"';",TARGET)==value)
 source_hash=r.query("SELECT md5(to_jsonb(t)::text)FROM contingencia_journal.fixture t WHERE id='"+a+"';")
 check('JSON, Unicode, array, timestamp e bytea preservados',r.query("SELECT md5(to_jsonb(t)::text)FROM contingencia_journal.fixture t WHERE id='"+a+"';",TARGET)==source_hash)
 second=r.run();check('Repetir a transmissão não duplica registros',second['changed_rows']==0 and second['pending_transactions']==0)
 # Simular perda da confirmação depois de o destino já ter confirmado o commit.
 r.query("DELETE FROM contingencia_journal.delivery d USING contingencia_journal.event e WHERE d.origin=e.origin AND d.event_id=e.event_id AND e.schema_name='contingencia_journal'AND e.table_name='fixture'AND e.new_row->>'id'IN('"+a+"','"+b+"')AND d.target='"+r.state['target_instance']+"';")
 repeat=r.run();check('Perda de confirmação não repete a gravação no destino',repeat['changed_rows']==0 and repeat['pending_transactions']==0)
 # Uma transação altera duas linhas; divergência na segunda deve desfazer a primeira.
 r.query("BEGIN;UPDATE contingencia_journal.fixture SET note='after'WHERE id='"+a+"';UPDATE contingencia_journal.fixture SET note='after'WHERE id='"+b+"';COMMIT;")
 r.query("UPDATE contingencia_journal.fixture SET note='divergent'WHERE id='"+b+"';",TARGET)
 conflict=r.run();check('Divergência é recusada sem sobrescrever o destino',bool(conflict['conflicts']) and r.query("SELECT note FROM contingencia_journal.fixture WHERE id='"+b+"';",TARGET)=='divergent')
 check('Conflito desfaz a transação inteira, inclusive a primeira linha',r.query("SELECT note FROM contingencia_journal.fixture WHERE id='"+a+"';",TARGET)=='initial')
 r.query("UPDATE contingencia_journal.fixture SET note='initial'WHERE id='"+b+"';",TARGET)
 recovered=r.run();check('Retorno prossegue após resolver a divergência do ensaio',not recovered['conflicts']and recovered['pending_transactions']==0 and r.query("SELECT count(*)FROM contingencia_journal.fixture WHERE id IN('"+a+"','"+b+"')AND note='after';",TARGET)=='2')
 r.query("DELETE FROM contingencia_journal.fixture WHERE id IN('"+a+"','"+b+"');")
 deleted=r.run();check('Exclusão confirmada é transmitida uma única vez',deleted['pending_transactions']==0 and r.query("SELECT count(*)FROM contingencia_journal.fixture WHERE id IN('"+a+"','"+b+"');",TARGET)=='0')
 check('Diário inacessível ao usuário comum',r.query("SELECT has_schema_privilege('authenticated','contingencia_journal','USAGE');",TARGET)=='f')
 proof={'all_passed':all(x['passed']for x in checks),'tests':checks,'source':SOURCE,'target':TARGET,'supabase_updated':False,'production_failback_ready':False}
 p=pathlib.Path('/var/lib/florest-reserva/return-test/replay-test-proof.json');p.write_text(json.dumps(proof,indent=2));p.chmod(0o600);print(json.dumps(proof),flush=True)

if __name__=='__main__':main()
