-- 0020 — Endurecimento: o app público não mexe em usuário da Central nem forja auditoria.
--
-- Por quê: o safetycar_app (API pública) tem SELECT, INSERT e UPDATE em usuario e SELECT e
-- INSERT em auditoria (0007). Com isso, um app comprometido conseguiria:
--   - trocar o keycloak_sub ou o e-mail de um operador da Central (tomada de identidade: a
--     Central identifica o operador pelo sub do JWT);
--   - suspender o último titular de conceder_permissao por fora da SC023, ou reativar um
--     operador suspenso (devolvendo as permissões dele);
--   - criar usuário com perfil central ou promover alguém a central;
--   - gravar eventos central_* falsos (inclusive o "último acesso") e ler toda a auditoria da
--     Central (quem tem cada permissão, quem aprovou o quê).
--
-- O que muda:
--   1) usuario: o app não cria usuário central, não promove ninguém a central e, num usuário
--      central, só muda ultimo_login_em (SC029). Isso vale pelo papel que conectou
--      (session_user), que o app não troca.
--   2) usuario, para qualquer escritor: o último titular efetivo de conceder_permissao não sai
--      de "ativo", não é excluído (excluido_em) e não muda de perfil (SC023).
--   3) Caminho legítimo pela Central (SECURITY DEFINER, só safetycar_central):
--      cadastrar_usuario_central e definir_status_usuario_central (com conceder_permissao, nunca
--      a si mesmo) e registrar_mfa_central (o próprio operador, espelho do 2FA do Keycloak).
--      O e-mail fica só em usuario, nunca na auditoria. Trocar o keycloak_sub de um usuário
--      central fica só com o migrator.
--   4) auditoria: o app não grava DIRETO ação com prefixo reservado (central_, migrator_,
--      parametrizacao_) (SC030). As linhas que os triggers gravam quando o app altera dados
--      (pg_trigger_depth() > 1) continuam. O app perde o SELECT em auditoria (mantém INSERT).
--   5) vw_operador_central conta só os central_acesso gravados pela Central ou pelo migrator.
--
-- mfa_ativado_em é só um ESPELHO informativo: a Central NÃO decide 2FA por essa coluna. A
-- exigência de 2FA é conferida pela API no token (OTP na sessão / acr do Keycloak).
--
-- Códigos de erro novos:
--   SC029 o app criando ou alterando usuário da Central (ou promovendo alguém a central)
--   SC030 ação de auditoria com prefixo reservado gravada direto pelo app
-- Reaproveitado: SC023 (último titular), agora também no status, na exclusão e no perfil.

-- ---------------------------------------------------------------------
-- usuario: proteção do usuário da Central
-- ---------------------------------------------------------------------

CREATE FUNCTION usuario_central_protegido() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.perfil = 'central' AND session_user = 'safetycar_app' THEN
      RAISE EXCEPTION 'o app não cria usuário da Central' USING ERRCODE = 'SC029';
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE pelo app: num usuário central, só ultimo_login_em (atualizado_em é do trigger).
  IF session_user = 'safetycar_app' AND (OLD.perfil = 'central' OR NEW.perfil = 'central') THEN
    IF NEW.perfil IS DISTINCT FROM OLD.perfil THEN
      RAISE EXCEPTION 'o app não muda o perfil para nem de central' USING ERRCODE = 'SC029';
    END IF;
    IF (to_jsonb(NEW) - 'ultimo_login_em' - 'atualizado_em')
       IS DISTINCT FROM (to_jsonb(OLD) - 'ultimo_login_em' - 'atualizado_em') THEN
      RAISE EXCEPTION 'num usuário da Central, o app só altera ultimo_login_em' USING ERRCODE = 'SC029';
    END IF;
  END IF;

  -- Qualquer escritor: o último titular efetivo de conceder_permissao não sai de ativo, não é
  -- excluído e não muda de perfil (a recuperação é revogar_permissao_manual + concessão inicial).
  IF OLD.perfil = 'central'
     AND ((OLD.status = 'ativo' AND NEW.status IS DISTINCT FROM 'ativo')
          OR (OLD.excluido_em IS NULL AND NEW.excluido_em IS NOT NULL)
          OR NEW.perfil IS DISTINCT FROM OLD.perfil) THEN
    PERFORM exige_outro_titular_conceder(OLD.id);
  END IF;
  RETURN NEW;
END $$;
-- Nome em ordem alfabética antes de tg_usuario_perfil_vinculado: a SC023 vem antes da SC001.
CREATE TRIGGER tg_usuario_central_protegido BEFORE INSERT OR UPDATE ON usuario
  FOR EACH ROW EXECUTE FUNCTION usuario_central_protegido();

-- ---------------------------------------------------------------------
-- auditoria: prefixos reservados
-- ---------------------------------------------------------------------

CREATE FUNCTION auditoria_acao_reservada() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  -- pg_trigger_depth() = 1: INSERT direto (este é o único trigger da pilha). Maior que 1: a
  -- linha vem de outro trigger (ex.: auditar_parametrizacao numa escrita legítima do app).
  IF session_user = 'safetycar_app' AND pg_trigger_depth() = 1
     AND (NEW.acao LIKE 'central\_%' OR NEW.acao LIKE 'migrator\_%' OR NEW.acao LIKE 'parametrizacao\_%') THEN
    RAISE EXCEPTION 'a ação "%" é reservada (Central, migrator ou trigger de parametrização)', NEW.acao
      USING ERRCODE = 'SC030';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_auditoria_acao_reservada BEFORE INSERT ON auditoria
  FOR EACH ROW EXECUTE FUNCTION auditoria_acao_reservada();

REVOKE SELECT ON auditoria FROM safetycar_app;

-- Último acesso: só o que a Central (ou o migrator) gravou.
CREATE OR REPLACE VIEW vw_operador_central AS
SELECT o.usuario_id, o.ativo, o.criado_em,
       (SELECT max(a.criado_em) FROM auditoria a
         WHERE a.entidade = 'operador_central' AND a.entidade_id = o.usuario_id
           AND a.acao = 'central_acesso'
           AND a.papel_bd IN ('safetycar_central', 'safetycar_migrator')) AS ultimo_acesso_em
  FROM operador_central o;

-- ---------------------------------------------------------------------
-- Funções da Central (SECURITY DEFINER; EXECUTE só para safetycar_central)
-- ---------------------------------------------------------------------

-- Cria o usuário da Central (perfil central, status ativo). Não o torna operador: para isso,
-- cadastrar_operador (0014). O e-mail fica só em usuario; a auditoria não o recebe.
CREATE FUNCTION cadastrar_usuario_central(p_ator uuid, p_keycloak_sub uuid, p_email text, p_motivo text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'conceder_permissao');
  IF p_keycloak_sub IS NULL THEN
    RAISE EXCEPTION 'keycloak_sub é obrigatório' USING ERRCODE = '22023';
  END IF;
  IF p_email IS NULL OR p_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RAISE EXCEPTION 'e-mail inválido' USING ERRCODE = '22023';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO usuario (keycloak_sub, email, perfil, status)
  VALUES (p_keycloak_sub, lower(btrim(p_email)), 'central', 'ativo')
  RETURNING id INTO v_id;
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, depois)
  VALUES (p_ator, 'central_cadastrar_usuario_central', 'usuario', v_id,
          jsonb_build_object('perfil', 'central', 'status', 'ativo', 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_id;
END $$;

-- Suspende, bloqueia ou reativa um usuário da Central. Nunca a si mesmo; nunca o último titular.
CREATE FUNCTION definir_status_usuario_central(p_ator uuid, p_usuario uuid, p_status text, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_atual text; v_perfil text; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'conceder_permissao');
  IF p_usuario = p_ator THEN
    RAISE EXCEPTION 'ninguém altera o próprio status' USING ERRCODE = 'SC017';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('ativo', 'suspenso', 'bloqueado') THEN
    RAISE EXCEPTION 'status inválido para esta função: % (use ativo, suspenso ou bloqueado)', p_status
      USING ERRCODE = '22023';
  END IF;
  -- Catálogo antes do usuário (mesma ordem das demais funções da 0016).
  PERFORM 1 FROM permissao_central WHERE codigo = 'conceder_permissao' FOR UPDATE;
  SELECT status, perfil INTO v_atual, v_perfil FROM usuario WHERE id = p_usuario FOR UPDATE;
  IF NOT FOUND OR v_perfil <> 'central' THEN
    RAISE EXCEPTION 'usuário % inexistente ou fora da Central', p_usuario USING ERRCODE = '22023';
  END IF;
  IF v_atual = p_status THEN
    RAISE EXCEPTION 'usuário % já está %; nada a alterar', p_usuario, p_status USING ERRCODE = '22023';
  END IF;
  IF v_atual NOT IN ('ativo', 'suspenso', 'bloqueado') THEN
    RAISE EXCEPTION 'usuário % está %; esta função não o altera', p_usuario, v_atual USING ERRCODE = '22023';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  UPDATE usuario SET status = p_status WHERE id = p_usuario;   -- o trigger aplica a SC023
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_definir_status_usuario', 'usuario', p_usuario,
          jsonb_build_object('status', v_atual),
          jsonb_build_object('status', p_status, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

-- Espelho do 2FA do próprio usuário da Central (informado pelo backend da Central a partir do
-- Keycloak). Informativo: a Central não decide 2FA por esta coluna.
CREATE FUNCTION registrar_mfa_central(p_ator uuid, p_mfa_ativado_em timestamptz) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_antes timestamptz;
BEGIN
  SELECT mfa_ativado_em INTO v_antes FROM usuario
   WHERE id = p_ator AND perfil = 'central' AND status = 'ativo' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ator % não é usuário ativo da Central', p_ator USING ERRCODE = 'SC016';
  END IF;
  IF p_mfa_ativado_em > clock_timestamp() THEN
    RAISE EXCEPTION 'mfa_ativado_em no futuro' USING ERRCODE = '22023';
  END IF;
  UPDATE usuario SET mfa_ativado_em = p_mfa_ativado_em WHERE id = p_ator;
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_registrar_mfa', 'usuario', p_ator,
          jsonb_build_object('mfa_ativo', v_antes IS NOT NULL),
          jsonb_build_object('mfa_ativo', p_mfa_ativado_em IS NOT NULL));
END $$;

-- ---------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION
  cadastrar_usuario_central(uuid, uuid, text, text),
  definir_status_usuario_central(uuid, uuid, text, text),
  registrar_mfa_central(uuid, timestamptz)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  cadastrar_usuario_central(uuid, uuid, text, text),
  definir_status_usuario_central(uuid, uuid, text, text),
  registrar_mfa_central(uuid, timestamptz)
TO safetycar_central;

-- Conferência: o app não lê mais a auditoria e continua inserindo.
DO $$
BEGIN
  IF has_table_privilege('safetycar_app', 'auditoria', 'SELECT')
     OR NOT has_table_privilege('safetycar_app', 'auditoria', 'INSERT') THEN
    RAISE EXCEPTION '0020: safetycar_app deveria ter INSERT e não ter SELECT em auditoria';
  END IF;
END $$;
