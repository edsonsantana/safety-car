-- Dados fictícios para os testes de integração da Central (db/scripts/testar_api_central.sh).
-- Roda como safetycar_migrator SÓ no banco descartável safetycar_api_teste (o script recusa
-- outro banco). E-mails @exemplo.invalid e UUIDs 00000000-…; nenhum dado real.
--
-- id (…00000a0a0N)  sub (…00000a0b0N)  situação
-- 01                01                 central ativo, operador ativo, conceder_permissao (inicial)
-- 02                02                 central ativo, operador ativo, sem permissão
-- 03                03                 central suspenso, operador ativo
-- 04                04                 central ativo, sem cadastro de operador
\set ON_ERROR_STOP on

DO $$
BEGIN
  IF current_database() <> 'safetycar_api_teste' THEN
    RAISE EXCEPTION 'semente da Central só roda no banco safetycar_api_teste (atual: %)', current_database();
  END IF;
END $$;

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000a0a01', '00000000-0000-4000-8000-0000000a0b01', 'api-central-01@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000a0a02', '00000000-0000-4000-8000-0000000a0b02', 'api-central-02@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000a0a03', '00000000-0000-4000-8000-0000000a0b03', 'api-central-03@exemplo.invalid', 'central', 'suspenso'),
  ('00000000-0000-4000-8000-0000000a0a04', '00000000-0000-4000-8000-0000000a0b04', 'api-central-04@exemplo.invalid', 'central', 'ativo');

SELECT conceder_permissao_inicial('00000000-0000-4000-8000-0000000a0a01', '[TESTE] administrador da integração');
INSERT INTO operador_central (usuario_id) VALUES
  ('00000000-0000-4000-8000-0000000a0a02'),
  ('00000000-0000-4000-8000-0000000a0a03');
