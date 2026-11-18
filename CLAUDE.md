# Safety Car

Plataforma de assistência rodoviária conectada (guincho, mecânica e serviços correlatos): o tomador solicita socorro, o parceiro aceita e compartilha a posição, e a Central acompanha. Projeto em parceria com o Adailton. Idioma do projeto: português do Brasil.

## Estado atual
- Protótipo v8 (Python/SQLite, HTML/JS) e documentação servem de referência; o desenvolvimento na stack definitiva está começando.
- Protótipo 1 (cadastro, verificação de e-mail, 2FA e login) aprovado.
- Modelo de dados de referência: `docs/safety_car_modelo_dados_v1.sql`. A tarefa atual está descrita em `docs/PROMPT_BANCO_INICIAL.md`, que prevalece sobre o SQL v1 em caso de conflito.
- **Banco inicial concluído e testado** (PostgreSQL 16 + PostGIS 3.6 em Docker): migrações `db/migrations/0001` a `0007` (extensões, núcleo, tomador, parceiro tipificado, geo, antifraude base e permissões) e testes em `db/tests` (`bash db/scripts/testar.sh`). Documentação, decisões e pendências em `docs/BANCO_DE_DADOS.md`.
  - Papéis: `safetycar_migrator` (aplica migrações) e `safetycar_app` (DML, sem DDL). A `0001` roda como superusuário (PostGIS).
  - Migração aplicada não se edita: o `migrar.sh` confere o sha256. Toda migração nova declara os GRANTs do `safetycar_app` (não há default privileges).
  - Já decidido nesta fase: `tipo_parceiro` com `exige_viatura` e `permite_viatura` (guincho exige; mecânica e chaveiro permitem; seguros não); registro Susep exigido na aprovação; CNPJ numérico e alfanumérico com DV; área de atuação por centro + raio.
  - Fora do Git até revisão: zips, docx, pdf, html, png, `files/` e `docs/README.md` (README do protótipo v5, com senhas de demonstração).

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
- CPF obrigatório (momento a confirmar: no cadastro ou antes do primeiro chamado).
- Verificação do celular obrigatória.
- Migrar do protótipo Python/SQLite.
- Módulo de seguros na Fase 1 (escopo a definir).
- Identidade visual da v8.
- Protótipos 1 a 3 (cadastro e 2FA, verificação de identidade e documentos do parceiro, painel da Central) feitos no canvas; as perguntas de validação estão na seção 15 do documento de alinhamento.

## Decisões pendentes (NÃO assumir; perguntar)
Confirmação do Keycloak com o Adailton, confirmação da regra de 2FA, momento de exigência do CPF, canal de verificação do celular (SMS ou WhatsApp), escopo do módulo de seguros, processador de pagamento, regras de cancelamento e taxas, serviços por nível de verificação, motor de rotas e tempo de chegada (serviço externo ou pgRouting), retenção de histórico de GPS e base legal.

## Como trabalhar neste repositório
- Para qualquer mudança que toque mais de um arquivo, propor um plano antes de editar.
- Migração já aplicada não se edita; cria-se uma nova.
- Commits pequenos, com mensagem em português descrevendo o porquê.
- Não rodar comandos destrutivos nem instalar dependências sem pedir confirmação.
- Em dúvida de regra de negócio, perguntar em vez de inventar.
