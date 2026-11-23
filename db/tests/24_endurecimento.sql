-- 24 — Endurecimento (0020), como safetycar_migrator (dono das funções).
-- Último titular no status, na exclusão e no perfil; usuário da Central pelas funções da Central;
-- espelho do 2FA; e-mail fora da auditoria.
-- Usuários FICTÍCIOS: A, B e C de perfil central; T tomador; D criado pela função.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d4b01', gen_random_uuid(), 'end-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d4b02', gen_random_uuid(), 'end-b@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d4b03', gen_random_uuid(), 'end-c@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d4b09', gen_random_uuid(), 'end-t@exemplo.invalid', 'tomador', 'ativo');

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $f$
  SELECT ('00000000-0000-4000-8000-0000000d4b0' ||
          CASE p WHEN 'A' THEN '1' WHEN 'B' THEN '2' WHEN 'C' THEN '3' ELSE '9' END)::uuid
$f$;
CREATE TEMP TABLE v (k text PRIMARY KEY, id uuid);
CREATE FUNCTION pg_temp.id(p text) RETURNS uuid LANGUAGE sql STABLE AS $f$ SELECT id FROM v WHERE k = p $f$;

SELECT conceder_permissao_inicial(pg_temp.u('A'), '[TESTE] administrador');
SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u(o), '[TESTE] equipe') FROM unnest(ARRAY['B','C']) o;

-- ---------- Último titular (A) no usuário, para qualquer escritor (SC023) ----------
SELECT pg_temp.espera_erro($$UPDATE usuario SET status = 'suspenso' WHERE id = pg_temp.u('A')$$,
  'SC023', 'o único titular não é suspenso');
SELECT pg_temp.espera_erro($$UPDATE usuario SET status = 'bloqueado' WHERE id = pg_temp.u('A')$$,
  'SC023', 'o único titular não é bloqueado');
SELECT pg_temp.espera_erro($$UPDATE usuario SET status = 'excluido', excluido_em = now() WHERE id = pg_temp.u('A')$$,
  'SC023', 'o único titular não é excluído (excluido_em)');
SELECT pg_temp.espera_erro($$UPDATE usuario SET perfil = 'tomador' WHERE id = pg_temp.u('A')$$,
  'SC023', 'o único titular não muda de perfil (a SC023 vem antes da SC001)');
SELECT pg_temp.espera_erro($$UPDATE usuario SET perfil = 'tomador' WHERE id = pg_temp.u('C')$$,
  'SC001', 'operador que não é titular continua sem trocar de perfil (SC001 da 0014)');
SELECT pg_temp.aceita($$UPDATE usuario SET status = 'suspenso' WHERE id = pg_temp.u('C')$$,
  'quem não é titular pode ser suspenso');
UPDATE usuario SET status = 'ativo' WHERE id = pg_temp.u('C');

SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('B'), 'conceder_permissao', '[TESTE] segundo titular');
SELECT pg_temp.aceita($$UPDATE usuario SET status = 'suspenso' WHERE id = pg_temp.u('A')$$,
  'com outro titular (B), A pode ser suspenso');
SELECT pg_temp.espera_erro($$UPDATE usuario SET status = 'suspenso' WHERE id = pg_temp.u('B')$$,
  'SC023', 'B, agora único titular efetivo (A suspenso), não é suspenso');
SELECT pg_temp.aceita($$UPDATE usuario SET status = 'ativo' WHERE id = pg_temp.u('A')$$,
  'reativar não passa pela regra');

-- ---------- cadastrar_usuario_central ----------
SELECT pg_temp.espera_erro($$SELECT cadastrar_usuario_central(pg_temp.u('C'), gen_random_uuid(), 'x@exemplo.invalid', '[TESTE]')$$,
  'SC016', 'sem conceder_permissao não cadastra usuário da Central');
SELECT pg_temp.espera_erro($$SELECT cadastrar_usuario_central(pg_temp.u('A'), NULL, 'x@exemplo.invalid', '[TESTE]')$$,
  '22023', 'keycloak_sub é obrigatório');
SELECT pg_temp.espera_erro($$SELECT cadastrar_usuario_central(pg_temp.u('A'), gen_random_uuid(), 'sem-arroba', '[TESTE]')$$,
  '22023', 'e-mail inválido');
SELECT pg_temp.espera_erro($$SELECT cadastrar_usuario_central(pg_temp.u('A'), gen_random_uuid(), NULL, '[TESTE]')$$,
  '22023', 'e-mail ausente');
SELECT pg_temp.espera_erro($$SELECT cadastrar_usuario_central(pg_temp.u('A'), gen_random_uuid(), 'x@exemplo.invalid', '  ')$$,
  '22023', 'sem motivo');
INSERT INTO v (k, id) SELECT 'D', cadastrar_usuario_central(pg_temp.u('A'), '00000000-0000-4000-8000-0000000d4b0d',
                                                         'End-D@Exemplo.invalid', '[TESTE] nova operadora');
SELECT pg_temp.confere(
  (SELECT perfil = 'central' AND status = 'ativo' AND email = 'end-d@exemplo.invalid'
          AND keycloak_sub = '00000000-0000-4000-8000-0000000d4b0d' FROM usuario WHERE id = pg_temp.id('D'))
  AND NOT EXISTS (SELECT 1 FROM operador_central WHERE usuario_id = pg_temp.id('D')),
  'usuário central criado (e-mail normalizado), ainda sem ser operador');
SELECT pg_temp.espera_erro($$SELECT cadastrar_usuario_central(pg_temp.u('A'), '00000000-0000-4000-8000-0000000d4b0d', 'outro@exemplo.invalid', '[TESTE]')$$,
  '23505', 'keycloak_sub repetido');
SELECT pg_temp.espera_erro($$SELECT cadastrar_usuario_central(pg_temp.u('A'), gen_random_uuid(), 'end-d@exemplo.invalid', '[TESTE]')$$,
  '23505', 'e-mail repetido');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_cadastrar_usuario_central' AND entidade = 'usuario'
             AND entidade_id = pg_temp.id('D') AND ator_usuario_id = pg_temp.u('A')
             AND depois ->> 'motivo' = '[TESTE] nova operadora')
  AND NOT EXISTS (SELECT 1 FROM auditoria WHERE entidade_id = pg_temp.id('D')
                   AND (coalesce(antes::text, '') || coalesce(depois::text, '')) ~ '@|0000000d4b0d'),
  'cadastro na auditoria com ator e motivo, sem o e-mail nem o keycloak_sub');

-- ---------- definir_status_usuario_central ----------
SELECT pg_temp.espera_erro($$SELECT definir_status_usuario_central(pg_temp.u('C'), pg_temp.id('D'), 'suspenso', '[TESTE]')$$,
  'SC016', 'sem conceder_permissao não altera status');
SELECT pg_temp.espera_erro($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.u('A'), 'suspenso', '[TESTE]')$$,
  'SC017', 'ninguém altera o próprio status');
SELECT pg_temp.espera_erro($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.id('D'), 'excluido', '[TESTE]')$$,
  '22023', 'exclusão não é por esta função');
SELECT pg_temp.espera_erro($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.id('D'), 'pendente', '[TESTE]')$$,
  '22023', 'pendente não é por esta função');
SELECT pg_temp.espera_erro($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.u('T'), 'suspenso', '[TESTE]')$$,
  '22023', 'usuário fora da Central não é alterado por esta função');
SELECT pg_temp.espera_erro($$SELECT definir_status_usuario_central(pg_temp.u('A'), gen_random_uuid(), 'suspenso', '[TESTE]')$$,
  '22023', 'usuário inexistente');
SELECT pg_temp.espera_erro($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.id('D'), 'ativo', '[TESTE]')$$,
  '22023', 'status igual: nada a alterar');
SELECT pg_temp.aceita($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.id('D'), 'suspenso', '[TESTE] afastamento')$$,
  'A suspende D');
SELECT pg_temp.aceita($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.id('D'), 'bloqueado', '[TESTE] bloqueio')$$,
  'A bloqueia D');
SELECT pg_temp.aceita($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.id('D'), 'ativo', '[TESTE] retorno')$$,
  'A reativa D');
SELECT pg_temp.confere(
  (SELECT count(*) = 3 FROM auditoria WHERE acao = 'central_definir_status_usuario' AND entidade_id = pg_temp.id('D')
      AND ator_usuario_id = pg_temp.u('A'))
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_definir_status_usuario' AND entidade_id = pg_temp.id('D')
                 AND antes ->> 'status' = 'ativo' AND depois ->> 'status' = 'suspenso'),
  'cada mudança de status na auditoria, com antes e depois');
SELECT pg_temp.aceita($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.u('B'), 'suspenso', '[TESTE]')$$,
  'A suspende B (A continua titular)');
SELECT pg_temp.confere(NOT operador_tem_permissao(pg_temp.u('B'), 'conceder_permissao'),
  'B suspenso perde o efeito da permissão, sem apagar a concessão');
SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.u('B'), 'ativo', '[TESTE] retorno');

-- ---------- registrar_mfa_central (espelho; a Central não decide 2FA por ele) ----------
SELECT pg_temp.aceita($$SELECT registrar_mfa_central(pg_temp.id('D'), clock_timestamp() - interval '1 minute')$$,
  'D registra o próprio espelho do 2FA');
SELECT pg_temp.confere((SELECT mfa_ativado_em IS NOT NULL FROM usuario WHERE id = pg_temp.id('D')),
  'mfa_ativado_em preenchido');
SELECT pg_temp.espera_erro($$SELECT registrar_mfa_central(pg_temp.id('D'), clock_timestamp() + interval '1 hour')$$,
  '22023', 'mfa_ativado_em no futuro');
SELECT pg_temp.espera_erro($$SELECT registrar_mfa_central(pg_temp.u('T'), clock_timestamp())$$,
  'SC016', 'tomador não usa esta função');
SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.id('D'), 'suspenso', '[TESTE]');
SELECT pg_temp.espera_erro($$SELECT registrar_mfa_central(pg_temp.id('D'), NULL)$$,
  'SC016', 'usuário da Central suspenso não registra');
SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.id('D'), 'ativo', '[TESTE]');
SELECT pg_temp.aceita($$SELECT registrar_mfa_central(pg_temp.id('D'), NULL)$$, '2FA desativado: espelho limpo');
SELECT pg_temp.confere(
  (SELECT mfa_ativado_em IS NULL FROM usuario WHERE id = pg_temp.id('D'))
  AND (SELECT count(*) = 2 FROM auditoria WHERE acao = 'central_registrar_mfa' AND ator_usuario_id = pg_temp.id('D'))
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_registrar_mfa' AND ator_usuario_id = pg_temp.id('D')
                 AND (antes ->> 'mfa_ativo')::boolean AND NOT (depois ->> 'mfa_ativo')::boolean),
  'espelho limpo e as duas mudanças na auditoria (só verdadeiro ou falso, sem horário)');

-- ---------- Último acesso: a Central e o migrator contam ----------
SELECT registrar_acesso_central(pg_temp.u('A'));
SELECT pg_temp.confere(
  (SELECT ultimo_acesso_em IS NOT NULL FROM vw_operador_central WHERE usuario_id = pg_temp.u('A')),
  'acesso registrado pela função (papel migrator) conta no último acesso');

-- ---------- Privilégios do app ----------
SELECT pg_temp.confere(
  NOT has_table_privilege('safetycar_app', 'auditoria', 'SELECT')
  AND has_table_privilege('safetycar_app', 'auditoria', 'INSERT')
  AND NOT has_function_privilege('safetycar_app', 'cadastrar_usuario_central(uuid, uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('safetycar_app', 'definir_status_usuario_central(uuid, uuid, text, text)', 'EXECUTE')
  AND NOT has_function_privilege('safetycar_app', 'registrar_mfa_central(uuid, timestamptz)', 'EXECUTE'),
  'app: INSERT sem SELECT em auditoria; nenhuma das funções novas');

-- ---------- Falha da auditoria desfaz a operação ----------
CREATE FUNCTION public.teste_falhar_auditoria() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF current_setting('teste.falhar_auditoria', true) = 'sim' THEN
    RAISE EXCEPTION '[TESTE] auditoria indisponível' USING ERRCODE = 'TS001';
  END IF;
  RETURN NEW;
END $f$;
CREATE TRIGGER tg_teste_falhar_auditoria BEFORE INSERT ON auditoria
  FOR EACH ROW EXECUTE FUNCTION public.teste_falhar_auditoria();
SET LOCAL teste.falhar_auditoria = 'sim';
SELECT pg_temp.espera_erro($$SELECT cadastrar_usuario_central(pg_temp.u('A'), gen_random_uuid(), 'end-falha@exemplo.invalid', '[TESTE]')$$,
  'TS001', 'cadastro com a auditoria falhando é recusado');
SELECT pg_temp.espera_erro($$SELECT definir_status_usuario_central(pg_temp.u('A'), pg_temp.id('D'), 'suspenso', '[TESTE]')$$,
  'TS001', 'mudança de status com a auditoria falhando é recusada');
SET LOCAL teste.falhar_auditoria = 'nao';
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM usuario WHERE email = 'end-falha@exemplo.invalid')
  AND (SELECT status = 'ativo' FROM usuario WHERE id = pg_temp.id('D')),
  'nada ficou gravado');

-- ---------- Sem dado pessoal na auditoria ----------
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM auditoria
               WHERE acao IN ('central_cadastrar_usuario_central','central_definir_status_usuario','central_registrar_mfa')
                 AND (coalesce(antes::text, '') || coalesce(depois::text, '')) LIKE '%@%'),
  'nenhum e-mail na auditoria das funções novas');
