"""Prepara apenas a cópia web de teste, baseada no main atual e sem chaves privadas."""
from pathlib import Path
import hashlib,json,subprocess
ROOT=Path(__file__).resolve().parent
REPO=Path(__file__).resolve().parents[3]
def git(*args):return subprocess.check_output(['git','-C',str(REPO),*args])
sha=git('rev-parse','origin/main').decode().strip()
files=[]
for name in git('ls-tree','-r','--name-only',sha,'florest-erp/sistema').decode().splitlines():
 relative=name.removeprefix('florest-erp/sistema/')
 if Path(relative).suffix not in ['.html','.js','.css','.png','.webp','.jpg','.jpeg','.svg','.ico']:continue
 data=git('show',sha+':'+name)
 files.append({'path':relative,'sha256':hashlib.sha256(data).hexdigest()})
(ROOT/'web-source-manifest.json').write_text(json.dumps({'sha':sha,'files':files},indent=2))
print(json.dumps({'main_sha':sha,'web_files':len(files)}))
