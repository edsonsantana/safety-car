-- 17 — Operadores e permissões pelo papel safetycar_central (0014).
-- Preparação como postgres até a linha "-- @como_central"; depois dela, a sessão é safetycar_central.
-- No fim, RESET SESSION AUTHORIZATION volta a postgres para conferir a auditoria.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000c0b01', gen_random_uuid(), 'cen-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000c0b02', gen_random_uuid(), 'cen-b@exemplo.invalid', 'central', 'ativo');
SELECT conceder_permissao_inicial('00000000-0000-4000-8000-0000000c0b01', '[TESTE] administrador da Central');

-- @como_central

SELECT pg_temp.confere(session_user = 'safetycar_central' AND current_user = 'safetycar_central',
  'sessão como safetycar_central');

-- ---------- O papel age só pelas funções ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO permissao_concessao (operador_id, permissao_codigo, motivo, origem)
  VALUES ('00000000-0000-4000-8000-0000000c0b02', 'aprovar_reajuste_taxa', 'x', 'inicial')$$,
  '42501', 'Central não insere concessão direto');
SELECT pg_temp.espera_erro($$UPDATE operador_central SET ativo = false$$,
  '42501', 'Central não altera operador direto');
SELECT pg_temp.espera_erro($$UPDATE permissao_central SET permite_autoaprovacao = true$$,
  '42501', 'Central não altera o catálogo de permissões');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao_inicial('00000000-0000-4000-8000-0000000c0b02', 'x')$$,
  '42501', 'Central não faz concessão inicial (só o migrator, à mão)');
SELECT pg_temp.espera_erro($$SELECT revogar_permissao_manual('00000000-0000-4000-8000-0000000c0b01', 'conceder_permissao', 'x')$$,
  '42501', 'Central não faz revogação manual');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM usuario$$,
  '42501', 'Central não lê a tabela de usuários');
SELECT pg_temp.espera_erro($$INSERT INTO auditoria (acao, entidade) VALUES ('x', 'x')$$,
  '42501', 'Central não escreve na auditoria direto');

-- ---------- Fluxo normal ----------
SELECT pg_temp.aceita($$
  SELECT cadastrar_operador('00000000-0000-4000-8000-0000000c0b01', '00000000-0000-4000-8000-0000000c0b02', '[TESTE] nova operadora')$$,
  'Central: A cadastra B');
SELECT pg_temp.espera_erro($$
  SELECT conceder_permissao('00000000-0000-4000-8000-0000000c0b02', '00000000-0000-4000-8000-0000000c0b02', 'aprovar_reajuste_taxa', '[TESTE]')$$,
  'SC017', 'Central: B não concede a si mesma');
-- Declarar como ator alguém sem a permissão não adianta: o banco confere (SC016).
-- Risco residual (documentado): quem tem a credencial do papel poderia declarar A como ator;
-- por isso a API da Central tira o ator do JWT do Keycloak.
SELECT pg_temp.espera_erro($$
  SELECT cadastrar_operador('00000000-0000-4000-8000-0000000c0b02', gen_random_uuid(), '[TESTE]')$$,
  'SC016', 'Central: ator sem conceder_permissao é recusado');
SELECT pg_temp.aceita($$
  SELECT conceder_permissao('00000000-0000-4000-8000-0000000c0b01', '00000000-0000-4000-8000-0000000c0b02', 'aprovar_reajuste_taxa', '[TESTE] aprovadora de taxas')$$,
  'Central: A concede aprovar_reajuste_taxa a B');
SELECT pg_temp.confere(operador_tem_permissao('00000000-0000-4000-8000-0000000c0b02', 'aprovar_reajuste_taxa'),
  'Central: B tem a permissão vigente');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM vw_permissao_vigente WHERE efetiva),
  'Central lê as permissões vigentes');
SELECT pg_temp.aceita($$
  SELECT revogar_permissao('00000000-0000-4000-8000-0000000c0b01', '00000000-0000-4000-8000-0000000c0b02', 'aprovar_reajuste_taxa', '[TESTE] fim do projeto')$$,
  'Central: A revoga a permissão de B');
SELECT pg_temp.confere(NOT operador_tem_permissao('00000000-0000-4000-8000-0000000c0b02', 'aprovar_reajuste_taxa'),
  'Central: B não tem mais a permissão');

-- ---------- Auditoria (conferida como postgres) ----------
RESET SESSION AUTHORIZATION;
SELECT pg_temp.confere(
  (SELECT count(*) = 3 FROM auditoria
    WHERE entidade IN ('operador_central','permissao_concessao','permissao_revogacao')
      AND acao = 'parametrizacao_insert'
      AND papel_bd = 'safetycar_central'
      AND ator_usuario_id = '00000000-0000-4000-8000-0000000c0b01'),
  'cadastro, concessão e revogação na auditoria com ator A e papel_bd = safetycar_central (session_user)');
SELECT pg_temp.confere(
  (SELECT papel_bd = 'safetycar_central' FROM permissao_concessao
    WHERE operador_id = '00000000-0000-4000-8000-0000000c0b02'),
  'a própria concessão guarda o papel que a fez');
SELECT pg_temp.confere(
  (SELECT current_setting('safetycar.ator_usuario_id', true) IS NOT DISTINCT FROM '' OR
          current_setting('safetycar.ator_usuario_id', true) IS NULL),
  'o ator não fica pendurado na sessão depois da função');
