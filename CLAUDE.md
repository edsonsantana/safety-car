# Safety Car

Plataforma de assistência rodoviária conectada (guincho, mecânica e serviços correlatos): o tomador solicita socorro, o parceiro aceita e compartilha a posição, e a Central acompanha. Projeto em parceria com o Adailton. Idioma do projeto: português do Brasil.

## Estado atual
- Documentação: o produto em `docs/COMO_FUNCIONA.md` (para o sócio e interessados; descreve comportamento, sem tabelas); o guia de desenvolvimento, que era o README da raiz, em `docs/DESENVOLVIMENTO.md`. O `README.md` é só a apresentação e o mapa dos documentos.
- Protótipo v8 (Python/SQLite, HTML/JS) e documentação servem de referência; o desenvolvimento na stack definitiva está começando.
- Protótipo 1 (cadastro, verificação de e-mail, 2FA e login) aprovado.
- Modelo de dados de referência: `docs/safety_car_modelo_dados_v1.sql`. A tarefa atual está descrita em `docs/PROMPT_BANCO_INICIAL.md`, que prevalece sobre o SQL v1 em caso de conflito.
- **Banco inicial concluído e testado** (PostgreSQL 16 + PostGIS 3.6 em Docker): migrações `db/migrations/0001` a `0007` (extensões, núcleo, tomador, parceiro tipificado, geo, antifraude base e permissões) e testes em `db/tests` (`bash db/scripts/testar.sh`). Documentação, decisões e pendências em `docs/BANCO_DE_DADOS.md`.
  - Papéis: `safetycar_migrator` (aplica migrações) e `safetycar_app` (DML, sem DDL). A `0001` roda como superusuário (PostGIS).
  - Migração aplicada não se edita: o `migrar.sh` confere o sha256. Toda migração nova declara os GRANTs do `safetycar_app` (não há default privileges).
  - Já decidido nesta fase: `tipo_parceiro` com `exige_viatura` e `permite_viatura` (guincho exige; mecânica e chaveiro permitem; seguros não); registro Susep exigido na aprovação; CNPJ numérico e alfanumérico com DV; área de atuação por centro + raio.
  - Fora do Git até revisão: zips, docx, pdf, html, png, `files/` e `docs/README.md` (README do protótipo v5, com senhas de demonstração).
- **Dados do SNV/DNIT** (arquivos `202610A`) em `docs/SNV`: inventário, hashes e observações no `docs/SNV/README.md`, o único arquivo versionado da pasta. Os zips dos shapefiles passam de 50 MB; a planilha e o manual ficam fora por decisão (licença registrada). Origem, data, versão e licença foram preenchidas pelo Edson no README. Nenhuma decisão sobre distância rodoviária foi tomada.
- **Parametrização do modelo de negócio** (migrações `0008` a `0013`, testes `09` a `15`):
  - `0008`: CPF do tomador obrigatório no cadastro (NOT NULL); CPF do responsável de PJ/MEI exigido na aprovação (sem UNIQUE).
  - `0009`: níveis de verificação (catálogo, requisitos por nível e perfil, nível mínimo por serviço e perfil); o nível atual de tomador e parceiro só muda pelo histórico (`nivel_verificacao_historico`, somente inserção).
  - `0010`: `regra_taxa` por tipo de parceiro, serviço e UF (nula = nacional), em inteiros (centavos, centavos/km, pontos-base); vigência sem sobreposição (`btree_gist`) e imutável (só o fim é definido; mudança = nova linha); `base_distancia` padrão `linha_reta`.
  - `0011`: `politica_garantia` (pré-autorização ou Pix; fixo ou percentual; por serviço e nível) e `provedor_pagamento` (capacidades e ambiente, **sem credenciais**).
  - `0012`: o app **só lê** a parametrização; **alteração só por migração**, sempre auditada (`auditoria.papel_bd`, `safetycar.ator_usuario_id`). Carga inicial toda `a_definir`; os requisitos por nível são **proposta**.
  - "A definir" nunca vale como zero nem como nível: as consultas (`nivel_minimo_servico`, `regra_taxa_vigente`, `politica_garantia_vigente`) recusam com SC013.
  - `0013`: nível 0 "cadastro incompleto". Tomador e parceiro nascem no 0 e só sobem por linha no histórico. O 0 não cumpre o mínimo de nenhum serviço, não tem requisitos nem garantia (CHECK `>= 1`; garantia no 0 dá 22023). Origem `migracao` no histórico. O comentário da 0003 sobre os níveis está superado.
- **Operadores e permissões da Central** (migração `0014`, testes `16` e `17`):
  - Catálogo `permissao_central` (`conceder_permissao`, `aprovar_reajuste_taxa`; extensível por migração), `operador_central` e histórico somente de inserção (`permissao_concessao`, `permissao_revogacao`). A permissão vigente é derivada do histórico; `operador_tem_permissao()` responde "tem agora?".
  - Autorização pela alternativa B: as ações sensíveis são funções SECURITY DEFINER executáveis **só** pelo papel `safetycar_central`, nunca pelo `safetycar_app`. O ator é verificado no banco. **O backend da Central usa um pool de conexão separado e tira o ator do JWT do Keycloak, nunca do corpo da requisição.**
  - Ninguém concede permissão a si mesmo. A primeira concessão de `conceder_permissao` é feita à mão pelo migrator (`conceder_permissao_inicial`), só quando não há concessão vigente dela. Recuperação: `revogar_permissao_manual` e depois `conceder_permissao_inicial`.
  - O app não executa `operador_tem_permissao`, para não sondar quem é aprovador. `auditoria.papel_bd` passou a ser `session_user`.
  - Senha do papel em `SAFETYCAR_CENTRAL_PASSWORD`, só no `.env`. Em volume antigo, o papel é criado com `bash db/scripts/criar_papeis.sh`.
  - Primeiro administrador: `bash db/scripts/primeiro_administrador.sh --email … --sub …` (`--simular` antes; grava só se for digitado o nome do banco). Roda **uma vez por ambiente** (trabalho, casa), cada um com o `keycloak_sub` do seu próprio Keycloak. Teste: `bash db/scripts/testar_primeiro_administrador.sh` (bancos descartáveis). Ainda não foi rodado no `safetycar`.
- **Reajuste de taxas em lote** (migração `0015`, testes `18` e `19`):
  - `reajuste_taxa` (lote) e `reajuste_taxa_decisao`, ambos somente de inserção; `regra_taxa` ganhou `reajuste_id` e `regra_origem_id`. Funções da Central: simular, solicitar, aprovar, rejeitar e cancelar.
  - **Regras atualizadas pela 0019** (ver abaixo): só percentual, início imediato, limite de variação, `solicitar_reajuste_taxa` para pedir. Aprova quem tem `aprovar_reajuste_taxa`, nunca o próprio solicitante.
  - A aprovação calcula sobre as regras vigentes naquele momento e, numa só transação, encerra as antigas e cria as novas no mesmo instante. Não há reajuste parcial.
  - Locks: `pg_advisory_xact_lock(150001)` e depois `FOR UPDATE`. O início é lido com `clock_timestamp()` depois dos locks, nunca no passado.
  - Faixa de ±5000 pb; por km só no percentual; pontos-base só com `inclui_pontos_base`; a regra nacional só com `inclui_nacional` (vale para todas as UFs).
  - Arredondamento ao centavo com `numeric`, uma vez, sobre o valor final: 0,5 ou mais sobe.
  - Recusas: "a definir" (SC013), escopo vazio (SC019), lote decidido (SC020), regra futura (SC021), resultado inválido ou nada a alterar (SC022). Valor igual entra como nova versão.
  - O chamado (fase seguinte) guardará o `regra_taxa.id` de cada componente e os valores usados; a regra antiga continua consultável por data e por id.
  - Fora do escopo: tela de administração e busca automática de índice (IPCA).
- **Permissões da Central ampliadas** (migração `0016`, testes `20`, cenários 7a e 7b de concorrência), primeira etapa do desenho `docs/CENTRAL_PERMISSOES_TARIFAS_PARAMETROS.md` (0016 a 0019; o que já existia prevalece):
  - Códigos mantidos: `conceder_permissao` = "administrar permissões"; `aprovar_reajuste_taxa` = "aprovar tarifa". Novos: `solicitar_reajuste_taxa` (exigida só a partir da 0019), `analisar_cadastros` (ainda **não** imposta pelo banco) e `administrar_parametros`. Coluna `sensivel`, informativa para a API exigir OTP; o banco não valida 2FA.
  - Último titular efetivo de `conceder_permissao` não é revogado nem desativado (SC023), por função ou escrita direta. A revogação manual do migrator continua liberada (recuperação).
  - Eventos `central_permissao_concedida`, `central_permissao_revogada` e `central_acesso` (`registrar_acesso_central`); visões `vw_operador_permissao` e `vw_operador_central` (último acesso), só para a Central.
  - O risco de o app alterar `usuario.status` e inserir eventos `central_*` foi resolvido na 0020.
- **Regiões e primeira tarifa** (migração `0017`, testes `21`, cenários 8 e 9 de concorrência):
  - `regra_taxa` segue por UF ou nacional; `regiao`/`regiao_uf` (IBGE) são só atalho de escopo, expandido em UFs.
  - Primeira tarifa por **lote de definição** (itens em jsonb, cada um com exatamente um alvo: `uf`, `regiao` ou `nacional: true`). Pede quem tem `solicitar_reajuste_taxa`; aprova ou rejeita, numa só decisão, quem tem `aprovar_reajuste_taxa` e não é o solicitante. Simula quem tem uma das duas.
  - Regra "a definir" é encerrada e substituída; escopo sem regra ganha regra nova; regra já definida recusa (SC028, use o reajuste); outro lote em aberto no mesmo escopo recusa (SC024). Valor 0 é aceito como definido. Combinação tipo × serviço nova só por migração.
  - Mesmo advisory lock do reajuste (150001) na solicitação e na aprovação.
- **Parâmetros de negócio** (migração `0018`, testes `22`, cenários 10 e 11 de concorrência):
  - `parametro` (catálogo, só por migração: tipo `percentual` ou `dias`, faixa, sensível) e `parametro_valor` (histórico com vigência imutável, sem sobreposição, um valor em aberto). Carga: `limite_variacao_reajuste` = 20 (1 a 50, sensível; CHECK impede máximo acima do teto de 50%) e `alerta_documento_dias` = 30 (1 a 180, comum).
  - Comum: `alterar_parametro` direto, com `administrar_parametros`. Sensível: pedido de quem tem `administrar_parametros` e decisão de outro operador com a mesma permissão; um pedido em aberto por parâmetro (SC024). Fora da faixa ou do tipo: SC026; caminho errado: SC027; valor igual ao vigente é recusado.
  - Sem valor: SC013 em `parametro_vigente`. O app só lê `vw_parametro_vigente` (sem operador nem motivo).
- **Reajuste conforme o desenho** (migração `0019`, testes `18` e `19` reescritos, cenários de concorrência 2 a 6 adaptados e 12):
  - Só **percentual** (até 2 casas, ±50% de teto absoluto); início **imediato** na aprovação. O tipo "valor" e o início agendado saíram; as assinaturas antigas de simular, solicitar e aprovar foram removidas (DROP).
  - Limite de variação: o parâmetro `limite_variacao_reajuste` é **copiado no pedido** (`limite_bp_na_criacao`); acima dele, exige `motivo_excecao` (SC025). A aprovação usa o limite copiado, não o de agora.
  - Solicitar exige `solicitar_reajuste_taxa`; simular, ela ou `aprovar_reajuste_taxa`. Quem pede nunca aprova nem rejeita (sem exceção de autoaprovação; CHECK no catálogo).
  - Sem dois lotes em aberto com regra vigente em comum (SC024). Região como atalho de escopo (`regioes`). `vw_reajuste_taxa_regra` mostra valor base e valor novo.
- **Endurecimento de permissões** (migração `0020`, testes `24`, cenário de concorrência 13; teste 13 e teste de integração da API ajustados):
  - O app (`session_user = safetycar_app`) não cria usuário central, não promove ninguém a central e, num usuário central, só altera `ultimo_login_em` (SC029). Fecha a tomada de identidade pela troca de `keycloak_sub`.
  - Último titular de `conceder_permissao` também não sai de `ativo`, não é excluído e não muda de perfil, por qualquer escritor (SC023).
  - Central: `cadastrar_usuario_central` (e-mail só em `usuario`, nunca na auditoria), `definir_status_usuario_central` e `registrar_mfa_central`. `mfa_ativado_em` é espelho: **a Central não decide 2FA por ele**, e sim pelo OTP/`acr` do token.
  - Auditoria: o app perde o SELECT e não grava direto `central_`, `migrator_` nem `parametrizacao_` (SC030; as linhas de trigger, com `pg_trigger_depth() > 1`, continuam). `vw_operador_central` só conta acesso gravado pela Central ou pelo migrator.
  - Testes: `_app.sql` com `-- @como_app` prepara dados como postgres antes de virar o app.
  - Com migração própria, ainda a planejar: REVOKE geral de EXECUTE (pendência 16) e decisões da Central gravadas pelo app (pendência 18).
- **Keycloak de desenvolvimento** no `docker-compose.yml` (26.8.2, `start-dev`, só em 127.0.0.1), com banco próprio (`keycloak-db`). O realm `safetycar-dev` é versionado em `keycloak/realms/safetycar-dev.json`, **sem usuários, senhas nem segredos**. O client `safetycar-web` é público, com PKCE S256 e `aud=safetycar-api`. Detalhes em `docs/KEYCLOAK.md`.
- **Esqueleto do backend** em `apps/api` (Node 24 + TypeScript estrito; Fastify, `pg`, Zod, `jose` e pino-pretty em dev; testes com `node:test`). Rotas: `GET /saude` (SELECT 1) e `GET /me` (ver Login abaixo).
  - Conecta só como `safetycar_app`: a configuração recusa `safetycar_migrator` e `postgres`, e a subida recusa papel superusuário ou com CREATE no schema `public`.
  - Configuração por variáveis de ambiente (`API_*` e `KEYCLOAK_*`, lidas do `.env` da raiz), validada na subida.
  - Log sem dados pessoais: sem corpo, query, cabeçalhos, IP, token nem `keycloak_sub`; o `detail` dos erros do PostgreSQL é removido.
  - SQL puro parametrizado, sem ORM nem construtor de consultas (decidido; reavaliar quando houver consultas reais).
- **Esqueleto do frontend** em `apps/web` (React 19 + TypeScript estrito; Vite 8, Tailwind 4, React Router 7 declarativo; testes com Vitest, Testing Library e `vitest-axe`), conforme `docs/PLANO_FRONTEND.md`. Ainda sem formulários reais.
  - Componentes-base em `src/componentes` (Botao, CampoTexto, CampoCodigo, IndicadorEtapas, CartaoAviso, SeloStatus); layouts móvel (390 px) e de painel em `src/layouts`; rotas vazias `/cadastro`, `/entrar`, `/verificacao` e `/central`; `/componentes` só em desenvolvimento (o build confere que ela não vai para o `dist/`).
  - Cores só pelos tokens do `@theme` em `src/estilos.css`; o teste de contraste roda no build. Verde-limão nunca sobre fundo claro.
  - A página inicial mostra o estado do `GET /saude` via proxy do Vite (`/api` → `API_URL_DEV`). Variáveis `VITE_*` vão para o navegador: nunca segredo nelas.
  - ESLint 10 com `overrides` relaxando só o peer do `eslint-plugin-jsx-a11y`. React Hook Form + Zod entram só com o primeiro formulário real.
- **Login com Keycloak** (`oidc-client-ts`, PKCE S256, tokens só em memória; F5 por renovação silenciosa em `/renovar-sessao.html`): telas de entrada (`/`), "Entrando…" (`/entrando`) e Acesso restrito, com rotas por perfil. O perfil vem do `GET /me` da API (`usuario.perfil`/`status` pelo `keycloak_sub`; o `GET /eu` foi removido): 200 para ativo e pendente; o mesmo 403 para sem registro, suspenso, bloqueado e excluído. A API exige `azp = safetycar-web`. Keycloak na porta 8180 em desenvolvimento. Passo a passo do client e pendências (canal de "Falar com a Central", cadastro) em `docs/DESENVOLVIMENTO.md`.
- **Tema de login do Keycloak** `safetycar` em `keycloak/themes/safetycar/login` (pai `keycloak.v2`, montado só leitura). Só CSS, mensagens pt-BR e recursos próprios (logo, Inter e Playfair com licença OFL): **nenhum `.ftl` sobrescrito**, nenhum script nem URL externa, CSP do Keycloak intacta. Celular escuro (verde-limão); desktop em duas colunas com o formulário claro e **botão #0B1F3A com texto branco** (limão só em fundo escuro). Erro de login genérico. Realm existente: escolher o tema no console. Detalhes, checklist e upgrade em `docs/KEYCLOAK.md`.

## Comandos
```bash
docker compose up -d                                # banco, Keycloak e banco do Keycloak
bash db/scripts/criar_papeis.sh                     # só em volume antigo: cria safetycar_central (idempotente)
bash db/scripts/criar_papeis.sh --verificar         # login de cada papel com a senha do .env (ok/FALHOU), só leitura
bash db/scripts/criar_papeis.sh --sincronizar       # ALTER ROLE só nos papéis cuja senha diverge do .env (pede confirmação)
bash db/scripts/testar_senhas.sh                    # à parte: testa os dois modos num contêiner descartável, removido no fim
bash db/scripts/migrar.sh                           # migrações no banco safetycar
bash db/scripts/testar.sh                           # testes do banco (recria safetycar_teste)
bash db/scripts/testar_concorrencia.sh              # à parte: duas sessões simultâneas (0014 a 0020) em safetycar_conc, apagado no fim
bash db/scripts/primeiro_administrador.sh --email … --sub … [--simular]  # 1º administrador da Central, uma vez por ambiente
bash db/scripts/testar_primeiro_administrador.sh    # à parte: testa o script acima em bancos descartáveis, apagados no fim
node --test keycloak/tests/tema.test.mjs            # estrutura e contraste do tema de login
bash keycloak/scripts/conferir_tema.sh              # tema montado e em uso no Keycloak local (só leitura)
cd apps/api && npm ci                               # dependências da API
npm run dev | test | test:integracao | lint | build  # em apps/api
cd apps/web && npm ci                               # dependências do frontend
npm run dev | test | lint | build                   # em apps/web (build inclui contraste e checagem do dist/)
```

## Terminologia
- **tomador**: quem solicita o serviço. Usuário e Motorista (nomes da v8) são tomadores.
- **parceiro**: entidade única, com nome e **tipificação** (guincho, mecânica, chaveiro, seguros etc.). Pode ter mais de um tipo. Cobre o que na v8 era Prestador e Parceiro de Seguros.
- **central**: operação interna do Safety Car.
- Perfis de usuário: `tomador`, `parceiro`, `central`.

## Stack
- Banco: **PostgreSQL com PostGIS** (decidido). Dados geográficos em `geography(Point, 4326)`.
- Autenticação: **Keycloak** (decidido; confirmação com o Adailton pendente). Senha, TOTP e códigos de recuperação ficam lá; o banco da aplicação guarda só o vínculo `keycloak_sub`.
- Backend: **Node.js com TypeScript**.
- Frontend: **React com TypeScript, Vite e Tailwind**.
- Não instalar bibliotecas (frameworks, ORMs etc.) sem perguntar.
- Waze e Google Maps servem apenas como navegação externa (não fornecem telemetria). Distâncias calculadas no banco são geodésicas (linha reta), não rota viária.

## Regras de segurança (inegociáveis)
- 2FA por aplicativo autenticador (TOTP), compatível com Google e Microsoft Authenticator.
- CPF e chave Pix cifrados na aplicação; busca e unicidade por hash (HMAC com chave fora do repositório).
- Nunca armazenar número de cartão: apenas token do processador de pagamento.
- Nenhum segredo, chave ou senha no código ou no Git. Usar variáveis de ambiente (`.env` fora do Git).
- Nenhuma conta ou senha de demonstração em ambiente compartilhado.
- Valores controlados em texto com CHECK; tabela de auditoria somente de inserção.
- Posição de GPS com mais de 180 segundos não é apresentada como atual.
- Nunca sugerir a um usuário em socorro que uma apólice nova cobre o evento que já ocorreu.
- Ambulância: fluxo apenas fictício; em urgência, 192 (SAMU) e 193 (Bombeiros).

## Decisões já tomadas
- 2FA incentivado para o tomador; obrigatório para parceiro e Central (proposta, a confirmar).
- Garantia por pré-autorização no cartão e Pix pré-pago.
- CPF obrigatório **no cadastro** do tomador (decidido, migração 0008). Para parceiro PJ e MEI, o CPF do responsável é exigido na aprovação do credenciamento.
- Valores de parametrização (taxas, garantia, níveis mínimos) mudam só por migração nova, nunca pelo app. Exceção: reajuste de taxas em lote, solicitado e aprovado pela Central nas funções da 0015 (nunca pelo app).
- Aprovações sensíveis são feitas por quem tem a permissão correspondente vigente (por exemplo, `aprovar_reajuste_taxa`), e não por um "administrador" fixo. Quem solicita não aprova o próprio pedido; a exceção (`permite_autoaprovacao`) está desligada e só muda por migração.
- Verificação do celular obrigatória.
- Migrar do protótipo Python/SQLite.
- Módulo de seguros na Fase 1 (escopo a definir).
- Identidade visual da v8.
- Protótipos 1 a 3 (cadastro e 2FA, verificação de identidade e documentos do parceiro, painel da Central) feitos no canvas; as perguntas de validação estão na seção 15 do documento de alinhamento.

## Decisões pendentes (NÃO assumir; perguntar)
Confirmação do Keycloak com o Adailton, confirmação da regra de 2FA, canal de verificação do celular (SMS ou WhatsApp), escopo do módulo de seguros, processador de pagamento, regras de cancelamento e **valores** de taxas e garantia (a estrutura existe, tudo `a_definir`), requisitos de cada nível (carregados como proposta) e nível mínimo por serviço, distância rodoviária na cobrança (o SNV é publicado sob a licença Creative Commons Atribuição-SemDerivações 3.0: uso com citação da fonte, sem redistribuir versão modificada do dado; depende ainda dos termos do provedor externo, se houver), motor de rotas e tempo de chegada (serviço externo ou pgRouting), retenção de histórico de GPS e base legal.

## Como trabalhar neste repositório
- Para qualquer mudança que toque mais de um arquivo, propor um plano antes de editar.
- Migração já aplicada não se edita; cria-se uma nova.
- Commits pequenos, com mensagem em português descrevendo o porquê.
- Não rodar comandos destrutivos nem instalar dependências sem pedir confirmação.
- Em dúvida de regra de negócio, perguntar em vez de inventar.
