-- 19 — Reajuste de taxas pelo papel safetycar_central (0015).
-- Preparação como postgres até "-- @como_central"; depois, a sessão é safetycar_central.
-- No fim, RESET SESSION AUTHORIZATION volta a postgres para conferir a auditoria.
-- Operadores: A (conceder), S (solicitante), P (aprovador), X (inativo).

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d0b01', gen_random_uuid(), 'rc-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0b02', gen_random_uuid(), 'rc-s@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0b03', gen_random_uuid(), 'rc-p@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0b05', gen_random_uuid(), 'rc-x@exemplo.invalid', 'central', 'ativo');
SELECT conceder_permissao_inicial('00000000-0000-4000-8000-0000000d0b01', '[TESTE] administrador');
SELECT cadastrar_operador('00000000-0000-4000-8000-0000000d0b01', u::uuid, '[TESTE] equipe')
  FROM unnest(ARRAY['00000000-0000-4000-8000-0000000d0b02','00000000-0000-4000-8000-0000000d0b03',
                    '00000000-0000-4000-8000-0000000d0b05']) u;
SELECT conceder_permissao('00000000-0000-4000-8000-0000000d0b01', '00000000-0000-4000-8000-0000000d0b03',
                          'aprovar_reajuste_taxa', '[TESTE] aprovador');
SELECT definir_operador_ativo('00000000-0000-4000-8000-0000000d0b01', '00000000-0000-4000-8000-0000000d0b05',
                              false, '[TESTE] afastado');
INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao)
VALUES ('chaveiro', 'pneu', NULL, 'base', 'centavos', 10000, 'definido');
CREATE TEMP TABLE lote (id uuid);
GRANT ALL ON lote TO safetycar_central;

-- @como_central

SELECT pg_temp.confere(session_user = 'safetycar_central', 'sessão como safetycar_central');

SELECT pg_temp.confere(
  (SELECT count(*) = 1 AND bool_and(valor_novo = 10300 AND problema IS NULL)
     FROM simular_reajuste_taxa('00000000-0000-4000-8000-0000000d0b02', 'percentual', 300, NULL,
                                '{chaveiro}', '{pneu}', NULL, true, '{base}', false)),
  'Central: operador ativo simula +3% (10000 vira 10300)');
SELECT pg_temp.espera_erro($$
  SELECT solicitar_reajuste_taxa('00000000-0000-4000-8000-0000000d0b05', 'percentual', 300, NULL,
                                 '{chaveiro}', '{pneu}', NULL, true, '{base}', false, '[TESTE]')$$,
  'SC016', 'Central: operador inativo não solicita');
INSERT INTO lote
SELECT solicitar_reajuste_taxa('00000000-0000-4000-8000-0000000d0b02', 'percentual', 300, NULL,
                               '{chaveiro}', '{pneu}', NULL, true, '{base}', false, '[TESTE] índice do mês', 'IPCA (fictício)');
SELECT pg_temp.confere((SELECT situacao = 'solicitado' FROM vw_reajuste_taxa WHERE id = (SELECT id FROM lote)),
  'Central: S solicita e lê o lote');
SELECT pg_temp.espera_erro($$
  SELECT aprovar_reajuste_taxa('00000000-0000-4000-8000-0000000d0b02', (SELECT id FROM lote), '[TESTE]')$$,
  'SC016', 'Central: solicitante sem permissão não aprova');
SELECT pg_temp.espera_erro($$INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, componente, unidade, valor, situacao)
                             VALUES ('chaveiro', 'pneu', 'minimo', 'centavos', 1, 'definido')$$,
  '42501', 'Central não escreve em regra_taxa direto');
SELECT pg_temp.espera_erro($$INSERT INTO reajuste_taxa_decisao (reajuste_id, situacao, decidido_por, motivo)
                             VALUES ((SELECT id FROM lote), 'aprovado', '00000000-0000-4000-8000-0000000d0b03', 'x')$$,
  '42501', 'Central não grava decisão direto');
SELECT pg_temp.confere(
  aprovar_reajuste_taxa('00000000-0000-4000-8000-0000000d0b03', (SELECT id FROM lote), '[TESTE] aprovado') = 1,
  'Central: P aprova');
SELECT pg_temp.confere(
  (SELECT valor = 10300 FROM regra_taxa WHERE reajuste_id = (SELECT id FROM lote)),
  'Central: regra nova com 10300');

-- ---------- Auditoria (conferida como postgres) ----------
RESET SESSION AUTHORIZATION;
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'reajuste_taxa' AND entidade_id = (SELECT id FROM lote)
             AND ator_usuario_id = '00000000-0000-4000-8000-0000000d0b02' AND papel_bd = 'safetycar_central')
  AND EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'reajuste_taxa_decisao'
                 AND ator_usuario_id = '00000000-0000-4000-8000-0000000d0b03' AND papel_bd = 'safetycar_central')
  AND (SELECT count(*) = 2 FROM auditoria WHERE entidade = 'regra_taxa'
          AND acao IN ('parametrizacao_update','parametrizacao_insert')
          AND ator_usuario_id = '00000000-0000-4000-8000-0000000d0b03' AND papel_bd = 'safetycar_central'),
  'lote (ator S), decisão e regra encerrada e criada (ator P) na auditoria, com papel_bd = safetycar_central');
SELECT pg_temp.confere(
  (SELECT papel_bd = 'safetycar_central' FROM reajuste_taxa WHERE id = (SELECT id FROM lote))
  AND (SELECT papel_bd = 'safetycar_central' FROM reajuste_taxa_decisao WHERE reajuste_id = (SELECT id FROM lote)),
  'lote e decisão guardam o papel que os gravou');
