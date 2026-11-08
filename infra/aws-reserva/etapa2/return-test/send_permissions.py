from pathlib import Path
import json,zlib,base64,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]))
from exportar_origem import send
root=Path(__file__).resolve().parent
payload={name:(root/name).read_text()for name in ['pair.sql','check_permissions.py']}
encoded=base64.b64encode(zlib.compress(json.dumps(payload).encode())).decode()
code="import pathlib,json,base64,zlib,sys\nroot=pathlib.Path('/var/lib/florest-reserva/return-test')\nfor name,text in json.loads(zlib.decompress(base64.b64decode('"+encoded+"'))).items():\n p=root/name;p.write_text(text);p.chmod(0o600)\nsys.path.insert(0,str(root));from replay import Replayer,SOURCE,TARGET\nr=Replayer()\nfor db in [SOURCE,TARGET]:r.query((root/'pair.sql').read_text(),db)\nexec(compile((root/'check_permissions.py').read_text(),str(root/'check_permissions.py'),'exec'))"
print(send(["python3 - <<'FLOREST_LAB_PERMISSIONS'\n"+code+'\nFLOREST_LAB_PERMISSIONS'],'check_lab_permissions',240))
