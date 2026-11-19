# Conferência e vínculo de produtos nas Notas de Entrada

A importação resolve primeiro o GTIN e depois os vínculos existentes por fornecedor/código, antes de montar a prévia. A unidade de estoque vem do produto vinculado. Quantidade, unidade e valores fiscais do XML permanecem preservados; fator e quantidade de estoque são informados separadamente e diferenças exigem confirmação do operador.

A consulta `notas_entrada_produtos_vinculados` é somente leitura, limitada a 100 códigos por lote, com permissão de notas de entrada e isolamento pela empresa ativa. Não cria vínculos, não muda unidades e não lança notas. Quando já existe vínculo de fornecedor, selecionar cadastro novo exige escolher explicitamente um produto para impedir nova resolução silenciosa na confirmação.

O servidor continua rejeitando unidades divergentes. A mensagem identifica item, produto, unidade cadastrada e unidade enviada. Não remove a validação nem deduz fatores por descrição ou peso no nome.

Arquivos: `notas-entrada.js`, seção Notas de Entrada de `index.html`, migração `20261119155832_notas_entrada_vinculo_previo.sql`.

Testes: `tests/notas-entrada-vinculos.test.cjs` (Node), `tests/notas-entrada-conversao.browser.cjs` (Playwright), `tests/notas-entrada-vinculos.db.cjs` (PGlite). O teste de banco reproduz a divergência e verifica rollback integral, entrada corrigida em ambiente isolado, preservação fiscal, proteção contra duplicidade e isolamento por empresa. Nenhuma nota real é confirmada pelos testes.
