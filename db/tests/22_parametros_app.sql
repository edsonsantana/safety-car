-- 22 — Parâmetros (0018) vistos pelo app. Roda CONECTADO como safetycar_app.

SELECT pg_temp.confere(current_user = 'safetycar_app', 'teste conectado como safetycar_app');

SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM vw_parametro_vigente
    WHERE (chave, valor) IN (('limite_variacao_reajuste', 20), ('alerta_documento_dias', 30))),
  'app lê os valores vigentes em vw_parametro_vigente');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'vw_parametro_vigente'
                 AND (column_name LIKE '%\_por' OR column_name IN ('motivo', 'alteracao_id', 'papel_bd'))),
  'a visão não expõe quem alterou, quem aprovou nem o motivo');

SELECT pg_temp.espera_erro($$SELECT count(*) FROM parametro$$, '42501', 'app não lê o catálogo direto');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM parametro_valor$$, '42501', 'app não lê o histórico (identifica operadores)');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM parametro_alteracao$$, '42501', 'app não lê os pedidos');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM parametro_alteracao_decisao$$, '42501', 'app não lê as decisões');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM vw_parametro_alteracao$$, '42501', 'app não lê a visão dos pedidos');
SELECT pg_temp.espera_erro($$SELECT parametro_vigente('alerta_documento_dias')$$,
  '42501', 'app não executa parametro_vigente (lê só a visão)');
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(gen_random_uuid(), 'alerta_documento_dias', 10, 'x')$$,
  '42501', 'app não altera parâmetro');
SELECT pg_temp.espera_erro($$SELECT solicitar_alteracao_parametro(gen_random_uuid(), 'limite_variacao_reajuste', 10, 'x')$$,
  '42501', 'app não pede alteração');
SELECT pg_temp.espera_erro($$SELECT aprovar_alteracao_parametro(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não aprova');
SELECT pg_temp.espera_erro($$SELECT rejeitar_alteracao_parametro(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não rejeita');
SELECT pg_temp.espera_erro($$SELECT cancelar_alteracao_parametro(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não cancela');
SELECT pg_temp.espera_erro($$INSERT INTO parametro_valor (parametro_chave, valor, origem, motivo) VALUES ('alerta_documento_dias', 10, 'migracao', 'x')$$,
  '42501', 'app não grava valor');
