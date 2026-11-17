-- 0001 — Extensões
-- Aplicada como superusuário pelo migrar.sh: o PostGIS não é extensão "trusted".
--   postgis  : tipos geography/geometry e funções espaciais (ST_DWithin, ST_Distance...)
--   citext   : texto sem distinção de maiúsculas (e-mail)
--   pgcrypto : gen_random_uuid() e hmac() (este último só em testes; o HMAC real é feito na aplicação)

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
