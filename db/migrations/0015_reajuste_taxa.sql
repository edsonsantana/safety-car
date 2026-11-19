-- 0015 — Reajuste de taxas em lote, com solicitação e aprovação.
--
-- Por quê: em pico de inflação, reajustar preços só por migração é lento demais. Agora um
-- operador ativo da Central solicita (e simula) um reajuste, e quem tem a permissão
-- aprovar_reajuste_taxa vigente aprova ou rejeita. Nada entra em vigor sem aprovação.
--
-- Regras (decididas):
--   - Quem solicita não aprova o próprio pedido, salvo permissao_central.permite_autoaprovacao
--     (desligada; só muda por migração). Escrita só por funções SECURITY DEFINER do
--     safetycar_central (0014); o ator é verificado e auditado.
--   - A aprovação calcula sobre as regras vigentes NO MOMENTO da aprovação e, numa só transação,
--     encerra as antigas no início e cria as novas. Qualquer erro desfaz tudo (sem reajuste parcial).
--   - Locks: pg_advisory_xact_lock (serializa as aprovações) e depois FOR UPDATE nas regras do
--     escopo. O relógio (clock_timestamp) é lido DEPOIS dos locks; o início padrão e a checagem
--     de "início no passado" usam esse mesmo relógio, nunca now().
--   - Arredondamento ao centavo com numeric, uma só vez, sobre o valor final: floor(x + 0,5)
--     (0,5 ou mais sobe; menos de 0,5 desce). Com o valor de partida inteiro, arredondar o valor
--     final ou a diferença dá o mesmo; o código arredonda uma vez só, sem passos intermediários.
--   - Percentual de -5000 a +5000 pb, diferente de 0. Tipo "valor" (centavos, diferente de 0) só
--     em componentes em centavos: nunca por_km nem pontos-base.
--   - Pontos-base (comissão e cancelamento percentual) só com inclui_pontos_base = true; a
--     comissão só pode ser listada com essa opção.
--   - UF: a lista ufs só alcança regras daquela UF; a regra NACIONAL (uf nula) só é reajustada
--     com inclui_nacional = true e, por ser nacional, vale para todas as UFs sem regra própria.
--   - Recusa (na solicitação e de novo na aprovação): escopo vazio (SC019), regra "a definir"
--     (SC013), regra futura agendada ou vigente que termina antes do início (SC021), resultado
--     negativo, zerado a partir de > 0 ou acima de 10000 pb (SC022) e, se nenhuma regra mudar
--     de valor, "nada a alterar" (SC022). Valor igual numa regra entra como nova versão.
--   - Direito adquirido: a regra antiga nunca é apagada (só encerrada) e continua consultável
--     por data (regra_taxa_vigente) e por id. O chamado (fase seguinte) guardará o id da regra
--     de cada componente e os valores usados na hora do pedido.
--
-- Códigos de erro novos:
--   SC019 escopo do reajuste vazio
--   SC020 lote de reajuste já decidido
--   SC021 regra futura agendada no escopo, ou regra vigente que termina antes do início
--   SC022 resultado inválido (negativo, zerado, acima de 10000 pb) ou nada a alterar

-- ---------------------------------------------------------------------
-- Utilitários
-- ---------------------------------------------------------------------

-- Arredonda ao centavo: 0,5 ou mais sobe; menos de 0,5 desce. Só numeric.
CREATE FUNCTION arredondar_centavos(p_valor numeric) RETURNS bigint
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_valor IS NULL THEN
    RAISE EXCEPTION 'valor a arredondar é obrigatório' USING ERRCODE = '22023';
  END IF;
  RETURN floor(p_valor + 0.5)::bigint;
END $$;

-- Operador ativo da Central (usuário ativo, perfil central, operador ativo).
CREATE FUNCTION exige_operador_ativo(p_ator uuid) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_ator IS NULL OR NOT EXISTS (
       SELECT 1 FROM operador_central o
         JOIN usuario u ON u.id = o.usuario_id AND u.status = 'ativo' AND u.perfil = 'central'
        WHERE o.usuario_id = p_ator AND o.ativo) THEN
    RAISE EXCEPTION 'ator % não é operador ativo da Central', p_ator USING ERRCODE = 'SC016';
  END IF;
END $$;

-- Parâmetros de um reajuste (22023 se inválidos).
CREATE FUNCTION reajuste_validar(p_tipo text, p_percentual_bp integer, p_valor_centavos bigint,
                                 p_tipos text[], p_servicos text[], p_ufs text[],
                                 p_inclui_nacional boolean, p_componentes text[],
                                 p_inclui_pontos_base boolean) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE v_invalido text;
BEGIN
  IF p_tipo IS NULL OR p_tipo NOT IN ('percentual','valor') THEN
    RAISE EXCEPTION 'tipo de reajuste inválido: %', p_tipo USING ERRCODE = '22023';
  END IF;
  IF p_inclui_nacional IS NULL OR p_inclui_pontos_base IS NULL THEN
    RAISE EXCEPTION 'inclui_nacional e inclui_pontos_base são obrigatórios' USING ERRCODE = '22023';
  END IF;
  IF p_tipo = 'percentual' THEN
    IF p_percentual_bp IS NULL OR p_percentual_bp = 0 OR p_percentual_bp NOT BETWEEN -5000 AND 5000
       OR p_valor_centavos IS NOT NULL THEN
      RAISE EXCEPTION 'reajuste percentual exige percentual_bp entre -5000 e 5000, diferente de 0, e sem valor_centavos'
        USING ERRCODE = '22023';
    END IF;
  ELSE
    IF p_valor_centavos IS NULL OR p_valor_centavos = 0 OR p_percentual_bp IS NOT NULL THEN
      RAISE EXCEPTION 'reajuste por valor exige valor_centavos diferente de 0, e sem percentual_bp'
        USING ERRCODE = '22023';
    END IF;
    IF p_componentes && ARRAY['por_km','comissao_plataforma'] OR p_inclui_pontos_base THEN
      RAISE EXCEPTION 'reajuste por valor só se aplica a componentes em centavos (nunca por_km nem pontos-base)'
        USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_componentes IS NULL OR cardinality(p_componentes) = 0
     OR NOT p_componentes <@ ARRAY['base','por_km','minimo','cancelamento','nao_comparecimento','comissao_plataforma'] THEN
    RAISE EXCEPTION 'componentes inválidos: %', p_componentes USING ERRCODE = '22023';
  END IF;
  IF 'comissao_plataforma' = ANY (p_componentes) AND NOT p_inclui_pontos_base THEN
    RAISE EXCEPTION 'a comissão (pontos-base) só entra com inclui_pontos_base = true' USING ERRCODE = '22023';
  END IF;
  IF p_tipos IS NOT NULL THEN
    SELECT string_agg(t, ', ') INTO v_invalido FROM unnest(p_tipos) t
     WHERE t IS NULL OR NOT EXISTS (SELECT 1 FROM tipo_parceiro WHERE codigo = t);
    IF cardinality(p_tipos) = 0 OR v_invalido IS NOT NULL THEN
      RAISE EXCEPTION 'tipos de parceiro inválidos: %', coalesce(v_invalido, '(lista vazia)') USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_servicos IS NOT NULL THEN
    SELECT string_agg(s, ', ') INTO v_invalido FROM unnest(p_servicos) s
     WHERE s IS NULL OR NOT EXISTS (SELECT 1 FROM servico_catalogo WHERE codigo = s);
    IF cardinality(p_servicos) = 0 OR v_invalido IS NOT NULL THEN
      RAISE EXCEPTION 'serviços inválidos: %', coalesce(v_invalido, '(lista vazia)') USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_ufs IS NOT NULL THEN
    SELECT string_agg(coalesce(u, 'nulo'), ', ') INTO v_invalido FROM unnest(p_ufs) u
     WHERE u IS NULL OR uf_codigo_ibge(u) IS NULL;
    IF v_invalido IS NOT NULL THEN
      RAISE EXCEPTION 'UFs inválidas: %', v_invalido USING ERRCODE = '22023';
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Lote de reajuste (somente inserção) e decisão (somente inserção, uma por lote)
-- ---------------------------------------------------------------------

CREATE TABLE reajuste_taxa (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo               text NOT NULL CHECK (tipo IN ('percentual','valor')),
  percentual_bp      integer CHECK (percentual_bp BETWEEN -5000 AND 5000 AND percentual_bp <> 0),
  valor_centavos     bigint  CHECK (valor_centavos <> 0),
  tipos_parceiro     text[],                       -- nulo = todos
  servicos           text[],                       -- nulo = todos
  ufs                text[],                       -- nulo = todas as regras estaduais
  inclui_nacional    boolean NOT NULL,             -- regra nacional vale para todas as UFs
  componentes        text[] NOT NULL,
  inclui_pontos_base boolean NOT NULL DEFAULT false,
  motivo             text NOT NULL CHECK (btrim(motivo) <> ''),
  indice_referencia  text,                         -- texto livre (ex.: "IPCA out/2026")
  inicio_solicitado  timestamptz,                  -- nulo = no momento da aprovação
  solicitado_por     uuid NOT NULL REFERENCES operador_central(usuario_id),
  solicitado_em      timestamptz NOT NULL DEFAULT clock_timestamp(),
  papel_bd           text NOT NULL DEFAULT session_user,
  CONSTRAINT ck_reajuste_tipo CHECK (
       (tipo = 'percentual' AND percentual_bp IS NOT NULL AND valor_centavos IS NULL)
    OR (tipo = 'valor'      AND valor_centavos IS NOT NULL AND percentual_bp IS NULL)),
  CONSTRAINT ck_reajuste_componentes CHECK (
    cardinality(componentes) > 0
    AND componentes <@ ARRAY['base','por_km','minimo','cancelamento','nao_comparecimento','comissao_plataforma']),
  -- Por valor: só componentes em centavos (por_km só no percentual).
  CONSTRAINT ck_reajuste_valor_so_centavos CHECK (
    tipo <> 'valor' OR (NOT componentes && ARRAY['por_km','comissao_plataforma'] AND NOT inclui_pontos_base)),
  CONSTRAINT ck_reajuste_comissao_explicita CHECK (NOT 'comissao_plataforma' = ANY (componentes) OR inclui_pontos_base)
);
-- Consulta prevista: "lotes de um operador" (acompanhamento na Central)
CREATE INDEX ix_reajuste_solicitado_por ON reajuste_taxa (solicitado_por, solicitado_em DESC);

CREATE FUNCTION reajuste_taxa_preparar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.solicitado_em := clock_timestamp();
  NEW.papel_bd := session_user;
  PERFORM reajuste_validar(NEW.tipo, NEW.percentual_bp, NEW.valor_centavos, NEW.tipos_parceiro,
                           NEW.servicos, NEW.ufs, NEW.inclui_nacional, NEW.componentes,
                           NEW.inclui_pontos_base);
  RETURN NEW;
END $$;
CREATE TRIGGER tg_reajuste_taxa_preparar BEFORE INSERT ON reajuste_taxa
  FOR EACH ROW EXECUTE FUNCTION reajuste_taxa_preparar();
CREATE TRIGGER tg_reajuste_taxa_sem_alteracao BEFORE UPDATE OR DELETE ON reajuste_taxa
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_reajuste_taxa_sem_truncate BEFORE TRUNCATE ON reajuste_taxa
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_reajuste_taxa_auditoria AFTER INSERT ON reajuste_taxa
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();

CREATE TABLE reajuste_taxa_decisao (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reajuste_id     uuid NOT NULL UNIQUE REFERENCES reajuste_taxa(id),
  situacao        text NOT NULL CHECK (situacao IN ('aprovado','rejeitado','cancelado')),
  decidido_por    uuid NOT NULL REFERENCES operador_central(usuario_id),
  decidido_em     timestamptz NOT NULL DEFAULT clock_timestamp(),
  motivo          text NOT NULL CHECK (btrim(motivo) <> ''),
  inicio_efetivo  timestamptz,
  regras_afetadas integer CHECK (regras_afetadas > 0),
  autoaprovacao   boolean NOT NULL DEFAULT false,
  papel_bd        text NOT NULL DEFAULT session_user,
  CONSTRAINT ck_decisao_aprovacao CHECK (
    (situacao = 'aprovado') = (inicio_efetivo IS NOT NULL)
    AND (situacao = 'aprovado') = (regras_afetadas IS NOT NULL)),
  CONSTRAINT ck_decisao_autoaprovacao CHECK (NOT autoaprovacao OR situacao = 'aprovado')
);

CREATE FUNCTION reajuste_decisao_preparar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.decidido_em := clock_timestamp();
  NEW.papel_bd := session_user;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_reajuste_decisao_preparar BEFORE INSERT ON reajuste_taxa_decisao
  FOR EACH ROW EXECUTE FUNCTION reajuste_decisao_preparar();
CREATE TRIGGER tg_reajuste_decisao_sem_alteracao BEFORE UPDATE OR DELETE ON reajuste_taxa_decisao
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_reajuste_decisao_sem_truncate BEFORE TRUNCATE ON reajuste_taxa_decisao
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_reajuste_decisao_auditoria AFTER INSERT ON reajuste_taxa_decisao
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();

-- Situação derivada: "solicitado" enquanto não há decisão.
CREATE VIEW vw_reajuste_taxa WITH (security_invoker = true) AS
SELECT r.*,
       coalesce(d.situacao, 'solicitado') AS situacao,
       d.decidido_por, d.decidido_em, d.motivo AS motivo_decisao,
       d.inicio_efetivo, d.regras_afetadas, d.autoaprovacao
  FROM reajuste_taxa r
  LEFT JOIN reajuste_taxa_decisao d ON d.reajuste_id = r.id;

-- ---------------------------------------------------------------------
-- Ligação das regras novas ao lote e à regra substituída
-- ---------------------------------------------------------------------

ALTER TABLE regra_taxa
  ADD COLUMN reajuste_id     uuid REFERENCES reajuste_taxa(id),
  ADD COLUMN regra_origem_id uuid REFERENCES regra_taxa(id),
  ADD CONSTRAINT ck_regra_taxa_reajuste CHECK ((reajuste_id IS NULL) = (regra_origem_id IS NULL));
-- Consulta prevista: "regras criadas pelo lote X"
CREATE INDEX ix_regra_taxa_reajuste ON regra_taxa (reajuste_id) WHERE reajuste_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- Cálculo (só leitura): regras do escopo e valor novo de cada uma
-- ---------------------------------------------------------------------

-- Escopo: regras vigentes em p_instante, ou futuras (para recusar com SC021), de tipo, serviço,
-- UF (ou nacional, com inclui_nacional) e componente pedidos; pontos-base só com a opção.
-- Regras anuladas (intervalo vazio) não entram.
CREATE FUNCTION reajuste_calculo(p_tipo text, p_percentual_bp integer, p_valor_centavos bigint,
                                 p_tipos text[], p_servicos text[], p_ufs text[],
                                 p_inclui_nacional boolean, p_componentes text[],
                                 p_inclui_pontos_base boolean,
                                 p_instante timestamptz, p_inicio timestamptz)
RETURNS TABLE (regra_id uuid, tipo_parceiro_codigo text, servico_codigo text, uf text,
               abrangencia text, componente text, unidade text, situacao text,
               inicio_vigencia timestamptz, fim_vigencia timestamptz,
               valor_atual bigint, valor_novo bigint, problema text)
LANGUAGE sql STABLE AS $$
  WITH alvo AS (
    SELECT r.*,
           CASE WHEN p_tipo = 'percentual'
                THEN arredondar_centavos(r.valor::numeric * (10000 + p_percentual_bp)::numeric / 10000)
                ELSE r.valor + p_valor_centavos
           END AS novo
      FROM regra_taxa r
     WHERE (p_tipos    IS NULL OR r.tipo_parceiro_codigo = ANY (p_tipos))
       AND (p_servicos IS NULL OR r.servico_codigo = ANY (p_servicos))
       AND ((r.uf IS NULL AND p_inclui_nacional)
            OR (r.uf IS NOT NULL AND (p_ufs IS NULL OR r.uf::text = ANY (p_ufs))))
       AND r.componente = ANY (p_componentes)
       AND (r.unidade <> 'pontos_base' OR p_inclui_pontos_base)
       AND NOT isempty(tstzrange(r.inicio_vigencia, r.fim_vigencia, '[)'))
       AND (tstzrange(r.inicio_vigencia, r.fim_vigencia, '[)') @> p_instante OR r.inicio_vigencia > p_instante)
  )
  SELECT a.id, a.tipo_parceiro_codigo, a.servico_codigo, a.uf::text,
         CASE WHEN a.uf IS NULL THEN 'nacional: vale para todas as UFs sem regra própria'
              ELSE 'UF ' || a.uf END,
         a.componente, a.unidade, a.situacao, a.inicio_vigencia, a.fim_vigencia,
         a.valor, a.novo,
         CASE
           WHEN a.situacao <> 'definido'                                   THEN 'a_definir'
           WHEN a.inicio_vigencia > p_instante                             THEN 'regra_futura'
           WHEN a.fim_vigencia IS NOT NULL AND a.fim_vigencia <= p_inicio  THEN 'termina_antes_do_inicio'
           WHEN a.novo < 0                                                 THEN 'negativo'
           WHEN a.valor > 0 AND a.novo = 0                                 THEN 'zeraria'
           WHEN a.unidade = 'pontos_base' AND a.novo > 10000               THEN 'acima_10000_pb'
           WHEN a.novo = a.valor                                           THEN 'sem_alteracao'
         END
    FROM alvo a
   ORDER BY a.tipo_parceiro_codigo, a.servico_codigo, a.uf NULLS FIRST, a.componente, a.inicio_vigencia
$$;

-- Recusa o reajuste se o escopo não puder ser aplicado; devolve quantas regras ganharão nova versão.
CREATE FUNCTION reajuste_exigir_aplicavel(p_tipo text, p_percentual_bp integer, p_valor_centavos bigint,
                                          p_tipos text[], p_servicos text[], p_ufs text[],
                                          p_inclui_nacional boolean, p_componentes text[],
                                          p_inclui_pontos_base boolean,
                                          p_instante timestamptz, p_inicio timestamptz) RETURNS integer
LANGUAGE plpgsql STABLE AS $$
DECLARE v_total int; v_a_definir int; v_vigencia int; v_resultado int; v_mudam int;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE c.problema = 'a_definir'),
         count(*) FILTER (WHERE c.problema IN ('regra_futura','termina_antes_do_inicio')),
         count(*) FILTER (WHERE c.problema IN ('negativo','zeraria','acima_10000_pb')),
         count(*) FILTER (WHERE c.problema IS NULL)
    INTO v_total, v_a_definir, v_vigencia, v_resultado, v_mudam
    FROM reajuste_calculo(p_tipo, p_percentual_bp, p_valor_centavos, p_tipos, p_servicos, p_ufs,
                          p_inclui_nacional, p_componentes, p_inclui_pontos_base,
                          p_instante, p_inicio) c;
  IF v_total = 0 THEN
    RAISE EXCEPTION 'escopo do reajuste vazio: nenhuma regra vigente corresponde' USING ERRCODE = 'SC019';
  END IF;
  IF v_a_definir > 0 THEN
    RAISE EXCEPTION '% regra(s) do escopo estão "a definir"; reajuste recusado', v_a_definir USING ERRCODE = 'SC013';
  END IF;
  IF v_vigencia > 0 THEN
    RAISE EXCEPTION '% regra(s) do escopo têm vigência futura agendada ou terminam antes do início; resolva e repita',
      v_vigencia USING ERRCODE = 'SC021';
  END IF;
  IF v_resultado > 0 THEN
    RAISE EXCEPTION '% regra(s) ficariam negativas, zeradas ou acima de 10000 pb; reajuste recusado', v_resultado
      USING ERRCODE = 'SC022';
  END IF;
  IF v_mudam = 0 THEN
    RAISE EXCEPTION 'nada a alterar: nenhuma regra do escopo muda de valor' USING ERRCODE = 'SC022';
  END IF;
  RETURN v_total;
END $$;

-- ---------------------------------------------------------------------
-- Funções da Central (SECURITY DEFINER; EXECUTE só para safetycar_central)
-- ---------------------------------------------------------------------

-- Simulação por parâmetros (antes de solicitar). Não grava nem recusa por problema de regra:
-- a coluna "problema" mostra o que a aprovação recusaria.
CREATE FUNCTION simular_reajuste_taxa(p_ator uuid, p_tipo text, p_percentual_bp integer,
                                      p_valor_centavos bigint, p_tipos text[], p_servicos text[],
                                      p_ufs text[], p_inclui_nacional boolean, p_componentes text[],
                                      p_inclui_pontos_base boolean, p_inicio timestamptz DEFAULT NULL)
RETURNS TABLE (regra_id uuid, tipo_parceiro_codigo text, servico_codigo text, uf text,
               abrangencia text, componente text, unidade text, situacao text,
               inicio_vigencia timestamptz, fim_vigencia timestamptz,
               valor_atual bigint, valor_novo bigint, problema text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_agora timestamptz;
BEGIN
  PERFORM exige_operador_ativo(p_ator);
  PERFORM reajuste_validar(p_tipo, p_percentual_bp, p_valor_centavos, p_tipos, p_servicos, p_ufs,
                           p_inclui_nacional, p_componentes, p_inclui_pontos_base);
  v_agora := clock_timestamp();
  IF p_inicio IS NOT NULL AND p_inicio < v_agora THEN
    RAISE EXCEPTION 'início do reajuste no passado: %', p_inicio USING ERRCODE = 'SC012';
  END IF;
  RETURN QUERY SELECT c.* FROM reajuste_calculo(p_tipo, p_percentual_bp, p_valor_centavos, p_tipos,
                                                p_servicos, p_ufs, p_inclui_nacional, p_componentes,
                                                p_inclui_pontos_base, v_agora, coalesce(p_inicio, v_agora)) c;
END $$;

-- Simulação de um lote já solicitado (com as regras de agora).
CREATE FUNCTION simular_reajuste_taxa(p_ator uuid, p_reajuste_id uuid)
RETURNS TABLE (regra_id uuid, tipo_parceiro_codigo text, servico_codigo text, uf text,
               abrangencia text, componente text, unidade text, situacao text,
               inicio_vigencia timestamptz, fim_vigencia timestamptz,
               valor_atual bigint, valor_novo bigint, problema text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_lote reajuste_taxa; v_agora timestamptz;
BEGIN
  PERFORM exige_operador_ativo(p_ator);
  SELECT * INTO v_lote FROM reajuste_taxa WHERE id = p_reajuste_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reajuste inexistente: %', p_reajuste_id USING ERRCODE = '22023';
  END IF;
  v_agora := clock_timestamp();
  RETURN QUERY SELECT c.* FROM reajuste_calculo(v_lote.tipo, v_lote.percentual_bp, v_lote.valor_centavos,
                                                v_lote.tipos_parceiro, v_lote.servicos, v_lote.ufs,
                                                v_lote.inclui_nacional, v_lote.componentes,
                                                v_lote.inclui_pontos_base, v_agora,
                                                greatest(coalesce(v_lote.inicio_solicitado, v_agora), v_agora)) c;
END $$;

-- Solicitação: qualquer operador ativo. Não toca em nenhuma regra; recusa cedo o que a
-- aprovação recusaria (a aprovação refaz todas as checagens).
CREATE FUNCTION solicitar_reajuste_taxa(p_ator uuid, p_tipo text, p_percentual_bp integer,
                                        p_valor_centavos bigint, p_tipos text[], p_servicos text[],
                                        p_ufs text[], p_inclui_nacional boolean, p_componentes text[],
                                        p_inclui_pontos_base boolean, p_motivo text,
                                        p_indice_referencia text DEFAULT NULL,
                                        p_inicio timestamptz DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_id uuid;
  v_agora timestamptz;
  v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_operador_ativo(p_ator);
  PERFORM reajuste_validar(p_tipo, p_percentual_bp, p_valor_centavos, p_tipos, p_servicos, p_ufs,
                           p_inclui_nacional, p_componentes, p_inclui_pontos_base);
  v_agora := clock_timestamp();
  IF p_inicio IS NOT NULL AND p_inicio < v_agora THEN
    RAISE EXCEPTION 'início do reajuste no passado: %', p_inicio USING ERRCODE = 'SC012';
  END IF;
  PERFORM reajuste_exigir_aplicavel(p_tipo, p_percentual_bp, p_valor_centavos, p_tipos, p_servicos, p_ufs,
                                    p_inclui_nacional, p_componentes, p_inclui_pontos_base,
                                    v_agora, coalesce(p_inicio, v_agora));

  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO reajuste_taxa (tipo, percentual_bp, valor_centavos, tipos_parceiro, servicos, ufs,
                             inclui_nacional, componentes, inclui_pontos_base, motivo,
                             indice_referencia, inicio_solicitado, solicitado_por)
  VALUES (p_tipo, p_percentual_bp, p_valor_centavos, p_tipos, p_servicos, p_ufs,
          p_inclui_nacional, p_componentes, p_inclui_pontos_base, p_motivo,
          p_indice_referencia, p_inicio, p_ator)
  RETURNING id INTO v_id;
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_id;
END $$;

-- Aprovação: quem tem aprovar_reajuste_taxa. Numa só transação, encerra as regras antigas no
-- início e cria as novas. Devolve quantas regras ganharam nova versão.
CREATE FUNCTION aprovar_reajuste_taxa(p_ator uuid, p_reajuste_id uuid, p_motivo text,
                                      p_inicio timestamptz DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_lote reajuste_taxa;
  v_auto boolean;
  v_agora timestamptz;
  v_inicio timestamptz;
  v_n integer := 0;
  c record;
  v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'aprovar_reajuste_taxa');

  -- 1) Serializa as aprovações de reajuste de taxa (chave fixa 150001 = migração 0015).
  PERFORM pg_advisory_xact_lock(150001);

  -- 2) Trava o lote e confere a situação.
  SELECT * INTO v_lote FROM reajuste_taxa WHERE id = p_reajuste_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reajuste inexistente: %', p_reajuste_id USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM reajuste_taxa_decisao WHERE reajuste_id = v_lote.id) THEN
    RAISE EXCEPTION 'reajuste % já foi decidido', v_lote.id USING ERRCODE = 'SC020';
  END IF;

  -- 3) Quem solicita não aprova o próprio pedido (salvo exceção configurada).
  v_auto := (v_lote.solicitado_por = p_ator);
  IF v_auto AND NOT (SELECT permite_autoaprovacao FROM permissao_central WHERE codigo = 'aprovar_reajuste_taxa') THEN
    RAISE EXCEPTION 'quem solicitou o reajuste não pode aprová-lo' USING ERRCODE = 'SC017';
  END IF;

  -- 4) Trava as regras do escopo (FOR UPDATE, em ordem de id). Repetido com o relógio lido
  --    depois do primeiro lock, para cobrir regra que tenha começado nesse intervalo.
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

  -- 5) Início: o informado, o solicitado ou agora (relógio lido depois dos locks); nunca no passado.
  v_inicio := coalesce(p_inicio, v_lote.inicio_solicitado, v_agora);
  IF v_inicio < v_agora THEN
    RAISE EXCEPTION 'início do reajuste no passado: %', v_inicio USING ERRCODE = 'SC012';
  END IF;

  -- 6) Todas as checagens antes de qualquer escrita.
  PERFORM reajuste_exigir_aplicavel(v_lote.tipo, v_lote.percentual_bp, v_lote.valor_centavos,
                                    v_lote.tipos_parceiro, v_lote.servicos, v_lote.ufs,
                                    v_lote.inclui_nacional, v_lote.componentes,
                                    v_lote.inclui_pontos_base, v_agora, v_inicio);

  -- 7) Escrita: encerra a antiga no início e cria a nova no mesmo instante ([início, fim) contíguos).
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  FOR c IN SELECT * FROM reajuste_calculo(v_lote.tipo, v_lote.percentual_bp, v_lote.valor_centavos,
                                          v_lote.tipos_parceiro, v_lote.servicos, v_lote.ufs,
                                          v_lote.inclui_nacional, v_lote.componentes,
                                          v_lote.inclui_pontos_base, v_agora, v_inicio)
  LOOP
    UPDATE regra_taxa SET fim_vigencia = v_inicio WHERE id = c.regra_id;
    INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor,
                            base_distancia, situacao, observacao, inicio_vigencia, fim_vigencia,
                            reajuste_id, regra_origem_id)
    SELECT r.tipo_parceiro_codigo, r.servico_codigo, r.uf, r.componente, r.unidade, c.valor_novo,
           r.base_distancia, 'definido', format('Reajuste %s', v_lote.id), v_inicio, c.fim_vigencia,
           v_lote.id, r.id
      FROM regra_taxa r WHERE r.id = c.regra_id;
    v_n := v_n + 1;
  END LOOP;

  INSERT INTO reajuste_taxa_decisao (reajuste_id, situacao, decidido_por, motivo, inicio_efetivo,
                                     regras_afetadas, autoaprovacao)
  VALUES (v_lote.id, 'aprovado', p_ator, p_motivo, v_inicio, v_n, v_auto);
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_n;
END $$;

-- Rejeição: quem tem aprovar_reajuste_taxa. Não altera nenhuma regra.
CREATE FUNCTION rejeitar_reajuste_taxa(p_ator uuid, p_reajuste_id uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'aprovar_reajuste_taxa');
  PERFORM 1 FROM reajuste_taxa WHERE id = p_reajuste_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'reajuste inexistente: %', p_reajuste_id USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM reajuste_taxa_decisao WHERE reajuste_id = p_reajuste_id) THEN
    RAISE EXCEPTION 'reajuste % já foi decidido', p_reajuste_id USING ERRCODE = 'SC020';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO reajuste_taxa_decisao (reajuste_id, situacao, decidido_por, motivo)
  VALUES (p_reajuste_id, 'rejeitado', p_ator, p_motivo);
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

-- Cancelamento: o próprio solicitante (se ativo) ou quem tem aprovar_reajuste_taxa.
CREATE FUNCTION cancelar_reajuste_taxa(p_ator uuid, p_reajuste_id uuid, p_motivo text) RETURNS void
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
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

-- ---------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION
  arredondar_centavos(numeric),
  exige_operador_ativo(uuid),
  reajuste_validar(text, integer, bigint, text[], text[], text[], boolean, text[], boolean),
  reajuste_calculo(text, integer, bigint, text[], text[], text[], boolean, text[], boolean, timestamptz, timestamptz),
  reajuste_exigir_aplicavel(text, integer, bigint, text[], text[], text[], boolean, text[], boolean, timestamptz, timestamptz),
  simular_reajuste_taxa(uuid, text, integer, bigint, text[], text[], text[], boolean, text[], boolean, timestamptz),
  simular_reajuste_taxa(uuid, uuid),
  solicitar_reajuste_taxa(uuid, text, integer, bigint, text[], text[], text[], boolean, text[], boolean, text, text, timestamptz),
  aprovar_reajuste_taxa(uuid, uuid, text, timestamptz),
  rejeitar_reajuste_taxa(uuid, uuid, text),
  cancelar_reajuste_taxa(uuid, uuid, text)
FROM PUBLIC;

-- Central: age só pelas funções; lê as regras e os lotes.
GRANT SELECT ON regra_taxa, reajuste_taxa, reajuste_taxa_decisao, vw_reajuste_taxa TO safetycar_central;
GRANT EXECUTE ON FUNCTION
  simular_reajuste_taxa(uuid, text, integer, bigint, text[], text[], text[], boolean, text[], boolean, timestamptz),
  simular_reajuste_taxa(uuid, uuid),
  solicitar_reajuste_taxa(uuid, text, integer, bigint, text[], text[], text[], boolean, text[], boolean, text, text, timestamptz),
  aprovar_reajuste_taxa(uuid, uuid, text, timestamptz),
  rejeitar_reajuste_taxa(uuid, uuid, text),
  cancelar_reajuste_taxa(uuid, uuid, text)
TO safetycar_central;

-- App: nada novo. Continua só lendo regra_taxa (inclusive as regras criadas por reajuste) e
-- não acessa os lotes, que identificam operadores.
