-- 21 — Definição da primeira tarifa (0017) pelo papel safetycar_central.
-- Preparação como postgres até a linha "-- @como_central"; depois dela, a sessão é safetycar_central.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d1b01', gen_random_uuid(), 'def-cen-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d1b02', gen_random_uuid(), 'def-cen-s@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d1b03', gen_random_uuid(), 'def-cen-p@exemplo.invalid', 'central', 'ativo');
SELECT conceder_permissao_inicial('00000000-0000-4000-8000-0000000d1b01', '[TESTE] administrador');
SELECT cadastrar_operador('00000000-0000-4000-8000-0000000d1b01', o::uuid, '[TESTE] equipe')
  FROM unnest(ARRAY['00000000-0000-4000-8000-0000000d1b02', '00000000-0000-4000-8000-0000000d1b03']) o;
SELECT conceder_permissao('00000000-0000-4000-8000-0000000d1b01', '00000000-0000-4000-8000-0000000d1b02',
                          'solicitar_reajuste_taxa', '[TESTE] solicitante');
SELECT conceder_permissao('00000000-0000-4000-8000-0000000d1b01', '00000000-0000-4000-8000-0000000d1b03',
                          'aprovar_reajuste_taxa', '[TESTE] aprovador');

-- @como_central

SELECT pg_temp.confere(session_user = 'safetycar_central', 'sessão como safetycar_central');
CREATE TEMP TABLE v (k text PRIMARY KEY, id uuid);

SELECT pg_temp.confere(
  (SELECT count(*) = 1 AND bool_and(acao = 'definir' AND problema IS NULL)
     FROM simular_definicao_taxa('00000000-0000-4000-8000-0000000d1b02',
       '[{"tipo_parceiro":"guincho","servico":"guincho_pesado","nacional":true,"componente":"base","valor":30000}]'::jsonb)),
  'Central: S simula a definição');
INSERT INTO v (k, id)
SELECT 'L', solicitar_definicao_taxa('00000000-0000-4000-8000-0000000d1b02',
  '[{"tipo_parceiro":"guincho","servico":"guincho_pesado","nacional":true,"componente":"base","valor":30000}]'::jsonb,
  '[TESTE] primeira tarifa');
SELECT pg_temp.confere(
  (SELECT situacao = 'solicitado' AND itens = 1 FROM vw_definicao_taxa WHERE id = (SELECT id FROM v WHERE k = 'L')),
  'Central: S solicita e lê o lote');
SELECT pg_temp.confere(
  (SELECT count(*) = 1 FROM simular_definicao_taxa('00000000-0000-4000-8000-0000000d1b03', (SELECT id FROM v WHERE k = 'L'))),
  'Central: P simula o lote solicitado');
SELECT pg_temp.espera_erro($$
  SELECT aprovar_definicao_taxa('00000000-0000-4000-8000-0000000d1b02', (SELECT id FROM v WHERE k = 'L'), '[TESTE]')$$,
  'SC016', 'Central: o solicitante sem permissão não aprova');
SELECT pg_temp.confere(
  aprovar_definicao_taxa('00000000-0000-4000-8000-0000000d1b03', (SELECT id FROM v WHERE k = 'L'), '[TESTE] aprovado') = 1,
  'Central: P aprova');
SELECT pg_temp.confere(
  (SELECT valor = 30000 AND situacao = 'definido' FROM regra_taxa
    WHERE definicao_id = (SELECT id FROM v WHERE k = 'L')),
  'Central: regra definida com 30000');

-- ---------- Sem escrita direta nem acesso aos utilitários ----------
SELECT pg_temp.espera_erro($$INSERT INTO definicao_taxa (motivo, solicitado_por) VALUES ('x', '00000000-0000-4000-8000-0000000d1b02')$$,
  '42501', 'Central não insere lote direto');
SELECT pg_temp.espera_erro($$INSERT INTO definicao_taxa_decisao (definicao_id, situacao, decidido_por, motivo)
  VALUES ((SELECT id FROM v WHERE k = 'L'), 'rejeitado', '00000000-0000-4000-8000-0000000d1b03', 'x')$$,
  '42501', 'Central não grava decisão direto');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET fim_vigencia = now() + interval '1 day' WHERE definicao_id IS NOT NULL$$,
  '42501', 'Central não escreve em regra_taxa direto');
SELECT pg_temp.espera_erro($$INSERT INTO regiao (codigo, nome) VALUES ('leste', 'Leste')$$,
  '42501', 'Central não altera as regiões');
SELECT pg_temp.espera_erro($$SELECT * FROM definicao_itens('[]'::jsonb)$$,
  '42501', 'Central não executa definicao_itens');
SELECT pg_temp.espera_erro($$SELECT * FROM definicao_calculo('[]'::jsonb, now())$$,
  '42501', 'Central não executa definicao_calculo');
SELECT pg_temp.espera_erro($$SELECT ufs_da_regiao('sul')$$,
  '42501', 'Central não executa ufs_da_regiao (lê regiao_uf)');
SELECT pg_temp.confere(
  (SELECT count(*) = 5 FROM regiao) AND (SELECT count(*) = 27 FROM regiao_uf),
  'Central lê regiões e UFs');

-- ---------- Auditoria (conferida como postgres) ----------
RESET SESSION AUTHORIZATION;
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_definicao_taxa_solicitada' AND papel_bd = 'safetycar_central'
             AND ator_usuario_id = '00000000-0000-4000-8000-0000000d1b02')
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_definicao_taxa_aprovada' AND papel_bd = 'safetycar_central'
             AND ator_usuario_id = '00000000-0000-4000-8000-0000000d1b03'),
  'solicitação (ator S) e aprovação (ator P) com papel_bd = safetycar_central');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM auditoria WHERE entidade = 'regra_taxa' AND papel_bd = 'safetycar_central'
      AND ator_usuario_id = '00000000-0000-4000-8000-0000000d1b03'),
  'regra encerrada e regra criada na auditoria, com ator P e papel_bd = safetycar_central');
SELECT pg_temp.confere(
  (SELECT papel_bd = 'safetycar_central' FROM definicao_taxa_decisao WHERE definicao_id = (SELECT id FROM v WHERE k = 'L')),
  'a decisão guarda o papel que a gravou');
