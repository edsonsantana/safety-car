-- 20 — Permissões da Central (0016) pelo papel safetycar_central.
-- Preparação como postgres até a linha "-- @como_central"; depois dela, a sessão é safetycar_central.
-- No fim, RESET SESSION AUTHORIZATION volta a postgres para conferir a auditoria.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000c0f01', gen_random_uuid(), 'perm-cen-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000c0f02', gen_random_uuid(), 'perm-cen-b@exemplo.invalid', 'central', 'ativo');
SELECT conceder_permissao_inicial('00000000-0000-4000-8000-0000000c0f01', '[TESTE] administrador da Central');

-- @como_central

SELECT pg_temp.confere(session_user = 'safetycar_central', 'sessão como safetycar_central');

SELECT pg_temp.aceita($$
  SELECT cadastrar_operador('00000000-0000-4000-8000-0000000c0f01', '00000000-0000-4000-8000-0000000c0f02', '[TESTE] equipe')$$,
  'Central: A cadastra B');

-- ---------- Último titular ----------
SELECT pg_temp.espera_erro($$
  SELECT revogar_permissao('00000000-0000-4000-8000-0000000c0f01', '00000000-0000-4000-8000-0000000c0f01', 'conceder_permissao', '[TESTE] abdica')$$,
  'SC023', 'Central: o único titular não abdica');
SELECT pg_temp.aceita($$
  SELECT conceder_permissao('00000000-0000-4000-8000-0000000c0f01', '00000000-0000-4000-8000-0000000c0f02', 'conceder_permissao', '[TESTE] segundo titular')$$,
  'Central: A concede conceder_permissao a B');
SELECT pg_temp.aceita($$
  SELECT definir_operador_ativo('00000000-0000-4000-8000-0000000c0f02', '00000000-0000-4000-8000-0000000c0f01', false, '[TESTE] afastamento')$$,
  'Central: B desativa A (B continua titular)');
SELECT pg_temp.espera_erro($$
  SELECT revogar_permissao('00000000-0000-4000-8000-0000000c0f02', '00000000-0000-4000-8000-0000000c0f02', 'conceder_permissao', '[TESTE] abdica')$$,
  'SC023', 'Central: B, único titular efetivo, não abdica');
SELECT pg_temp.aceita($$
  SELECT definir_operador_ativo('00000000-0000-4000-8000-0000000c0f02', '00000000-0000-4000-8000-0000000c0f01', true, '[TESTE] retorno')$$,
  'Central: B reativa A');

-- ---------- Acesso e leitura ----------
SELECT pg_temp.aceita($$SELECT registrar_acesso_central('00000000-0000-4000-8000-0000000c0f01')$$,
  'Central: registra o acesso de A');
SELECT pg_temp.confere(
  (SELECT ultimo_acesso_em IS NOT NULL FROM vw_operador_central WHERE usuario_id = '00000000-0000-4000-8000-0000000c0f01'),
  'Central lê o último acesso em vw_operador_central');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM vw_operador_permissao WHERE vigente AND permissao_codigo = 'conceder_permissao'),
  'Central lê o histórico em vw_operador_permissao');
SELECT pg_temp.confere(
  (SELECT count(*) = 5 FROM permissao_central) AND (SELECT count(*) = 3 FROM permissao_central WHERE sensivel),
  'Central lê o catálogo, com a marca de sensível');

-- ---------- Sem escrita direta nem acesso aos utilitários ----------
SELECT pg_temp.espera_erro($$UPDATE permissao_central SET sensivel = false$$,
  '42501', 'Central não altera o catálogo');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM auditoria$$,
  '42501', 'Central continua sem ler a auditoria (só o último acesso, pela visão)');
SELECT pg_temp.espera_erro($$SELECT existe_outro_titular_conceder('00000000-0000-4000-8000-0000000c0f01')$$,
  '42501', 'Central não executa o utilitário interno existe_outro_titular_conceder');
SELECT pg_temp.espera_erro($$SELECT exige_outro_titular_conceder('00000000-0000-4000-8000-0000000c0f01')$$,
  '42501', 'Central não executa o utilitário interno exige_outro_titular_conceder');

-- ---------- Auditoria (conferida como postgres) ----------
RESET SESSION AUTHORIZATION;
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_permissao_concedida' AND papel_bd = 'safetycar_central'
             AND ator_usuario_id = '00000000-0000-4000-8000-0000000c0f01'
             AND depois ->> 'operador_id' = '00000000-0000-4000-8000-0000000c0f02'),
  'central_permissao_concedida com papel_bd = safetycar_central e ator A');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_acesso' AND papel_bd = 'safetycar_central'
             AND ator_usuario_id = '00000000-0000-4000-8000-0000000c0f01'
             AND entidade = 'operador_central' AND entidade_id = '00000000-0000-4000-8000-0000000c0f01'),
  'central_acesso com papel_bd = safetycar_central');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM auditoria WHERE acao IN ('central_desativar_operador','central_ativar_operador')
      AND papel_bd = 'safetycar_central' AND ator_usuario_id = '00000000-0000-4000-8000-0000000c0f02'),
  'desativação e reativação na auditoria com ator B');
