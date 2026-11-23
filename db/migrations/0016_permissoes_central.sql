-- 0016 — Permissões da Central: catálogo ampliado, último titular e eventos de auditoria.
--
-- Por quê: o desenho aprovado em 23/11/2026 (docs/CENTRAL_PERMISSOES_TARIFAS_PARAMETROS.md)
-- pede permissões novas (solicitar reajuste, analisar cadastros, administrar parâmetros), a marca
-- de permissão sensível (a API exigirá OTP na sessão para elas; o banco NÃO valida 2FA) e a regra
-- de que a Central nunca fica sem quem administre permissões.
--
-- Conciliação com a 0014 (o que existe prevalece):
--   - "administrar_permissoes" do desenho = conceder_permissao (código mantido; muda só o rótulo).
--     Renomear quebraria a PK, os CHECKs da 0014, a SC018 e o primeiro_administrador.sh.
--   - "aprovar_tarifa" = aprovar_reajuste_taxa (mantido).
--   - "solicitar_tarifa" = solicitar_reajuste_taxa (novo). Só passa a ser EXIGIDA na 0019; até lá
--     as funções da 0015 continuam aceitando qualquer operador ativo como solicitante.
--   - analisar_cadastros (novo) AINDA NÃO é imposta pelo banco: a aprovação de parceiro e de
--     documento é feita por DML do app. Vira função numa migração futura.
--   - conceder_permissao_inicial e revogar_permissao_manual NÃO mudam.
--
-- Último titular (SC023): revogar (com origem 'operador') ou desativar o último operador com
-- conceder_permissao EFETIVA é recusado. Vale para qualquer escritor (triggers). A revogação
-- manual do migrator continua liberada: é o caminho de recuperação da 0014. Um titular que já
-- não é efetivo (operador inativo, usuário suspenso) não conta como "outro titular", e removê-lo
-- não é barrado (não reduz quem administra de fato).
-- Locks: as funções travam a linha conceder_permissao do catálogo (FOR UPDATE) ANTES de tocar no
-- operador ou na concessão, na mesma ordem do trigger de concessão da 0014 (catálogo e depois
-- operador). Duas remoções simultâneas dos dois últimos titulares ficam em série: a segunda
-- enxerga a primeira e termina em SC023. (Um UPDATE ou INSERT direto, fora das funções, trava na
-- ordem inversa e, em corrida, pode dar 40P01; nunca deixa a Central sem titular.)
--
-- Auditoria: além da linha automática (parametrizacao_insert), as funções gravam eventos com
-- nome próprio, na mesma transação: central_permissao_concedida, central_permissao_revogada e
-- central_acesso. Só identificadores internos e motivo (o motivo é texto livre: NÃO incluir dado
-- pessoal nele). Se a auditoria falhar, a operação inteira é desfeita.
--
-- Código de erro novo:
--   SC023 revogar ou desativar o último titular efetivo de conceder_permissao

-- ---------------------------------------------------------------------
-- Catálogo: coluna "sensivel" e permissões novas
-- ---------------------------------------------------------------------

-- Informativa para a API (exigir OTP na sessão); o banco não valida 2FA.
ALTER TABLE permissao_central ADD COLUMN sensivel boolean NOT NULL DEFAULT false;

UPDATE permissao_central
   SET sensivel = true,
       nome = 'Administrar permissões'
 WHERE codigo = 'conceder_permissao';
UPDATE permissao_central SET sensivel = true WHERE codigo = 'aprovar_reajuste_taxa';

ALTER TABLE permissao_central
  ADD CONSTRAINT ck_permissao_conceder_sensivel CHECK (codigo <> 'conceder_permissao' OR sensivel);

INSERT INTO permissao_central (codigo, nome, descricao, sensivel, permite_autoaprovacao) VALUES
  ('solicitar_reajuste_taxa', 'Solicitar reajuste de taxas',
   'Solicita e simula reajustes e definições de taxa. Exigida a partir da 0019.', false, false),
  ('analisar_cadastros', 'Analisar cadastros',
   'Analisa cadastros e documentos de parceiros. Ainda não imposta pelo banco (a aprovação é feita pelo app).', false, false),
  ('administrar_parametros', 'Administrar parâmetros',
   'Altera parâmetros comuns e decide pedidos de alteração de parâmetros sensíveis (0018).', true, false);

-- ---------------------------------------------------------------------
-- Último titular de conceder_permissao (SC023)
-- ---------------------------------------------------------------------

-- Há outro operador, além de p_operador, com conceder_permissao efetiva agora?
CREATE FUNCTION existe_outro_titular_conceder(p_operador uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM permissao_concessao c
     WHERE c.permissao_codigo = 'conceder_permissao'
       AND c.operador_id <> p_operador
       AND NOT EXISTS (SELECT 1 FROM permissao_revogacao r WHERE r.concessao_id = c.id)
       AND operador_tem_permissao(c.operador_id, 'conceder_permissao'))
$$;

-- Recusa se p_operador é titular efetivo e não há outro. Trava antes o catálogo (FOR UPDATE).
CREATE FUNCTION exige_outro_titular_conceder(p_operador uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM permissao_central WHERE codigo = 'conceder_permissao' FOR UPDATE;
  IF operador_tem_permissao(p_operador, 'conceder_permissao')
     AND NOT existe_outro_titular_conceder(p_operador) THEN
    RAISE EXCEPTION 'operador % é o último titular efetivo de conceder_permissao; conceda a outro operador antes',
      p_operador USING ERRCODE = 'SC023';
  END IF;
END $$;

-- Revogação (redefine a 0014): acrescenta a regra do último titular, só para origem 'operador'.
CREATE OR REPLACE FUNCTION permissao_revogacao_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_titular uuid; v_permissao text;
BEGIN
  NEW.revogada_em := clock_timestamp();
  NEW.papel_bd := session_user;
  SELECT operador_id, permissao_codigo INTO v_titular, v_permissao
    FROM permissao_concessao WHERE id = NEW.concessao_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM permissao_revogacao WHERE concessao_id = NEW.concessao_id) THEN
    RAISE EXCEPTION 'concessão % já foi revogada', NEW.concessao_id USING ERRCODE = 'SC018';
  END IF;
  -- Revogar a própria permissão é permitido (só reduz poder); a de outro exige conceder_permissao.
  IF NEW.origem = 'operador' AND NEW.revogada_por IS DISTINCT FROM v_titular
     AND NOT operador_tem_permissao(NEW.revogada_por, 'conceder_permissao') THEN
    RAISE EXCEPTION 'operador % não tem a permissão conceder_permissao vigente', NEW.revogada_por
      USING ERRCODE = 'SC016';
  END IF;
  -- A revogação manual (recuperação, pelo migrator) não passa por esta regra.
  IF NEW.origem = 'operador' AND v_permissao = 'conceder_permissao' THEN
    PERFORM exige_outro_titular_conceder(v_titular);
  END IF;
  RETURN NEW;
END $$;

-- Desativação de operador (qualquer escritor).
CREATE FUNCTION operador_ultimo_titular() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.ativo AND NOT NEW.ativo THEN
    PERFORM exige_outro_titular_conceder(OLD.usuario_id);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_operador_central_ultimo_titular BEFORE UPDATE OF ativo ON operador_central
  FOR EACH ROW EXECUTE FUNCTION operador_ultimo_titular();

-- ---------------------------------------------------------------------
-- Funções da Central redefinidas (mesmas assinaturas: os GRANTs da 0014 continuam)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION definir_operador_ativo(p_ator uuid, p_operador uuid, p_ativo boolean, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'conceder_permissao');
  IF p_operador = p_ator THEN
    RAISE EXCEPTION 'ninguém altera o próprio cadastro de operador' USING ERRCODE = 'SC017';
  END IF;
  IF p_ativo IS NULL THEN
    RAISE EXCEPTION 'ativo é obrigatório' USING ERRCODE = '22023';
  END IF;
  -- Catálogo antes do operador (mesma ordem do trigger de concessão): o trigger do último
  -- titular roda depois com o lock já obtido.
  IF NOT p_ativo THEN
    PERFORM 1 FROM permissao_central WHERE codigo = 'conceder_permissao' FOR UPDATE;
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  UPDATE operador_central SET ativo = p_ativo WHERE usuario_id = p_operador;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operador % inexistente', p_operador USING ERRCODE = '22023';
  END IF;
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, depois)
  VALUES (p_ator, CASE WHEN p_ativo THEN 'central_ativar_operador' ELSE 'central_desativar_operador' END,
          'operador_central', p_operador, jsonb_build_object('motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

CREATE OR REPLACE FUNCTION conceder_permissao(p_ator uuid, p_operador uuid, p_permissao text, p_motivo text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  IF p_ator IS NULL THEN
    RAISE EXCEPTION 'ator é obrigatório' USING ERRCODE = 'SC016';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  -- As regras (a si mesmo, permissão do ator, já vigente) ficam no trigger.
  INSERT INTO permissao_concessao (operador_id, permissao_codigo, concedida_por, motivo, origem)
  VALUES (p_operador, p_permissao, p_ator, p_motivo, 'operador')
  RETURNING id INTO v_id;
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, depois)
  VALUES (p_ator, 'central_permissao_concedida', 'permissao_concessao', v_id,
          jsonb_build_object('operador_id', p_operador, 'permissao_codigo', p_permissao,
                             'vigente', true, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION revogar_permissao(p_ator uuid, p_operador uuid, p_permissao text, p_motivo text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_concessao uuid; v_id uuid; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  IF p_ator IS NULL OR NOT EXISTS (SELECT 1 FROM operador_central WHERE usuario_id = p_ator AND ativo) THEN
    RAISE EXCEPTION 'ator % não é operador ativo', p_ator USING ERRCODE = 'SC016';
  END IF;
  -- Catálogo antes da concessão: duas revogações dos dois últimos titulares ficam em série.
  IF p_permissao = 'conceder_permissao' THEN
    PERFORM 1 FROM permissao_central WHERE codigo = 'conceder_permissao' FOR UPDATE;
  END IF;
  SELECT c.id INTO v_concessao
    FROM permissao_concessao c
   WHERE c.operador_id = p_operador AND c.permissao_codigo = p_permissao
     AND NOT EXISTS (SELECT 1 FROM permissao_revogacao r WHERE r.concessao_id = c.id)
   FOR UPDATE;
  IF v_concessao IS NULL THEN
    RAISE EXCEPTION 'operador % não tem a permissão "%" vigente', p_operador, p_permissao USING ERRCODE = 'SC018';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO permissao_revogacao (concessao_id, revogada_por, motivo, origem)
  VALUES (v_concessao, p_ator, p_motivo, 'operador')
  RETURNING id INTO v_id;
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_permissao_revogada', 'permissao_revogacao', v_id,
          jsonb_build_object('concessao_id', v_concessao, 'vigente', true),
          jsonb_build_object('concessao_id', v_concessao, 'operador_id', p_operador,
                             'permissao_codigo', p_permissao, 'vigente', false, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Acesso à Central (para "último acesso"): a API chama uma vez por início de sessão.
-- ---------------------------------------------------------------------

CREATE FUNCTION registrar_acesso_central(p_ator uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM exige_operador_ativo(p_ator);   -- 0015: usuário ativo, perfil central, operador ativo (SC016)
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id)
  VALUES (p_ator, 'central_acesso', 'operador_central', p_ator);
END $$;

-- ---------------------------------------------------------------------
-- Visões de leitura da Central
-- ---------------------------------------------------------------------

-- Histórico de concessões com a revogação (se houver), vigência e efetividade.
CREATE VIEW vw_operador_permissao WITH (security_invoker = true) AS
SELECT c.id AS concessao_id, c.operador_id, o.ativo AS operador_ativo,
       c.permissao_codigo, p.sensivel,
       c.concedida_por, c.concedida_em, c.origem AS origem_concessao, c.motivo AS motivo_concessao,
       r.revogada_por, r.revogada_em, r.origem AS origem_revogacao, r.motivo AS motivo_revogacao,
       (r.id IS NULL) AS vigente,
       (r.id IS NULL AND operador_tem_permissao(c.operador_id, c.permissao_codigo)) AS efetiva
  FROM permissao_concessao c
  JOIN operador_central o   ON o.usuario_id = c.operador_id
  JOIN permissao_central p  ON p.codigo = c.permissao_codigo
  LEFT JOIN permissao_revogacao r ON r.concessao_id = c.id;

-- Operadores com o último acesso. SEM security_invoker, de propósito: a Central não lê a
-- auditoria; a visão expõe só o instante do último central_acesso de cada operador (sem
-- e-mail, nome nem conteúdo da auditoria).
CREATE VIEW vw_operador_central AS
SELECT o.usuario_id, o.ativo, o.criado_em,
       (SELECT max(a.criado_em) FROM auditoria a
         WHERE a.entidade = 'operador_central' AND a.entidade_id = o.usuario_id
           AND a.acao = 'central_acesso') AS ultimo_acesso_em
  FROM operador_central o;

-- ---------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION
  existe_outro_titular_conceder(uuid),
  exige_outro_titular_conceder(uuid),
  registrar_acesso_central(uuid)
FROM PUBLIC;

GRANT SELECT ON vw_operador_permissao, vw_operador_central TO safetycar_central;
GRANT EXECUTE ON FUNCTION registrar_acesso_central(uuid) TO safetycar_central;

-- App: nada novo. Continua lendo só o catálogo permissao_central (agora com "sensivel").
