from pathlib import Path
import json,zlib,base64,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from exportar_origem import send
source=Path(__file__).with_name('replay.py').read_text();compile(source,'replay','exec');encoded=base64.b64encode(zlib.compress(source.encode())).decode()
code="import pathlib,base64,zlib,subprocess\np=pathlib.Path('/var/lib/florest-reserva/return-test/replay.py');p.write_bytes(zlib.decompress(base64.b64decode('"+encoded+"')));p.chmod(0o700)\nsubprocess.run(['python3',str(p)],check=True)"
print(send(["python3 - <<'FLOREST_REPLAY_TEST'\n"+code+'\nFLOREST_REPLAY_TEST'],'replay_return_test',180))
