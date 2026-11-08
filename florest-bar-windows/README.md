# Florest Bar Windows 1.0.0

Aplicativo x64 que empacota o Módulo Bar de `florest-erp/sistema/index.html`, sem redesenhar suas telas. A fonte usada foi a main `08bd2958f8ab49e7f6d7a205b3cf72e449412e84`; o build registra também o SHA-256 do HTML em `src/renderer/reference.json`.

## Interface e operação

Mesas, Caixa, Histórico, Produto Composto, Garçons, Relatórios e Configurações usam o HTML, CSS e funções originais. A entrada fica restrita ao Bar. Os outros módulos não são oferecidos na navegação. O ERP, o PDV Windows, o Gastronomia, o PET e o aplicativo Android não foram alterados.

O SDK Supabase é distribuído localmente. A sessão continua no Supabase Auth; credenciais persistidas ficam protegidas pelo safeStorage/DPAPI do Windows. Todas as operações online usam o token do operador e as RPCs/RLS existentes. O cache SQLite e os rascunhos são separados por empresa e operador. Respostas de uma sessão anterior são recusadas após a troca de usuário.

## Garçom e sincronização

O Florest Garçom continua enviando ao mesmo Supabase e às mesmas mesas. O Windows preserva o Realtime do original e acrescenta consulta silenciosa a cada cinco segundos, evitando atualizar durante recebimento ou digitação em modal. Não existe outra base central, outro Garçom nem outra fila de impressão.

## Offline e conciliação

Consultas previamente recebidas, produtos/preços carregados e rascunhos de pedidos ficam disponíveis localmente. Os rascunhos são persistidos por mesa e operador e podem ser retomados depois de reiniciar. A autorização local depende da última sessão validada; a cópia autenticada tem limite de 24 horas e não substitui a validação do servidor quando a conexão existe.

Pagamento novo, lançamento em mesa compartilhada, fechamento, transferência, junção, estorno e alterações administrativas são bloqueados sem conexão. Esses atos não podem ser conciliados silenciosamente com outros terminais. Isso não é venda integral offline.

A solicitação iniciada online é gravada antes do envio. Recebimentos idempotentes sem resposta podem ser confirmados com a MESMA chave; nunca recebem outra chave durante recuperação. A confirmação automática permanece disponível para o operador recuperar o resultado sem receber novamente.

Pedidos com resposta perdida são conciliados SOMENTE por consulta ao pedido original, empresa, operador, mesa e chave. Nunca são reenviados automaticamente: a mesa pode ter sido fechada e reutilizada. Se o pedido existe, a recuperação limpa o rascunho e pede conferência da mesa atual; não imprime novamente. Se não houver confirmação segura, a pendência permanece para conferência no ERP/suporte. Não há botão para apagar pendências.

Senhas de cadastro de garçom e tokens não são gravados no diário de operações. A fila contém solicitações operacionais sem os cabeçalhos privados.

## Fiscal

Usa a opção `configuracoes_fiscais.emite_nota_fiscal` e o fluxo original com Dados Jah. O aplicativo não tem outro emissor. A emissão de NFC-e offline/contingência é bloqueada no Windows; a venda e o tratamento posterior continuam no ERP. Quando a configuração está desmarcada, o original não apresenta a pergunta fiscal.

## Print Agent e modelos

O instalador principal inclui o Print Agent 1.3.0 derivado do agente existente 1.2.0 Montserrat. Mantém AppId, serviço, mutex, IPC, diretórios, credenciais, impressoras, reserva atômica de jobs e diário de impressões. A instalação oferece instalar/atualizar apenas se não encontrar versão compatível; o instalador existente faz a atualização no lugar. Não instala dois serviços. O agente tem instalador separado.

Depois da instalação, o pareamento continua no Tray/ERP e a escolha dos destinos continua na aba Impressoras original do Bar. A instalação não pareia automaticamente uma empresa nem troca impressoras.

Os modelos são JSON declarativos, schema 1, separados do programa. O menu nativo Florest Bar → Atualizar modelos de impressão abre o importador do Print Agent 1.3.0 (`FlorestPrintAgent.Tray.exe --modelos`). O Windows solicita elevação para gravar na pasta protegida do agente. Selecione o pacote JSON desejado. O serviço lê o modelo local no próximo trabalho, sem reiniciar e sem recompilar o Bar.

O pacote exemplo está em `resources/modelos-1.0.0.json`. Cada modelo tem Kind e Version próprios. A importação mescla somente os tipos recebidos, guarda a versão anterior em histórico e recusa downgrade ou reutilização de versão com conteúdo diferente. Tipos: pedido_bar, bar, cozinha, recibo, relatorio_mesa e teste. Campos independentes nesta versão: Font (Montserrat, Arial, Tahoma, Consolas ou Courier New), Pixels (12–40), LineGap (0–16) e CenterHeaders. O padrão preserva o desenho Montserrat anterior. Mudanças de regras/conteúdo, diferentemente de ajustes visuais suportados, exigem atualização do agente.

## Atualizações e compilação

Bar, Print Agent e modelos têm entregas separadas. A atualização do Bar é sob demanda, usa electron-updater, checksum SHA-512, bloqueio durante atendimento e backup SQLite antes de instalar. Não apaga userData. A publicação futura deve usar canal `bar` e tag SemVer com pré-release `bar` (ex.: `v1.0.1-bar.1`), acompanhada de `bar.yml`, EXE e blockmap. O canal evita confundir atualizações do Bar com outros aplicativos deste repositório.

Build: Node 22, `npm ci --ignore-scripts`, `node node_modules/electron/install.js`, `npm run prepare:ui`, `npm run check`, `npm test`, testes de interface e `npm run build:win`. Compile o Print Agent existente com .NET 8 self-contained win-x64 e Inno Setup antes do Bar; copie seu EXE para resources/print-agent.exe e atualize o SHA-256 de resources/print-agent.json. O usuário final não precisa de Node, Python ou SDKs.

## Validação e limites

Foram executados testes automatizados de SQLite/transporte, regressões do código Bar, comparação visual com dados simulados e os 546 testes do Print Agent. O modal da mesa e as sete abas do Windows produziram capturas idênticas às da referência com os mesmos dados.

Os testes automatizados não substituem homologação real. A conta informada é bar@gmail.com / angelo; nenhuma senha foi recebida. Login real, mesas compartilhadas com Android/navegador, instalação/atualização no perfil do cliente e impressão física precisam ser concluídos com o operador. O ambiente informado não possui impressora. O controle de janelas desta sessão falhou com "failed to write kernel assets". Não declarar esses testes como realizados.

Nenhuma mudança foi aplicada ao Supabase de produção. Não publicar no portal ou em Releases antes da homologação e da autorização correspondente.

A preparação remove do template DANFE uma inclusão indevida de `gastronomia-fotos.js` adicionada na main, cujo fechamento interrompe o módulo HTML. O arquivo original do ERP permanece intacto.
