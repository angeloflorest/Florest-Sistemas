# Florest Print Agent (Windows) — versão 1.2.0 (cupom da cozinha sem nº do pedido + relatório da mesa)

Programa Windows que liga um computador (com impressoras) ao **Florest ERP**.
Esta versão faz: instalar, identificar o computador, **parear com o ERP**, guardar a credencial com segurança,
enviar **heartbeat**, **detectar as impressoras reais do Windows** e **sincronizá-las** com o ERP.

> **Continua fora do escopo:** impressão fiscal/DANFE/NFC-e (o recibo do Caixa é NÃO fiscal), descoberta ativa de
> impressoras de rede não instaladas e atualização automática. A impressão de pedidos (Bar/Cozinha) e do recibo do
> Caixa existe a partir da 1.1.0 (veja a seção abaixo).

---

## NOVO NA 1.2.0 — cupom da cozinha/bar e relatório da mesa

Somente o **desenho do papel** mudou (`TicketBuilder`/`TicketData`); pareamento, heartbeat, fila, spooler, diário e Tray são os mesmos da 1.1.0.

1. **Cupom de cozinha/bar:** o número do pedido não é mais impresso (nem no cabeçalho nem no rodapé); fica só `MESA 41`. O campo `pedido`
   do payload, se vier, é ignorado. A **observação do produto** sai em negrito, letra de dupla altura e vídeo reverso (a largura não muda).
2. **Novo tipo de papel `relatorio_mesa`** (destino Caixa): relatório de conferência da mesa ABERTA, com empresa, mesa, data/hora, itens
   (quantidade, preço unitário, total, observações, escolhas), subtotal, desconto, acréscimo, taxa, total, já pago/falta pagar (quando houver
   pagamento parcial) e o rodapé `RELATÓRIO DA MESA - NÃO É DOCUMENTO FISCAL`. Não é recibo, não registra pagamento e não é fiscal.
3. Travessão/meia-risca (— –) viram hífen na impressão (a página de código 860 não tem esses caracteres).

**Compatibilidade:** um agente 1.1.0 recusa o tipo `relatorio_mesa` ("Tipo de impressão desconhecido"). Por isso a Migration 047 só enfileira o
relatório quando o agente ativo da impressora do Caixa informa versão **1.2.0 ou maior**; senão o ERP avisa para atualizar o agente.
O cupom da cozinha sem número já funciona com o agente 1.1.0 (basta a Migration 047); só a observação maior/negrito exige o 1.2.0.

---

## NOVO NA 1.1.0 — o agente imprime (Bar / Cozinha / Caixa)

A partir da 1.1.0 o **Serviço** (não o Tray, não o navegador) recebe os pedidos e imprime. Continua valendo tudo da 1.0.0
(pareamento, heartbeat, descoberta/sincronização de impressoras, Tray, Named Pipe); nada disso foi alterado.

Fluxo: ERP lança o item → o banco gera um *job* por destino (`impressao_jobs`, Migration 033) → o Serviço consulta
(`/agent/jobs/claim`, long-poll de 15 s, credencial do agente) → o servidor **reserva** o job de forma atômica e informa a
impressora do destino **desta estação** → o Serviço monta o ticket ESC/POS e envia **RAW** ao spooler do Windows
(impressora indicada pelo ERP; **nunca** a padrão do Windows) → só depois de o Windows aceitar e a fila não indicar
erro/offline/sem papel é que confirma `impresso` (`/agent/jobs/complete`). Falha → `/agent/jobs/fail` (nova tentativa com
espera crescente: 15 s, 30 s, 1 min, 2 min, 5 min; até 5 tentativas; depois `falhou` com o erro registrado).

Garantias: a empresa e a estação **nunca** são enviadas pelo agente — saem da credencial, no banco; um agente só enxerga e
só confirma jobs da própria empresa/estação. Entrega "pelo menos uma vez": se a internet cair entre "imprimiu" e
"confirmei", o job fica num diário local (`data\impressoes-pendentes.json`, só id e hora) e é confirmado depois **sem
reimprimir**. Nenhum token/segredo vai para o log.

Ajustes opcionais do papel: `C:\ProgramData\Florest Sistemas\Print Agent\data\impressao.json` (somente Administradores):

```json
{ "colunas": 48, "pagina_codigo": 860, "cortar": true,
  "impressoras": { "COZINHA": { "colunas": 32 }, "Bar 58mm": { "colunas": 32, "pagina_codigo": 850, "cortar": false } } }
```

Padrão: bobina de 80 mm (48 colunas), ESC/POS, página de código 860 (Português), corte parcial.
Limitação: o Serviço (LocalSystem) enxerga impressoras **locais** (USB, TCP/IP, compartilhadas já instaladas na máquina).
Impressoras de rede mapeadas só dentro da sessão de um usuário aparecem no Tray, mas o Serviço não consegue imprimir nelas:
instale-as como impressora local (porta TCP/IP) ou conexão para todos os usuários.

Build + publicação num comando só: `.\scripts\build-and-publish.ps1` (restaura, compila, testa e publica `dist\app` completa
+ `dist\FlorestPrintAgent-1.1.0-app.zip`). Instalar/atualizar no cliente: `scripts\install-service.ps1` (Administrador).

---

## INSTALAÇÃO DEFINITIVA (instalar uma vez) — revisão 2 da 1.1.0

No cliente: **`FlorestPrintAgent-Setup-1.1.0.exe` → instalar → parear empresa/estação no Tray → escolher as impressoras no
ERP → pronto.** Sem PowerShell, sem CMD, sem abrir o `Service.exe`, sem configurar de novo.

Depois da instalação, **todo dia**: o cliente liga o computador → o Windows inicia o serviço sozinho (Automático) → o serviço
lê o que está em `ProgramData` (identidade, vínculo, credencial protegida) → autentica → sincroniza → consulta a fila → imprime.
Ninguém precisa abrir o Tray. Se o roteador ainda não respondeu, o serviço **não encerra**: registra "sem conexão", tenta de novo
com espera crescente (5 s até 60 s) e retoma sozinho quando a internet volta.

| O quê | Onde / como |
|---|---|
| Binários | `C:\Program Files\Florest Sistemas\Print Agent\` (o instalador pode ser apagado depois) |
| Dados persistentes | `C:\ProgramData\Florest Sistemas\Print Agent\data\` — `instalacao.json` (identidade), `credencial.dpapi` (credencial), `estado.json` (empresa/estação), `impressoes-pendentes.json` (diário), `impressao.json` (ajustes opcionais); logs em `...\logs\` |
| Credencial | DPAPI com escopo **LocalMachine** (+ entropia do aplicativo) e ACL SYSTEM/Administradores. **Só o Serviço** lê e grava; o Tray nunca toca nela (o pareamento é feito pelo Tray, mas quem recebe e grava a credencial é o Serviço, pelo Named Pipe). Sobrevive a reinício e logout |
| Serviço | `FlorestPrintAgent`, LocalSystem, início **Automático** (não "atrasado": ele não depende da internet, então iniciar logo no boot é melhor), depende do Spooler. Recuperação: reinicia 5 s / 5 s / 30 s após falha (e nas seguintes), contador zerado após 1 dia, inclusive quando o processo sai com código de erro |
| Tray | Só status, pareamento, impressoras, diagnóstico, última comunicação/impressão. Inicia no login (`HKLM\...\Run`, `--minimized`). Fechar o Tray **não** para nada |
| Atualização (1.1.0 → 1.2.0 → ...) | Rodar o novo Setup por cima (mesmo `AppId`): fecha o Tray, para o serviço, troca os binários, atualiza o serviço, preserva `ProgramData` (vínculo, estação, credencial, diário, configuração) e inicia de novo. **Não pede novo pareamento** |
| Desinstalação | Para e remove o serviço, remove o autostart do Tray e os binários. `ProgramData` só é apagada se o usuário responder **Sim** na pergunta final, ou com `unins000.exe /VERYSILENT /PURGEDATA` |

Gerar o instalador (no computador de desenvolvimento, com .NET SDK 8 e Inno Setup 6.3+): `.\scripts\build-setup.ps1`
(compila, testa, publica `dist\app` completa e gera `dist\installer\FlorestPrintAgent-Setup-1.1.0.exe`).
`scripts\install-service.ps1` continua funcionando para desenvolvimento/suporte (não depende de `$PSScriptRoot` em valores
padrão de parâmetros, que chega vazio no PowerShell 5.1 com `-File`).

Diário contra papel duplicado: o job é gravado no diário **no instante em que o spooler do Windows aceita o documento**
(antes de esperar o papel sair). Se a energia, o serviço ou a internet caírem depois disso, o job volta pela fila e o agente
**só confirma**, nunca reimprime. Se a impressora acusar problema depois (documento removido da fila do Windows), a entrada
do diário é apagada, porque o papel não saiu.

Resolução da impressora (determinística): 1) identificador estável sincronizado pelo próprio agente; 2) nome da fila, igualdade
exata (ignora maiúsculas/espaços repetidos; "parecido" nunca vale; porta que mudou só gera aviso no log); 3) nada confere →
falha controlada `impressora_nao_encontrada` (entra no retry da fila). **Nunca a impressora padrão do Windows.**

---

## 0. Estado de verificação — LEIA ANTES DE COMPILAR

Este projeto foi escrito **sem acesso a um Windows nem ao SDK do .NET** (o ambiente de geração não tem `dotnet`).
Portanto:

| Item | Situação |
|---|---|
| Sintaxe C# de todos os arquivos | Conferida com analisador sintático (tree-sitter) |
| Revisão de código (compilação, segurança, checklist da Fase B3) com correções aplicadas, incluindo a revisão corretiva da Fase B3 | Feita por revisão de leitura |
| `dotnet build` / `dotnet test` | **Executados pela equipe no Windows 10 real (.NET SDK 8.0.425):** build Release 0 erros / 7 avisos; testes 380 de 382 aprovados. As 2 falhas (teste do merge de impressoras e teste de identidade do pipe) foram corrigidas **só nos testes** — veja `REVISAO-B3-correcao-testes.txt`. A nova execução ainda precisa ser feita no Windows |
| `dotnet publish` | **Não executado ainda** (seção 8) |
| Testes dependentes de Windows (ACL do pipe, identidade do chamador) | Escritos; **só executam no Windows** (em outro SO retornam sem verificar) |
| Tray (WinForms), ícone, janela | **NÃO executado** |
| Winspool / spooler real, DPAPI, ACL do Named Pipe, serviço do Windows | **NÃO executado** |
| Script do instalador (`.iss`) e scripts PowerShell | **NÃO compilados / executados** |

Isso significa que **podem existir erros de compilação pequenos** (um `using` faltando, um nome errado).
O caminho esperado é: revisão (ChatGPT) → `scripts\build.ps1` → corrigir o que aparecer → só então instalar.
Nenhum arquivo deste projeto instala algo sozinho: **nada é executado até você rodar um script**.

---

## 1. Pré-requisitos (para desenvolver/compilar)

- Windows 10 ou 11 **x64**.
- **.NET 8 SDK** (x64): <https://dotnet.microsoft.com/download/dotnet/8.0> — confira com `dotnet --version` (deve começar com `8.`).
- PowerShell 5.1 (já vem no Windows) ou PowerShell 7.
- (Opcional, só para gerar o instalador) **Inno Setup 6.3 ou mais novo**, gratuito: <https://jrsoftware.org/isinfo.php>.
- Acesso à internet para o `dotnet restore` baixar os pacotes NuGet (Microsoft.Extensions.Hosting, xunit etc.).

O **cliente final não precisa instalar o .NET**: a publicação é *self-contained* (seção 8).

## 2. Restaurar, compilar e testar

Abra o PowerShell na pasta do projeto (onde está `FlorestPrintAgent.sln`) e rode:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build.ps1
```

O script faz `dotnet restore`, `dotnet build -c Release` e `dotnet test` e para no primeiro erro.
Para pular os testes: `.\scripts\build.ps1 -SkipTests`.

Se preferir os comandos manuais:

```powershell
dotnet restore FlorestPrintAgent.sln
dotnet build   FlorestPrintAgent.sln -c Release --no-restore
dotnet test    FlorestPrintAgent.sln -c Release --no-build
```

> Se o PowerShell reclamar de "execução de scripts desabilitada", use o `-ExecutionPolicy Bypass` como acima
> (vale só para aquela execução).

## 3. Rodar em desenvolvimento (sem instalar nada)

Abra **duas** janelas do PowerShell na pasta do projeto:

```powershell
# Janela 1 — o Service (fica rodando; Ctrl+C para parar)
.\scripts\run-dev.ps1 -Component Service

# Janela 2 — o Tray (ícone perto do relógio)
.\scripts\run-dev.ps1 -Component Tray
```

Em desenvolvimento os dados ficam em `.\devdata` (variável `FLORESTPRINTAGENT_DATA_DIR`), **não** em ProgramData. Essa variável só vale em compilação **Debug**; em Release ela é ignorada (segurança).
Rodando assim, o Service roda com o **seu usuário** (não como LocalSystem), então o comportamento de impressoras
por usuário e de DPAPI é um pouco diferente do serviço real. Para o teste definitivo, use a seção 4.

## 4. Instalar o Service para teste (sem o instalador)

1. Gere a publicação (seção 8): `.\scripts\publish.ps1`.
2. Abra o PowerShell **como Administrador** e rode:

```powershell
.\scripts\install-service.ps1 -WithTrayAutostart
```

Isso copia os arquivos para `C:\Program Files\Florest Sistemas\Print Agent`, cria o serviço **Florest Print Agent**
(conta LocalSystem, início **Automático**, depende do serviço de impressão *Spooler*, reinício automático em falha) e inicia. Com `-WithTrayAutostart` o Tray passa
a abrir no login de cada usuário (chave `HKLM\...\Run`, valor `FlorestPrintAgentTray`, com `--minimized`).

Para confirmar: `Get-Service FlorestPrintAgent` deve mostrar `Running`.

## 5. Abrir o Tray

- Pelo atalho do Menu Iniciar (se instalou pelo instalador), ou
- `C:\Program Files\Florest Sistemas\Print Agent\FlorestPrintAgent.Tray.exe`, ou
- em desenvolvimento: `.\scripts\run-dev.ps1 -Component Tray`.

Duplo clique no ícone abre a janela. Menu do ícone: **Abrir Florest Print Agent**, **Buscar impressoras**, **Status**,
**Sair**. **"Sair" fecha só o Tray; o Service continua rodando e mantendo o heartbeat.**
Clicar no X da janela apenas a esconde.

### Fluxo de pareamento (teste com o ERP)

1. No Florest ERP, gere o **código de pareamento** da estação (formato `XXXX-XXXX`).
2. No Tray: **Conectar ao Florest ERP** → digite o código → **Verificar**.
3. O Tray mostra *"Conectar este computador à empresa NOME?"*. O usuário **nunca informa o empresa_id**.
4. **Confirmar conexão** → o Service chama `/pair/confirm`, guarda a credencial protegida e faz o primeiro sync.
5. A janela passa a mostrar ● Conectado, empresa, estação, última comunicação e a tabela de impressoras.

## 6. Onde ficam os dados

`C:\ProgramData\Florest Sistemas\Print Agent\data\` (somente SYSTEM e Administradores; usuário comum não altera):

| Arquivo | Conteúdo |
|---|---|
| `instalacao.json` | `identificador_instalacao` (GUID permanente — **não muda** em reinício/atualização/Tray fechado) |
| `credencial.dpapi` | credencial protegida por **DPAPI (LocalMachine)**. Nunca em texto legível |
| `estado.json` | estado não sensível (última comunicação, impressoras por usuário, expiração de 7 dias) |

O **código de pareamento nunca é gravado**. O token nunca aparece em arquivo legível, em log, nem no Tray.

## 7. Onde ficam os logs

- Service: `C:\ProgramData\Florest Sistemas\Print Agent\logs\service*.log` (rotativos).
- Tray: `%LOCALAPPDATA%\Florest Sistemas\Print Agent\logs\` (o usuário comum não grava em ProgramData).

Os logs **nunca** contêm token, segredo, Authorization, hash da credencial, código de pareamento ou service_role.
Para suporte, é seguro enviar estes arquivos.

### Remover (desinstalar)

```powershell
# como Administrador — remove o serviço (mantém arquivos e dados)
.\scripts\uninstall-service.ps1

# remove também os arquivos do programa
.\scripts\uninstall-service.ps1 -RemoveFiles

# remove também os dados (instalação + credencial). Pede para digitar APAGAR
.\scripts\uninstall-service.ps1 -RemoveFiles -RemoveData
```

Se instalou pelo instalador, use *Configurações → Aplicativos → Florest Print Agent → Desinstalar*
(para e remove o serviço, fecha o Tray e pergunta se deseja apagar os dados).

> **Importante:** apagar os dados faz o computador **perder o vínculo** (nova identidade). Desinstalar/atualizar
> *sem* apagar os dados mantém o vínculo.

## 8. Publicar self-contained x64

```powershell
.\scripts\publish.ps1
```

Gera `dist\app\` com `FlorestPrintAgent.Service.exe` e `FlorestPrintAgent.Tray.exe` (win-x64, self-contained —
o runtime do .NET vai junto; não precisa instalar o .NET no cliente). Também é possível usar
`-Configuration Debug` ou `-Runtime <rid>`.

## 9. Gerar o instalador

Com o .NET SDK 8 e o Inno Setup 6.3+ instalados, um comando só:

```powershell
.\scripts\build-setup.ps1          # compila + testa + publica dist\app + gera o Setup.exe  (-SkipTests, -IsccPath "C:\...\ISCC.exe")
```

ou, em duas etapas: `.\scripts\publish.ps1` e `.\scripts\build-installer.ps1`.

Resultado: `dist\installer\FlorestPrintAgent-Setup-1.1.0.exe`. O instalador copia os arquivos, cria a pasta de dados,
cria (ou atualiza) e inicia o serviço (automático, com recuperação), configura o Tray para abrir no login e cria o atalho no
Menu Iniciar e a entrada em "Aplicativos instalados". Instalação silenciosa: `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`.
**Assinatura digital:** não é necessário comprar certificado agora; o `.iss` tem as linhas de `SignTool` comentadas,
prontas para quando houver certificado. Sem assinatura, o SmartScreen do Windows pode mostrar um aviso.

---

## 10. Arquitetura (resumo)

```
 Florest ERP (Edge Function florest-print-agent)
        ▲  HTTPS (Bearer fpa_<id>.<segredo>)
        │
 ┌──────┴──────────────────┐      Named Pipe local        ┌────────────────────────┐
 │  Service (LocalSystem)  │◄────── FlorestPrintAgent ───►│  Tray (sessão usuário) │
 │  heartbeat • sync       │       .Ipc.v1 (sem token)    │  ícone • janela        │
 │  credencial (DPAPI)     │                              │  impressoras do usuário│
 │  impressoras (conjunto A)│                             │  (conjunto B)          │
 └─────────────────────────┘                              └────────────────────────┘
```

- **Core**: toda a lógica (API, IPC, armazenamento, impressoras, coordenador). **Service** e **Tray** são casca fina.
- O **Service** é a única parte que fala com o servidor e a única que enxerga o token. O Tray só envia comandos,
  o código de pareamento digitado e as impressoras da sessão do usuário.
- **Impressoras por usuário:** o Service (LocalSystem) enxerga as impressoras da máquina (A). O Tray envia as do
  usuário logado (B). O Service **une A+B**, sem duplicar (identificador determinístico SHA-256). Para a mesma
  impressora, a versão do Service sempre vale; entre sessões de usuário vale a mais completa. Impressoras
  compartilhadas não se perdem.
- **Heartbeat:** `heartbeat_segundos` do servidor (120 s até a primeira resposta), jitter ±10 %, nunca concorrente.
  Sem internet o vínculo e o token são **mantidos**; há retentativa com backoff limitado (15 s → 5 min).
- **Renovação:** se o servidor pedir (`renovar_credencial`), o novo token é protegido e gravado de forma atômica
  **antes** de substituir o token em memória; se falhar, o token atual continua valendo.
- **Desvincular:** exige confirmação; a credencial local só é apagada **após** o servidor confirmar. Servidor
  indisponível → erro exibido e vínculo mantido. A identidade da instalação é sempre preservada.
- **Sync:** no máximo 100 impressoras e 256 KB. Lista vazia só é enviada após uma descoberta **completa e bem
  sucedida**; falha técnica de descoberta **nunca** envia lista vazia. Sync: após parear, ao iniciar, quando o
  servidor pede, em "Buscar impressoras", quando o Tray envia nova lista e a cada ~30 min; nunca dois ao mesmo tempo.

### Segurança

- Endpoint fixo em **uma** constante (`AgentConstants.EdgeBaseUrl`), **somente HTTPS**, sem desativar validação TLS.
- Sem `service_role`, sem `apikey`, sem JWT de usuário do ERP no executável; `empresa_id` nunca é enviado.
- Named Pipe `FlorestPrintAgent.Ipc.v1`: sem acesso de rede (ACL nega NETWORK e o .NET recusa clientes remotos),
  só usuários locais interativos, mensagens com prefixo de tamanho e limites (16 KB comandos / 256 KB lista de
  impressoras / 512 KB resposta), no máximo 8 clientes simultâneos, timeout de leitura. **Sem servidor HTTP local,
  sem porta TCP.**
- A sessão do Tray é identificada pelo usuário autenticado do pipe, não por um texto enviado pelo cliente.

#### Autorização do pipe

O Windows informa ao Service **quem** abriu o pipe (token do cliente, via `RunAsClient`, com nível de representação
*Identification*; sessão via `GetNamedPipeClientSessionId`). A identidade nunca vem do JSON da mensagem. Um cliente
anônimo/convidado é recusado. Com isso:

| Comando | Quem pode |
|---|---|
| status, listar/buscar impressoras (limitado a 1 busca a cada 5 s), enviar impressoras da sessão | qualquer usuário interativo (cada sessão só altera a **sua** lista) |
| verificar código de pareamento | qualquer usuário interativo; fica **preso a usuário+sessão** (só em memória, 5 min, nunca em disco/log) |
| confirmar pareamento | **somente** o mesmo usuário+sessão que verificou aquele mesmo código |
| desvincular | SYSTEM, administrador **elevado**, ou o usuário que fez o pareamento (SID gravado em `estado.json`) |

A credencial local só é apagada **depois** do sucesso no servidor; sem internet, o desvínculo falha e o vínculo é mantido
(nada de "fingir" desvinculação). O Tray normal **não** precisa de administrador.

### IPs e portas

IP/porta **nunca são inventados**: ficam `null` quando desconhecidos. A porta 9100 **não** é presumida. IP/porta só
vêm de leitura (somente leitura) das portas TCP/IP padrão do Windows no registro.

## 11. Limitações conhecidas (honestas)

- Não há teste de alcance TCP na impressora; o status reflete a visão do **spooler** do Windows.
- O número da porta USB não entra na identidade da impressora (para o identificador não mudar ao trocar de USB).
- Se a resposta de uma renovação de credencial se perder no caminho, só a janela de tolerância do servidor recupera.
- Qualquer usuário local **interativo** consegue **conectar** ao pipe e pedir *status*, *buscar impressoras* e enviar a
  lista das **suas** impressoras. As operações sensíveis são autorizadas pelo Service (seção 10, "Autorização do pipe"):
  pareamento só pelo mesmo usuário+sessão que verificou o código; desvincular só por SYSTEM, administrador elevado ou o
  usuário que pareou. Um **segundo usuário/sessão não consegue desvincular nem concluir o pareamento de outro**.
  Em contrapartida, enquanto o pareamento de A está em andamento (até 5 min), B é recusado com "pareamento em andamento".
- Se o usuário que pareou for removido do Windows e não houver administrador elevado disponível, o desvínculo exige um
  administrador (Tray "Executar como administrador") — comportamento intencional.
- *Pipe squatting*: o Service cria a primeira instância do pipe com `FirstPipeInstance` (se o nome já estiver ocupado, falha e
  registra aviso em vez de atender num pipe alheio). **Ainda não** há verificação, no lado do Tray, de que o processo do outro
  lado é o Service (PID/SID da conta SYSTEM). Como o serviço inicia de forma atrasada, há uma janela após o boot em que um
  processo local malicioso poderia ocupar o nome antes dele — pendência registrada para a próxima rodada.
- A pasta `ProgramData\Florest Sistemas\Print Agent` é criada pelo instalador com a herança padrão; o Service restringe `data\`
  na primeira execução e **recusa iniciar** se `Root`, `data` ou `logs` forem links (junction/symlink). Não há, ainda, a
  verificação de dono de arquivos pré-existentes em `data\` (um usuário que pré-criasse `estado.json` antes da primeira
  execução poderia influenciar `pareado_por_sid`). Em instalação limpa, rode o instalador e inicie o serviço antes de liberar
  o computador para outros usuários.
- Impressoras: um usuário comum **nunca sobrescreve** uma impressora que o Service enxerga (a versão do Service sempre vale);
  ele ainda pode informar impressoras que só a sessão dele vê (ficam 7 dias). O ERP deve tratar IP/porta como dado informado
  pelo computador, não como verdade absoluta.
- Limites locais (DoS): 8 conexões simultâneas ao pipe, 15 s para a 1ª mensagem; não há limite por usuário e `PairVerify` não tem
  limite local por usuário (o servidor tem o seu). Um usuário local malicioso pode atrapalhar a disponibilidade do Tray.
- O serviço roda como `LocalSystem` completo (sem redução de privilégios) e a credencial usa DPAPI `LocalMachine`: a proteção
  real é a ACL de `data\`.
- Remoção local forçada durante um problema de identidade **transitório** (arquivo bloqueado) ainda é aceita para quem tem
  permissão; o ideal seria recusar enquanto o problema for transitório.
- Se `instalacao.json` **e** seu backup ficarem ilegíveis enquanto existe vínculo, o agente entra em **estado de erro
  recuperável** ("identidade inválida") e **não** chama o servidor nem cria outra identidade (isso causaria
  `instalacao_divergente`). A saída é apagar o vínculo apenas neste computador (Tray como administrador → *Desvincular* →
  "Remover o vínculo apenas deste computador?" → Sim) e parear de novo; na primeira instalação limpa a identidade continua sendo um GUID novo.
- O serviço (LocalSystem) pode ter configuração de proxy diferente da do usuário.
- A impressora virtual é filtrada de forma conservadora (PDF, XPS, OneNote, Fax etc.); uma impressora real com
  nome parecido pode ser filtrada — ajuste em `PrinterFilter`.
- O relógio de agendamento usa a hora do sistema: um ajuste manual do relógio para trás pode atrasar um heartbeat.
- Uma identidade/credencial que existe mas não pode ser lida por um erro temporário (arquivo bloqueado) **não** é regerada nem apagada: o agente mostra erro e tenta de novo.
- Os itens da seção 0 marcados "NÃO executado" ainda precisam de validação no Windows real.

## 12. Problemas comuns

| Sintoma | O que verificar |
|---|---|
| `dotnet` não encontrado | Instale o .NET 8 SDK e reabra o PowerShell |
| Erro de pacote NuGet | Internet/proxy; rode `dotnet restore` de novo |
| Tray mostra "Serviço não encontrado" | `Get-Service FlorestPrintAgent`; em desenvolvimento, deixe o `run-dev.ps1 -Component Service` rodando |
| "Sem conexão" | Internet/firewall para `*.supabase.co:443`; o vínculo **não** é perdido |
| Código inválido/expirado | Gere outro código no ERP |
| Impressora não aparece | Veja se é virtual (filtrada); abra o Tray no usuário que a instalou e clique em *Buscar impressoras* |

## 13. Estrutura

```
FlorestPrintAgent/
├─ FlorestPrintAgent.sln
├─ Directory.Build.props, global.json
├─ src/
│  ├─ FlorestPrintAgent.Core/      lógica compartilhada
│  ├─ FlorestPrintAgent.Service/   serviço do Windows (Worker + servidor do pipe)
│  └─ FlorestPrintAgent.Tray/      ícone e janela (WinForms)
├─ tests/FlorestPrintAgent.Tests/  xunit
├─ installer/FlorestPrintAgent.iss Inno Setup
├─ scripts/                        build, publish, install, uninstall, run-dev, build-installer
└─ README.md
```

Backend: Edge Function `florest-print-agent` (Fase B2), **não alterada** nesta fase. Nenhuma alteração em Supabase,
ERP, BAR, Fiscal, NFC-e foi feita; não há Migration 031.
