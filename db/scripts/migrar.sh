#!/usr/bin/env bash
# Aplica, em ordem, as migrações de db/migrations ainda não aplicadas.
# Uso: db/scripts/migrar.sh [banco]   (padrão: safetycar)
#
# - Cada migração roda numa única transação, junto com o seu registro em schema_migracao.
# - Migração já aplicada é pulada; se o arquivo mudou depois de aplicado (sha256 diferente),
#   o script para: migração aplicada não se edita, cria-se outra.
# - 0001 (extensões) roda como superusuário porque o PostGIS não é extensão "trusted".
#   As demais rodam como safetycar_migrator.
set -euo pipefail
source "$(dirname "$0")/_comum.sh"

BANCO="${1:-safetycar}"
exige_banco_saudavel

psql_como safetycar_migrator "$BANCO" <<'SQL'
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS schema_migracao (
  versao      text PRIMARY KEY,
  arquivo     text NOT NULL,
  sha256      char(64) NOT NULL,
  aplicada_em timestamptz NOT NULL DEFAULT now()
);
SQL

aplicadas=0
for caminho in db/migrations/[0-9][0-9][0-9][0-9]_*.sql; do
  arquivo="$(basename "$caminho")"
  versao="${arquivo:0:4}"
  hash="$(sha256sum "$caminho" | cut -d' ' -f1)"

  registrado="$(psql_como safetycar_migrator "$BANCO" -tA \
    -c "SELECT sha256 FROM schema_migracao WHERE versao = '$versao'")"

  if [[ -n "$registrado" ]]; then
    if [[ "$registrado" != "$hash" ]]; then
      echo "ERRO: $arquivo foi alterado depois de aplicado (sha256 registrado $registrado)." >&2
      exit 1
    fi
    echo "  = $arquivo (já aplicada)"
    continue
  fi

  papel=safetycar_migrator
  [[ "$versao" == "0001" ]] && papel=postgres

  echo "  + $arquivo (como $papel)"
  {
    cat "$caminho"
    printf "\nINSERT INTO schema_migracao (versao, arquivo, sha256) VALUES ('%s', '%s', '%s');\n" \
      "$versao" "$arquivo" "$hash"
  } | psql_como "$papel" "$BANCO" --single-transaction
  aplicadas=$((aplicadas + 1))
done

echo "Migrações aplicadas agora em '$BANCO': $aplicadas"
