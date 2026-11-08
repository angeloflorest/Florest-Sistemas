from pathlib import Path
import sys,zlib,base64
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from exportar_origem import send
source=Path(__file__).with_name('monitor_mirror.py').read_text();compile(source,'mirror_monitor','exec')
encoded=base64.b64encode(zlib.compress(source.encode())).decode()
code="import base64,zlib,pathlib\np=pathlib.Path('/var/lib/florest-reserva/replication/monitor_mirror.py');p.write_bytes(zlib.decompress(base64.b64decode('"+encoded+"')));p.chmod(0o700)\nexec(compile(p.read_text(),str(p),'exec'))"
print(send(["python3 - <<'FLOREST_MIRROR_MONITOR'\n"+code+'\nFLOREST_MIRROR_MONITOR'],'monitor_live_mirror',150))
