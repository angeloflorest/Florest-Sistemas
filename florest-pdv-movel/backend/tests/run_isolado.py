"""Only uses the locally created florest-mobile-pg Docker container and synthetic DB."""
from pathlib import Path
import re
import subprocess
root=Path(__file__).resolve().parent
D=['docker','--host=unix:///var/run/docker.sock','exec','-i','florest-mobile-pg']
# This dedicated database contains only fixtures from this test script.
subprocess.run(D+['dropdb','-U','postgres','--if-exists','mobile_test'],check=True)
subprocess.run(D+['createdb','-U','postgres','mobile_test'],check=True)
base=(root/'base_isolada.sql').read_text().replace('create role anon nologin; create role authenticated nologin;','')
roles="do $$begin if not exists(select 1 from pg_roles where rolname='anon') then create role anon nologin; end if; if not exists(select 1 from pg_roles where rolname='authenticated') then create role authenticated nologin; end if; end$$;\n"
migration=(root.parent/'migrations/20261105_pdv_movel.sql').read_text()
# The live contract guard is checked read-only on Supabase separately. Local helper
# stubs intentionally have different hashes; only skip this guard in this fixture DB.
migration=re.sub(r'do \$guard\$.*?end \$guard\$;', '', migration, flags=re.S)
sql=roles+base+(root/'funcoes_inspecionadas.sql').read_text()+migration+(root/'transacoes.sql').read_text()+(root/'permissoes.sql').read_text()
r=subprocess.run(D+['psql','-U','postgres','-d','mobile_test','-v','ON_ERROR_STOP=1'],input=sql,text=True,capture_output=True)
if r.returncode:
 print(r.stderr[-4000:]);raise SystemExit(r.returncode)
print(r.stderr.strip())
subprocess.run(['python3',str(root/'concorrencia.py')],check=True)
print('SQL transacional e concorrência passaram no banco sintético isolado.')
