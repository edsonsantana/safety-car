#!/bin/bash
# Executado pelo entrypoint do contêiner apenas na PRIMEIRA inicialização do volume.
# Cria os papéis do Safety Car e o banco de desenvolvimento.
# As senhas vêm do .env (via docker-compose); nada fica no repositório.
# Em volume já existente, papéis novos são criados por db/scripts/criar_papeis.sh.
set -euo pipefail

: "${SAFETYCAR_MIGRATOR_PASSWORD:?SAFETYCAR_MIGRATOR_PASSWORD não definida}"
: "${SAFETYCAR_APP_PASSWORD:?SAFETYCAR_APP_PASSWORD não definida}"
: "${SAFETYCAR_CENTRAL_PASSWORD:?SAFETYCAR_CENTRAL_PASSWORD não definida}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
     -v migrator_pw="$SAFETYCAR_MIGRATOR_PASSWORD" \
     -v app_pw="$SAFETYCAR_APP_PASSWORD" \
     -v central_pw="$SAFETYCAR_CENTRAL_PASSWORD" <<'SQL'
-- Executa migrações. Não é superusuário: é dono do banco (e, no PG 15+, do schema public).
CREATE ROLE safetycar_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'migrator_pw';

-- Usado pela aplicação. Privilégio mínimo; os GRANTs ficam na migração 0007.
CREATE ROLE safetycar_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOINHERIT
  PASSWORD :'app_pw';

-- Usado só pelo backend da Central para ações sensíveis (permissões, aprovações).
-- Só executa as funções liberadas na 0014 em diante; GRANTs nas migrações.
CREATE ROLE safetycar_central LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOINHERIT
  PASSWORD :'central_pw';

CREATE DATABASE safetycar OWNER safetycar_migrator;

-- Ninguém além dos papéis previstos conecta (GRANTs de conexão do app na 0007).
REVOKE ALL ON DATABASE safetycar FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
SQL
