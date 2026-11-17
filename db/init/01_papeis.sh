#!/bin/bash
# Executado pelo entrypoint do contêiner apenas na PRIMEIRA inicialização do volume.
# Cria os papéis do Safety Car e o banco de desenvolvimento.
# As senhas vêm do .env (via docker-compose); nada fica no repositório.
set -euo pipefail

: "${SAFETYCAR_MIGRATOR_PASSWORD:?SAFETYCAR_MIGRATOR_PASSWORD não definida}"
: "${SAFETYCAR_APP_PASSWORD:?SAFETYCAR_APP_PASSWORD não definida}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
     -v migrator_pw="$SAFETYCAR_MIGRATOR_PASSWORD" \
     -v app_pw="$SAFETYCAR_APP_PASSWORD" <<'SQL'
-- Executa migrações. Não é superusuário: é dono do banco (e, no PG 15+, do schema public).
CREATE ROLE safetycar_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION
  PASSWORD :'migrator_pw';

-- Usado pela aplicação. Privilégio mínimo; os GRANTs ficam na migração 0007.
CREATE ROLE safetycar_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOINHERIT
  PASSWORD :'app_pw';

CREATE DATABASE safetycar OWNER safetycar_migrator;

-- Ninguém além dos papéis previstos conecta (GRANTs de conexão do app na 0007).
REVOKE ALL ON DATABASE safetycar FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
SQL
