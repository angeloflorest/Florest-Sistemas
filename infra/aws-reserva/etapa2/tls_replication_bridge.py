"""Ponte PostgreSQL com TLS verificado em ambos os trechos; não registra payloads."""
import socket,ssl,struct,threading,json
from pathlib import Path
CONFIG=Path('/etc/florest-reserva-replication.json')
cfg=json.loads(CONFIG.read_text());semaphore=threading.BoundedSemaphore(8)
SSL_REQUEST=struct.pack('!II',8,80877103)
def transfer(a,b):
 try:
  while True:
   chunk=a.recv(65536)
   if not chunk:break
   b.sendall(chunk)
 except (OSError,ssl.SSLError):pass
 finally:
  for s in [a,b]:
   try:s.shutdown(socket.SHUT_RDWR)
   except OSError:pass

def connection(raw):
 upstream=None;client=None
 try:
  raw.settimeout(15);request=b''
  while len(request)<8:
   chunk=raw.recv(8-len(request))
   if not chunk:return
   request+=chunk
  if request!=SSL_REQUEST:return
  directory=Path(cfg['certificates'])
  certificates=sorted(directory.rglob(cfg['public_host']+'.crt'),key=lambda p:p.stat().st_mtime,reverse=True)
  if not certificates:raise RuntimeError('Certificado HTTPS não disponível')
  cert=certificates[0];key=cert.with_suffix('.key')
  ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.minimum_version=ssl.TLSVersion.TLSv1_2;ctx.load_cert_chain(str(cert),str(key))
  raw.sendall(b'S');client=ctx.wrap_socket(raw,server_side=True)
  upstream=socket.create_connection((cfg['source_host'],5432),timeout=15);upstream.sendall(SSL_REQUEST)
  if upstream.recv(1)!=b'S':raise RuntimeError('Origem não aceitou TLS')
  ctx=ssl.create_default_context(cafile=cfg['source_ca']);ctx.minimum_version=ssl.TLSVersion.TLSv1_2
  upstream=ctx.wrap_socket(upstream,server_hostname=cfg['source_host']);upstream.settimeout(600);client.settimeout(600)
  t=threading.Thread(target=transfer,args=(client,upstream),daemon=True);t.start();transfer(upstream,client);t.join(timeout=2)
 except (OSError,ssl.SSLError,RuntimeError):
  print('Conexão de replicação encerrada sem registrar credenciais ou consultas.',flush=True)
 finally:
  for s in [upstream,client,raw]:
   if s:
    try:s.close()
    except OSError:pass
  semaphore.release()
listener=socket.socket(socket.AF_INET,socket.SOCK_STREAM);listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listener.bind((cfg['listen_host'],15432));listener.listen(8)
print('Ponte PostgreSQL privada iniciada com verificação TLS.',flush=True)
while True:
 raw,_=listener.accept()
 if not semaphore.acquire(blocking=False):raw.close();continue
 threading.Thread(target=connection,args=(raw,),daemon=True).start()
