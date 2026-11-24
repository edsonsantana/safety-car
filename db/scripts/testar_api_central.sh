#!/usr/bin/env bash
# Testes de integração da API da Central contra um banco DESCARTÁVEL.
#
#   bash db/scripts/testar_api_central.sh
#
# - Recria do zero o banco safetycar_api_teste, aplica todas as migrações, carrega a semente
#   fictícia (apps/api/test/integracao/central/semente.sql, como safetycar_migrator) e roda
#   "npm run test:integracao:central" em apps/api com API_DB_NOME=safetycar_api_teste.
# - Apaga o banco no fim, mesmo em caso de falha ou Ctrl+C. Recusa rodar contra o safetycar (e
#   contra os outros bancos conhecidos); o teste em Node recusa de novo se o banco não for este.
# - A API conecta por TCP com as senhas do .env (API_DB_SENHA e API_CENTRAL_DB_SENHA). Este
#   script só confere que as variáveis existem; nunca imprime valores.
set -euo pipefail
source "$(dirname "$0")/_comum.sh"

BANCO=safetycar_api_teste

case "$BANCO" in
  safetycar|postgres|safetycar_teste|safetycar_conc|template0|template1)
    echo "ERRO: banco alvo inválido: $BANCO (o teste da Central só roda num banco descartável)" >&2
    exit 1;;
esac

exige_banco_saudavel
if [[ "$(psql_como postgres postgres -tA -c "SELECT count(*) FROM pg_roles WHERE rolname = 'safetycar_central'")" != "1" ]]; then
  echo "ERRO: o papel safetycar_central não existe (migração 0014). Rode: bash db/scripts/criar_papeis.sh" >&2
  exit 1
fi
for variavel in API_DB_SENHA API_CENTRAL_DB_SENHA; do
  if [[ -z "$(le_env "$variavel")" ]]; then
    echo "ERRO: defina $variavel no .env (veja .env.example)." >&2
    exit 1
  fi
done

limpar() {
  local status=$?
  echo "== Apagando $BANCO"
  psql_como postgres postgres -c "DROP DATABASE IF EXISTS $BANCO WITH (FORCE);" >/dev/null 2>&1 || true
  exit "$status"
}
trap limpar EXIT
trap 'exit 130' INT TERM

echo "== Recriando $BANCO"
psql_como postgres postgres <<SQL
SET client_min_messages = warning;
DROP DATABASE IF EXISTS $BANCO WITH (FORCE);
CREATE DATABASE $BANCO OWNER safetycar_migrator TEMPLATE template0 ENCODING 'UTF8';
REVOKE ALL ON DATABASE $BANCO FROM PUBLIC;
SQL

echo "== Migrando $BANCO do zero"
bash db/scripts/migrar.sh "$BANCO" | tail -n 1

echo "== Semente fictícia (como safetycar_migrator)"
psql_como safetycar_migrator "$BANCO" -o /dev/null < apps/api/test/integracao/central/semente.sql

echo "== Testes de integração da Central"
(cd apps/api && API_DB_NOME="$BANCO" npm run --silent test:integracao:central)
