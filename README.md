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

Sobe junto com o `docker compose up -d`. O console fica em http://localhost:8080/admin (usuário e senha `KEYCLOAK_ADMIN_*` do `.env`). O realm `safetycar-dev` é importado de `keycloak/realms/safetycar-dev.json`, que não tem usuários nem segredos. Detalhes em [`docs/KEYCLOAK.md`](docs/KEYCLOAK.md).

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
