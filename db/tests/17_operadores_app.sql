-- 17 — Operadores e permissões vistos pelo app (0014). Este arquivo roda CONECTADO como safetycar_app.

SELECT pg_temp.confere(current_user = 'safetycar_app', 'teste conectado como safetycar_app');

-- ---------- Leitura permitida ----------
SELECT pg_temp.confere((SELECT count(*) = 2 FROM permissao_central), 'app lê o catálogo de permissões');

-- ---------- Sem consulta de permissão nem leitura de quem são os operadores ----------
SELECT pg_temp.espera_erro($$SELECT operador_tem_permissao(gen_random_uuid(), 'aprovar_reajuste_taxa')$$,
  '42501', 'app não executa operador_tem_permissao (não sonda quem é aprovador)');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM operador_central$$,
  '42501', 'app não lê operador_central');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM permissao_revogacao$$,
  '42501', 'app não lê permissao_revogacao');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM vw_permissao_vigente$$,
  '42501', 'app não lê vw_permissao_vigente');

-- ---------- Nenhuma ação ----------
SELECT pg_temp.espera_erro($$SELECT cadastrar_operador(gen_random_uuid(), gen_random_uuid(), 'x')$$,
  '42501', 'app não cadastra operador');
SELECT pg_temp.espera_erro($$SELECT definir_operador_ativo(gen_random_uuid(), gen_random_uuid(), false, 'x')$$,
  '42501', 'app não ativa nem desativa operador');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao(gen_random_uuid(), gen_random_uuid(), 'aprovar_reajuste_taxa', 'x')$$,
  '42501', 'app não concede permissão');
SELECT pg_temp.espera_erro($$SELECT revogar_permissao(gen_random_uuid(), gen_random_uuid(), 'aprovar_reajuste_taxa', 'x')$$,
  '42501', 'app não revoga permissão');
SELECT pg_temp.espera_erro($$SELECT conceder_permissao_inicial(gen_random_uuid(), 'x')$$,
  '42501', 'app não faz a concessão inicial');
SELECT pg_temp.espera_erro($$SELECT revogar_permissao_manual(gen_random_uuid(), 'conceder_permissao', 'x')$$,
  '42501', 'app não faz revogação manual');
SELECT pg_temp.espera_erro($$
  INSERT INTO permissao_concessao (operador_id, permissao_codigo, motivo, origem)
  VALUES (gen_random_uuid(), 'conceder_permissao', 'x', 'inicial')$$,
  '42501', 'app não insere concessão direto');
SELECT pg_temp.espera_erro($$INSERT INTO operador_central (usuario_id) VALUES (gen_random_uuid())$$,
  '42501', 'app não cadastra operador direto');
SELECT pg_temp.espera_erro($$UPDATE permissao_central SET permite_autoaprovacao = true$$,
  '42501', 'app não liga a autoaprovação');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM permissao_concessao$$,
  '42501', 'app não lê o histórico de concessões');

-- Nenhuma função SECURITY DEFINER executável pelo app.
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'public' AND p.prosecdef
                 AND has_function_privilege('safetycar_app', p.oid, 'EXECUTE')),
  'app não executa nenhuma função SECURITY DEFINER');
