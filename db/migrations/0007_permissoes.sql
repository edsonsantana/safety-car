-- 0007 — Privilégios do safetycar_app (privilégio mínimo, sem DDL).
--
-- Regra para migrações futuras: NÃO há ALTER DEFAULT PRIVILEGES. Cada migração que cria
-- tabela/view/função declara os GRANTs do safetycar_app explicitamente.
--
-- Resumo:
--   dados de cadastro .............. SELECT, INSERT, UPDATE, DELETE
--   usuario, consentimento,
--   verificacao_identidade ......... SELECT, INSERT, UPDATE (sem DELETE: exclusão é lógica/anonimização,
--                                    e consentimento/verificação são prova perante a LGPD)
--   sinal_risco .................... SELECT, INSERT (registro de evento)
--   auditoria ...................... SELECT, INSERT (e o trigger da 0002 bloqueia UPDATE/DELETE/TRUNCATE)
--   catálogos e schema_migracao .... SELECT (mudam só por migração)

-- ---------------------------------------------------------------------
-- Banco e schema
-- ---------------------------------------------------------------------

DO $$
BEGIN
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO safetycar_app', current_database());
END $$;

-- Só o dono (safetycar_migrator) cria objetos; o app apenas usa.
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO safetycar_app;

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------

GRANT SELECT, INSERT, UPDATE, DELETE ON
  endereco,
  tomador, veiculo, contato_emergencia,
  parceiro, parceiro_tipo, parceiro_membro, parceiro_servico, parceiro_viatura,
  parceiro_documento, parceiro_conta_recebimento,
  parceiro_area_atuacao, parceiro_posicao_atual,
  meio_pagamento, dispositivo, bloqueio
TO safetycar_app;

GRANT SELECT, INSERT, UPDATE ON usuario, consentimento, verificacao_identidade TO safetycar_app;

GRANT SELECT, INSERT ON sinal_risco, auditoria TO safetycar_app;

GRANT SELECT ON tipo_parceiro, servico_catalogo, schema_migracao TO safetycar_app;

-- PostGIS: tabela de sistemas de referência (só leitura).
GRANT SELECT ON spatial_ref_sys TO safetycar_app;

-- ---------------------------------------------------------------------
-- Views e funções de consulta
-- ---------------------------------------------------------------------

GRANT SELECT ON vw_parceiro_posicao_valida TO safetycar_app;

GRANT EXECUTE ON FUNCTION
  parceiros_proximos(double precision, double precision, integer, text),
  esta_bloqueado(text, bytea),
  cnpj_valido(text),
  cnpj_dv(text)
TO safetycar_app;
