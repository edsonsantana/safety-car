-- 0019 — Reajuste de taxas: só percentual, início imediato, limite de variação e um lote em
-- aberto por escopo.
--
-- Por quê: o desenho de 23/11/2026 fechou o reajuste assim:
--   - o operador informa só o PERCENTUAL (positivo ou negativo); o tipo "valor" sai;
--   - o valor novo é calculado na aprovação, sobre a regra vigente naquele momento, com
--     arredondamento ao centavo em numeric (0,5 ou mais sobe) — já era assim na 0015;
--   - início IMEDIATO, na hora da aprovação; sem data de vigência (o início futuro sai);
--   - sempre 1 aprovador, diferente de quem pediu: a exceção de autoaprovação deixa de existir
--     para o reajuste (CHECK no catálogo); rejeitar o próprio pedido também é recusado;
--   - o limite de variação é o parâmetro limite_variacao_reajuste (0018). Acima dele, o pedido
--     exige motivo_excecao (SC025). O limite usado é o COPIADO no pedido, não o de agora;
--   - teto absoluto de ±50% mantido (CHECK da 0015);
--   - solicitar exige solicitar_reajuste_taxa (0016); simular, essa ou aprovar_reajuste_taxa;
--   - não há dois lotes em aberto com escopo sobreposto (SC024): duas regras vigentes em comum.
-- Região (0017) entra como atalho de escopo: as UFs da região se somam à lista de UFs.
--
-- Assinaturas: as antigas de simular (por parâmetros), solicitar e aprovar saem (DROP); nenhum
-- código as chamava. Lote antigo (tipo valor, início solicitado ou sem limite copiado) ainda em
-- aberto não é aprovado: cancele e peça de novo (22023).
--
-- Código de erro novo:
--   SC025 percentual acima do limite copiado no pedido, sem motivo_excecao
-- Reaproveitado: SC024 (lote em aberto com escopo sobreposto).

-- ---------------------------------------------------------------------
-- Catálogo: o reajuste nunca admite autoaprovação
-- ---------------------------------------------------------------------

ALTER TABLE permissao_central
  ADD CONSTRAINT ck_permissao_reajuste_sem_auto CHECK (codigo <> 'aprovar_reajuste_taxa' OR NOT permite_autoaprovacao);

-- ---------------------------------------------------------------------
-- Lote: colunas novas e regras para os lotes novos (NOT VALID: os antigos ficam como estão)
-- ---------------------------------------------------------------------

ALTER TABLE reajuste_taxa
  ADD COLUMN regioes              text[],      -- atalho de escopo informado (as UFs vão expandidas em ufs)
  ADD COLUMN motivo_excecao       text,        -- obrigatório acima do limite
  ADD COLUMN limite_bp_na_criacao integer,     -- cópia do parâmetro no momento do pedido, em pb
  ADD CONSTRAINT ck_reajuste_so_percentual CHECK (tipo = 'percentual') NOT VALID,
  ADD CONSTRAINT ck_reajuste_inicio_imediato CHECK (inicio_solicitado IS NULL) NOT VALID,
  ADD CONSTRAINT ck_reajuste_limite CHECK (limite_bp_na_criacao IS NOT NULL AND limite_bp_na_criacao BETWEEN 100 AND 5000) NOT VALID,
  ADD CONSTRAINT ck_reajuste_excecao CHECK (
    abs(percentual_bp) <= limite_bp_na_criacao OR btrim(coalesce(motivo_excecao, '')) <> '') NOT VALID;

-- ---------------------------------------------------------------------
-- Utilitários
-- ---------------------------------------------------------------------

-- Percentual (até 2 casas, de -50 a +50, diferente de 0) em pontos-base.
CREATE FUNCTION percentual_para_bp(p_percentual numeric) RETURNS integer
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_percentual IS NULL OR p_percentual = 0 OR abs(p_percentual) > 50 THEN
    RAISE EXCEPTION 'percentual deve estar entre -50 e +50, diferente de 0 (recebido: %)', p_percentual
      USING ERRCODE = '22023';
  END IF;
  IF p_percentual <> round(p_percentual, 2) THEN
    RAISE EXCEPTION 'percentual tem no máximo 2 casas (recebido: %)', p_percentual USING ERRCODE = '22023';
  END IF;
  RETURN (p_percentual * 100)::integer;
END $$;

-- UFs do escopo: a lista de UFs mais as UFs das regiões. Sem regiões, a lista como veio
-- (nula = todas as regras estaduais).
CREATE FUNCTION reajuste_ufs_escopo(p_ufs text[], p_regioes text[]) RETURNS text[]
LANGUAGE plpgsql STABLE AS $$
DECLARE v text[];
BEGIN
  IF p_regioes IS NULL THEN
    RETURN p_ufs;
  END IF;
  IF cardinality(p_regioes) = 0 THEN
    RAISE EXCEPTION 'lista de regiões vazia (use nulo para não filtrar por região)' USING ERRCODE = '22023';
  END IF;
  SELECT array_agg(DISTINCT u ORDER BY u) INTO v
    FROM (SELECT unnest(coalesce(p_ufs, '{}'::text[])) AS u
          UNION
          SELECT unnest(ufs_da_regiao(r)) FROM unnest(p_regioes) r) x;
  RETURN v;
END $$;

-- Algum lote em aberto tem regra em comum com este escopo, agora? (SC024)
CREATE FUNCTION reajuste_exigir_sem_lote_aberto(p_percentual_bp integer, p_tipos text[], p_servicos text[],
                                                p_ufs text[], p_inclui_nacional boolean, p_componentes text[],
                                                p_inclui_pontos_base boolean, p_instante timestamptz) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE v_lote uuid;
BEGIN
  SELECT r.id INTO v_lote
    FROM reajuste_taxa r
   WHERE NOT EXISTS (SELECT 1 FROM reajuste_taxa_decisao d WHERE d.reajuste_id = r.id)
     AND EXISTS (
       SELECT 1
         FROM reajuste_calculo(r.tipo, r.percentual_bp, r.valor_centavos, r.tipos_parceiro, r.servicos, r.ufs,
                               r.inclui_nacional, r.componentes, r.inclui_pontos_base, p_instante, p_instante) a
         JOIN reajuste_calculo('percentual', p_percentual_bp, NULL, p_tipos, p_servicos, p_ufs,
                               p_inclui_nacional, p_componentes, p_inclui_pontos_base, p_instante, p_instante) b
           ON b.regra_id = a.regra_id)
   LIMIT 1;
  IF v_lote IS NOT NULL THEN
    RAISE EXCEPTION 'o lote de reajuste % (ainda sem decisão) já cobre regra deste escopo', v_lote
      USING ERRCODE = 'SC024';
  END IF;
END $$;

-- Regras do lote (redefine a 0015): só percentual, início imediato, limite copiado, exceção e
-- lote em aberto. Vale para qualquer escritor.
CREATE OR REPLACE FUNCTION reajuste_taxa_preparar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.solicitado_em := clock_timestamp();
  NEW.papel_bd := session_user;
  IF NEW.tipo IS DISTINCT FROM 'percentual' THEN
    RAISE EXCEPTION 'desde a 0019, o reajuste é só por percentual' USING ERRCODE = '22023';
  END IF;
  IF NEW.inicio_solicitado IS NOT NULL THEN
    RAISE EXCEPTION 'desde a 0019, o início do reajuste é imediato (na aprovação)' USING ERRCODE = '22023';
  END IF;
  PERFORM reajuste_validar(NEW.tipo, NEW.percentual_bp, NEW.valor_centavos, NEW.tipos_parceiro,
                           NEW.servicos, NEW.ufs, NEW.inclui_nacional, NEW.componentes,
                           NEW.inclui_pontos_base);

  -- Limite do momento do pedido (o enviado é ignorado).
  NEW.limite_bp_na_criacao := round(parametro_vigente('limite_variacao_reajuste', clock_timestamp()) * 100)::integer;
  IF btrim(coalesce(NEW.motivo_excecao, '')) = '' THEN
    NEW.motivo_excecao := NULL;
  END IF;
  IF abs(NEW.percentual_bp) > NEW.limite_bp_na_criacao AND NEW.motivo_excecao IS NULL THEN
    RAISE EXCEPTION 'percentual de % pb acima do limite de % pb: informe o motivo da exceção',
      NEW.percentual_bp, NEW.limite_bp_na_criacao USING ERRCODE = 'SC025';
  END IF;

  -- Mesma chave das alterações de regra_taxa: dois pedidos sobrepostos não passam juntos.
  PERFORM pg_advisory_xact_lock(150001);
  PERFORM reajuste_exigir_sem_lote_aberto(NEW.percentual_bp, NEW.tipos_parceiro, NEW.servicos, NEW.ufs,
                                          NEW.inclui_nacional, NEW.componentes, NEW.inclui_pontos_base,
                                          clock_timestamp());
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- Assinaturas antigas saem
-- ---------------------------------------------------------------------

DROP FUNCTION simular_reajuste_taxa(uuid, text, integer, bigint, text[], text[], text[], boolean, text[], boolean, timestamptz);
DROP FUNCTION solicitar_reajuste_taxa(uuid, text, integer, bigint, text[], text[], text[], boolean, text[], boolean, text, text, timestamptz);
DROP FUNCTION aprovar_reajuste_taxa(uuid, uuid, text, timestamptz);

-- ---------------------------------------------------------------------
-- Funções da Central (SECURITY DEFINER; EXECUTE só para safetycar_central)
-- ---------------------------------------------------------------------

-- Simulação por parâmetros (antes de solicitar). Não grava nem recusa por problema de regra.
CREATE FUNCTION simular_reajuste_taxa(p_ator uuid, p_percentual numeric, p_tipos text[], p_servicos text[],
                                      p_ufs text[], p_regioes text[], p_inclui_nacional boolean,
                                      p_componentes text[], p_inclui_pontos_base boolean)
RETURNS TABLE (regra_id uuid, tipo_parceiro_codigo text, servico_codigo text, uf text,
               abrangencia text, componente text, unidade text, situacao text,
               inicio_vigencia timestamptz, fim_vigencia timestamptz,
               valor_atual bigint, valor_novo bigint, problema text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_pb integer; v_ufs text[]; v_agora timestamptz;
BEGIN
  PERFORM exige_solicitar_ou_aprovar_taxa(p_ator);
  v_pb := percentual_para_bp(p_percentual);
  v_ufs := reajuste_ufs_escopo(p_ufs, p_regioes);
  PERFORM reajuste_validar('percentual', v_pb, NULL, p_tipos, p_servicos, v_ufs,
                           p_inclui_nacional, p_componentes, p_inclui_pontos_base);
  v_agora := clock_timestamp();
  RETURN QUERY SELECT c.* FROM reajuste_calculo('percentual', v_pb, NULL, p_tipos, p_servicos, v_ufs,
                                                p_inclui_nacional, p_componentes, p_inclui_pontos_base,
                                                v_agora, v_agora) c;
END $$;

-- Simulação de um lote já solicitado, com as regras de agora (redefine a 0015).
CREATE OR REPLACE FUNCTION simular_reajuste_taxa(p_ator uuid, p_reajuste_id uuid)
RETURNS TABLE (regra_id uuid, tipo_parceiro_codigo text, servico_codigo text, uf text,
               abrangencia text, componente text, unidade text, situacao text,
               inicio_vigencia timestamptz, fim_vigencia timestamptz,
               valor_atual bigint, valor_novo bigint, problema text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_lote reajuste_taxa; v_agora timestamptz;
BEGIN
  PERFORM exige_solicitar_ou_aprovar_taxa(p_ator);
  SELECT * INTO v_lote FROM reajuste_taxa WHERE id = p_reajuste_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reajuste inexistente: %', p_reajuste_id USING ERRCODE = '22023';
  END IF;
  v_agora := clock_timestamp();
  RETURN QUERY SELECT c.* FROM reajuste_calculo(v_lote.tipo, v_lote.percentual_bp, v_lote.valor_centavos,
                                                v_lote.tipos_parceiro, v_lote.servicos, v_lote.ufs,
                                                v_lote.inclui_nacional, v_lote.componentes,
                                                v_lote.inclui_pontos_base, v_agora, v_agora) c;
END $$;

-- Solicitação: quem tem solicitar_reajuste_taxa. Não toca em nenhuma regra; recusa cedo o que a
-- aprovação recusaria. Limite, exceção e lote em aberto ficam no trigger.
CREATE FUNCTION solicitar_reajuste_taxa(p_ator uuid, p_percentual numeric, p_tipos text[], p_servicos text[],
                                        p_ufs text[], p_regioes text[], p_inclui_nacional boolean,
                                        p_componentes text[], p_inclui_pontos_base boolean, p_motivo text,
                                        p_motivo_excecao text DEFAULT NULL,
                                        p_indice_referencia text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_id uuid; v_pb integer; v_ufs text[]; v_agora timestamptz; v_lote reajuste_taxa;
  v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'solicitar_reajuste_taxa');
  v_pb := percentual_para_bp(p_percentual);
  v_ufs := reajuste_ufs_escopo(p_ufs, p_regioes);
  PERFORM reajuste_validar('percentual', v_pb, NULL, p_tipos, p_servicos, v_ufs,
                           p_inclui_nacional, p_componentes, p_inclui_pontos_base);
  PERFORM pg_advisory_xact_lock(150001);
  v_agora := clock_timestamp();
  PERFORM reajuste_exigir_aplicavel('percentual', v_pb, NULL, p_tipos, p_servicos, v_ufs,
                                    p_inclui_nacional, p_componentes, p_inclui_pontos_base, v_agora, v_agora);

  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO reajuste_taxa (tipo, percentual_bp, tipos_parceiro, servicos, ufs, regioes, inclui_nacional,
                             componentes, inclui_pontos_base, motivo, motivo_excecao, indice_referencia,
                             solicitado_por)
  VALUES ('percentual', v_pb, p_tipos, p_servicos, v_ufs, p_regioes, p_inclui_nacional,
          p_componentes, p_inclui_pontos_base, p_motivo, p_motivo_excecao, p_indice_referencia, p_ator)
  RETURNING * INTO v_lote;
  v_id := v_lote.id;
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, depois)
  VALUES (p_ator, 'central_reajuste_solicitado', 'reajuste_taxa', v_id,
          jsonb_build_object('percentual_bp', v_pb, 'limite_bp_na_criacao', v_lote.limite_bp_na_criacao,
                             'acima_do_limite', abs(v_pb) > v_lote.limite_bp_na_criacao,
                             'motivo', p_motivo, 'motivo_excecao', v_lote.motivo_excecao));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_id;
END $$;

-- Aprovação: quem tem aprovar_reajuste_taxa e não é o solicitante (sempre). Calcula sobre as
-- regras vigentes agora e, numa só transação, encerra as antigas e cria as novas no mesmo
-- instante (imediato). Devolve quantas regras ganharam nova versão.
CREATE FUNCTION aprovar_reajuste_taxa(p_ator uuid, p_reajuste_id uuid, p_motivo text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_lote reajuste_taxa;
  v_agora timestamptz;
  v_n integer := 0;
  c record;
  v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'aprovar_reajuste_taxa');

  -- 1) Serializa as alterações de regra_taxa pela Central.
  PERFORM pg_advisory_xact_lock(150001);

  -- 2) Trava o lote e confere a situação.
  SELECT * INTO v_lote FROM reajuste_taxa WHERE id = p_reajuste_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reajuste inexistente: %', p_reajuste_id USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM reajuste_taxa_decisao WHERE reajuste_id = v_lote.id) THEN
    RAISE EXCEPTION 'reajuste % já foi decidido', v_lote.id USING ERRCODE = 'SC020';
  END IF;
  IF v_lote.tipo <> 'percentual' OR v_lote.inicio_solicitado IS NOT NULL OR v_lote.limite_bp_na_criacao IS NULL THEN
    RAISE EXCEPTION 'reajuste % foi pedido antes da 0019 (valor, início agendado ou sem limite); cancele e peça de novo',
      v_lote.id USING ERRCODE = '22023';
  END IF;

  -- 3) Quem solicitou não aprova.
  IF v_lote.solicitado_por = p_ator THEN
    RAISE EXCEPTION 'quem solicitou o reajuste não pode aprová-lo' USING ERRCODE = 'SC017';
  END IF;

  -- 4) Trava as regras do escopo (em ordem de id) e só então lê o relógio; repete com ele.
  PERFORM 1 FROM regra_taxa
   WHERE id IN (SELECT x.regra_id FROM reajuste_calculo(v_lote.tipo, v_lote.percentual_bp, v_lote.valor_centavos,
                  v_lote.tipos_parceiro, v_lote.servicos, v_lote.ufs, v_lote.inclui_nacional, v_lote.componentes,
                  v_lote.inclui_pontos_base, clock_timestamp(), clock_timestamp()) x)
   ORDER BY id FOR UPDATE;
  v_agora := clock_timestamp();
  PERFORM 1 FROM regra_taxa
   WHERE id IN (SELECT x.regra_id FROM reajuste_calculo(v_lote.tipo, v_lote.percentual_bp, v_lote.valor_centavos,
                  v_lote.tipos_parceiro, v_lote.servicos, v_lote.ufs, v_lote.inclui_nacional, v_lote.componentes,
                  v_lote.inclui_pontos_base, v_agora, v_agora) x)
   ORDER BY id FOR UPDATE;

  -- 5) Todas as checagens antes de qualquer escrita. O limite não é conferido de novo: vale o
  --    copiado no pedido.
  PERFORM reajuste_exigir_aplicavel(v_lote.tipo, v_lote.percentual_bp, v_lote.valor_centavos,
                                    v_lote.tipos_parceiro, v_lote.servicos, v_lote.ufs,
                                    v_lote.inclui_nacional, v_lote.componentes,
                                    v_lote.inclui_pontos_base, v_agora, v_agora);

  -- 6) Escrita: encerra a antiga agora e cria a nova no mesmo instante.
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  FOR c IN SELECT * FROM reajuste_calculo(v_lote.tipo, v_lote.percentual_bp, v_lote.valor_centavos,
                                          v_lote.tipos_parceiro, v_lote.servicos, v_lote.ufs,
                                          v_lote.inclui_nacional, v_lote.componentes,
                                          v_lote.inclui_pontos_base, v_agora, v_agora)
  LOOP
    UPDATE regra_taxa SET fim_vigencia = v_agora WHERE id = c.regra_id;
    INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor,
                            base_distancia, situacao, observacao, inicio_vigencia, fim_vigencia,
                            reajuste_id, regra_origem_id)
    SELECT r.tipo_parceiro_codigo, r.servico_codigo, r.uf, r.componente, r.unidade, c.valor_novo,
           r.base_distancia, 'definido', format('Reajuste %s', v_lote.id), v_agora, c.fim_vigencia,
           v_lote.id, r.id
      FROM regra_taxa r WHERE r.id = c.regra_id;
    v_n := v_n + 1;
  END LOOP;

  INSERT INTO reajuste_taxa_decisao (reajuste_id, situacao, decidido_por, motivo, inicio_efetivo,
                                     regras_afetadas, autoaprovacao)
  VALUES (v_lote.id, 'aprovado', p_ator, p_motivo, v_agora, v_n, false);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_reajuste_aprovado', 'reajuste_taxa', v_lote.id,
          jsonb_build_object('situacao', 'solicitado'),
          jsonb_build_object('situacao', 'aprovado', 'percentual_bp', v_lote.percentual_bp,
                             'regras_afetadas', v_n, 'inicio_efetivo', v_agora, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_n;
END $$;

-- Rejeição: quem tem aprovar_reajuste_taxa e não é o solicitante (redefine a 0015).
CREATE OR REPLACE FUNCTION rejeitar_reajuste_taxa(p_ator uuid, p_reajuste_id uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_solicitante uuid; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'aprovar_reajuste_taxa');
  SELECT solicitado_por INTO v_solicitante FROM reajuste_taxa WHERE id = p_reajuste_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reajuste inexistente: %', p_reajuste_id USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM reajuste_taxa_decisao WHERE reajuste_id = p_reajuste_id) THEN
    RAISE EXCEPTION 'reajuste % já foi decidido', p_reajuste_id USING ERRCODE = 'SC020';
  END IF;
  IF v_solicitante = p_ator THEN
    RAISE EXCEPTION 'quem solicitou o reajuste não pode rejeitá-lo (cancele)' USING ERRCODE = 'SC017';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO reajuste_taxa_decisao (reajuste_id, situacao, decidido_por, motivo)
  VALUES (p_reajuste_id, 'rejeitado', p_ator, p_motivo);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_reajuste_rejeitado', 'reajuste_taxa', p_reajuste_id,
          jsonb_build_object('situacao', 'solicitado'),
          jsonb_build_object('situacao', 'rejeitado', 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

-- Cancelamento: o próprio solicitante (ativo) ou quem tem aprovar_reajuste_taxa (redefine a 0015).
CREATE OR REPLACE FUNCTION cancelar_reajuste_taxa(p_ator uuid, p_reajuste_id uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_solicitante uuid; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  SELECT solicitado_por INTO v_solicitante FROM reajuste_taxa WHERE id = p_reajuste_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reajuste inexistente: %', p_reajuste_id USING ERRCODE = '22023';
  END IF;
  IF p_ator IS NOT DISTINCT FROM v_solicitante THEN
    PERFORM exige_operador_ativo(p_ator);
  ELSE
    PERFORM exige_permissao(p_ator, 'aprovar_reajuste_taxa');
  END IF;
  IF EXISTS (SELECT 1 FROM reajuste_taxa_decisao WHERE reajuste_id = p_reajuste_id) THEN
    RAISE EXCEPTION 'reajuste % já foi decidido', p_reajuste_id USING ERRCODE = 'SC020';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO reajuste_taxa_decisao (reajuste_id, situacao, decidido_por, motivo)
  VALUES (p_reajuste_id, 'cancelado', p_ator, p_motivo);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_reajuste_cancelado', 'reajuste_taxa', p_reajuste_id,
          jsonb_build_object('situacao', 'solicitado'),
          jsonb_build_object('situacao', 'cancelado', 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

-- ---------------------------------------------------------------------
-- Visões
-- ---------------------------------------------------------------------

-- Recriada para incluir as colunas novas do lote (r.* é expandido na criação da visão).
DROP VIEW vw_reajuste_taxa;
CREATE VIEW vw_reajuste_taxa WITH (security_invoker = true) AS
SELECT r.*,
       coalesce(d.situacao, 'solicitado') AS situacao,
       d.decidido_por, d.decidido_em, d.motivo AS motivo_decisao,
       d.inicio_efetivo, d.regras_afetadas, d.autoaprovacao
  FROM reajuste_taxa r
  LEFT JOIN reajuste_taxa_decisao d ON d.reajuste_id = r.id;

-- Por regra reajustada: valor base (da regra substituída) e valor novo.
CREATE VIEW vw_reajuste_taxa_regra WITH (security_invoker = true) AS
SELECT n.reajuste_id, n.id AS regra_id, n.regra_origem_id,
       n.tipo_parceiro_codigo, n.servico_codigo, n.uf, n.componente, n.unidade,
       o.valor AS valor_base, n.valor AS valor_novo, n.inicio_vigencia
  FROM regra_taxa n
  JOIN regra_taxa o ON o.id = n.regra_origem_id
 WHERE n.reajuste_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION
  percentual_para_bp(numeric),
  reajuste_ufs_escopo(text[], text[]),
  reajuste_exigir_sem_lote_aberto(integer, text[], text[], text[], boolean, text[], boolean, timestamptz),
  simular_reajuste_taxa(uuid, numeric, text[], text[], text[], text[], boolean, text[], boolean),
  solicitar_reajuste_taxa(uuid, numeric, text[], text[], text[], text[], boolean, text[], boolean, text, text, text),
  aprovar_reajuste_taxa(uuid, uuid, text)
FROM PUBLIC;

GRANT SELECT ON vw_reajuste_taxa, vw_reajuste_taxa_regra TO safetycar_central;
GRANT EXECUTE ON FUNCTION
  simular_reajuste_taxa(uuid, numeric, text[], text[], text[], text[], boolean, text[], boolean),
  solicitar_reajuste_taxa(uuid, numeric, text[], text[], text[], text[], boolean, text[], boolean, text, text, text),
  aprovar_reajuste_taxa(uuid, uuid, text)
TO safetycar_central;

-- App: nada novo. Continua só lendo regra_taxa.
