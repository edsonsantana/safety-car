-- 24 — Endurecimento (0020) visto pelo app.
-- Preparação como postgres até "-- @como_app" (o app não consegue criar usuário da Central);
-- depois, a sessão é safetycar_app (SET SESSION AUTHORIZATION: session_user é o app).
-- No fim, RESET SESSION AUTHORIZATION volta a postgres para conferir a auditoria.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d4a01', '00000000-0000-4000-8000-0000000d4a51', 'end-app-c@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d4a02', gen_random_uuid(), 'end-app-t@exemplo.invalid', 'tomador', 'ativo'),
  ('00000000-0000-4000-8000-0000000d4a03', gen_random_uuid(), 'end-app-u@exemplo.invalid', 'tomador', 'pendente'),
  ('00000000-0000-4000-8000-0000000d4a04', gen_random_uuid(), 'end-app-p@exemplo.invalid', 'parceiro', 'ativo');
INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash) VALUES
  ('00000000-0000-4000-8000-0000000d4a02', '[TESTE] Tomador', '\x01',
   hmac('52998224725', 'chave-ficticia-de-teste', 'sha256'));
SELECT conceder_permissao_inicial('00000000-0000-4000-8000-0000000d4a01', '[TESTE] administrador');

-- @como_app

SELECT pg_temp.confere(session_user = 'safetycar_app' AND current_user = 'safetycar_app', 'sessão como safetycar_app');

-- ---------- Usuário da Central (SC029) ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO usuario (keycloak_sub, email, perfil, status) VALUES (gen_random_uuid(), 'end-app-novo@exemplo.invalid', 'central', 'ativo')$$,
  'SC029', 'app não cria usuário da Central');
SELECT pg_temp.espera_erro($$UPDATE usuario SET perfil = 'central' WHERE id = '00000000-0000-4000-8000-0000000d4a03'$$,
  'SC029', 'app não promove ninguém a central');
SELECT pg_temp.espera_erro($$UPDATE usuario SET keycloak_sub = gen_random_uuid() WHERE id = '00000000-0000-4000-8000-0000000d4a01'$$,
  'SC029', 'app não troca o keycloak_sub de usuário da Central (tomada de identidade)');
SELECT pg_temp.espera_erro($$UPDATE usuario SET email = 'outro@exemplo.invalid' WHERE id = '00000000-0000-4000-8000-0000000d4a01'$$,
  'SC029', 'app não troca o e-mail de usuário da Central');
SELECT pg_temp.espera_erro($$UPDATE usuario SET celular_e164 = '+5511900000000' WHERE id = '00000000-0000-4000-8000-0000000d4a01'$$,
  'SC029', 'app não troca o celular de usuário da Central');
SELECT pg_temp.espera_erro($$UPDATE usuario SET status = 'suspenso' WHERE id = '00000000-0000-4000-8000-0000000d4a01'$$,
  'SC029', 'app não suspende usuário da Central (nem o último titular)');
SELECT pg_temp.espera_erro($$UPDATE usuario SET status = 'excluido', excluido_em = now() WHERE id = '00000000-0000-4000-8000-0000000d4a01'$$,
  'SC029', 'app não exclui usuário da Central');
SELECT pg_temp.espera_erro($$UPDATE usuario SET perfil = 'tomador' WHERE id = '00000000-0000-4000-8000-0000000d4a01'$$,
  'SC029', 'app não tira ninguém da Central');
SELECT pg_temp.espera_erro($$UPDATE usuario SET mfa_ativado_em = now() WHERE id = '00000000-0000-4000-8000-0000000d4a01'$$,
  'SC029', 'app não forja o espelho do 2FA de usuário da Central');
SELECT pg_temp.espera_erro($$UPDATE usuario SET email_verificado_em = now() WHERE id = '00000000-0000-4000-8000-0000000d4a01'$$,
  'SC029', 'app não marca verificação de usuário da Central');
SELECT pg_temp.aceita($$UPDATE usuario SET ultimo_login_em = now() WHERE id = '00000000-0000-4000-8000-0000000d4a01'$$,
  'app atualiza ultimo_login_em de usuário da Central (única coluna liberada)');

-- ---------- Tomador e parceiro: nada muda ----------
SELECT pg_temp.aceita($$UPDATE usuario SET status = 'suspenso', mfa_ativado_em = now() WHERE id = '00000000-0000-4000-8000-0000000d4a02'$$,
  'app continua alterando status e espelho do 2FA de tomador');
SELECT pg_temp.aceita($$UPDATE usuario SET email = 'end-app-p2@exemplo.invalid' WHERE id = '00000000-0000-4000-8000-0000000d4a04'$$,
  'app continua alterando o e-mail de parceiro');
SELECT pg_temp.aceita($$
  INSERT INTO usuario (keycloak_sub, email, perfil) VALUES (gen_random_uuid(), 'end-app-novo-t@exemplo.invalid', 'tomador')$$,
  'app continua criando tomador');

-- ---------- Auditoria: prefixos reservados (SC030) e sem leitura ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id)
  VALUES ('00000000-0000-4000-8000-0000000d4a01', 'central_acesso', 'operador_central', '00000000-0000-4000-8000-0000000d4a01')$$,
  'SC030', 'app não forja "último acesso" (central_acesso)');
SELECT pg_temp.espera_erro($$INSERT INTO auditoria (acao, entidade) VALUES ('central_permissao_concedida', 'permissao_concessao')$$,
  'SC030', 'app não forja evento central_*');
SELECT pg_temp.espera_erro($$INSERT INTO auditoria (acao, entidade) VALUES ('migrator_criar_usuario_central', 'usuario')$$,
  'SC030', 'app não forja evento migrator_*');
SELECT pg_temp.espera_erro($$INSERT INTO auditoria (acao, entidade) VALUES ('parametrizacao_update', 'regra_taxa')$$,
  'SC030', 'app não forja linha de parametrização');
SELECT pg_temp.aceita($$INSERT INTO auditoria (acao, entidade) VALUES ('centralizar', 'teste')$$,
  'só o prefixo com sublinhado é reservado ("centralizar" passa)');
SELECT pg_temp.aceita($$
  INSERT INTO auditoria (acao, entidade, papel_bd) VALUES ('teste_papel_app', 'teste', 'safetycar_migrator')$$,
  'app grava a própria ação (o papel_bd enviado é ignorado)');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM auditoria$$, '42501', 'app não lê a auditoria');
SELECT pg_temp.aceita($$
  INSERT INTO nivel_verificacao_historico (tomador_id, nivel, origem)
  VALUES ('00000000-0000-4000-8000-0000000d4a02', 1, 'automatica')$$,
  'escrita legítima do app gera a linha de parametrização pelo trigger (pg_trigger_depth > 1)');

-- ---------- Funções da Central ----------
SELECT pg_temp.espera_erro($$SELECT cadastrar_usuario_central(gen_random_uuid(), gen_random_uuid(), 'x@exemplo.invalid', 'x')$$,
  '42501', 'app não cadastra usuário da Central');
SELECT pg_temp.espera_erro($$SELECT definir_status_usuario_central(gen_random_uuid(), gen_random_uuid(), 'suspenso', 'x')$$,
  '42501', 'app não altera status de usuário da Central');
SELECT pg_temp.espera_erro($$SELECT registrar_mfa_central(gen_random_uuid(), now())$$,
  '42501', 'app não registra o espelho do 2FA da Central');

-- ---------- Conferências como postgres ----------
RESET SESSION AUTHORIZATION;
SELECT pg_temp.confere(
  (SELECT keycloak_sub = '00000000-0000-4000-8000-0000000d4a51' AND email = 'end-app-c@exemplo.invalid'
          AND status = 'ativo' AND perfil = 'central' AND mfa_ativado_em IS NULL AND ultimo_login_em IS NOT NULL
     FROM usuario WHERE id = '00000000-0000-4000-8000-0000000d4a01'),
  'o usuário da Central só teve o ultimo_login_em alterado');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'nivel_verificacao_historico' AND acao = 'parametrizacao_insert'
             AND papel_bd = 'safetycar_app'),
  'a linha de parametrização gravada pelo trigger, numa escrita do app, entrou (papel_bd = safetycar_app)');
SELECT pg_temp.confere(
  (SELECT papel_bd = 'safetycar_app' FROM auditoria WHERE acao = 'teste_papel_app'),
  'o app não forja papel_bd');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM auditoria WHERE papel_bd = 'safetycar_app'
               AND (acao LIKE 'central\_%' OR acao LIKE 'migrator\_%')),
  'nenhum evento central_* ou migrator_* com papel_bd = safetycar_app');
SELECT pg_temp.confere(
  (SELECT count(*) >= 42 FROM auditoria
    WHERE entidade = 'regra_taxa' AND acao = 'parametrizacao_insert' AND papel_bd = 'safetycar_migrator')
  AND (SELECT count(*) >= 12 FROM auditoria
    WHERE entidade = 'nivel_requisito' AND acao = 'parametrizacao_insert' AND papel_bd = 'safetycar_migrator'),
  'carga das taxas e dos requisitos na auditoria, feita pelo safetycar_migrator (vinha do teste 13)');
