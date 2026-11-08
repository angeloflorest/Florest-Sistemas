from pathlib import Path
import json,zlib,base64,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from exportar_origem import send
root=Path(__file__).resolve().parent
payload={name:(root/name).read_text()for name in ['journal.sql','apply.sql','prepare.py']}
for name in ['prepare.py']:compile(payload[name],name,'exec')
encoded=base64.b64encode(zlib.compress(json.dumps(payload).encode())).decode()
code="import pathlib,json,base64,zlib\nroot=pathlib.Path('/var/lib/florest-reserva/return-test');root.mkdir(mode=0o700,exist_ok=True)\nfor name,text in json.loads(zlib.decompress(base64.b64decode('"+encoded+"'))).items():\n p=root/name;p.write_text(text);p.chmod(0o600)\nexec(compile((root/'prepare.py').read_text(),str(root/'prepare.py'),'exec'))"
print(send(["python3 - <<'FLOREST_RETURN_PREPARE'\n"+code+'\nFLOREST_RETURN_PREPARE'],'prepare_return_test',900))
