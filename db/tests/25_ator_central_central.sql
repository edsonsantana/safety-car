-- 25 — ator_central (0021) pelo papel safetycar_central.
-- Preparação como postgres até "-- @como_central"; depois, a sessão é safetycar_central.
-- Dados fictícios: e-mails @exemplo.invalid e uuids 00000000-…; ROLLBACK no fim.
--
-- id   (…0000000e5c0N)    sub (…0000000e5d0N)   situação
-- c01  central ativo, operador ativo                → devolve o id
-- c02  central ativo, operador inativo              → NULL
-- c03  central ativo, sem cadastro de operador      → NULL
-- c04  central suspenso, operador ativo             → NULL
-- c05  central bloqueado, operador ativo            → NULL
-- c06  central excluído (excluido_em), operador ativo → NULL
-- c07  central pendente, operador ativo             → NULL
-- c08  tomador ativo                                → NULL
-- c09  parceiro ativo                               → NULL

INSERT INTO usuario (id, keycloak_sub, email, perfil, status, excluido_em) VALUES
  ('00000000-0000-4000-8000-0000000e5c01', '00000000-0000-4000-8000-0000000e5d01', 'ator-c01@exemplo.invalid', 'central',  'ativo',     NULL),
  ('00000000-0000-4000-8000-0000000e5c02', '00000000-0000-4000-8000-0000000e5d02', 'ator-c02@exemplo.invalid', 'central',  'ativo',     NULL),
  ('00000000-0000-4000-8000-0000000e5c03', '00000000-0000-4000-8000-0000000e5d03', 'ator-c03@exemplo.invalid', 'central',  'ativo',     NULL),
  ('00000000-0000-4000-8000-0000000e5c04', '00000000-0000-4000-8000-0000000e5d04', 'ator-c04@exemplo.invalid', 'central',  'suspenso',  NULL),
  ('00000000-0000-4000-8000-0000000e5c05', '00000000-0000-4000-8000-0000000e5d05', 'ator-c05@exemplo.invalid', 'central',  'bloqueado', NULL),
  ('00000000-0000-4000-8000-0000000e5c06', '00000000-0000-4000-8000-0000000e5d06', 'ator-c06@exemplo.invalid', 'central',  'excluido',  now()),
  ('00000000-0000-4000-8000-0000000e5c07', '00000000-0000-4000-8000-0000000e5d07', 'ator-c07@exemplo.invalid', 'central',  'pendente',  NULL),
  ('00000000-0000-4000-8000-0000000e5c08', '00000000-0000-4000-8000-0000000e5d08', 'ator-c08@exemplo.invalid', 'tomador',  'ativo',     NULL),
  ('00000000-0000-4000-8000-0000000e5c09', '00000000-0000-4000-8000-0000000e5d09', 'ator-c09@exemplo.invalid', 'parceiro', 'ativo',     NULL);
INSERT INTO operador_central (usuario_id, ativo) VALUES
  ('00000000-0000-4000-8000-0000000e5c01', true),
  ('00000000-0000-4000-8000-0000000e5c02', false),
  ('00000000-0000-4000-8000-0000000e5c04', true),
  ('00000000-0000-4000-8000-0000000e5c05', true),
  ('00000000-0000-4000-8000-0000000e5c06', true),
  ('00000000-0000-4000-8000-0000000e5c07', true);

-- @como_central

SELECT pg_temp.confere(session_user = 'safetycar_central', 'sessão como safetycar_central');

SELECT pg_temp.confere(
  ator_central('00000000-0000-4000-8000-0000000e5d01') = '00000000-0000-4000-8000-0000000e5c01',
  'central ativo e operador ativo: devolve o usuario.id');
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d02') IS NULL,
  'operador inativo: NULL');
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d03') IS NULL,
  'usuário central sem cadastro de operador: NULL');
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d04') IS NULL,
  'usuário suspenso (operador ativo): NULL');
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d05') IS NULL,
  'usuário bloqueado (operador ativo): NULL');
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d06') IS NULL,
  'usuário excluído (excluido_em preenchido, operador ativo): NULL');
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d07') IS NULL,
  'usuário pendente (operador ativo): NULL');
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d08') IS NULL,
  'tomador: NULL');
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d09') IS NULL,
  'parceiro: NULL');
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5dff') IS NULL,
  'sub desconhecido: NULL');
SELECT pg_temp.confere(ator_central(NULL) IS NULL, 'sub nulo: NULL');
SELECT pg_temp.confere(
  ator_central('00000000-0000-4000-8000-0000000e5c01') IS NULL,
  'o usuario.id no lugar do sub não identifica ninguém: NULL');
SELECT pg_temp.espera_erro($$SELECT ator_central('nao-e-uuid')$$,
  '22P02', 'sub fora do formato uuid é recusado antes de consultar');

-- A Central continua sem ler usuario direto: a função não abre a tabela.
SELECT pg_temp.espera_erro($$SELECT count(*) FROM usuario$$,
  '42501', 'Central continua sem SELECT em usuario');

-- ---------- Estado atual, não cache: mudanças valem na hora ----------
RESET SESSION AUTHORIZATION;
UPDATE operador_central SET ativo = false WHERE usuario_id = '00000000-0000-4000-8000-0000000e5c01';
SET SESSION AUTHORIZATION safetycar_central;
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d01') IS NULL,
  'operador desativado: passa a NULL');

RESET SESSION AUTHORIZATION;
UPDATE operador_central SET ativo = true WHERE usuario_id = '00000000-0000-4000-8000-0000000e5c01';
UPDATE usuario SET status = 'suspenso' WHERE id = '00000000-0000-4000-8000-0000000e5c01';
SET SESSION AUTHORIZATION safetycar_central;
SELECT pg_temp.confere(ator_central('00000000-0000-4000-8000-0000000e5d01') IS NULL,
  'usuário suspenso depois: passa a NULL');

RESET SESSION AUTHORIZATION;
UPDATE usuario SET status = 'ativo' WHERE id = '00000000-0000-4000-8000-0000000e5c01';
SET SESSION AUTHORIZATION safetycar_central;
SELECT pg_temp.confere(
  ator_central('00000000-0000-4000-8000-0000000e5d01') = '00000000-0000-4000-8000-0000000e5c01',
  'reativado: volta a devolver o id');

-- ---------- A função não escreve nada ----------
-- Retrato tirado como postgres DEPOIS das escritas da preparação acima; a Central chama a
-- função em todas as situações e o retrato é comparado de novo.
RESET SESSION AUTHORIZATION;
CREATE TEMP TABLE retrato AS
SELECT (SELECT count(*) FROM auditoria) AS auditoria,
       (SELECT md5(string_agg(u::text, '|' ORDER BY u.id)) FROM usuario u) AS usuario,
       (SELECT md5(string_agg(o::text, '|' ORDER BY o.usuario_id)) FROM operador_central o) AS operador;

SET SESSION AUTHORIZATION safetycar_central;
SELECT ator_central(('00000000-0000-4000-8000-0000000e5d0' || n)::uuid)
  FROM generate_series(1, 9) n;   -- todas as situações de novo
RESET SESSION AUTHORIZATION;

SELECT pg_temp.confere(
  (SELECT r.auditoria = (SELECT count(*) FROM auditoria)
      AND r.usuario = (SELECT md5(string_agg(u::text, '|' ORDER BY u.id)) FROM usuario u)
      AND r.operador = (SELECT md5(string_agg(o::text, '|' ORDER BY o.usuario_id)) FROM operador_central o)
     FROM retrato r),
  'ator_central não grava auditoria nem altera usuario ou operador_central');
