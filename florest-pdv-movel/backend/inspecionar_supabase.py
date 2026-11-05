"""Read-only catalog retrieval using the configured Supabase management token.
Never puts credentials in command arguments, application configuration or output.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description='Inspecionar somente o esquema do projeto Supabase autorizado.')
    parser.add_argument('--project-ref', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9]{20}', args.project_ref):
        parser.error('Project ref inválido.')
    token = os.environ.get('SUPABASE_ACCESS_TOKEN')
    if not token:
        print('SUPABASE_ACCESS_TOKEN não está disponível nesta máquina. Configure o segredo no ambiente; não no aplicativo.', file=sys.stderr)
        return 2
    root = Path(__file__).resolve().parent
    query = (root/'INSPECIONAR_ESQUEMA_ATUAL.sql').read_text()
    request = urllib.request.Request(
        'https://api.supabase.com/v1/projects/'+args.project_ref+'/database/query',
        data=json.dumps({'query': query, 'read_only': True}).encode(),
        headers={'Authorization': 'Bearer '+token, 'Content-Type': 'application/json'}, method='POST')
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        print('API de gestão respondeu HTTP '+str(error.code)+'. Nenhuma alteração de banco foi solicitada.', file=sys.stderr)
        return 3
    except urllib.error.URLError:
        print('Não foi possível acessar api.supabase.com pela rede configurada. Nenhuma alteração foi solicitada.', file=sys.stderr)
        return 4
    if not isinstance(result, list) or len(result) != 1 or 'esquema_pdv_sem_dados' not in result[0]:
        print('Resposta inesperada do catálogo; interrompido sem alterações.', file=sys.stderr)
        return 5
    value = result[0]['esquema_pdv_sem_dados']
    catalog = json.loads(value) if isinstance(value, str) else value
    if not isinstance(catalog, dict) or not catalog.get('colunas') or not catalog.get('funcoes'):
        print('Catálogo incompleto; não autoriza preparar/aplicar migração.', file=sys.stderr)
        return 6
    output = root/'local'/'catalogo-atual.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2))
    output.chmod(0o600)
    print('Catálogo salvo localmente; '+str(len(catalog['colunas']))+' colunas e '+str(len(catalog['funcoes']))+' funções. Nenhum dado comercial consultado ou alterado.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
