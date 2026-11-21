# Keycloak (desenvolvimento)

O Keycloak guarda a senha, o TOTP e os códigos de recuperação. O banco da aplicação guarda só o vínculo `usuario.keycloak_sub`. A confirmação do Keycloak com o Adailton continua pendente (ver `CLAUDE.md`).

Esta configuração é **só para desenvolvimento local**: `start-dev`, HTTP sem TLS e portas apenas em 127.0.0.1. Produção vai exigir `start` com TLS, um hostname real e outra gestão de segredos.

## Como subir

```bash
cp .env.example .env     # se ainda não existir; troque TODOS os valores
docker compose up -d     # sobe db, keycloak-db e keycloak
docker compose ps        # espere "healthy" no keycloak (a primeira subida leva cerca de 1 min)
```

Os endereços abaixo usam a porta de desenvolvimento 8180, que é a `KEYCLOAK_PORTA` do `.env.example`; troque pela sua se for outra. Sem a variável, o `docker-compose.yml` publica na 8080.

- **Console de administração:** http://localhost:8180/admin. O usuário e a senha são `KEYCLOAK_ADMIN_USUARIO` e `KEYCLOAK_ADMIN_SENHA` do `.env`. Esse administrador do realm `master` só é criado na **primeira** subida: mudar o `.env` depois não muda a senha.
- **Descoberta OIDC do realm:** http://localhost:8180/realms/safetycar-dev/.well-known/openid-configuration
- **Recomeçar o Keycloak do zero** apaga usuários e configurações feitas no console, mas não toca no banco de negócio:
  ```bash
  docker compose rm -sf keycloak keycloak-db
  docker volume rm safetycar_keycloak_pgdata
  docker compose up -d
  ```
- **Trocar a porta:** a porta publicada é `KEYCLOAK_PORTA` (8180 no `.env.example`; 8080 se a variável faltar). No Windows a 8080 costuma estar reservada pelo sistema (erro *"forbidden by its access permissions"*); confira com `netsh interface ipv4 show excludedportrange protocol=tcp`. Ao trocar, ajuste **também** o `KEYCLOAK_ISSUER` da API (ex.: `http://localhost:8180/realms/safetycar-dev`) e o `VITE_KEYCLOAK_URL` do frontend (ex.: `http://localhost:8180`): nem o Node nem o Vite expandem `${KEYCLOAK_PORTA}` no `.env`. Depois, `docker compose up -d` recria o contêiner com o novo `KC_HOSTNAME`; o realm e os usuários não são afetados (o hostname não fica no banco). As redirect URIs do realm não mudam: apontam para o Vite (5173), não para o Keycloak.

## Contêineres

| Serviço | Imagem (tag fixada) | Digest (verificado em 2026-11-18) | Porta |
|---|---|---|---|
| `keycloak` | `quay.io/keycloak/keycloak:26.8.2` | `sha256:c68e286cacd87b942ac1939a0a1481461109d6acd3a57dc496969a319a76bbf0` | `127.0.0.1:${KEYCLOAK_PORTA}` → 8080 |
| `keycloak-db` | `postgres:16-alpine` (16.16) | `sha256:81e77a4833487b8132fe4b00bedd39dc3f74b8641e387f19312a48f7de218c2e` | nenhuma (rede interna do compose) |

- **Banco do Keycloak:** é próprio, separado do banco de negócio (`db`), no volume `safetycar_keycloak_pgdata`. Os dois nunca se misturam, e recriar um não afeta o outro.
- **Credenciais:** só no `.env` (`KEYCLOAK_DB_PASSWORD`, `KEYCLOAK_ADMIN_USUARIO` e `KEYCLOAK_ADMIN_SENHA`). O `.env.example` tem valores fictícios.
- **`KC_HOSTNAME=http://localhost:${KEYCLOAK_PORTA}`:** fixa o `iss` dos tokens em `http://localhost:${KEYCLOAK_PORTA}/realms/safetycar-dev`, que é o valor esperado pela API (`KEYCLOAK_ISSUER`). Acessar por `127.0.0.1` em vez de `localhost` não muda o `iss`.
- **Healthcheck:** consulta `/health/ready` na porta de gerenciamento (9000), que não é publicada.

## Realm `safetycar-dev`

Arquivo versionado em `keycloak/realms/safetycar-dev.json`. A importação acontece na subida (`--import-realm`) **só se o realm ainda não existir**. Por isso, mudar o JSON depois exige recriar o Keycloak (ver acima) ou aplicar a mudança no console.

**O arquivo não contém usuários, senhas nem segredos de cliente.** Os usuários de teste são criados no console do seu Keycloak local e ficam fora do Git.

| Configuração | Valor | Motivo |
|---|---|---|
| Cadastro pelo próprio Keycloak | desligado | o cadastro será feito pelo app (fluxo ainda não definido) |
| Login | por e-mail (e-mail como nome de usuário, sem duplicidade) | igual ao protótipo 1 |
| Política de senha | `length(12) and notUsername and notEmail` | **proposta, a confirmar** |
| Proteção contra força bruta | ligada: 5 falhas, espera crescente de 1 a 15 min | |
| Token de acesso | 5 min | |
| Sessão | 30 min ociosa, 10 h no máximo | |
| Idioma | pt-BR | |
| Tema de login | `safetycar` | identidade do Safety Car (ver [Tema de login](#tema-de-login-safetycar)) |
| **OTP** | TOTP, HmacSHA1, 6 dígitos, 30 s, janela 1, código não reutilizável | compatível com Google Authenticator e Microsoft Authenticator (regra de segurança do projeto) |
| 2FA obrigatório | **não configurado** | a regra (incentivado para o tomador, obrigatório para parceiro e Central) é proposta, a confirmar |

### Client `safetycar-web`

É o cliente do frontend (`apps/web`), que usa o `oidc-client-ts` (Authorization Code com PKCE S256, tokens só em memória). Passo a passo no console e funcionamento do login: [`docs/DESENVOLVIMENTO.md`](DESENVOLVIMENTO.md#login-keycloak-no-app-e-na-api).

| Configuração | Valor |
|---|---|
| Tipo | **público** (`publicClient: true`), **sem segredo** |
| Fluxo | Authorization Code com **PKCE obrigatório, método S256** |
| Implicit, Direct Access Grants (senha direta), Service Account, Device, CIBA | desligados |
| Root URL e Home URL | `http://localhost:5173` (servidor de desenvolvimento do Vite) |
| Valid redirect URIs | **exatas**, sem curinga: `http://localhost:5173/entrando` (retorno do login) e `http://localhost:5173/renovar-sessao.html` (renovação silenciosa, iframe oculto) |
| Valid post logout redirect URIs | `http://localhost:5173/` |
| Web origins | `http://localhost:5173` (CORS da troca do código pelo token, feita pelo navegador) |
| Front channel logout | ligado |
| Use refresh tokens | ligado (o refresh token fica só na memória do app) |
| Lightweight access token | desligado |
| `fullScopeAllowed` | `false`: o token não carrega papéis que o client não pediu |
| Mapeador `audiencia-safetycar-api` | acrescenta `aud: "safetycar-api"` ao **token de acesso**. É o valor que a API exige (`KEYCLOAK_AUDIENCE`) |

A API não é um client do Keycloak: ela só **valida** tokens (assinatura via JWKS, `iss`, `aud`, `azp` igual a `safetycar-web` e `exp`). Por isso não existe segredo de cliente nenhum.

## Como conferir

Lendo a configuração do próprio Keycloak, com um token de administrador do realm `master`:

```bash
set -a; . ./.env; set +a
TOKEN=$(curl -s -d grant_type=password -d client_id=admin-cli \
  --data-urlencode "username=$KEYCLOAK_ADMIN_USUARIO" --data-urlencode "password=$KEYCLOAK_ADMIN_SENHA" \
  "http://localhost:${KEYCLOAK_PORTA:-8180}/realms/master/protocol/openid-connect/token" | python -c "import json,sys;print(json.load(sys.stdin)['access_token'])")
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:${KEYCLOAK_PORTA:-8180}/admin/realms/safetycar-dev/clients?clientId=safetycar-web"
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:${KEYCLOAK_PORTA:-8180}/admin/realms/safetycar-dev/users/count"   # 0 depois da importação
```

## Usuário de teste local

Pelo console: realm **safetycar-dev** → *Users* → *Create user*. Use um e-mail fictício (por exemplo, `teste@exemplo.invalid`) e defina a senha em *Credentials*. Esse usuário existe só no seu volume local. Nunca o registre no Git nem em ambiente compartilhado.

## Tema de login `safetycar`

As telas que o Keycloak hospeda (e-mail e senha, código do autenticador, cadastro do autenticador com QR, troca de senha, esqueci a senha e erro) usam o tema `keycloak/themes/safetycar/login/`. Ele é montado **somente leitura** em `/opt/keycloak/themes/safetycar`. O app nunca toca em senha.

### Estrutura

| Arquivo | O que faz |
|---|---|
| `theme.properties` | `parent=keycloak.v2`, o tema de login padrão da 26 (PatternFly 5). Acrescenta `css/safetycar.css` depois do CSS do pai. `darkMode=false`, porque a identidade é fixa; isso também tira o script de modo escuro do pai |
| `resources/css/safetycar.css` | todo o visual. As cores são variáveis `--sc-*` no `:root`; os ícones são SVG embutidos (`data:`) |
| `resources/img/logo-icone.png` | cópia do `apps/web/public/logo-icone.png` |
| `resources/fonts/` | Inter (variável, latin) e Playfair Display 700 (latin), copiadas dos pacotes `@fontsource` do `apps/web`, com as licenças OFL |
| `messages/messages_pt_BR.properties` | só os textos que mudam: cabeçalho, mensagem genérica de credencial inválida, OTP, QR, erro e outros |

- **Nenhum template `.ftl` é sobrescrito.** Cada `.ftl` copiado teria de ser reconciliado a cada upgrade do Keycloak. O que dependeria de template sai por outros meios:
  - **Cabeçalho:** a mensagem `loginTitleHtml` traz `<span class="sc-nome">` e `<span class="sc-lema">`, que o `kcSanitize` aceita.
  - **Logo:** pseudo-elemento no CSS.
  - **Variações por tela:** o `<body data-page-id="login-…">`. Por exemplo, o logo de 130 px em `login-login-otp` e `login-error`.
- **OTP:** o tema pai já põe `inputmode="numeric"` e `autocomplete="one-time-code"` no campo. Ele fica único, grande e com espaçamento entre os dígitos, sem caixas separadas e sem JavaScript.
- **Celular** (até 959 px):
  - fundo #07162D com dois painéis diagonais e cartão translúcido;
  - campos em pílula com borda verde-limão;
  - botão verde-limão com texto #0B1F3A;
  - links brancos e "Criar conta" em #D4FF00.
- **Desktop** (a partir de 960 px):
  - painel azul de 560 px com nome, logo de 260 px e uma frase neutra, que serve a tomador, parceiro e Central;
  - formulário sobre #F4F7FB, com campos retangulares;
  - **botão azul-marinho #0B1F3A com texto branco**: o verde-limão fica só nos fundos escuros (regra do projeto);
  - rótulos #14233B e links #0B1F3A sublinhados.
- **Ícones e autofill:** o ícone fica no `::before` e a borda no `::after` do contêiner do campo, acima do input. O autofill do navegador é neutralizado com uma sombra interna da cor do campo e `-webkit-text-fill-color`, sem transições longas nem JavaScript. Assim, ele não cobre nem o ícone nem a borda.
- **Mensagem de erro de login genérica:** "E-mail ou senha inválidos." também no bloqueio temporário. Assim, a tela não revela se o e-mail existe.
- **Segurança:** o tema não acrescenta nenhum script nem recurso externo, e a CSP do Keycloak (`frame-src 'self'; frame-ancestors 'self'; object-src 'none';`) não foi relaxada. Os scripts inline que restam são do template do próprio Keycloak.

### Ativar

- **Volume novo:** o `safetycar-dev.json` já traz `"loginTheme": "safetycar"`.
- **Realm já existente:**
  1. `docker compose up -d keycloak`: recria o contêiner com o volume do tema. Usuários e configuração ficam no `keycloak-db` e não são afetados.
  2. Console → realm **safetycar-dev** → *Realm settings* → *Themes* → *Login theme* = **safetycar** → *Save*.
  3. *Realm settings* → *Localization*: confira *Internationalization* **On**, *Default locale* **pt-BR** e só o pt-BR suportado.

No `start-dev`, o cache de temas fica desligado: mudanças no CSS ou nas mensagens aparecem ao recarregar a página.

### Testar

```bash
node --test keycloak/tests/tema.test.mjs   # estrutura, sem Keycloak rodando
bash keycloak/scripts/conferir_tema.sh     # no Keycloak local: só leitura
```

- **`tema.test.mjs`** confere:
  - o tema pai e as propriedades;
  - que os arquivos referenciados existem e que não há URL externa nem `@import`;
  - que não há nenhum `.ftl`;
  - que as mensagens estão em UTF-8 e sem script;
  - que as fontes têm licença;
  - o **contraste de 4,5:1** de cada par de texto, calculado das variáveis do `:root`, com o cartão translúcido composto sobre o fundo e sobre cada painel diagonal;
  - que o desktop não usa verde-limão e tem o botão #0B1F3A com texto branco;
  - o `loginTheme` no realm.
- **`conferir_tema.sh`** confere:
  - que o tema está montado e o volume é somente leitura;
  - que a página de login está em pt-BR e usa o tema;
  - que não há o script de modo escuro;
  - que a CSP está idêntica;
  - que não há nenhum host externo;
  - que cada CSS, script, fonte e imagem responde 200 com o tipo certo.

**Checklist manual.** Use um usuário fictício `@exemplo.invalid`. Confira cada tela em 390 px e em 1280 px: no teclado (foco visível em campos, botões e links), com zoom de 200 %, e confira que nenhum texto fica em inglês.
- [ ] **E-mail e senha:** a tela de entrada do app (`http://localhost:5173`) → ENTRAR.
- [ ] **Erro de login:** senha errada. Esperado: caixa vermelho-clara com ícone, "E-mail ou senha inválidos.", os dois campos com borda vermelha.
- [ ] **Cadastro do autenticador (QR):** *Users* → usuário → *Required user actions* = *Configure OTP*. No próximo login, confira os passos numerados, o QR sobre fundo branco e o link "Não consegue ler o código QR?", que mostra a chave.
- [ ] **Código do autenticador:** depois de cadastrado, no login seguinte. Esperado: campo único, numérico, centralizado, e o logo de 130 px.
- [ ] **Troca de senha:** *Required user actions* = *Update Password*.
- [ ] **Esqueci a senha:** fica desligada no realm. Para ver a tela, ligue temporariamente *Realm settings* → *Login* → *Forgot password* e desligue depois. Sem SMTP, o envio falha.
- [ ] **Página de erro:** abra a URL de login com `redirect_uri=http://localhost:5173/nao-existe`.

### Upgrade do Keycloak

O tema depende das classes do PatternFly 5 (`pf-v5-c-*`) e da estrutura do `template.ftl` do `keycloak.v2`: `#kc-header-wrapper`, `data-page-id`, `#kc-totp-settings` e `.kc-qr-code`. Ao trocar a versão da imagem:
1. Rode os dois testes.
2. Repasse o checklist.
3. Se o pai mudou de PatternFly (por exemplo, para o v6), revise o `safetycar.css`.

### Pendências do tema

- O favicon ainda é o do Keycloak. Falta um `.ico` do Safety Car.
- A borda dos campos no desktop (#C9D3E2 sobre #F4F7FB) foi a aprovada no protótipo, mas tem contraste baixo para limite de componente (WCAG 1.4.11 pede 3:1). O rótulo acima e o foco forte compensam. Reavaliar na revisão de acessibilidade.
