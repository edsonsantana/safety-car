-- 0010 — Regras de taxa: componentes por tipo de parceiro, serviço e UF, com vigência.
--
-- - Valores sempre inteiros (bigint): centavos, centavos por km ou pontos-base (1 pb = 0,01%). Nunca float.
-- - Vigência [inicio, fim) sem sobreposição por escopo (restrição de exclusão; requer btree_gist).
-- - Regra é imutável: só fim_vigencia pode ser definido (sem retroagir). Mudança = nova linha.
-- - UF nula = regra nacional; a regra da UF prevalece sobre a nacional.
-- - "a_definir" tem valor 0 e é recusado pela consulta (SC013): nunca é tratado como zero.
-- - Fora desta fase: trechos de rodovia, motor de rotas, integração com Google/Waze. base_distancia
--   só registra QUAL distância a regra usará (padrão linha_reta, a geodésica já calculada no banco).
--
-- Código de erro novo:
--   SC012 regra com vigência é imutável (só o fim pode ser definido; sem retroagir; sem exclusão)

-- btree_gist: contrib do PostgreSQL, "trusted" (o dono do banco cria sem superusuário). Permite
-- igualdade de texto dentro da restrição de exclusão GiST junto com a sobreposição de intervalos.
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- ---------------------------------------------------------------------
-- Imutabilidade de regras com vigência (reutilizada na 0011)
-- Exige colunas inicio_vigencia e fim_vigencia (e opcionalmente atualizado_em).
-- ---------------------------------------------------------------------

CREATE FUNCTION vigencia_imutavel() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_old_fim timestamptz;
  v_new_fim timestamptz;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Regra nova não retroage (mudaria o que já foi cobrado). now() = início da transação.
    IF (to_jsonb(NEW) ->> 'inicio_vigencia')::timestamptz < now() THEN
      RAISE EXCEPTION '%: início de vigência no passado não é permitido', TG_TABLE_NAME
        USING ERRCODE = 'SC012';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION '%: regra não é excluída; encerre a vigência (fim_vigencia)', TG_TABLE_NAME
      USING ERRCODE = 'SC012';
  END IF;

  -- UPDATE: nada além de fim_vigencia (e atualizado_em, mantido por trigger) pode mudar.
  IF (to_jsonb(NEW) - 'fim_vigencia' - 'atualizado_em') <> (to_jsonb(OLD) - 'fim_vigencia' - 'atualizado_em') THEN
    RAISE EXCEPTION '%: regra é imutável; só fim_vigencia pode ser definido (mudança = nova linha)', TG_TABLE_NAME
      USING ERRCODE = 'SC012';
  END IF;

  v_old_fim := (to_jsonb(OLD) ->> 'fim_vigencia')::timestamptz;
  v_new_fim := (to_jsonb(NEW) ->> 'fim_vigencia')::timestamptz;
  IF v_new_fim IS NOT DISTINCT FROM v_old_fim THEN
    RETURN NEW;
  END IF;
  IF v_old_fim IS NOT NULL AND v_old_fim <= now() THEN
    RAISE EXCEPTION '%: regra já encerrada não pode ser alterada', TG_TABLE_NAME USING ERRCODE = 'SC012';
  END IF;
  IF v_new_fim IS NULL THEN
    RAISE EXCEPTION '%: fim de vigência não pode ser removido', TG_TABLE_NAME USING ERRCODE = 'SC012';
  END IF;
  -- Sem retroagir. Regra futura pode ser anulada com fim = início (intervalo vazio, nunca vigente).
  IF v_new_fim < now() THEN
    RAISE EXCEPTION '%: fim de vigência no passado não é permitido', TG_TABLE_NAME USING ERRCODE = 'SC012';
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- Regra de taxa
-- ---------------------------------------------------------------------

CREATE TABLE regra_taxa (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo_parceiro_codigo text NOT NULL REFERENCES tipo_parceiro(codigo),
  servico_codigo       text NOT NULL REFERENCES servico_catalogo(codigo),
  uf                   dom_uf,                 -- nulo = nacional
  componente           text NOT NULL
                       CHECK (componente IN ('base','por_km','minimo','cancelamento',
                                             'nao_comparecimento','comissao_plataforma')),
  unidade              text NOT NULL CHECK (unidade IN ('centavos','centavos_por_km','pontos_base')),
  valor                bigint NOT NULL CHECK (valor >= 0),
  base_distancia       text CHECK (base_distancia IN ('linha_reta','rodoviaria_snv','rodoviaria_osm','provedor_externo')),
  situacao             text NOT NULL DEFAULT 'a_definir' CHECK (situacao IN ('a_definir','definido')),
  observacao           text,
  inicio_vigencia      timestamptz NOT NULL DEFAULT now(),
  fim_vigencia         timestamptz,
  criado_em            timestamptz NOT NULL DEFAULT now(),
  atualizado_em        timestamptz NOT NULL DEFAULT now(),

  -- Unidade fixa por componente.
  CONSTRAINT ck_regra_taxa_unidade CHECK (
       (componente IN ('base','minimo','nao_comparecimento') AND unidade = 'centavos')
    OR (componente = 'por_km'              AND unidade = 'centavos_por_km')
    OR (componente = 'cancelamento'        AND unidade IN ('centavos','pontos_base'))
    OR (componente = 'comissao_plataforma' AND unidade = 'pontos_base')),
  -- Pontos-base: até 10000 (100%).
  CONSTRAINT ck_regra_taxa_pontos_base CHECK (unidade <> 'pontos_base' OR valor <= 10000),
  -- base_distancia só (e sempre) no componente por km; o trigger preenche linha_reta se vier vazia.
  CONSTRAINT ck_regra_taxa_base_distancia CHECK ((componente = 'por_km') = (base_distancia IS NOT NULL)),
  -- "a definir" não carrega valor: fica zerado e marcado.
  CONSTRAINT ck_regra_taxa_a_definir CHECK (situacao = 'definido' OR valor = 0),
  -- fim = início é permitido: anula uma regra futura (intervalo vazio).
  CONSTRAINT ck_regra_taxa_vigencia CHECK (fim_vigencia IS NULL OR fim_vigencia >= inicio_vigencia),
  -- Uma regra por escopo e componente em cada instante.
  CONSTRAINT ex_regra_taxa_vigencia EXCLUDE USING gist (
    tipo_parceiro_codigo WITH =,
    servico_codigo WITH =,
    (coalesce(uf::text, '*')) WITH =,
    componente WITH =,
    tstzrange(inicio_vigencia, fim_vigencia, '[)') WITH &&)
);
-- A restrição de exclusão também atende a consulta da regra vigente (mesmas colunas, GiST).

CREATE FUNCTION regra_taxa_padrao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.componente = 'por_km' AND NEW.base_distancia IS NULL THEN
    NEW.base_distancia := 'linha_reta';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_regra_taxa_padrao BEFORE INSERT ON regra_taxa
  FOR EACH ROW EXECUTE FUNCTION regra_taxa_padrao();
CREATE TRIGGER tg_regra_taxa_imutavel BEFORE INSERT OR UPDATE OR DELETE ON regra_taxa
  FOR EACH ROW EXECUTE FUNCTION vigencia_imutavel();
CREATE TRIGGER tg_regra_taxa_atualizado_em BEFORE UPDATE ON regra_taxa
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_regra_taxa_auditoria AFTER INSERT OR UPDATE OR DELETE ON regra_taxa
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_regra_taxa_sem_truncate BEFORE TRUNCATE ON regra_taxa
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

-- Regra vigente de um componente no instante dado: a da UF, se existir; senão, a nacional.
-- Recusa (SC013) se não houver regra ou se a regra aplicável estiver "a definir" — mesmo que
-- exista uma nacional definida (a da UF prevalece e não está decidida). Nunca devolve "a definir".
CREATE FUNCTION regra_taxa_vigente(p_tipo text, p_servico text, p_uf text, p_componente text,
                                   p_instante timestamptz DEFAULT now())
RETURNS regra_taxa
LANGUAGE plpgsql STABLE AS $$
DECLARE v_regra regra_taxa;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM tipo_parceiro WHERE codigo = p_tipo) THEN
    RAISE EXCEPTION 'tipo de parceiro inexistente: %', p_tipo USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM servico_catalogo WHERE codigo = p_servico) THEN
    RAISE EXCEPTION 'serviço inexistente: %', p_servico USING ERRCODE = '22023';
  END IF;
  IF p_componente IS NULL OR p_componente NOT IN ('base','por_km','minimo','cancelamento',
                                                  'nao_comparecimento','comissao_plataforma') THEN
    RAISE EXCEPTION 'componente inválido: %', p_componente USING ERRCODE = '22023';
  END IF;
  IF p_instante IS NULL THEN
    RAISE EXCEPTION 'instante é obrigatório' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_regra
    FROM regra_taxa
   WHERE tipo_parceiro_codigo = p_tipo
     AND servico_codigo = p_servico
     AND componente = p_componente
     AND (uf IS NULL OR uf = p_uf)
     AND tstzrange(inicio_vigencia, fim_vigencia, '[)') @> p_instante
   ORDER BY (uf IS NULL)          -- UF específica primeiro
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sem regra de taxa vigente para %/%/%/% em %',
      p_tipo, p_servico, coalesce(p_uf, 'nacional'), p_componente, p_instante USING ERRCODE = 'SC013';
  END IF;
  IF v_regra.situacao <> 'definido' THEN
    RAISE EXCEPTION 'regra de taxa %/%/%/% está a definir',
      p_tipo, p_servico, coalesce(v_regra.uf, 'nacional'), p_componente USING ERRCODE = 'SC013';
  END IF;
  RETURN v_regra;
END $$;

-- ---------------------------------------------------------------------
-- Privilégios do safetycar_app: só leitura (alterações só por migração; ver 0012)
-- ---------------------------------------------------------------------

GRANT SELECT ON regra_taxa TO safetycar_app;
GRANT EXECUTE ON FUNCTION regra_taxa_vigente(text, text, text, text, timestamptz) TO safetycar_app;
