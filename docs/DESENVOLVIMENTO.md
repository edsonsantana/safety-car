# Safety Car

Plataforma de assistência rodoviária conectada (guincho, mecânica e serviços correlatos). Contexto, terminologia e regras do projeto estão em [`CLAUDE.md`](../CLAUDE.md).

## Banco de dados local

PostgreSQL 16 + PostGIS em Docker. O `psql` roda dentro do contêiner, então nada é instalado no computador. No Windows, use o Git Bash. Documentação completa: [`docs/BANCO_DE_DADOS.md`](BANCO_DE_DADOS.md).

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

Sobe junto com o `docker compose up -d`. O console fica em http://localhost:8180/admin (porta `KEYCLOAK_PORTA` do `.env`; usuário e senha `KEYCLOAK_ADMIN_*`). O realm `safetycar-dev` é importado de `keycloak/realms/safetycar-dev.json`, que não tem usuários nem segredos. Detalhes em [`docs/KEYCLOAK.md`](KEYCLOAK.md).

## API (`apps/api`)

Node.js 24 + TypeScript (Fastify, `pg`, Zod e `jose`). Ela valida os tokens do Keycloak e conecta ao banco com **dois pools separados**: o do app, **sempre** como `safetycar_app`, e o da Central (rotas `/central`), **sempre** como `safetycar_central`. Lê o `.env` da raiz e falha na subida, com a lista do que falta, se alguma variável estiver ausente ou inválida. Desde a etapa 2 da Central, `API_CENTRAL_DB_SENHA` é obrigatória.

```bash
cd apps/api
npm ci                        # instala as dependências do package-lock.json
npm run dev                   # sobe em http://127.0.0.1:3000 e reinicia ao salvar (log legível com pino-pretty)
npm test                      # testes unitários (não precisam de Docker)
npm run test:integracao       # testes contra o banco real (docker compose up -d + migrações)
npm run lint                  # tsc, ESLint e Prettier
npm run build                 # gera dist/ (npm start roda o dist/)
bash db/scripts/testar_api_central.sh  # (na raiz) integração da Central num banco descartável
```

| Rota | Autenticação | Resposta |
|---|---|---|
| `GET /saude` | pública | `200 {"status":"ok","banco":"ok"}`, ou `503` se o banco não responde |
| `GET /me` | `Authorization: Bearer <token de acesso do realm safetycar-dev>` | `200 {"perfil":"tomador\|parceiro\|central","status":"ativo"}` ou `200 {…,"status":"pendente"}`; `403 acesso_restrito` sem registro, suspenso, bloqueado ou excluído (mesma resposta para todos); `401` sem token ou com token inválido; `503` se o Keycloak não fornece as chaves ou o banco não responde |

- **Log:** JSON, uma linha por requisição (método, rota, status e duração). Não registra corpo, query, cabeçalhos, IP, token nem `keycloak_sub`. Chaves como `cpf`, `email` e `celular` são trocadas por `[removido]`.
- **Erros:** formato único `{"erro":{"codigo","mensagem"}}`. Um `500` responde só com mensagem genérica.
- **`npm audit`:** sem vulnerabilidades (conferido em 2026-11-21; o ReDoS do `picomatch` apontado antes já não aparece).

### API da Central (`/central`)

Módulo próprio em `apps/api/src/central`. Usa o pool do `safetycar_central` e aceita **só** tokens do client da Central. Hoje tem a base (etapa 2): as leituras e as escritas da Central entram nas etapas seguintes.

| Variável | Padrão | Uso |
|---|---|---|
| `API_CENTRAL_DB_USUARIO` | `safetycar_central` | papel do pool da Central; qualquer outro é recusado. O pool do app, por sua vez, recusa o `safetycar_central` |
| `API_CENTRAL_DB_SENHA` | (obrigatória) | mesmo valor de `SAFETYCAR_CENTRAL_PASSWORD` |
| `KEYCLOAK_CENTRAL_CLIENT_ID` | `safetycar-central` | `azp` exigido em `/central`; precisa ser diferente de `KEYCLOAK_CLIENT_ID`. O client nasce na etapa do realm |
| `KEYCLOAK_CENTRAL_ACR` | `2` | valor **exato** do `acr` de nível 2 (senha + OTP). Provisório até a conferência com token real |

Na subida, a API confere que o pool da Central é o `safetycar_central`, sem superusuário nem DDL e sem SELECT em `usuario`, e que ele executa `ator_central`, isto é, que a migração 0021 foi aplicada.

**Cada requisição** a `/central`:
1. Token válido do client da Central. Sem token ou com token inválido, inclusive um token do `safetycar-web`: `401`.
2. `acr` **exatamente igual** a `KEYCLOAK_CENTRAL_ACR`, e `auth_time` presente. Qualquer outro valor, inclusive `"1"` (só senha), `"0"` (SSO) e o número 2, recebe `401 segundo_fator_exigido` com `WWW-Authenticate: Bearer …, error="insufficient_user_authentication", acr_values="2"` (RFC 9470). Nesse caso o banco não é consultado.
3. O ator vem do `sub` por `ator_central`, **nunca** do corpo nem da URL. Sem ator: `403 acesso_negado`, a mesma resposta para quem não tem registro, não é operador, está inativo, não tem a permissão ou recebeu SC016.
4. Limite por ator.
5. Nas ações sensíveis (★, nas próximas etapas): permissão da rota (o mesmo 403) e depois OTP recente, com `auth_time` de até 600 s. Fora disso, `401 otp_recente_exigido` com `max_age=600`.

| Rota | Resposta |
|---|---|
| `GET /central/eu` | `200 {"permissoes":[{"codigo","sensivel"}],"otp":{"recente":true,"validoAte":"<ISO>"}}`. Com o OTP vencido, `recente:false` e `validoAte:null`. Sem id, `sub`, e-mail nem nome |
| `POST /central/sessao` | `204`, sem corpo. Grava o `central_acesso` (último acesso). A repetição do mesmo login (mesmo `sub` e `auth_time`) é ignorada; se a gravação falhar, a próxima chamada grava |

- **Erros do banco:** cada SQLSTATE vira uma resposta fixa, e a mensagem do PostgreSQL, que traz UUIDs e valores, nunca é repassada.
  - `403`: SC016 e SC017.
  - `409`: SC013, SC018, SC020, SC021, SC023, SC024, SC027, SC028, `23505`, `40P01`, `40001` e `55P03` (estes três como `tente_novamente`).
  - `422`: SC012, SC019, SC022, SC025, SC026, `22023`, `22P02` e `23514`.
  - `503`: `57014` e falha de conexão.
  - `500`: qualquer outro, inclusive SC029 e SC030.
  - O log registra **só o nome da função e o SQLSTATE**.
- **Limite de requisições, em memória: vale para UMA instância.**
  - Por ator, 120 leituras (GET) e 20 escritas por minuto. Por IP, 30 respostas `401`/`403` por minuto; atingido esse limite, o IP recebe `429` antes de o token ser lido.
  - O `429` vem com `retry-after`.
  - O IP é guardado como pseudônimo (HMAC com chave aleatória do processo) e nunca vai para o log.
  - Com mais de uma instância, ou atrás de proxy (hoje `trustProxy` está desligado, e o IP visto é o do proxy), o limite precisa ir para um armazenamento compartilhado ou para o proxy.
  - O registro de sessões do `POST /central/sessao` também fica em memória.
- `cache-control: no-store` em toda resposta de `/central`. Sem CORS: em desenvolvimento, o Vite serve tudo na mesma origem.
- **Testes de integração:** `bash db/scripts/testar_api_central.sh`.
  - O script recria o banco descartável `safetycar_api_teste`, aplica as migrações, carrega a semente fictícia como migrator, roda `npm run test:integracao:central` e apaga o banco no fim.
  - Ele recusa o `safetycar`, e o teste em Node recusa qualquer `API_DB_NOME` que não seja `safetycar_api_teste`.
  - Precisa de `API_CENTRAL_DB_SENHA` no `.env`. Os tokens são assinados com chaves locais, sem Keycloak.

## Frontend (`apps/web`)

React 19 + TypeScript + Vite + Tailwind 4, com a identidade visual da v8. Plano em [`docs/PLANO_FRONTEND.md`](PLANO_FRONTEND.md). Login pelo Keycloak (seção abaixo); ainda sem formulários reais.

```bash
cd apps/web
npm ci                        # instala as dependências do package-lock.json
npm run dev                   # sobe na porta 5173: abra http://localhost:5173 (não 127.0.0.1; ver Login); /api vai para a API pelo proxy
npm test                      # testes de componente (Vitest + Testing Library + axe)
npm run lint                  # tsc, ESLint (com jsx-a11y) e Prettier
npm run build                 # teste de contraste, gera dist/ e confere que /componentes ficou de fora
```

| Rota | Layout | Acesso | Conteúdo |
|---|---|---|---|
| `/` | escuro (entrada) | pública | tela de entrada: ENTRAR (Keycloak) e "Criar conta"; quem já entrou vai ao próprio início |
| `/entrando` | escuro | pública | retorno do Keycloak ("Entrando…") e erro com "Tentar de novo" |
| `/acesso-restrito` | escuro | com sessão | Acesso restrito: "Ir para o meu início" (só com perfil ativo) e "Sair" |
| `/tomador`, `/parceiro` | móvel (390 px) | perfil correspondente, ativo | só o título e "Sair" |
| `/central` | painel (menu lateral, gaveta em tela estreita) | perfil `central`, ativo | só o título e "Sair" |
| `/cadastro`, `/verificacao` | móvel | pública | só o título |
| `/entrar` | | | redireciona para `/` (o login agora é no Keycloak) |
| `/componentes` | móvel | pública | componentes-base e estado do `GET /saude`, **só em desenvolvimento** |

- **Configuração:** o Vite lê o `.env` da raiz. `VITE_API_BASE` (padrão `/api`) vai para o navegador, portanto **nunca** segredo em variável `VITE_*`. `API_URL_DEV` (padrão `http://127.0.0.1:3000`) é o destino do proxy; o proxy remove o prefixo `/api`, então não há CORS.
- **Cores:** só os tokens do `@theme` em `src/estilos.css` (a paleta padrão do Tailwind foi removida), inclusive `fundo-escuro` (#07162D), `anel` (#12335F) e `texto-claro` (#B9C8E0) das telas de entrada. O fundo com os dois painéis diagonais é a classe `fundo-diagonais` (CSS puro). O `src/estilos.test.ts` confere o contraste de cada par em uso (4,5:1 para texto e 3:1 para componentes) e roda no build. O verde-limão nunca vai sobre fundo claro como texto ou botão; a única exceção é a barra decorativa à esquerda do aviso em Acesso restrito, do desenho aprovado.
- **Acessibilidade:** `lang="pt-BR"`, link "Pular para o conteúdo", foco visível (anel azul-marinho no claro e verde-limão no azul-marinho), alvos de pelo menos 44 px e respeito a `prefers-reduced-motion`. Cada componente tem teste com o `vitest-axe`.
- **Fontes, logo e ícones:** Inter no corpo e Playfair Display 700 (subconjunto latino) só no nome da marca, ambas servidas pelo próprio app (`@fontsource`, sem Google Fonts). O logo das telas de entrada é `public/logo-icone.png`, cópia de `docs/Imagens/logo-icone.png`. Os ícones originais da v8 estão em `docs/marca/`.
- **Botão principal:** pílula verde-limão com texto azul-marinho em caixa-alta (`Botao` e `classesBotao('principal')`), só sobre fundo escuro.
- **ESLint 10:** o `eslint-plugin-jsx-a11y` ainda não declara suporte; o `overrides` do `package.json` só relaxa esse peer (as regras foram conferidas funcionando).
- **`npm audit`:** sem vulnerabilidades (conferido em 2026-11-21). Licenças das dependências do login: `oidc-client-ts` 3.5.0 (Apache-2.0, com `jwt-decode` 4.0.0, MIT) e `@fontsource/playfair-display` 5.3.0 (fonte sob OFL-1.1).

## Login (Keycloak no app e na API)

O Keycloak guarda só a identidade (senha, TOTP, recuperação). O **perfil** (`tomador`, `parceiro`, `central`) e o **status** vêm sempre do banco, em `usuario.perfil` e `usuario.status`, ligados ao token por `usuario.keycloak_sub` = `sub`. Nada além do `sub` é lido do token.

### Como funciona

1. **ENTRAR** (`/`) leva ao Keycloak com Authorization Code + **PKCE S256**, pelo client público `safetycar-web` (sem segredo). Biblioteca: `oidc-client-ts`, escolhida por ser OIDC padrão: se o provedor mudar (a confirmação do Keycloak com o Adailton está pendente), o app só troca as variáveis.
2. O Keycloak volta para **`/entrando`**, que troca o código pelo token e chama o **`GET /me`** da API.
3. Com `status: "ativo"`, o usuário segue para o destino ou para o próprio início (`/tomador`, `/parceiro`, `/central`). Com `pendente`, ou com `403` (sem registro, suspenso, bloqueado, excluído), vai para **Acesso restrito**.
4. As rotas protegidas conferem o perfil. Isso é só experiência de uso: quem protege os dados é a API, rota a rota.
5. **Sair** apaga a sessão da memória e encerra a sessão no Keycloak (`end_session` com `id_token_hint`), voltando para `/`.

**Onde ficam os tokens:** só em memória (`InMemoryWebStorage`), nunca em `localStorage` ou `sessionStorage`. O `sessionStorage` guarda apenas o `state`, o `nonce` e o verificador PKCE durante a ida ao Keycloak (a memória se perde no redirecionamento), e a biblioteca os apaga no retorno.

**F5 (recarregar a página):** a memória é perdida. Na abertura, o app tenta uma **renovação silenciosa**: um iframe oculto com `prompt=none` em `/renovar-sessao.html`, que usa o cookie de sessão do próprio Keycloak. Se funcionar, o usuário vê "Entrando…" por um instante e continua onde estava; se não (sessão expirada, `login_required`, 2FA pendente), volta à tela de entrada. Com o app aberto, a renovação usa o refresh token em memória. Custos:
- uma ida ao Keycloak a cada F5;
- a sessão do app dura o mesmo que a sessão SSO do realm (30 min ociosa, 10 h no máximo);
- em produção, o Keycloak precisa estar no **mesmo site** do app (ex.: `auth.dominio` e `app.dominio`); se não, os navegadores bloqueiam o cookie no iframe e todo F5 vira um novo login. O `monitorSession` (iframe de check-session) fica desligado pelo mesmo motivo.

**API:** valida o token com `jose` contra o JWKS do realm: assinatura RS256, `iss` = `KEYCLOAK_ISSUER`, `aud` contém `KEYCLOAK_AUDIENCE`, `azp` = `KEYCLOAK_CLIENT_ID`, `exp`, `typ` = `Bearer` e `sub` em formato uuid. Consulta o banco como `safetycar_app`. O `GET /me` não devolve e-mail, id nem `sub`, responde com `no-store`, e o log não registra `sub` nem token.

### Configuração

Variáveis no `.env` da raiz (valores de desenvolvimento no `.env.example`; nenhuma é segredo):

| Variável | Quem usa | Desenvolvimento |
|---|---|---|
| `KEYCLOAK_PORTA` | Docker | `8180` |
| `KEYCLOAK_ISSUER` | API | `http://localhost:8180/realms/safetycar-dev` |
| `KEYCLOAK_AUDIENCE` | API | `safetycar-api` |
| `KEYCLOAK_CLIENT_ID` | API (`azp`) | `safetycar-web` |
| `VITE_KEYCLOAK_URL` | navegador | `http://localhost:8180` |
| `VITE_KEYCLOAK_REALM` | navegador | `safetycar-dev` |
| `VITE_KEYCLOAK_CLIENT_ID` | navegador | `safetycar-web` |
| `VITE_CADASTRO_HABILITADO` | navegador | `false`: mostra "Criar conta, em breve", sem link. Com `true`, "Criar conta" abre o cadastro do Keycloak (`prompt=create`), o que exige "User registration" ligado no realm |

### Client `safetycar-web` no console

O `keycloak/realms/safetycar-dev.json` já traz esta configuração para volumes novos. Num Keycloak já existente, o realm não é reimportado: confira no console, em http://localhost:8180/admin → realm **safetycar-dev** → *Clients* → **safetycar-web**:

1. **Settings → Capability config:** *Client authentication* **Off** (público). Só *Standard flow* marcado; *Direct access grants*, *Implicit flow*, *Service accounts*, *OAuth 2.0 Device Authorization Grant* e *OIDC CIBA Grant* desmarcados.
2. **Settings → Access settings:**
   - *Root URL* e *Home URL*: `http://localhost:5173`
   - *Valid redirect URIs* (exatamente estas duas, sem `/*`): `http://localhost:5173/entrando` e `http://localhost:5173/renovar-sessao.html`
   - *Valid post logout redirect URIs*: `http://localhost:5173/`
   - *Web origins*: `http://localhost:5173`
3. **Advanced → Advanced settings:** *Proof Key for Code Exchange Code Challenge Method* = **S256**.
4. **Settings → Logout settings:** *Front channel logout* **On**.
5. **Advanced → OpenID Connect Compatibility Modes:** *Use refresh tokens* **On**; *Always use lightweight access token* **Off**.
6. **Client scopes → safetycar-web-dedicated → Mappers:** o mapeador `audiencia-safetycar-api` (*Included Custom Audience* `safetycar-api`, *Add to access token* **On**).

Abra o app sempre em **`http://localhost:5173`**. Para o OIDC, `127.0.0.1:5173` é outra origem, e o Keycloak recusaria o retorno.

### Rodar e testar o login

```bash
docker compose up -d && bash db/scripts/migrar.sh
cd apps/api && npm run dev        # num terminal
cd apps/web && npm run dev        # em outro; abra http://localhost:5173
```

Para entrar, o usuário precisa existir no Keycloak **e** ter uma linha em `usuario` com o mesmo `keycloak_sub` (o `sub` do usuário, visto em *Users* → *Details* → *ID*) e `status = 'ativo'`. Sem a linha, o login termina em Acesso restrito (ainda não há provisionamento de usuários). Use só dados fictícios (`@exemplo.invalid`) e nada disso vai para o Git.

### Pendências desta etapa

- **"Falar com a Central"** não aparece em Acesso restrito até haver um canal definido (telefone, WhatsApp ou e-mail).
- **Cadastro pelo app:** "Criar conta" está pronto, mas desligado (`VITE_CADASTRO_HABILITADO=false` e cadastro desligado no realm). Falta decidir o fluxo e o provisionamento da linha em `usuario`.
- **Tema do Keycloak:** feito (tema de login `safetycar`). Ativação, testes e checklist em [`docs/KEYCLOAK.md`](KEYCLOAK.md#tema-de-login-safetycar).
- **Pendente × restrito:** a API já separa `pendente` (200) de sem registro, suspenso, bloqueado e excluído (o mesmo 403), mas o app ainda trata os dois como Acesso restrito, com o mesmo texto ("Sua conta ainda não foi liberada para esta área.").
