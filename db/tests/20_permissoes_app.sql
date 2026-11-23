-- 20 — Permissões da Central (0016) vistas pelo app. Este arquivo roda CONECTADO como safetycar_app.

SELECT pg_temp.confere(current_user = 'safetycar_app', 'teste conectado como safetycar_app');

SELECT pg_temp.confere(
  (SELECT count(*) = 5 FROM permissao_central) AND (SELECT count(*) = 3 FROM permissao_central WHERE sensivel),
  'app lê o catálogo de permissões, com a marca de sensível');

SELECT pg_temp.espera_erro($$SELECT count(*) FROM vw_operador_permissao$$,
  '42501', 'app não lê vw_operador_permissao');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM vw_operador_central$$,
  '42501', 'app não lê vw_operador_central (último acesso dos operadores)');
SELECT pg_temp.espera_erro($$SELECT registrar_acesso_central(gen_random_uuid())$$,
  '42501', 'app não registra acesso à Central');
SELECT pg_temp.espera_erro($$SELECT existe_outro_titular_conceder(gen_random_uuid())$$,
  '42501', 'app não executa existe_outro_titular_conceder (não sonda titulares)');
SELECT pg_temp.espera_erro($$SELECT exige_outro_titular_conceder(gen_random_uuid())$$,
  '42501', 'app não executa exige_outro_titular_conceder');
SELECT pg_temp.espera_erro($$UPDATE permissao_central SET sensivel = false$$,
  '42501', 'app não altera o catálogo');
