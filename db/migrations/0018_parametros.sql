-- 0018 — Parâmetros de negócio ajustáveis pela Central.
--
-- Por quê: o desenho de 23/11/2026 pede que regras de negócio fiquem em tabela de parâmetros, e
-- não em código, e que o limite de variação do reajuste seja editável. Esta migração cria o
-- catálogo, o histórico de valores e o pedido de alteração de parâmetro sensível.
--
-- Exceção à regra "parametrização só por migração" (registrada na pendência 19): o VALOR de um
-- parâmetro deste catálogo pode ser alterado pela Central, pelas funções do safetycar_central:
--   - parâmetro COMUM: aplicado direto por quem tem administrar_parametros;
--   - parâmetro SENSÍVEL: pedido de quem tem administrar_parametros e decisão de OUTRO operador
--     com a mesma permissão (mesmas travas do reajuste). Nunca direto.
-- O catálogo em si (chave, tipo, mínimo, máximo, sensível) continua só por migração. O app só lê
-- vw_parametro_vigente.
--
-- Valores: numeric. "dias" é inteiro; "percentual" tem até 2 casas (1 pb = 0,01%), para casar
-- com os pontos-base do reajuste. O valor fica sempre entre o mínimo e o máximo do catálogo,
-- conferido na gravação (vale para qualquer escritor). Valor igual ao vigente é recusado (não cria
-- versão vazia no histórico).
--
-- Histórico (parametro_valor): mesma técnica da regra_taxa: vigência [início, fim), imutável
-- (vigencia_imutavel, SC012), sem sobreposição (EXCLUDE) e um só valor em aberto por parâmetro.
-- A troca encerra o valor atual e abre o novo no mesmo instante, lido com clock_timestamp()
-- depois do lock da linha do parâmetro; nunca no passado.
--
-- Carga (decidida): limite_variacao_reajuste = 20 (percentual, de 1 a 50, sensível; o teto de
-- 50% é o mesmo do reajuste e um CHECK impede subir o máximo) e alerta_documento_dias = 30 (dias,
-- de 1 a 180, comum), com referência ao desenho de 23/11/2026.
--
-- Códigos de erro novos:
--   SC026 valor de parâmetro fora do mínimo e máximo, ou incompatível com o tipo
--   SC027 caminho errado: parâmetro sensível alterado direto, ou parâmetro comum por pedido
-- Reaproveitados: SC024 (pedido em aberto para o mesmo parâmetro), SC020 (pedido já decidido),
-- SC017 (decidir o próprio pedido), SC016 (sem permissão), SC013 (parâmetro sem valor).

-- ---------------------------------------------------------------------
-- Catálogo (só por migração)
-- ---------------------------------------------------------------------

CREATE TABLE parametro (
  chave         text PRIMARY KEY CHECK (chave ~ '^[a-z][a-z0-9_]*$'),
  descricao     text NOT NULL CHECK (btrim(descricao) <> ''),
  tipo          text NOT NULL CHECK (tipo IN ('percentual','dias')),
  minimo        numeric NOT NULL,
  maximo        numeric NOT NULL,
  sensivel      boolean NOT NULL,
  ativo         boolean NOT NULL DEFAULT true,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_parametro_faixa CHECK (minimo <= maximo),
  CONSTRAINT ck_parametro_dias_inteiro CHECK (tipo <> 'dias' OR (minimo = trunc(minimo) AND maximo = trunc(maximo) AND minimo >= 0)),
  CONSTRAINT ck_parametro_percentual CHECK (tipo <> 'percentual' OR (minimo >= 0 AND maximo <= 100)),
  -- O teto absoluto do reajuste é ±50% (0015); o limite nunca passa disso.
  CONSTRAINT ck_parametro_limite_reajuste CHECK (chave <> 'limite_variacao_reajuste' OR (sensivel AND maximo <= 50))
);
CREATE TRIGGER tg_parametro_atualizado_em BEFORE UPDATE ON parametro
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_parametro_auditoria AFTER INSERT OR UPDATE OR DELETE ON parametro
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_parametro_sem_truncate BEFORE TRUNCATE ON parametro
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

-- Confere o valor contra o catálogo; devolve a linha do parâmetro.
CREATE FUNCTION parametro_validar_valor(p_chave text, p_valor numeric) RETURNS parametro
LANGUAGE plpgsql STABLE AS $$
DECLARE p parametro;
BEGIN
  SELECT * INTO p FROM parametro WHERE chave = p_chave;
  IF NOT FOUND OR NOT p.ativo THEN
    RAISE EXCEPTION 'parâmetro inexistente ou inativo: %', p_chave USING ERRCODE = '22023';
  END IF;
  IF p_valor IS NULL THEN
    RAISE EXCEPTION 'valor do parâmetro % é obrigatório', p_chave USING ERRCODE = '22023';
  END IF;
  IF p.tipo = 'dias' AND p_valor <> trunc(p_valor) THEN
    RAISE EXCEPTION 'parâmetro % é em dias inteiros (recebido: %)', p_chave, p_valor USING ERRCODE = 'SC026';
  END IF;
  IF p.tipo = 'percentual' AND p_valor <> round(p_valor, 2) THEN
    RAISE EXCEPTION 'parâmetro % é percentual com até 2 casas (recebido: %)', p_chave, p_valor USING ERRCODE = 'SC026';
  END IF;
  IF p_valor < p.minimo OR p_valor > p.maximo THEN
    RAISE EXCEPTION 'parâmetro % vai de % a % (recebido: %)', p_chave, p.minimo, p.maximo, p_valor USING ERRCODE = 'SC026';
  END IF;
  RETURN p;
END $$;

-- ---------------------------------------------------------------------
-- Pedido de alteração de parâmetro sensível (somente inserção) e decisão (uma por pedido)
-- ---------------------------------------------------------------------

CREATE TABLE parametro_alteracao (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parametro_chave        text NOT NULL REFERENCES parametro(chave),
  valor_novo             numeric NOT NULL,
  valor_na_criacao       numeric,          -- valor vigente quando o pedido foi feito (informativo)
  referencia_alinhamento text,             -- ex.: seção do documento de alinhamento
  motivo                 text NOT NULL CHECK (btrim(motivo) <> ''),
  solicitado_por         uuid NOT NULL REFERENCES operador_central(usuario_id),
  solicitado_em          timestamptz NOT NULL DEFAULT clock_timestamp(),
  papel_bd               text NOT NULL DEFAULT session_user
);
-- Consulta prevista: "pedidos do parâmetro X" (e o pedido em aberto, para a SC024)
CREATE INDEX ix_parametro_alteracao_chave ON parametro_alteracao (parametro_chave, solicitado_em DESC);

CREATE TABLE parametro_alteracao_decisao (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  alteracao_id   uuid NOT NULL UNIQUE REFERENCES parametro_alteracao(id),
  situacao       text NOT NULL CHECK (situacao IN ('aprovado','rejeitado','cancelado')),
  decidido_por   uuid NOT NULL REFERENCES operador_central(usuario_id),
  decidido_em    timestamptz NOT NULL DEFAULT clock_timestamp(),
  motivo         text NOT NULL CHECK (btrim(motivo) <> ''),
  inicio_efetivo timestamptz,
  papel_bd       text NOT NULL DEFAULT session_user,
  CONSTRAINT ck_parametro_decisao_aprovacao CHECK ((situacao = 'aprovado') = (inicio_efetivo IS NOT NULL))
);

CREATE FUNCTION parametro_alteracao_preparar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE p parametro;
BEGIN
  NEW.solicitado_em := clock_timestamp();
  NEW.papel_bd := session_user;
  p := parametro_validar_valor(NEW.parametro_chave, NEW.valor_novo);
  IF NOT p.sensivel THEN
    RAISE EXCEPTION 'parâmetro % é comum: é alterado direto, sem pedido', NEW.parametro_chave USING ERRCODE = 'SC027';
  END IF;
  IF EXISTS (SELECT 1 FROM parametro_alteracao a
              WHERE a.parametro_chave = NEW.parametro_chave
                AND NOT EXISTS (SELECT 1 FROM parametro_alteracao_decisao d WHERE d.alteracao_id = a.id)) THEN
    RAISE EXCEPTION 'já existe pedido em aberto para o parâmetro %', NEW.parametro_chave USING ERRCODE = 'SC024';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_parametro_alteracao_preparar BEFORE INSERT ON parametro_alteracao
  FOR EACH ROW EXECUTE FUNCTION parametro_alteracao_preparar();
CREATE TRIGGER tg_parametro_alteracao_sem_alteracao BEFORE UPDATE OR DELETE ON parametro_alteracao
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_parametro_alteracao_sem_truncate BEFORE TRUNCATE ON parametro_alteracao
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_parametro_alteracao_auditoria AFTER INSERT ON parametro_alteracao
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();

-- decidido_em e papel_bd pela hora e pelo papel do servidor (mesma função da 0015).
CREATE TRIGGER tg_parametro_decisao_preparar BEFORE INSERT ON parametro_alteracao_decisao
  FOR EACH ROW EXECUTE FUNCTION reajuste_decisao_preparar();
CREATE TRIGGER tg_parametro_decisao_sem_alteracao BEFORE UPDATE OR DELETE ON parametro_alteracao_decisao
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_parametro_decisao_sem_truncate BEFORE TRUNCATE ON parametro_alteracao_decisao
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_parametro_decisao_auditoria AFTER INSERT ON parametro_alteracao_decisao
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();

CREATE VIEW vw_parametro_alteracao WITH (security_invoker = true) AS
SELECT a.*,
       coalesce(d.situacao, 'solicitado') AS situacao,
       d.decidido_por, d.decidido_em, d.motivo AS motivo_decisao, d.inicio_efetivo
  FROM parametro_alteracao a
  LEFT JOIN parametro_alteracao_decisao d ON d.alteracao_id = a.id;

-- ---------------------------------------------------------------------
-- Histórico de valores
-- ---------------------------------------------------------------------

CREATE TABLE parametro_valor (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parametro_chave        text NOT NULL REFERENCES parametro(chave),
  valor                  numeric NOT NULL,
  origem                 text NOT NULL CHECK (origem IN ('migracao','central_direta','central_aprovada')),
  referencia_alinhamento text,
  motivo                 text NOT NULL CHECK (btrim(motivo) <> ''),
  alterado_por           uuid REFERENCES operador_central(usuario_id),   -- quem alterou ou pediu
  aprovado_por           uuid REFERENCES operador_central(usuario_id),   -- quem aprovou (sensível)
  alteracao_id           uuid REFERENCES parametro_alteracao(id),        -- pedido aprovado (sensível)
  inicio_vigencia        timestamptz NOT NULL DEFAULT now(),
  fim_vigencia           timestamptz,
  papel_bd               text NOT NULL DEFAULT session_user,
  criado_em              timestamptz NOT NULL DEFAULT now(),
  atualizado_em          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_parametro_valor_origem CHECK (
       (origem = 'migracao'         AND alterado_por IS NULL     AND aprovado_por IS NULL     AND alteracao_id IS NULL)
    OR (origem = 'central_direta'   AND alterado_por IS NOT NULL AND aprovado_por IS NULL     AND alteracao_id IS NULL)
    OR (origem = 'central_aprovada' AND alterado_por IS NOT NULL AND aprovado_por IS NOT NULL AND alteracao_id IS NOT NULL
        AND aprovado_por <> alterado_por)),
  CONSTRAINT ck_parametro_valor_vigencia CHECK (fim_vigencia IS NULL OR fim_vigencia >= inicio_vigencia),
  CONSTRAINT ex_parametro_valor_vigencia EXCLUDE USING gist (
    parametro_chave WITH =,
    tstzrange(inicio_vigencia, fim_vigencia, '[)') WITH &&)
);
-- Um só valor em aberto por parâmetro.
CREATE UNIQUE INDEX ux_parametro_valor_aberto ON parametro_valor (parametro_chave) WHERE fim_vigencia IS NULL;

CREATE FUNCTION parametro_valor_validar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE p parametro;
BEGIN
  NEW.papel_bd := session_user;
  p := parametro_validar_valor(NEW.parametro_chave, NEW.valor);
  IF p.sensivel AND NEW.origem = 'central_direta' THEN
    RAISE EXCEPTION 'parâmetro % é sensível: só muda por pedido aprovado por outro operador', NEW.parametro_chave
      USING ERRCODE = 'SC027';
  END IF;
  IF NOT p.sensivel AND NEW.origem = 'central_aprovada' THEN
    RAISE EXCEPTION 'parâmetro % é comum: é alterado direto, sem pedido', NEW.parametro_chave USING ERRCODE = 'SC027';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_parametro_valor_validar BEFORE INSERT ON parametro_valor
  FOR EACH ROW EXECUTE FUNCTION parametro_valor_validar();
CREATE TRIGGER tg_parametro_valor_imutavel BEFORE INSERT OR UPDATE OR DELETE ON parametro_valor
  FOR EACH ROW EXECUTE FUNCTION vigencia_imutavel();
CREATE TRIGGER tg_parametro_valor_atualizado_em BEFORE UPDATE ON parametro_valor
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_parametro_valor_auditoria AFTER INSERT OR UPDATE OR DELETE ON parametro_valor
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_parametro_valor_sem_truncate BEFORE TRUNCATE ON parametro_valor
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

-- Valor vigente no instante (SC013 se não houver; 22023 se o parâmetro não existir).
CREATE FUNCTION parametro_vigente(p_chave text, p_instante timestamptz DEFAULT now()) RETURNS numeric
LANGUAGE plpgsql STABLE AS $$
DECLARE v numeric;
BEGIN
  IF p_chave IS NULL OR NOT EXISTS (SELECT 1 FROM parametro WHERE chave = p_chave) THEN
    RAISE EXCEPTION 'parâmetro inexistente: %', p_chave USING ERRCODE = '22023';
  END IF;
  IF p_instante IS NULL THEN
    RAISE EXCEPTION 'instante é obrigatório' USING ERRCODE = '22023';
  END IF;
  SELECT valor INTO v FROM parametro_valor
   WHERE parametro_chave = p_chave AND tstzrange(inicio_vigencia, fim_vigencia, '[)') @> p_instante;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'parâmetro % sem valor vigente em %', p_chave, p_instante USING ERRCODE = 'SC013';
  END IF;
  RETURN v;
END $$;

-- Valores vigentes, para leitura do app e da Central. SEM security_invoker, de propósito: o app
-- não lê as tabelas de parâmetro (o histórico identifica operadores); a visão expõe só o
-- catálogo e o valor de agora.
CREATE VIEW vw_parametro_vigente AS
SELECT p.chave, p.descricao, p.tipo, p.minimo, p.maximo, p.sensivel,
       v.valor, v.inicio_vigencia AS vigente_desde
  FROM parametro p
  LEFT JOIN parametro_valor v
    ON v.parametro_chave = p.chave AND tstzrange(v.inicio_vigencia, v.fim_vigencia, '[)') @> now()
 WHERE p.ativo;

-- ---------------------------------------------------------------------
-- Carga (decidida em 23/11/2026)
-- ---------------------------------------------------------------------

INSERT INTO parametro (chave, descricao, tipo, minimo, maximo, sensivel) VALUES
  ('limite_variacao_reajuste',
   'Variação máxima, em %, de um reajuste de taxa sem motivo de exceção (usado a partir da 0019). Teto absoluto do reajuste: 50%.',
   'percentual', 1, 50, true),
  ('alerta_documento_dias',
   'Antecedência, em dias, do alerta de vencimento de documento do parceiro (a rotina de vencimento ainda não existe).',
   'dias', 1, 180, false);

INSERT INTO parametro_valor (parametro_chave, valor, origem, referencia_alinhamento, motivo) VALUES
  ('limite_variacao_reajuste', 20, 'migracao',
   'docs/CENTRAL_PERMISSOES_TARIFAS_PARAMETROS.md (desenho aprovado em 23/11/2026)', 'Carga inicial (0018)'),
  ('alerta_documento_dias', 30, 'migracao',
   'docs/CENTRAL_PERMISSOES_TARIFAS_PARAMETROS.md (desenho aprovado em 23/11/2026)', 'Carga inicial (0018)');

-- ---------------------------------------------------------------------
-- Funções da Central (SECURITY DEFINER; EXECUTE só para safetycar_central)
-- ---------------------------------------------------------------------

-- Troca o valor vigente: encerra o atual e abre o novo no mesmo instante. Interna.
-- Chamada com a linha do parâmetro já travada (FOR UPDATE).
CREATE FUNCTION parametro_trocar_valor(p_chave text, p_valor numeric, p_origem text, p_referencia text,
                                       p_motivo text, p_alterado_por uuid, p_aprovado_por uuid,
                                       p_alteracao_id uuid)
RETURNS TABLE (valor_id uuid, valor_anterior numeric, inicio timestamptz)
LANGUAGE plpgsql AS $$
DECLARE v_atual parametro_valor; v_agora timestamptz := clock_timestamp();
BEGIN
  SELECT * INTO v_atual FROM parametro_valor
   WHERE parametro_chave = p_chave AND tstzrange(inicio_vigencia, fim_vigencia, '[)') @> v_agora
   FOR UPDATE;
  IF FOUND AND v_atual.valor = p_valor THEN
    RAISE EXCEPTION 'parâmetro % já vale %; nada a alterar', p_chave, p_valor USING ERRCODE = '22023';
  END IF;
  IF FOUND THEN
    UPDATE parametro_valor SET fim_vigencia = v_agora WHERE id = v_atual.id;
  END IF;
  INSERT INTO parametro_valor (parametro_chave, valor, origem, referencia_alinhamento, motivo,
                               alterado_por, aprovado_por, alteracao_id, inicio_vigencia, fim_vigencia)
  VALUES (p_chave, p_valor, p_origem, p_referencia, p_motivo, p_alterado_por, p_aprovado_por,
          p_alteracao_id, v_agora, v_atual.fim_vigencia)
  RETURNING id INTO valor_id;
  valor_anterior := v_atual.valor;
  inicio := v_agora;
  RETURN NEXT;
END $$;

-- Parâmetro comum: quem tem administrar_parametros altera direto.
CREATE FUNCTION alterar_parametro(p_ator uuid, p_chave text, p_valor numeric, p_motivo text,
                                  p_referencia text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p parametro; t record; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'administrar_parametros');
  SELECT * INTO p FROM parametro WHERE chave = p_chave FOR UPDATE;   -- serializa as trocas do parâmetro
  p := parametro_validar_valor(p_chave, p_valor);
  IF p.sensivel THEN
    RAISE EXCEPTION 'parâmetro % é sensível: peça a alteração (solicitar_alteracao_parametro)', p_chave
      USING ERRCODE = 'SC027';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  SELECT * INTO t FROM parametro_trocar_valor(p_chave, p_valor, 'central_direta', p_referencia, p_motivo,
                                              p_ator, NULL, NULL);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_parametro_alterado', 'parametro_valor', t.valor_id,
          jsonb_build_object('parametro_chave', p_chave, 'valor', t.valor_anterior),
          jsonb_build_object('parametro_chave', p_chave, 'valor', p_valor, 'inicio_vigencia', t.inicio,
                             'referencia_alinhamento', p_referencia, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN t.valor_id;
END $$;

-- Parâmetro sensível: pedido de quem tem administrar_parametros.
CREATE FUNCTION solicitar_alteracao_parametro(p_ator uuid, p_chave text, p_valor numeric, p_motivo text,
                                              p_referencia text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE p parametro; v_atual numeric; v_id uuid; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'administrar_parametros');
  -- Trava o parâmetro: duas solicitações simultâneas não passam juntas pela SC024.
  SELECT * INTO p FROM parametro WHERE chave = p_chave FOR UPDATE;
  p := parametro_validar_valor(p_chave, p_valor);
  IF NOT p.sensivel THEN
    RAISE EXCEPTION 'parâmetro % é comum: altere direto (alterar_parametro)', p_chave USING ERRCODE = 'SC027';
  END IF;
  SELECT valor INTO v_atual FROM parametro_valor
   WHERE parametro_chave = p_chave AND tstzrange(inicio_vigencia, fim_vigencia, '[)') @> clock_timestamp();
  IF v_atual = p_valor THEN
    RAISE EXCEPTION 'parâmetro % já vale %; nada a alterar', p_chave, p_valor USING ERRCODE = '22023';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  -- A regra do pedido em aberto (SC024) fica no trigger.
  INSERT INTO parametro_alteracao (parametro_chave, valor_novo, valor_na_criacao, referencia_alinhamento,
                                   motivo, solicitado_por)
  VALUES (p_chave, p_valor, v_atual, p_referencia, p_motivo, p_ator)
  RETURNING id INTO v_id;
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_parametro_solicitado', 'parametro_alteracao', v_id,
          jsonb_build_object('parametro_chave', p_chave, 'valor', v_atual),
          jsonb_build_object('parametro_chave', p_chave, 'valor', p_valor,
                             'referencia_alinhamento', p_referencia, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_id;
END $$;

-- Aprovação: administrar_parametros e não o solicitante. Devolve o id do novo valor.
CREATE FUNCTION aprovar_alteracao_parametro(p_ator uuid, p_alteracao_id uuid, p_motivo text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a parametro_alteracao; t record; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'administrar_parametros');
  -- Trava o pedido e depois o parâmetro (sempre nesta ordem).
  SELECT * INTO a FROM parametro_alteracao WHERE id = p_alteracao_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pedido de alteração inexistente: %', p_alteracao_id USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM parametro_alteracao_decisao WHERE alteracao_id = a.id) THEN
    RAISE EXCEPTION 'pedido % já foi decidido', a.id USING ERRCODE = 'SC020';
  END IF;
  IF a.solicitado_por = p_ator THEN
    RAISE EXCEPTION 'quem pediu a alteração não pode aprová-la' USING ERRCODE = 'SC017';
  END IF;
  PERFORM 1 FROM parametro WHERE chave = a.parametro_chave FOR UPDATE;

  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  -- O valor é conferido de novo contra o catálogo de agora (trigger de parametro_valor).
  SELECT * INTO t FROM parametro_trocar_valor(a.parametro_chave, a.valor_novo, 'central_aprovada',
                                              a.referencia_alinhamento, a.motivo, a.solicitado_por,
                                              p_ator, a.id);
  INSERT INTO parametro_alteracao_decisao (alteracao_id, situacao, decidido_por, motivo, inicio_efetivo)
  VALUES (a.id, 'aprovado', p_ator, p_motivo, t.inicio);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_parametro_decidido', 'parametro_alteracao', a.id,
          jsonb_build_object('situacao', 'solicitado', 'parametro_chave', a.parametro_chave, 'valor', t.valor_anterior),
          jsonb_build_object('situacao', 'aprovado', 'parametro_chave', a.parametro_chave, 'valor', a.valor_novo,
                             'valor_id', t.valor_id, 'inicio_vigencia', t.inicio, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN t.valor_id;
END $$;

-- Rejeição: administrar_parametros e não o solicitante.
CREATE FUNCTION rejeitar_alteracao_parametro(p_ator uuid, p_alteracao_id uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a parametro_alteracao; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'administrar_parametros');
  SELECT * INTO a FROM parametro_alteracao WHERE id = p_alteracao_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pedido de alteração inexistente: %', p_alteracao_id USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM parametro_alteracao_decisao WHERE alteracao_id = a.id) THEN
    RAISE EXCEPTION 'pedido % já foi decidido', a.id USING ERRCODE = 'SC020';
  END IF;
  IF a.solicitado_por = p_ator THEN
    RAISE EXCEPTION 'quem pediu a alteração não pode rejeitá-la (cancele)' USING ERRCODE = 'SC017';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO parametro_alteracao_decisao (alteracao_id, situacao, decidido_por, motivo)
  VALUES (a.id, 'rejeitado', p_ator, p_motivo);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_parametro_decidido', 'parametro_alteracao', a.id,
          jsonb_build_object('situacao', 'solicitado'),
          jsonb_build_object('situacao', 'rejeitado', 'parametro_chave', a.parametro_chave, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

-- Cancelamento: o próprio solicitante (operador ativo) ou quem tem administrar_parametros.
CREATE FUNCTION cancelar_alteracao_parametro(p_ator uuid, p_alteracao_id uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE a parametro_alteracao; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  SELECT * INTO a FROM parametro_alteracao WHERE id = p_alteracao_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'pedido de alteração inexistente: %', p_alteracao_id USING ERRCODE = '22023';
  END IF;
  IF p_ator IS NOT DISTINCT FROM a.solicitado_por THEN
    PERFORM exige_operador_ativo(p_ator);
  ELSE
    PERFORM exige_permissao(p_ator, 'administrar_parametros');
  END IF;
  IF EXISTS (SELECT 1 FROM parametro_alteracao_decisao WHERE alteracao_id = a.id) THEN
    RAISE EXCEPTION 'pedido % já foi decidido', a.id USING ERRCODE = 'SC020';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO parametro_alteracao_decisao (alteracao_id, situacao, decidido_por, motivo)
  VALUES (a.id, 'cancelado', p_ator, p_motivo);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_parametro_decidido', 'parametro_alteracao', a.id,
          jsonb_build_object('situacao', 'solicitado'),
          jsonb_build_object('situacao', 'cancelado', 'parametro_chave', a.parametro_chave, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

-- ---------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION
  parametro_validar_valor(text, numeric),
  parametro_vigente(text, timestamptz),
  parametro_trocar_valor(text, numeric, text, text, text, uuid, uuid, uuid),
  alterar_parametro(uuid, text, numeric, text, text),
  solicitar_alteracao_parametro(uuid, text, numeric, text, text),
  aprovar_alteracao_parametro(uuid, uuid, text),
  rejeitar_alteracao_parametro(uuid, uuid, text),
  cancelar_alteracao_parametro(uuid, uuid, text)
FROM PUBLIC;

-- Central: lê catálogo, histórico e pedidos; age só pelas funções.
GRANT SELECT ON parametro, parametro_valor, parametro_alteracao, parametro_alteracao_decisao,
                vw_parametro_alteracao, vw_parametro_vigente
  TO safetycar_central;
GRANT EXECUTE ON FUNCTION
  parametro_vigente(text, timestamptz),
  alterar_parametro(uuid, text, numeric, text, text),
  solicitar_alteracao_parametro(uuid, text, numeric, text, text),
  aprovar_alteracao_parametro(uuid, uuid, text),
  rejeitar_alteracao_parametro(uuid, uuid, text),
  cancelar_alteracao_parametro(uuid, uuid, text)
TO safetycar_central;

-- App: só a visão dos valores vigentes (sem identificador de operador).
GRANT SELECT ON vw_parametro_vigente TO safetycar_app;
