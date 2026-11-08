from pathlib import Path
import sys,zlib,base64
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from exportar_origem import send
source=Path(__file__).with_name('initialize_mirror.py').read_text();compile(source,'mirror_init','exec')
encoded=base64.b64encode(zlib.compress(source.encode())).decode()
code="import base64,zlib\nexec(compile(zlib.decompress(base64.b64decode('"+encoded+"')),'mirror_init','exec'))"
print(send(["python3 - <<'FLOREST_MIRROR_INIT'\n"+code+'\nFLOREST_MIRROR_INIT'],'initialize_live_mirror',900))
