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
