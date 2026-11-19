#!/usr/bin/env bash
# Recria do zero o banco descartável safetycar_teste, aplica todas as migrações e roda db/tests.
# O banco de desenvolvimento (safetycar) não é tocado.
#
# Convenções dos testes:
# - db/tests/00_util.sql é prefixado a cada arquivo de teste (funções em pg_temp).
# - Cada arquivo roda em BEGIN ... ROLLBACK: não deixa dados.
# - Arquivo terminado em _app.sql roda conectado como safetycar_app; os demais como safetycar_migrator.
# - Arquivo terminado em _central.sql: o trecho ANTES da linha "-- @como_central" prepara dados
#   como postgres; depois dela a sessão passa a safetycar_central (SET SESSION AUTHORIZATION,
#   então session_user é o papel da Central) e os utilitários são criados já como ele.
# - Falha = RAISE EXCEPTION 'FALHOU: ...' -> o script para com código diferente de zero.
set -euo pipefail
source "$(dirname "$0")/_comum.sh"

BANCO=safetycar_teste
exige_banco_saudavel

if [[ "$(psql_como postgres postgres -tA -c "SELECT count(*) FROM pg_roles WHERE rolname = 'safetycar_central'")" != "1" ]]; then
  echo "ERRO: o papel safetycar_central não existe (migração 0014). Rode: bash db/scripts/criar_papeis.sh" >&2
  exit 1
fi

echo "== Recriando $BANCO"
psql_como postgres postgres <<SQL
DROP DATABASE IF EXISTS $BANCO WITH (FORCE);
CREATE DATABASE $BANCO OWNER safetycar_migrator TEMPLATE template0 ENCODING 'UTF8';
REVOKE ALL ON DATABASE $BANCO FROM PUBLIC;
SQL

echo "== Migrando $BANCO do zero"
bash db/scripts/migrar.sh "$BANCO"

echo "== Reaplicando (não deve haver nada a aplicar)"
bash db/scripts/migrar.sh "$BANCO"

total_ok=0
for caminho in db/tests/[0-9][0-9]_*.sql; do
  arquivo="$(basename "$caminho")"
  [[ "$arquivo" == "00_util.sql" ]] && continue

  papel=safetycar_migrator
  [[ "$arquivo" == *_app.sql ]] && papel=safetycar_app
  conexao="$papel"
  if [[ "$arquivo" == *_central.sql ]]; then
    papel=safetycar_central
    conexao=postgres
    if ! grep -q '^-- @como_central$' "$caminho"; then
      echo "!! $arquivo não tem a linha '-- @como_central'" >&2
      exit 1
    fi
  fi

  corpo_do_teste() {
    if [[ "$arquivo" == *_central.sql ]]; then
      sed '/^-- @como_central$/q' "$caminho"
      echo; echo "SET SESSION AUTHORIZATION safetycar_central;"
      cat db/tests/00_util.sql
      sed '1,/^-- @como_central$/d' "$caminho"
    else
      cat db/tests/00_util.sql "$caminho"
    fi
  }

  echo "== $arquivo (como $papel)"
  saida="$(
    { echo "BEGIN;"; corpo_do_teste; echo; echo "ROLLBACK;"; } \
      | psql_como "$conexao" "$BANCO" -o /dev/null 2>&1
  )" && status=0 || status=$?

  # Mostra só a mensagem (remove o prefixo "psql:<stdin>:N: NOTICE:")
  echo "$saida" | sed -E 's/^psql:<stdin>:[0-9]+: //; s/^(NOTICE|ERROR): +/\1: /' | sed 's/^/   /'

  if [[ $status -ne 0 ]] || grep -q 'ERROR' <<<"$saida"; then
    echo "!! $arquivo FALHOU" >&2
    exit 1
  fi
  total_ok=$((total_ok + $(grep -c 'OK:' <<<"$saida" || true)))
done

echo "== Todos os testes passaram ($total_ok verificações)."
