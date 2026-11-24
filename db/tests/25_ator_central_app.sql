-- 25 — ator_central (0021) visto pelo app: não executa.
-- Roda inteiro conectado como safetycar_app (sem preparação: a recusa é por privilégio).

SELECT pg_temp.confere(session_user = 'safetycar_app', 'sessão como safetycar_app');

SELECT pg_temp.espera_erro($$SELECT ator_central('00000000-0000-4000-8000-0000000e5d01')$$,
  '42501', 'app não executa ator_central (não sonda quem é operador)');
SELECT pg_temp.espera_erro($$SELECT ator_central(NULL)$$,
  '42501', 'app não executa ator_central nem com sub nulo');
