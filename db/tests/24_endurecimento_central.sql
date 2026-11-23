-- 24 — Endurecimento (0020) pelo papel safetycar_central.
-- Preparação como postgres até "-- @como_central"; depois, a sessão é safetycar_central.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d4c01', gen_random_uuid(), 'end-cen-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d4c02', gen_random_uuid(), 'end-cen-b@exemplo.invalid', 'central', 'ativo');
SELECT conceder_permissao_inicial('00000000-0000-4000-8000-0000000d4c01', '[TESTE] administrador');
SELECT cadastrar_operador('00000000-0000-4000-8000-0000000d4c01', '00000000-0000-4000-8000-0000000d4c02', '[TESTE] equipe');

-- Uma linha central_acesso "forjada" pelo app, gravada antes da 0020 existir (o trigger da 0020
-- é desligado só aqui, nesta transação, que termina em ROLLBACK).
ALTER TABLE auditoria DISABLE TRIGGER tg_auditoria_acao_reservada;
SET SESSION AUTHORIZATION safetycar_app;
INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id)
VALUES ('00000000-0000-4000-8000-0000000d4c02', 'central_acesso', 'operador_central', '00000000-0000-4000-8000-0000000d4c02');
RESET SESSION AUTHORIZATION;
ALTER TABLE auditoria ENABLE TRIGGER tg_auditoria_acao_reservada;
CREATE TEMP TABLE novo (id uuid);
GRANT ALL ON novo TO safetycar_central;

-- @como_central

SELECT pg_temp.confere(session_user = 'safetycar_central', 'sessão como safetycar_central');

SELECT pg_temp.confere(
  (SELECT ultimo_acesso_em IS NULL FROM vw_operador_central WHERE usuario_id = '00000000-0000-4000-8000-0000000d4c02'),
  'vw_operador_central ignora o central_acesso gravado pelo app');
SELECT registrar_acesso_central('00000000-0000-4000-8000-0000000d4c02');
SELECT pg_temp.confere(
  (SELECT ultimo_acesso_em IS NOT NULL FROM vw_operador_central WHERE usuario_id = '00000000-0000-4000-8000-0000000d4c02'),
  'o acesso registrado pela Central conta');

INSERT INTO novo
SELECT cadastrar_usuario_central('00000000-0000-4000-8000-0000000d4c01', '00000000-0000-4000-8000-0000000d4c5e',
                                 'end-cen-novo@exemplo.invalid', '[TESTE] nova operadora');
SELECT pg_temp.aceita($$
  SELECT cadastrar_operador('00000000-0000-4000-8000-0000000d4c01', (SELECT id FROM novo), '[TESTE] entrada na equipe')$$,
  'Central: o usuário criado pela função vira operador');
SELECT pg_temp.aceita($$
  SELECT definir_status_usuario_central('00000000-0000-4000-8000-0000000d4c01', (SELECT id FROM novo), 'suspenso', '[TESTE] afastamento')$$,
  'Central: A suspende o novo usuário');
SELECT pg_temp.aceita($$SELECT registrar_mfa_central('00000000-0000-4000-8000-0000000d4c01', now())$$,
  'Central: A registra o próprio espelho do 2FA');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM usuario$$,
  '42501', 'Central continua sem ler usuario');
SELECT pg_temp.espera_erro($$UPDATE usuario SET status = 'ativo' WHERE id = (SELECT id FROM novo)$$,
  '42501', 'Central continua sem escrever em usuario direto');

-- ---------- Conferências como postgres ----------
RESET SESSION AUTHORIZATION;
SELECT pg_temp.confere(
  (SELECT perfil = 'central' AND status = 'suspenso' AND email = 'end-cen-novo@exemplo.invalid'
     FROM usuario WHERE id = (SELECT id FROM novo))
  AND (SELECT mfa_ativado_em IS NOT NULL FROM usuario WHERE id = '00000000-0000-4000-8000-0000000d4c01'),
  'o e-mail ficou em usuario; status e espelho do 2FA gravados');
SELECT pg_temp.confere(
  (SELECT count(*) = 3 FROM auditoria
    WHERE acao IN ('central_cadastrar_usuario_central','central_definir_status_usuario','central_registrar_mfa')
      AND papel_bd = 'safetycar_central' AND ator_usuario_id = '00000000-0000-4000-8000-0000000d4c01')
  AND NOT EXISTS (SELECT 1 FROM auditoria WHERE papel_bd = 'safetycar_central'
                   AND (coalesce(antes::text, '') || coalesce(depois::text, '')) LIKE '%@%'),
  'os três eventos com papel_bd = safetycar_central e ator A, sem nenhum e-mail');
