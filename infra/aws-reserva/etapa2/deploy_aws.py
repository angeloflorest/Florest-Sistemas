"""Envia código sem segredos e prepara somente o backend privado de teste na ponte."""
import base64
import gzip
import io
from pathlib import Path
import sys
import tarfile
sys.path.insert(0,str(Path(__file__).resolve().parent.parent))
from exportar_origem import send

ROOT=Path(__file__).resolve().parent
def main():
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as tar:
        for relative in ['compose.yml','aws_bootstrap.py','aws_verify.py','gateway','functions','vendor/florest-login']:
            tar.add(ROOT/relative,arcname=relative,filter=lambda item:None if any(x.startswith('.') for x in Path(item.name).parts) else item)
    encoded=base64.b64encode(stream.getvalue()).decode()
    code=r'''import base64,io,tarfile,pathlib,subprocess,hashlib,json,os
root=pathlib.Path('/var/lib/florest-reserva/backend-preview');root.mkdir(mode=0o755,exist_ok=True)
data=base64.b64decode("'''+encoded+r'''")
with tarfile.open(fileobj=io.BytesIO(data),mode='r:gz') as tar:
 for member in tar.getmembers():
  destination=(root/member.name).resolve()
  if root not in destination.parents or member.issym() or member.islnk() or not(member.isfile() or member.isdir()):raise RuntimeError('Arquivo de implantação inválido')
  if member.isdir():destination.mkdir(parents=True,exist_ok=True,mode=0o755)
  else:
   destination.parent.mkdir(parents=True,exist_ok=True)
   destination.write_bytes(tar.extractfile(member).read());destination.chmod(0o644)
print('Pacote de backend enviado e verificado: '+hashlib.sha256(data).hexdigest(),flush=True)
subprocess.run(['python3',str(root/'aws_bootstrap.py')],check=True)
plugin=pathlib.Path('/usr/local/lib/docker/cli-plugins/docker-compose');plugin.parent.mkdir(parents=True,exist_ok=True)
if not plugin.exists():
 version='v2.40.3';base='https://github.com/docker/compose/releases/download/'+version+'/'
 binary=subprocess.run(['curl','--fail','--silent','--show-error','--location',base+'docker-compose-linux-x86_64'],capture_output=True,check=True).stdout
 sums=subprocess.run(['curl','--fail','--silent','--show-error','--location',base+'checksums.txt'],capture_output=True,text=True,check=True).stdout
 expected=next(line.split()[0] for line in sums.splitlines() if line.split()[-1].lstrip('*')=='docker-compose-linux-x86_64')
 if hashlib.sha256(binary).hexdigest()!=expected:raise RuntimeError('Checksum do Docker Compose inválido')
 plugin.write_bytes(binary);plugin.chmod(0o755)
subprocess.run(['docker','compose','version'],check=True)
build=subprocess.run(['docker','build','-t','florest-reserva-gateway:preview',str(root/'gateway')],env=dict(os.environ,DOCKER_BUILDKIT='0'),capture_output=True,text=True)
if build.returncode:
 print('Build do gateway falhou: '+build.stderr[-800:]);raise SystemExit(1)
command=['docker','compose','-p','florest-reserva-preview','--env-file',str(root/'.runtime/backend.env'),'-f',str(root/'compose.yml'),'up','-d','--no-build']
p=subprocess.run(command,cwd=str(root),capture_output=True,text=True)
if p.returncode:
 print('Implantação de contêineres falhou. Diagnóstico sem credenciais: '+p.stderr[-1200:]);raise SystemExit(1)
print('Backend privado de teste iniciado. Nenhum redirecionamento de produção realizado.',flush=True)
'''
    print('Tamanho do pacote:',len(stream.getvalue()),'bytes',flush=True)
    print(send(["python3 - <<'FLOREST_BACKEND_DEPLOY'\n"+code+'\nFLOREST_BACKEND_DEPLOY'],'backend_aws_deploy',900))

if __name__=='__main__':main()
