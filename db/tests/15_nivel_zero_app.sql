-- 15 — Nível 0 visto pelo app (0013). Este arquivo roda CONECTADO como safetycar_app.

SELECT pg_temp.confere(current_user = 'safetycar_app', 'teste conectado como safetycar_app');

-- ---------- Sem escrita na parametrização ----------
SELECT pg_temp.confere((SELECT count(*) = 1 FROM nivel_verificacao WHERE nivel = 0),
  'app lê o nível 0 no catálogo');
SELECT pg_temp.espera_erro($$UPDATE nivel_verificacao SET nome = 'x' WHERE nivel = 0$$,
  '42501', 'app não altera o nível 0');
SELECT pg_temp.espera_erro($$DELETE FROM nivel_verificacao WHERE nivel = 0$$,
  '42501', 'app não apaga o nível 0');
SELECT pg_temp.espera_erro($$INSERT INTO nivel_verificacao (nivel, nome) VALUES (0, 'x')$$,
  '42501', 'app não insere nível');
SELECT pg_temp.espera_erro($$UPDATE servico_nivel_minimo SET nivel_minimo = 1, situacao = 'definido'$$,
  '42501', 'app não define nível mínimo');
SELECT pg_temp.espera_erro($$UPDATE nivel_requisito SET nivel = 1$$,
  '42501', 'app não altera requisitos por nível');
SELECT pg_temp.espera_erro($$UPDATE politica_garantia SET fim_vigencia = now() + interval '1 day'$$,
  '42501', 'app não altera garantia');
SELECT pg_temp.espera_erro($$DELETE FROM regra_taxa$$,
  '42501', 'app não apaga taxa');

-- ---------- Cadastro pelo app nasce no 0; sobe só pelo histórico ----------
INSERT INTO usuario (id, keycloak_sub, email, perfil) VALUES
  ('00000000-0000-4000-8000-000000000f01', gen_random_uuid(), 'n0-app@exemplo.invalid', 'tomador');
INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash) VALUES
  ('00000000-0000-4000-8000-000000000f01', '[TESTE] Tomador N0 via app', '\x01', pg_temp.hmac_teste('39053344705'));
SELECT pg_temp.confere(
  (SELECT nivel_verificacao = 0 FROM tomador WHERE usuario_id = '00000000-0000-4000-8000-000000000f01'),
  'tomador cadastrado pelo app nasce no nível 0');
SELECT pg_temp.espera_erro($$
  UPDATE tomador SET nivel_verificacao = 1 WHERE usuario_id = '00000000-0000-4000-8000-000000000f01'$$,
  'SC011', 'app não promove ao nível 1 por UPDATE direto');
SELECT pg_temp.aceita($$
  INSERT INTO nivel_verificacao_historico (tomador_id, nivel, origem)
  VALUES ('00000000-0000-4000-8000-000000000f01', 1, 'automatica')$$,
  'app promove ao nível 1 pelo histórico');
SELECT pg_temp.confere(
  (SELECT nivel_verificacao = 1 FROM tomador WHERE usuario_id = '00000000-0000-4000-8000-000000000f01'),
  'nível atual 1 após a linha de histórico');

-- ---------- Consultas com a carga "a definir" ----------
SELECT pg_temp.espera_erro($$SELECT cumpre_nivel_minimo('tomador', 0, 'guincho_leve')$$,
  'SC013', 'app: nível 0 com mínimo da carga "a definir" recusa SC013');
SELECT pg_temp.espera_erro($$SELECT politica_garantia_vigente('guincho_leve', 0, 'pix_pre_pago')$$,
  '22023', 'app: garantia para o nível 0 não se aplica');
