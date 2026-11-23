-- 19 — Reajuste de taxas visto pelo app (0015, com as regras da 0019). Roda CONECTADO como safetycar_app.

SELECT pg_temp.confere(current_user = 'safetycar_app', 'teste conectado como safetycar_app');

SELECT pg_temp.espera_erro($$
  SELECT * FROM simular_reajuste_taxa(gen_random_uuid(), 1, '{chaveiro}', '{pneu}', NULL, NULL, true, '{base}', false)$$,
  '42501', 'app não simula reajuste');
SELECT pg_temp.espera_erro($$SELECT * FROM simular_reajuste_taxa(gen_random_uuid(), gen_random_uuid())$$,
  '42501', 'app não simula lote');
SELECT pg_temp.espera_erro($$
  SELECT solicitar_reajuste_taxa(gen_random_uuid(), 1, '{chaveiro}', '{pneu}', NULL, NULL, true, '{base}', false, 'x')$$,
  '42501', 'app não solicita reajuste');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não aprova reajuste');
SELECT pg_temp.espera_erro($$SELECT rejeitar_reajuste_taxa(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não rejeita reajuste');
SELECT pg_temp.espera_erro($$SELECT cancelar_reajuste_taxa(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não cancela reajuste');
SELECT pg_temp.espera_erro($$SELECT arredondar_centavos(1.5)$$,
  '42501', 'app não executa as funções internas do reajuste');
SELECT pg_temp.espera_erro($$SELECT percentual_para_bp(10)$$,
  '42501', 'app não executa os utilitários da 0019');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM reajuste_taxa$$,
  '42501', 'app não lê os lotes (identificam operadores)');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM reajuste_taxa_decisao$$,
  '42501', 'app não lê as decisões');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM vw_reajuste_taxa$$,
  '42501', 'app não lê a view de lotes');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM vw_reajuste_taxa_regra$$,
  '42501', 'app não lê a view de regras reajustadas');
SELECT pg_temp.espera_erro($$
  INSERT INTO reajuste_taxa (tipo, percentual_bp, inclui_nacional, componentes, motivo, solicitado_por)
  VALUES ('percentual', 100, true, '{base}', 'x', gen_random_uuid())$$,
  '42501', 'app não insere lote direto');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET fim_vigencia = now() + interval '1 day'$$,
  '42501', 'app continua sem escrever em regra_taxa');
SELECT pg_temp.confere(
  (SELECT count(*) >= 0 FROM regra_taxa WHERE reajuste_id IS NULL),
  'app lê regra_taxa, inclusive as colunas reajuste_id e regra_origem_id');
