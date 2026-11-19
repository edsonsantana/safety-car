# Safety Car

Plataforma de assistência rodoviária conectada (guincho, mecânica e serviços correlatos). Contexto, terminologia e regras do projeto estão em [`CLAUDE.md`](CLAUDE.md).

## Banco de dados local

PostgreSQL 16 + PostGIS em Docker. O `psql` roda dentro do contêiner, então nada é instalado no computador. No Windows, use o Git Bash. Documentação completa: [`docs/BANCO_DE_DADOS.md`](docs/BANCO_DE_DADOS.md).

```bash
cp .env.example .env          # troque TODOS os valores por senhas fortes (.env não vai para o Git)
docker compose up -d          # sobe o banco, o Keycloak e o banco do Keycloak
docker compose ps             # espere o status "healthy"
bash db/scripts/migrar.sh     # aplica as migrações no banco "safetycar"
bash db/scripts/testar.sh     # recria "safetycar_teste" do zero e roda todos os testes
```

Conexão a partir do computador: `127.0.0.1:5432` (ou `DB_PORTA`), banco `safetycar`, usuário `safetycar_app` e a senha do `.env`.

Para recomeçar do zero (**apaga os dados locais do banco e do Keycloak**): `docker compose down -v` e depois `docker compose up -d`.

O `docker compose` exige todas as variáveis marcadas como obrigatórias no `.env`, inclusive as do Keycloak. Ao atualizar o repositório em outro computador, compare o seu `.env` com o `.env.example`.

## Keycloak (desenvolvimento)

Sobe junto com o `docker compose up -d`. O console fica em http://localhost:8080/admin (porta `KEYCLOAK_PORTA` do `.env`; usuário e senha `KEYCLOAK_ADMIN_*`). O realm `safetycar-dev` é importado de `keycloak/realms/safetycar-dev.json`, que não tem usuários nem segredos. Detalhes em [`docs/KEYCLOAK.md`](docs/KEYCLOAK.md).

## API (`apps/api`)

Node.js 24 + TypeScript (Fastify, `pg`, Zod e `jose`). Ela conecta ao banco **sempre** como `safetycar_app` e valida os tokens do Keycloak. Lê o `.env` da raiz e falha na subida, com a lista do que falta, se alguma variável estiver ausente ou inválida.

```bash
cd apps/api
npm ci                        # instala as dependências do package-lock.json
npm run dev                   # sobe em http://127.0.0.1:3000 e reinicia ao salvar (log legível com pino-pretty)
npm test                      # testes unitários (não precisam de Docker)
npm run test:integracao       # testes contra o banco real (docker compose up -d + migrações)
npm run lint                  # tsc, ESLint e Prettier
npm run build                 # gera dist/ (npm start roda o dist/)
```

| Rota | Autenticação | Resposta |
|---|---|---|
| `GET /saude` | pública | `200 {"status":"ok","banco":"ok"}`, ou `503` se o banco não responde |
| `GET /eu` | `Authorization: Bearer <token de acesso do realm safetycar-dev>` | `200 {"keycloak_sub":"…"}`, `401` sem token ou com token inválido, `503` se o Keycloak não fornece as chaves |

- **Log:** JSON, uma linha por requisição (método, rota, status e duração). Não registra corpo, query, cabeçalhos, IP, token nem `keycloak_sub`. Chaves como `cpf`, `email` e `celular` são trocadas por `[removido]`.
- **Erros:** formato único `{"erro":{"codigo","mensagem"}}`. Um `500` responde só com mensagem genérica.
- **`npm audit`:** aponta um ReDoS no `picomatch`, que vem com o `typescript-eslint` (só desenvolvimento) e ainda não tem correção. As dependências de produção estão sem vulnerabilidades (`npm audit --omit=dev`).

## Frontend (`apps/web`)

React 19 + TypeScript + Vite + Tailwind 4, com a identidade visual da v8. Plano em [`docs/PLANO_FRONTEND.md`](docs/PLANO_FRONTEND.md). Ainda sem autenticação nem formulários reais: há os componentes-base, os layouts e as rotas vazias.

```bash
cd apps/web
npm ci                        # instala as dependências do package-lock.json
npm run dev                   # sobe em http://127.0.0.1:5173; /api vai para a API pelo proxy do Vite
npm test                      # testes de componente (Vitest + Testing Library + axe)
npm run lint                  # tsc, ESLint (com jsx-a11y) e Prettier
npm run build                 # teste de contraste, gera dist/ e confere que /componentes ficou de fora
```

| Rota | Layout | Conteúdo |
|---|---|---|
| `/` | móvel (390 px) | estado do `GET /saude`: ok, banco indisponível ou API indisponível |
| `/cadastro`, `/entrar`, `/verificacao` | móvel | só o título |
| `/central` | painel (menu lateral, gaveta em tela estreita) | só o título |
| `/componentes` | móvel | demonstração dos componentes-base, **só em desenvolvimento** |

- **Configuração:** o Vite lê o `.env` da raiz. `VITE_API_BASE` (padrão `/api`) vai para o navegador, portanto **nunca** segredo em variável `VITE_*`. `API_URL_DEV` (padrão `http://127.0.0.1:3000`) é o destino do proxy; o proxy remove o prefixo `/api`, então não há CORS.
- **Cores:** só os tokens do `@theme` em `src/estilos.css` (a paleta padrão do Tailwind foi removida). O `src/estilos.test.ts` confere o contraste de cada par em uso (4,5:1 para texto e 3:1 para componentes) e roda no build. O verde-limão nunca vai sobre fundo claro.
- **Acessibilidade:** `lang="pt-BR"`, link "Pular para o conteúdo", foco visível (anel azul-marinho no claro e verde-limão no azul-marinho), alvos de pelo menos 44 px e respeito a `prefers-reduced-motion`. Cada componente tem teste com o `vitest-axe`.
- **Fonte e ícones:** Inter servida pelo próprio app (sem Google Fonts). Os ícones originais da v8 estão em `docs/marca/`.
- **ESLint 10:** o `eslint-plugin-jsx-a11y` ainda não declara suporte; o `overrides` do `package.json` só relaxa esse peer (as regras foram conferidas funcionando).
- **`npm audit`:** o mesmo ReDoS do `picomatch` da API, aqui via Vite, Vitest e `typescript-eslint` (só desenvolvimento). As dependências de produção estão sem vulnerabilidades.
