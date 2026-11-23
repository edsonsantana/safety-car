-- 21 — Regiões e definição de tarifa (0017) vistas pelo app. Roda CONECTADO como safetycar_app.

SELECT pg_temp.confere(current_user = 'safetycar_app', 'teste conectado como safetycar_app');

SELECT pg_temp.espera_erro($$SELECT count(*) FROM regiao$$, '42501', 'app não lê regiao');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM regiao_uf$$, '42501', 'app não lê regiao_uf');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM definicao_taxa$$,
  '42501', 'app não lê os lotes de definição (identificam operadores)');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM definicao_taxa_item$$, '42501', 'app não lê os itens');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM definicao_taxa_decisao$$, '42501', 'app não lê as decisões');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM vw_definicao_taxa$$, '42501', 'app não lê a visão dos lotes');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM simular_definicao_taxa(gen_random_uuid(), '[]'::jsonb)$$,
  '42501', 'app não simula');
SELECT pg_temp.espera_erro($$SELECT solicitar_definicao_taxa(gen_random_uuid(), '[]'::jsonb, 'x')$$,
  '42501', 'app não solicita');
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não aprova');
SELECT pg_temp.espera_erro($$SELECT rejeitar_definicao_taxa(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não rejeita');
SELECT pg_temp.espera_erro($$SELECT cancelar_definicao_taxa(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não cancela');
SELECT pg_temp.espera_erro($$SELECT * FROM definicao_itens('[]'::jsonb)$$, '42501', 'app não executa definicao_itens');
SELECT pg_temp.espera_erro($$SELECT ufs_da_regiao('sul')$$, '42501', 'app não executa ufs_da_regiao');
SELECT pg_temp.espera_erro($$INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, componente, unidade, valor)
  VALUES ('guincho', 'guincho_leve', 'base', 'centavos', 0)$$,
  '42501', 'app continua sem escrever em regra_taxa');
SELECT pg_temp.confere(
  (SELECT count(*) = 0 FROM regra_taxa WHERE definicao_id IS NOT NULL),
  'app lê regra_taxa, inclusive a coluna nova definicao_id');
