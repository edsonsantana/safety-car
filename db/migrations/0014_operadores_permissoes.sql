-- 0014 — Operadores e permissões da Central.
--
-- Por quê: alterações sensíveis (a primeira: aprovar reajuste de taxas, na 0015) precisam de
-- aprovação por quem tem permissão, e não só de migração. Este é o alicerce: quem é operador
-- da Central, que permissões existem e quem as tem agora, com histórico somente de inserção.
--
-- Autorização (decidida: alternativa B do plano):
--   - As ações sensíveis são funções SECURITY DEFINER executáveis SÓ pelo papel
--     safetycar_central (backend da Central, pool de conexão separado, senha só no .env),
--     nunca pelo safetycar_app nem por PUBLIC.
--   - O ator vem por parâmetro e é verificado no banco (operador ativo, usuário ativo de perfil
--     central, permissão vigente, nunca a si mesmo). RISCO RESIDUAL: quem tiver a credencial do
--     safetycar_central pode declarar outro ator; por isso a API da Central tira o ator do JWT
--     do Keycloak, nunca do corpo da requisição. Um comprometimento do app público (tomador e
--     parceiro) não consegue conceder nem aprovar nada.
--   - auditoria.papel_bd passa a ser session_user (o papel que conectou): dentro de SECURITY
--     DEFINER, current_user seria o dono da função.
--
-- Quem concede: quem tem a permissão conceder_permissao vigente (a outro operador, nunca a si
-- mesmo). A primeira concessão é feita À MÃO pelo safetycar_migrator com
-- conceder_permissao_inicial(usuario, motivo); nunca por carga automática.
-- Regra estrita: a concessão inicial é recusada enquanto existir QUALQUER concessão de
-- conceder_permissao sem revogação, mesmo que o detentor esteja inativo ou suspenso.
-- Recuperação (detentor indisponível ou comprometido), à mão pelo migrator:
--   1) SELECT revogar_permissao_manual('<detentor>', 'conceder_permissao', '<motivo>');
--   2) SELECT conceder_permissao_inicial('<novo detentor>', '<motivo>');
--
-- Códigos de erro novos:
--   SC016 ator sem a permissão exigida, ou operador inativo
--   SC017 conceder permissão (ou alterar o próprio cadastro de operador) a si mesmo
--   SC018 concessão já vigente, revogação sem concessão vigente, ou concessão inicial com
--         detentor de conceder_permissao já existente

-- ---------------------------------------------------------------------
-- Papel da Central
-- ---------------------------------------------------------------------

DO $$
DECLARE r record;
BEGIN
  SELECT * INTO r FROM pg_roles WHERE rolname = 'safetycar_central';
  IF NOT FOUND THEN
    RAISE EXCEPTION '0014: o papel safetycar_central não existe; rode bash db/scripts/criar_papeis.sh';
  END IF;
  IF r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolbypassrls OR r.rolinherit THEN
    RAISE EXCEPTION '0014: safetycar_central deve ser NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOINHERIT';
  END IF;
  EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO safetycar_central', current_database());
END $$;
GRANT USAGE ON SCHEMA public TO safetycar_central;

-- ---------------------------------------------------------------------
-- auditoria.papel_bd = papel da sessão
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION auditoria_papel_bd() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.papel_bd := session_user;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- Catálogo de permissões (parametrização: só por migração)
-- ---------------------------------------------------------------------

CREATE TABLE permissao_central (
  codigo                text PRIMARY KEY CHECK (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome                  text NOT NULL,
  descricao             text,
  ativo                 boolean NOT NULL DEFAULT true,
  -- Exceção configurável à regra "quem solicita não aprova o próprio pedido" (usada na 0015).
  permite_autoaprovacao boolean NOT NULL DEFAULT false,
  criado_em             timestamptz NOT NULL DEFAULT now(),
  atualizado_em         timestamptz NOT NULL DEFAULT now(),
  -- Conceder a si mesmo é sempre recusado: não existe autoaprovação para conceder permissão.
  CONSTRAINT ck_permissao_conceder_sem_auto CHECK (codigo <> 'conceder_permissao' OR NOT permite_autoaprovacao)
);
CREATE TRIGGER tg_permissao_central_atualizado_em BEFORE UPDATE ON permissao_central
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_permissao_central_auditoria AFTER INSERT OR UPDATE OR DELETE ON permissao_central
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_permissao_central_sem_truncate BEFORE TRUNCATE ON permissao_central
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

-- Extensível por migração (ex.: aprovar_bloqueio, aprovar_nivel_manual).
INSERT INTO permissao_central (codigo, nome, descricao, permite_autoaprovacao) VALUES
  ('conceder_permissao',    'Conceder e revogar permissões',
   'Cadastra, ativa e desativa operadores; concede e revoga permissões a outros operadores.', false),
  ('aprovar_reajuste_taxa', 'Aprovar reajuste de taxas',
   'Aprova ou rejeita lotes de reajuste de regra_taxa (0015).', false);

-- ---------------------------------------------------------------------
-- Operador da Central
-- ---------------------------------------------------------------------

CREATE TABLE operador_central (
  usuario_id    uuid PRIMARY KEY REFERENCES usuario(id),
  ativo         boolean NOT NULL DEFAULT true,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER tg_operador_central_perfil BEFORE INSERT OR UPDATE OF usuario_id ON operador_central
  FOR EACH ROW EXECUTE FUNCTION exige_perfil('central', 'usuario_id');
CREATE TRIGGER tg_operador_central_atualizado_em BEFORE UPDATE ON operador_central
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_operador_central_auditoria AFTER INSERT OR UPDATE OR DELETE ON operador_central
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_operador_central_sem_truncate BEFORE TRUNCATE ON operador_central
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

CREATE FUNCTION operador_sem_exclusao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'operador da Central não é excluído; desative-o (ativo = false)' USING ERRCODE = 'SC010';
END $$;
CREATE TRIGGER tg_operador_central_sem_exclusao BEFORE DELETE ON operador_central
  FOR EACH ROW EXECUTE FUNCTION operador_sem_exclusao();

-- Usuário que é operador da Central também não troca de perfil (redefine a regra da 0004).
CREATE OR REPLACE FUNCTION usuario_perfil_vinculado() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM tomador WHERE usuario_id = NEW.id)
     OR EXISTS (SELECT 1 FROM parceiro_membro WHERE usuario_id = NEW.id)
     OR EXISTS (SELECT 1 FROM operador_central WHERE usuario_id = NEW.id) THEN
    RAISE EXCEPTION 'usuário % já tem vínculo como "%"; o perfil não pode mudar para "%"',
      NEW.id, OLD.perfil, NEW.perfil USING ERRCODE = 'SC001';
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- Concessão e revogação (somente inserção). Vigente = concessão sem revogação.
-- ---------------------------------------------------------------------

CREATE TABLE permissao_concessao (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operador_id      uuid NOT NULL REFERENCES operador_central(usuario_id),   -- quem recebeu
  permissao_codigo text NOT NULL REFERENCES permissao_central(codigo),
  concedida_por    uuid REFERENCES operador_central(usuario_id),            -- nulo só na inicial
  concedida_em     timestamptz NOT NULL DEFAULT clock_timestamp(),          -- hora do servidor
  motivo           text NOT NULL CHECK (btrim(motivo) <> ''),
  origem           text NOT NULL CHECK (origem IN ('operador','inicial')),
  papel_bd         text NOT NULL DEFAULT session_user,
  CONSTRAINT ck_concessao_origem CHECK ((origem = 'inicial') = (concedida_por IS NULL)),
  CONSTRAINT ck_concessao_inicial_so_conceder CHECK (origem <> 'inicial' OR permissao_codigo = 'conceder_permissao')
);
-- Consulta prevista: "permissões do operador X" e "quem tem a permissão P"
CREATE INDEX ix_concessao_operador  ON permissao_concessao (operador_id, permissao_codigo);
CREATE INDEX ix_concessao_permissao ON permissao_concessao (permissao_codigo);

CREATE TABLE permissao_revogacao (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  concessao_id uuid NOT NULL UNIQUE REFERENCES permissao_concessao(id),
  revogada_por uuid REFERENCES operador_central(usuario_id),                -- nulo só na manual
  revogada_em  timestamptz NOT NULL DEFAULT clock_timestamp(),
  motivo       text NOT NULL CHECK (btrim(motivo) <> ''),
  origem       text NOT NULL CHECK (origem IN ('operador','manual')),
  papel_bd     text NOT NULL DEFAULT session_user,
  CONSTRAINT ck_revogacao_origem CHECK ((origem = 'manual') = (revogada_por IS NULL))
);

-- Este operador tem esta permissão agora? (usada pelas migrações seguintes)
-- Exige: operador ativo, usuário ativo de perfil central, permissão ativa no catálogo e
-- concessão sem revogação. SECURITY DEFINER só para ler sem expor as tabelas; não escreve.
CREATE FUNCTION operador_tem_permissao(p_usuario uuid, p_permissao text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_permissao IS NULL OR NOT EXISTS (SELECT 1 FROM permissao_central WHERE codigo = p_permissao) THEN
    RAISE EXCEPTION 'permissão inexistente: %', p_permissao USING ERRCODE = '22023';
  END IF;
  RETURN EXISTS (
    SELECT 1
      FROM operador_central o
      JOIN usuario u           ON u.id = o.usuario_id AND u.status = 'ativo' AND u.perfil = 'central'
      JOIN permissao_central p ON p.codigo = p_permissao AND p.ativo
      JOIN permissao_concessao c ON c.operador_id = o.usuario_id AND c.permissao_codigo = p.codigo
     WHERE o.usuario_id = p_usuario
       AND o.ativo
       AND NOT EXISTS (SELECT 1 FROM permissao_revogacao r WHERE r.concessao_id = c.id));
END $$;

-- Regras da concessão (valem para qualquer escritor, inclusive o migrator).
CREATE FUNCTION permissao_concessao_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_ativo boolean;
BEGIN
  NEW.concedida_em := clock_timestamp();
  NEW.papel_bd := session_user;

  -- O trigger BEFORE roda antes dos CHECKs: a regra "inicial só de conceder_permissao"
  -- (ck_concessao_inicial_so_conceder) é conferida aqui primeiro, antes de qualquer lock.
  IF NEW.origem = 'inicial' AND NEW.permissao_codigo IS DISTINCT FROM 'conceder_permissao' THEN
    RAISE EXCEPTION 'concessão inicial só serve para conceder_permissao (recebido: %)', NEW.permissao_codigo
      USING ERRCODE = '23514';
  END IF;

  -- Um único lock por linha do catálogo, já no modo final: FOR UPDATE na concessão inicial
  -- (serializa as iniciais; a segunda espera e termina em SC018) e FOR SHARE nas demais.
  -- Nunca FOR SHARE seguido de FOR UPDATE na mesma linha (duas iniciais simultâneas dariam 40P01).
  IF NEW.origem = 'inicial' THEN
    SELECT ativo INTO v_ativo FROM permissao_central WHERE codigo = NEW.permissao_codigo FOR UPDATE;
  ELSE
    SELECT ativo INTO v_ativo FROM permissao_central WHERE codigo = NEW.permissao_codigo FOR SHARE;
  END IF;
  IF v_ativo IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'permissão "%" inexistente ou inativa', NEW.permissao_codigo USING ERRCODE = '22023';
  END IF;

  -- Serializa as concessões do mesmo operador.
  SELECT ativo INTO v_ativo FROM operador_central WHERE usuario_id = NEW.operador_id FOR UPDATE;
  IF v_ativo IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'operador % inexistente ou inativo', NEW.operador_id USING ERRCODE = 'SC016';
  END IF;

  IF NEW.origem = 'inicial' THEN
    -- (Lock FOR UPDATE já obtido acima; o CHECK garante que a inicial é de conceder_permissao.)
    IF EXISTS (SELECT 1 FROM permissao_concessao c
                WHERE c.permissao_codigo = 'conceder_permissao'
                  AND NOT EXISTS (SELECT 1 FROM permissao_revogacao r WHERE r.concessao_id = c.id)) THEN
      RAISE EXCEPTION 'já existe concessão vigente de conceder_permissao; a concessão inicial não se aplica'
        USING ERRCODE = 'SC018';
    END IF;
  ELSE
    IF NEW.concedida_por = NEW.operador_id THEN
      RAISE EXCEPTION 'ninguém concede permissão a si mesmo' USING ERRCODE = 'SC017';
    END IF;
    IF NOT operador_tem_permissao(NEW.concedida_por, 'conceder_permissao') THEN
      RAISE EXCEPTION 'operador % não tem a permissão conceder_permissao vigente', NEW.concedida_por
        USING ERRCODE = 'SC016';
    END IF;
  END IF;

  IF EXISTS (SELECT 1 FROM permissao_concessao c
              WHERE c.operador_id = NEW.operador_id AND c.permissao_codigo = NEW.permissao_codigo
                AND NOT EXISTS (SELECT 1 FROM permissao_revogacao r WHERE r.concessao_id = c.id)) THEN
    RAISE EXCEPTION 'operador % já tem a permissão "%" vigente', NEW.operador_id, NEW.permissao_codigo
      USING ERRCODE = 'SC018';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_permissao_concessao_validar BEFORE INSERT ON permissao_concessao
  FOR EACH ROW EXECUTE FUNCTION permissao_concessao_validar();

CREATE FUNCTION permissao_revogacao_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_titular uuid;
BEGIN
  NEW.revogada_em := clock_timestamp();
  NEW.papel_bd := session_user;
  SELECT operador_id INTO v_titular FROM permissao_concessao WHERE id = NEW.concessao_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM permissao_revogacao WHERE concessao_id = NEW.concessao_id) THEN
    RAISE EXCEPTION 'concessão % já foi revogada', NEW.concessao_id USING ERRCODE = 'SC018';
  END IF;
  -- Revogar a própria permissão é permitido (só reduz poder); a de outro exige conceder_permissao.
  IF NEW.origem = 'operador' AND NEW.revogada_por IS DISTINCT FROM v_titular
     AND NOT operador_tem_permissao(NEW.revogada_por, 'conceder_permissao') THEN
    RAISE EXCEPTION 'operador % não tem a permissão conceder_permissao vigente', NEW.revogada_por
      USING ERRCODE = 'SC016';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_permissao_revogacao_validar BEFORE INSERT ON permissao_revogacao
  FOR EACH ROW EXECUTE FUNCTION permissao_revogacao_validar();

CREATE TRIGGER tg_permissao_concessao_sem_alteracao BEFORE UPDATE OR DELETE ON permissao_concessao
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_permissao_concessao_sem_truncate BEFORE TRUNCATE ON permissao_concessao
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_permissao_concessao_auditoria AFTER INSERT ON permissao_concessao
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_permissao_revogacao_sem_alteracao BEFORE UPDATE OR DELETE ON permissao_revogacao
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_permissao_revogacao_sem_truncate BEFORE TRUNCATE ON permissao_revogacao
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_permissao_revogacao_auditoria AFTER INSERT ON permissao_revogacao
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();

-- Concessões sem revogação; "efetiva" considera também operador e usuário ativos.
CREATE VIEW vw_permissao_vigente WITH (security_invoker = true) AS
SELECT c.id AS concessao_id, c.operador_id, c.permissao_codigo, c.concedida_por, c.concedida_em,
       c.origem, c.motivo,
       operador_tem_permissao(c.operador_id, c.permissao_codigo) AS efetiva
  FROM permissao_concessao c
 WHERE NOT EXISTS (SELECT 1 FROM permissao_revogacao r WHERE r.concessao_id = c.id);

-- ---------------------------------------------------------------------
-- Funções de ação (SECURITY DEFINER; EXECUTE só para safetycar_central)
-- O ator é verificado aqui e registrado na auditoria (safetycar.ator_usuario_id local).
-- ---------------------------------------------------------------------

-- Utilitário interno: motivo obrigatório.
CREATE FUNCTION exige_motivo(p_motivo text) RETURNS void
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'motivo é obrigatório' USING ERRCODE = '22023';
  END IF;
END $$;

-- Utilitário interno: o ator precisa ter a permissão agora.
CREATE FUNCTION exige_permissao(p_ator uuid, p_permissao text) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_ator IS NULL OR NOT operador_tem_permissao(p_ator, p_permissao) THEN
    RAISE EXCEPTION 'ator % não tem a permissão "%" vigente (ou não é operador ativo)', p_ator, p_permissao
      USING ERRCODE = 'SC016';
  END IF;
END $$;

-- Em todas as funções de ação: o ator é gravado com set_config(..., is_local = true)
-- (equivale a SET LOCAL) e, no fim, o valor ANTERIOR é restaurado, para que uma chamada
-- aninhada não apague o ator de quem a chamou.

CREATE FUNCTION cadastrar_operador(p_ator uuid, p_usuario uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'conceder_permissao');
  IF p_usuario = p_ator THEN
    RAISE EXCEPTION 'ninguém altera o próprio cadastro de operador' USING ERRCODE = 'SC017';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO operador_central (usuario_id) VALUES (p_usuario);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, depois)
  VALUES (p_ator, 'central_cadastrar_operador', 'operador_central', p_usuario,
          jsonb_build_object('motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

CREATE FUNCTION definir_operador_ativo(p_ator uuid, p_operador uuid, p_ativo boolean, p_motivo text) RETURNS void
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

CREATE FUNCTION conceder_permissao(p_ator uuid, p_operador uuid, p_permissao text, p_motivo text) RETURNS uuid
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
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_id;
END $$;

CREATE FUNCTION revogar_permissao(p_ator uuid, p_operador uuid, p_permissao text, p_motivo text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_concessao uuid; v_id uuid; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  IF p_ator IS NULL OR NOT EXISTS (SELECT 1 FROM operador_central WHERE usuario_id = p_ator AND ativo) THEN
    RAISE EXCEPTION 'ator % não é operador ativo', p_ator USING ERRCODE = 'SC016';
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
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Ações manuais do migrator (sem GRANT: só o dono executa). Chamadas À MÃO, via psql.
-- ---------------------------------------------------------------------

-- Primeira concessão de conceder_permissao (ou recuperação, se ninguém mais a tiver).
-- Cadastra o operador se ainda não for. Fica na auditoria com papel_bd = safetycar_migrator.
CREATE FUNCTION conceder_permissao_inicial(p_usuario uuid, p_motivo text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM exige_motivo(p_motivo);
  INSERT INTO operador_central (usuario_id) VALUES (p_usuario) ON CONFLICT (usuario_id) DO NOTHING;
  INSERT INTO permissao_concessao (operador_id, permissao_codigo, motivo, origem)
  VALUES (p_usuario, 'conceder_permissao', p_motivo, 'inicial')
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- Revogação de emergência (ex.: único detentor comprometido).
CREATE FUNCTION revogar_permissao_manual(p_operador uuid, p_permissao text, p_motivo text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_concessao uuid; v_id uuid;
BEGIN
  PERFORM exige_motivo(p_motivo);
  SELECT c.id INTO v_concessao
    FROM permissao_concessao c
   WHERE c.operador_id = p_operador AND c.permissao_codigo = p_permissao
     AND NOT EXISTS (SELECT 1 FROM permissao_revogacao r WHERE r.concessao_id = c.id)
   FOR UPDATE;
  IF v_concessao IS NULL THEN
    RAISE EXCEPTION 'operador % não tem a permissão "%" vigente', p_operador, p_permissao USING ERRCODE = 'SC018';
  END IF;
  INSERT INTO permissao_revogacao (concessao_id, motivo, origem)
  VALUES (v_concessao, p_motivo, 'manual')
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------

-- Funções novas não ficam abertas a PUBLIC (padrão do PostgreSQL).
REVOKE ALL ON FUNCTION
  operador_tem_permissao(uuid, text),
  exige_motivo(text),
  exige_permissao(uuid, text),
  cadastrar_operador(uuid, uuid, text),
  definir_operador_ativo(uuid, uuid, boolean, text),
  conceder_permissao(uuid, uuid, text, text),
  revogar_permissao(uuid, uuid, text, text),
  conceder_permissao_inicial(uuid, text),
  revogar_permissao_manual(uuid, text, text)
FROM PUBLIC;

-- Central: lê o cadastro e o histórico; age só pelas funções.
GRANT SELECT ON permissao_central, operador_central, permissao_concessao, permissao_revogacao,
                vw_permissao_vigente
  TO safetycar_central;
GRANT EXECUTE ON FUNCTION
  operador_tem_permissao(uuid, text),
  cadastrar_operador(uuid, uuid, text),
  definir_operador_ativo(uuid, uuid, boolean, text),
  conceder_permissao(uuid, uuid, text, text),
  revogar_permissao(uuid, uuid, text, text)
TO safetycar_central;

-- App: só o catálogo de permissões (sem dado de pessoa). Nenhuma ação e nenhuma consulta de
-- permissão: operador_tem_permissao fica só com migrator e central, porque o app lê usuario
-- (perfil central) e poderia sondar um a um quem é aprovador. A interface da Central pergunta
-- pelo backend da Central.
GRANT SELECT ON permissao_central TO safetycar_app;
