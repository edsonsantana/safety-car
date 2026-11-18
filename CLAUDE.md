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
- **Keycloak de desenvolvimento** no `docker-compose.yml` (26.8.2, `start-dev`, só em 127.0.0.1), com banco próprio (`keycloak-db`). O realm `safetycar-dev` é versionado em `keycloak/realms/safetycar-dev.json`, **sem usuários, senhas nem segredos**. O client `safetycar-web` é público, com PKCE S256 e `aud=safetycar-api`. Detalhes em `docs/KEYCLOAK.md`.
- **Esqueleto do backend** em `apps/api` (Node 24 + TypeScript estrito; Fastify, `pg`, Zod, `jose` e pino-pretty em dev; testes com `node:test`). Ainda sem regra de negócio: `GET /saude` (SELECT 1) e `GET /eu` (valida o JWT do Keycloak e devolve o `keycloak_sub`).
  - Conecta só como `safetycar_app`: a configuração recusa `safetycar_migrator` e `postgres`, e a subida recusa papel superusuário ou com CREATE no schema `public`.
  - Configuração por variáveis de ambiente (`API_*` e `KEYCLOAK_*`, lidas do `.env` da raiz), validada na subida.
  - Log sem dados pessoais: sem corpo, query, cabeçalhos, IP, token nem `keycloak_sub`; o `detail` dos erros do PostgreSQL é removido.
  - SQL puro parametrizado, sem ORM nem construtor de consultas (decidido; reavaliar quando houver consultas reais).
- **Esqueleto do frontend** em `apps/web` (React 19 + TypeScript estrito; Vite 8, Tailwind 4, React Router 7 declarativo; testes com Vitest, Testing Library e `vitest-axe`), conforme `docs/PLANO_FRONTEND.md`. Ainda sem autenticação nem formulários reais.
  - Componentes-base em `src/componentes` (Botao, CampoTexto, CampoCodigo, IndicadorEtapas, CartaoAviso, SeloStatus); layouts móvel (390 px) e de painel em `src/layouts`; rotas vazias `/cadastro`, `/entrar`, `/verificacao` e `/central`; `/componentes` só em desenvolvimento (o build confere que ela não vai para o `dist/`).
  - Cores só pelos tokens do `@theme` em `src/estilos.css`; o teste de contraste roda no build. Verde-limão nunca sobre fundo claro.
  - A página inicial mostra o estado do `GET /saude` via proxy do Vite (`/api` → `API_URL_DEV`). Variáveis `VITE_*` vão para o navegador: nunca segredo nelas.
  - ESLint 10 com `overrides` relaxando só o peer do `eslint-plugin-jsx-a11y`. React Hook Form + Zod entram só com o primeiro formulário real.

## Comandos
```bash
docker compose up -d                                # banco, Keycloak e banco do Keycloak
bash db/scripts/migrar.sh                           # migrações no banco safetycar
bash db/scripts/testar.sh                           # testes do banco (recria safetycar_teste)
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
