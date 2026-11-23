-- 22 — Parâmetros (0018) pelo papel safetycar_central.
-- Preparação como postgres até a linha "-- @como_central"; depois dela, a sessão é safetycar_central.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d2b01', gen_random_uuid(), 'par-cen-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d2b02', gen_random_uuid(), 'par-cen-m@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d2b03', gen_random_uuid(), 'par-cen-n@exemplo.invalid', 'central', 'ativo');
SELECT conceder_permissao_inicial('00000000-0000-4000-8000-0000000d2b01', '[TESTE] administrador');
SELECT cadastrar_operador('00000000-0000-4000-8000-0000000d2b01', o::uuid, '[TESTE] equipe')
  FROM unnest(ARRAY['00000000-0000-4000-8000-0000000d2b02', '00000000-0000-4000-8000-0000000d2b03']) o;
SELECT conceder_permissao('00000000-0000-4000-8000-0000000d2b01', o::uuid, 'administrar_parametros', '[TESTE] parâmetros')
  FROM unnest(ARRAY['00000000-0000-4000-8000-0000000d2b02', '00000000-0000-4000-8000-0000000d2b03']) o;

-- @como_central

SELECT pg_temp.confere(session_user = 'safetycar_central', 'sessão como safetycar_central');
CREATE TEMP TABLE v (k text PRIMARY KEY, id uuid);

SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM vw_parametro_vigente) AND parametro_vigente('limite_variacao_reajuste') = 20,
  'Central lê os valores vigentes');
SELECT pg_temp.aceita($$
  SELECT alterar_parametro('00000000-0000-4000-8000-0000000d2b02', 'alerta_documento_dias', 60, '[TESTE] mais antecedência')$$,
  'Central: M altera o alerta (comum)');
INSERT INTO v (k, id)
SELECT 'P', solicitar_alteracao_parametro('00000000-0000-4000-8000-0000000d2b02', 'limite_variacao_reajuste', 22, '[TESTE] ajuste');
SELECT pg_temp.espera_erro($$
  SELECT aprovar_alteracao_parametro('00000000-0000-4000-8000-0000000d2b02', (SELECT id FROM v WHERE k = 'P'), '[TESTE]')$$,
  'SC017', 'Central: M não aprova o próprio pedido');
SELECT pg_temp.aceita($$
  SELECT aprovar_alteracao_parametro('00000000-0000-4000-8000-0000000d2b03', (SELECT id FROM v WHERE k = 'P'), '[TESTE] de acordo')$$,
  'Central: N aprova');
SELECT pg_temp.confere(
  parametro_vigente('limite_variacao_reajuste', clock_timestamp()) = 22
  AND parametro_vigente('alerta_documento_dias', clock_timestamp()) = 60
  AND (SELECT situacao = 'aprovado' FROM vw_parametro_alteracao WHERE id = (SELECT id FROM v WHERE k = 'P')),
  'Central: limite 22, alerta 60, pedido aprovado');
SELECT pg_temp.confere((SELECT count(*) = 4 FROM parametro_valor), 'Central lê o histórico de valores');

-- ---------- Sem escrita direta nem acesso aos utilitários ----------
SELECT pg_temp.espera_erro($$INSERT INTO parametro_valor (parametro_chave, valor, origem, motivo) VALUES ('alerta_documento_dias', 10, 'migracao', 'x')$$,
  '42501', 'Central não grava valor direto');
SELECT pg_temp.espera_erro($$UPDATE parametro SET maximo = 40 WHERE chave = 'limite_variacao_reajuste'$$,
  '42501', 'Central não altera o catálogo');
SELECT pg_temp.espera_erro($$INSERT INTO parametro_alteracao_decisao (alteracao_id, situacao, decidido_por, motivo)
  VALUES ((SELECT id FROM v WHERE k = 'P'), 'rejeitado', '00000000-0000-4000-8000-0000000d2b03', 'x')$$,
  '42501', 'Central não grava decisão direto');
SELECT pg_temp.espera_erro($$SELECT parametro_validar_valor('alerta_documento_dias', 10)$$,
  '42501', 'Central não executa parametro_validar_valor');
SELECT pg_temp.espera_erro($$SELECT * FROM parametro_trocar_valor('alerta_documento_dias', 10, 'migracao', NULL, 'x', NULL, NULL, NULL)$$,
  '42501', 'Central não executa parametro_trocar_valor');

-- ---------- Auditoria (conferida como postgres) ----------
RESET SESSION AUTHORIZATION;
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_parametro_alterado' AND papel_bd = 'safetycar_central'
             AND ator_usuario_id = '00000000-0000-4000-8000-0000000d2b02')
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_parametro_solicitado' AND papel_bd = 'safetycar_central'
             AND ator_usuario_id = '00000000-0000-4000-8000-0000000d2b02')
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_parametro_decidido' AND papel_bd = 'safetycar_central'
             AND ator_usuario_id = '00000000-0000-4000-8000-0000000d2b03'),
  'alterado e solicitado (ator M) e decidido (ator N), com papel_bd = safetycar_central');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM parametro_valor WHERE papel_bd = 'safetycar_central'),
  'os valores gravados guardam o papel que os gravou');
