from pathlib import Path
import base64,zlib,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from exportar_origem import send
text=Path(__file__).with_name('test_replay.py').read_text();compile(text,'replay_tests','exec');payload=base64.b64encode(zlib.compress(text.encode())).decode()
code="import base64,zlib\nexec(compile(zlib.decompress(base64.b64decode('"+payload+"')),'replay_tests','exec'))"
print(send(["python3 - <<'FLOREST_RETURN_TESTS'\n"+code+'\nFLOREST_RETURN_TESTS'],'return_replay_tests',360))
