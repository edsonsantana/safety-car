#!/usr/bin/env bash
# Papéis de banco num volume JÁ EXISTENTE (em volume novo, quem cria é db/init/01_papeis.sh).
#
#   bash db/scripts/criar_papeis.sh                # cria os papéis que faltam (idempotente)
#   bash db/scripts/criar_papeis.sh --verificar    # testa o login de cada papel com a senha do .env
#   bash db/scripts/criar_papeis.sh --sincronizar  # alinha com o .env a senha dos papéis que falharem
#
# Papéis e variáveis do .env:
#   safetycar_migrator  SAFETYCAR_MIGRATOR_PASSWORD
#   safetycar_app       SAFETYCAR_APP_PASSWORD (a API usa API_DB_SENHA, que deve ser igual)
#   safetycar_central   SAFETYCAR_CENTRAL_PASSWORD
#
# Sem argumento: cria o safetycar_central (migração 0014) se faltar. Papel que já existe só tem
# os atributos reafirmados (LOGIN, sem superusuário etc.); a senha NÃO é trocada.
#
# --verificar: só leitura. Conecta por TCP (o pg_hba.conf exige scram-sha-256 fora do loopback)
# com a senha do .env e imprime, por papel, só "ok" ou "FALHOU". Sai com 1 se algum falhar.
#
# --sincronizar: valida as três senhas (não vazias, sem o valor de exemplo trocar-*, 16+
# caracteres) e exige API_DB_SENHA igual a SAFETYCAR_APP_PASSWORD. Testa o login de cada papel e
# roda ALTER ROLE ... PASSWORD só nos que falharem, depois de confirmação (digitar o nome do
# banco). No fim, testa de novo. Rodar outra vez não altera nada.
#
# Sigilo: o .env não é executado, só lido. A senha nunca é impressa nem passada na linha de
# comando: vai ao contêiner por variável de ambiente (docker exec -e NOME, sem o valor) e ao
# psql por \getenv, com o SQL na entrada padrão. Na sessão do ALTER ROLE, o registro de comandos
# do servidor é desligado (log_statement e log_min_error_statement), para que a senha não vá ao
# log nem em caso de erro. A conexão de teste usa PGPASSWORD dentro do contêiner, sem .pgpass.
set -euo pipefail
source "$(dirname "$0")/_comum.sh"

BANCO=safetycar
PAPEIS=(safetycar_migrator safetycar_app safetycar_central)
declare -A VARIAVEL=(
  [safetycar_migrator]=SAFETYCAR_MIGRATOR_PASSWORD
  [safetycar_app]=SAFETYCAR_APP_PASSWORD
  [safetycar_central]=SAFETYCAR_CENTRAL_PASSWORD
)

uso() {
  echo "Uso: bash db/scripts/criar_papeis.sh [--verificar | --sincronizar]"
}

MODO=criar
case "${1:-}" in
  "") ;;
  --verificar) MODO=verificar ;;
  --sincronizar) MODO=sincronizar ;;
  -h|--help) uso; exit 0 ;;
  *) uso >&2; exit 2 ;;
esac
if (( $# > 1 )); then uso >&2; exit 2; fi

# valida_senha <NOME_DA_VARIAVEL> <valor>: sai com erro se a senha não servir.
valida_senha() {
  local nome="$1" valor="$2"
  if [[ -z "$valor" ]]; then
    echo "ERRO: defina $nome no .env (veja .env.example)." >&2
    exit 1
  fi
  if [[ "$valor" == trocar-* ]]; then
    echo "ERRO: $nome ainda tem o valor de exemplo; troque por uma senha forte." >&2
    exit 1
  fi
  if (( ${#valor} < 16 )); then
    echo "ERRO: $nome deve ter pelo menos 16 caracteres." >&2
    exit 1
  fi
}

# testa_login <papel> <senha>: imprime "ok" ou "FALHOU (motivo)"; retorna 0 só se conectou.
# O motivo vem da mensagem do servidor (que nunca contém a senha).
testa_login() {
  local papel="$1" saida
  export SC_PW="$2"
  set +e
  saida="$(exec_db -e SC_PW -- sh -c \
    'PGPASSWORD="$SC_PW" PGCONNECT_TIMEOUT=5 exec psql -X -q -tA -w -h "${HOSTNAME:-$(hostname)}" -U "$1" -d "$2" -c "SELECT 1"' \
    sh "$papel" "$BANCO" </dev/null 2>&1)"
  set -e
  unset SC_PW
  if [[ "$saida" == "1" ]]; then
    echo "ok"; return 0
  fi
  if [[ "$saida" == *"password authentication failed"* ]]; then
    echo "FALHOU (a senha do .env não confere com a do papel)"
  elif [[ "$saida" == *"no password supplied"* ]]; then
    echo "FALHOU (senha vazia no .env)"
  else
    echo "FALHOU ($(printf '%s' "$saida" | head -n 1))"
  fi
  return 1
}

# ---------------------------------------------------------------------------------------------
if [[ "$MODO" == criar ]]; then
  exige_banco_saudavel
  SC_CENTRAL_PW="$(le_env SAFETYCAR_CENTRAL_PASSWORD)"
  valida_senha SAFETYCAR_CENTRAL_PASSWORD "$SC_CENTRAL_PW"

  export SC_CENTRAL_PW
  exec_db -e SC_CENTRAL_PW -- psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
\getenv central_pw SC_CENTRAL_PW
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SELECT NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'safetycar_central') AS criar \gset
\if :criar
  CREATE ROLE safetycar_central LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOINHERIT NOBYPASSRLS
    PASSWORD :'central_pw';
  \echo 'safetycar_central: criado.'
\else
  ALTER ROLE safetycar_central LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOINHERIT NOBYPASSRLS;
  \echo 'safetycar_central: já existia; atributos reafirmados (senha mantida).'
\endif
\unset central_pw
SQL
  unset SC_CENTRAL_PW
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# --verificar e --sincronizar
exige_banco_saudavel

declare -A SENHA
for p in "${PAPEIS[@]}"; do
  SENHA[$p]="$(le_env "${VARIAVEL[$p]}")"
done
API_SENHA="$(le_env API_DB_SENHA)"
API_USUARIO="$(le_env API_DB_USUARIO)"
DB_PORTA_ENV="$(le_env DB_PORTA)"
API_PORTA_ENV="$(le_env API_DB_PORTA)"

# Coerência entre as variáveis da API e as dos papéis (sem mostrar valores).
AVISOS=0
if [[ "$API_SENHA" != "${SENHA[safetycar_app]}" ]]; then
  echo "AVISO: API_DB_SENHA é diferente de SAFETYCAR_APP_PASSWORD; iguale as duas no .env." >&2
  AVISOS=1
fi
if [[ -n "$API_USUARIO" && "$API_USUARIO" != safetycar_app ]]; then
  echo "AVISO: API_DB_USUARIO deveria ser safetycar_app." >&2
  AVISOS=1
fi
if [[ "${API_PORTA_ENV:-5432}" != "${DB_PORTA_ENV:-5432}" ]]; then
  echo "AVISO: API_DB_PORTA é diferente de DB_PORTA; a API não vai achar o banco." >&2
  AVISOS=1
fi

if [[ "$MODO" == verificar ]]; then
  FALHAS=0
  for p in "${PAPEIS[@]}"; do
    if r="$(testa_login "$p" "${SENHA[$p]}")"; then :; else FALHAS=1; fi
    echo "$p: $r"
  done
  if (( FALHAS )); then
    echo "Para alinhar as senhas dos papéis com o .env: bash db/scripts/criar_papeis.sh --sincronizar"
  fi
  (( FALHAS == 0 && AVISOS == 0 ))
  exit $?
fi

# --sincronizar
for p in "${PAPEIS[@]}"; do
  valida_senha "${VARIAVEL[$p]}" "${SENHA[$p]}"
done
if (( AVISOS )); then
  echo "ERRO: corrija os avisos acima no .env antes de sincronizar. Nada foi alterado." >&2
  exit 1
fi

DIVERGENTES=()
for p in "${PAPEIS[@]}"; do
  if r="$(testa_login "$p" "${SENHA[$p]}")"; then
    echo "$p: ok (nada a alterar)"
  else
    echo "$p: $r"
    DIVERGENTES+=("$p")
  fi
done

if (( ${#DIVERGENTES[@]} == 0 )); then
  echo "Todas as senhas já conferem com o .env. Nada foi alterado."
  exit 0
fi

# O papel precisa existir: este modo só troca senha, não cria papel.
for p in "${DIVERGENTES[@]}"; do
  # $p vem da lista fixa PAPEIS, não do .env.
  existe="$(psql_como postgres postgres -tA -c "SELECT count(*) FROM pg_roles WHERE rolname = '$p'" </dev/null)"
  if [[ "$existe" != 1 ]]; then
    echo "ERRO: o papel $p não existe. Rode sem argumento para criar os papéis que faltam. Nada foi alterado." >&2
    exit 1
  fi
done

echo
echo "Será trocada a senha de: ${DIVERGENTES[*]} (passa a ser a do .env)."
printf 'Para alterar, digite o nome do banco alvo (%s): ' "$BANCO"
resposta=""
IFS= read -r resposta || true
resposta="${resposta%$'\r'}"
if [[ "$resposta" != "$BANCO" ]]; then
  echo
  echo "Confirmação não confere com o nome do banco. Nada foi alterado."
  exit 1
fi

for p in "${DIVERGENTES[@]}"; do
  export SC_PW="${SENHA[$p]}"
  exec_db -e SC_PW -- psql -X -q -v ON_ERROR_STOP=1 -v papel="$p" -U postgres -d postgres <<'SQL'
\getenv nova_senha SC_PW
SET log_statement = 'none';
SET log_min_error_statement = 'panic';
SET log_min_duration_statement = -1;
SET password_encryption = 'scram-sha-256';
ALTER ROLE :"papel" PASSWORD :'nova_senha';
\unset nova_senha
SQL
  unset SC_PW
  echo "$p: senha alterada."
done

echo
echo "Conferindo:"
FALHAS=0
for p in "${PAPEIS[@]}"; do
  if r="$(testa_login "$p" "${SENHA[$p]}")"; then :; else FALHAS=1; fi
  echo "$p: $r"
done
exit "$FALHAS"
