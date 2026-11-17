-- 03 — Usuário (unicidades e perfis) e auditoria somente de inserção

INSERT INTO usuario (id, keycloak_sub, email, celular_e164, perfil)
VALUES ('00000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
        'tomador.teste@exemplo.invalid', '+5511900000001', 'tomador');

SELECT pg_temp.espera_erro($$
  INSERT INTO usuario (keycloak_sub, email, perfil)
  VALUES ('10000000-0000-4000-8000-000000000001', 'outro@exemplo.invalid', 'tomador')$$,
  '23505', 'keycloak_sub duplicado é rejeitado');

SELECT pg_temp.espera_erro($$
  INSERT INTO usuario (keycloak_sub, email, perfil)
  VALUES (gen_random_uuid(), 'TOMADOR.Teste@Exemplo.INVALID', 'tomador')$$,
  '23505', 'e-mail duplicado (só muda maiúsculas) é rejeitado');

SELECT pg_temp.espera_erro($$
  INSERT INTO usuario (keycloak_sub, email, celular_e164, perfil)
  VALUES (gen_random_uuid(), 'outro2@exemplo.invalid', '+5511900000001', 'tomador')$$,
  '23505', 'celular duplicado é rejeitado');

SELECT pg_temp.espera_erro($$
  INSERT INTO usuario (keycloak_sub, email, perfil)
  VALUES (gen_random_uuid(), 'seg@exemplo.invalid', 'seguradora')$$,
  '23514', 'perfil "seguradora" não existe mais');

SELECT pg_temp.aceita($$
  INSERT INTO usuario (keycloak_sub, email, perfil) VALUES
    (gen_random_uuid(), 'p@exemplo.invalid', 'parceiro'),
    (gen_random_uuid(), 'c@exemplo.invalid', 'central')$$,
  'perfis parceiro e central aceitos');

SELECT pg_temp.espera_erro($$
  UPDATE usuario SET status = 'excluido' WHERE id = '00000000-0000-4000-8000-000000000001'$$,
  '23514', 'status excluido exige excluido_em');

-- atualizado_em por trigger
UPDATE usuario SET atualizado_em = '2000-01-01', ultimo_login_em = now()
 WHERE id = '00000000-0000-4000-8000-000000000001';
SELECT pg_temp.confere(
  (SELECT atualizado_em > '2020-01-01' FROM usuario WHERE id = '00000000-0000-4000-8000-000000000001'),
  'atualizado_em é mantido pelo trigger (ignora valor enviado)');

-- Auditoria
INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, depois)
VALUES ('00000000-0000-4000-8000-000000000001', 'criar', 'usuario',
        '00000000-0000-4000-8000-000000000001', '{"teste": true}');

SELECT pg_temp.espera_erro($$UPDATE auditoria SET acao = 'adulterada'$$,
  'SC010', 'UPDATE em auditoria é bloqueado pelo trigger (mesmo para o dono)');
SELECT pg_temp.espera_erro($$DELETE FROM auditoria$$,
  'SC010', 'DELETE em auditoria é bloqueado pelo trigger (mesmo para o dono)');
SELECT pg_temp.espera_erro($$TRUNCATE auditoria$$,
  'SC010', 'TRUNCATE em auditoria é bloqueado pelo trigger');
SELECT pg_temp.confere((SELECT count(*) = 1 FROM auditoria), 'registro de auditoria continua lá');
