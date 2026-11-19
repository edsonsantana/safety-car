#!/usr/bin/env bash
# Cria, num volume JÁ EXISTENTE, os papéis de banco que vieram depois da criação do volume
# (em volume novo, quem cria é db/init/01_papeis.sh). Idempotente: pode rodar várias vezes.
#
#   bash db/scripts/criar_papeis.sh
#
# - safetycar_central (migração 0014): senha em SAFETYCAR_CENTRAL_PASSWORD no .env.
# - Papel que já existe: só reafirma os atributos (LOGIN, sem superusuário etc.); a senha
#   NÃO é trocada.
# - A senha nunca é impressa nem passada na linha de comando: vai ao psql do contêiner por
#   variável de ambiente (\getenv). O .env não é executado, só lido.
set -euo pipefail
source "$(dirname "$0")/_comum.sh"
exige_banco_saudavel

# Lê VAR=valor do .env (sem "source"), tirando aspas simples ou duplas das pontas.
le_env() {
  local nome="$1" linha
  [[ -f .env ]] || { echo "ERRO: .env não encontrado na raiz do projeto." >&2; exit 1; }
  linha="$(grep -E "^${nome}=" .env | tail -n 1 || true)"
  linha="${linha#*=}"
  linha="${linha%$'\r'}"
  linha="${linha#\"}"; linha="${linha%\"}"
  linha="${linha#\'}"; linha="${linha%\'}"
  printf '%s' "$linha"
}

SC_CENTRAL_PW="$(le_env SAFETYCAR_CENTRAL_PASSWORD)"
if [[ -z "$SC_CENTRAL_PW" ]]; then
  echo "ERRO: defina SAFETYCAR_CENTRAL_PASSWORD no .env (veja .env.example)." >&2
  exit 1
fi
if [[ "$SC_CENTRAL_PW" == trocar-* ]]; then
  echo "ERRO: SAFETYCAR_CENTRAL_PASSWORD ainda tem o valor de exemplo; troque por uma senha forte." >&2
  exit 1
fi
if (( ${#SC_CENTRAL_PW} < 16 )); then
  echo "ERRO: SAFETYCAR_CENTRAL_PASSWORD deve ter pelo menos 16 caracteres." >&2
  exit 1
fi

export SC_CENTRAL_PW
MSYS_NO_PATHCONV=1 docker compose exec -T -e SC_CENTRAL_PW db \
  psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
\getenv central_pw SC_CENTRAL_PW
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
