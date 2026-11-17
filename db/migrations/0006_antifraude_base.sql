-- 0006 — Antifraude base: meios de pagamento tokenizados, dispositivos, sinais de risco e bloqueios.
--
-- NUNCA armazenar número de cartão (PAN), CVV ou validade: só o token do processador (PSP)
-- e dados não sensíveis (bandeira, últimos 4 dígitos).
-- Todos os *_hash são HMAC-SHA256 calculados pela APLICAÇÃO com a mesma chave usada em
-- cpf_hash (fora do repositório), sobre o valor normalizado:
--   cpf_hash: 11 dígitos | email: minúsculas, sem espaços | celular: E.164
--   dispositivo: fingerprint do cliente | cartao_fingerprint: fingerprint do cartão fornecido pelo PSP
-- Assim, um CPF bloqueado em `bloqueio` bate com tomador.cpf_hash / parceiro.cpf_hash.
--
-- Fora desta fase (dependem do chamado): garantia/pré-autorização, taxas, evidências, disputa, repasse.

-- ---------------------------------------------------------------------
-- Meio de pagamento (por enquanto, cartão tokenizado; Pix depende da decisão sobre garantia)
-- ---------------------------------------------------------------------

CREATE TABLE meio_pagamento (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id              uuid NOT NULL REFERENCES usuario(id),
  psp                     text NOT NULL,   -- processador ainda não escolhido: texto livre
  token_psp               text NOT NULL,
  bandeira                text NOT NULL
                          CHECK (bandeira IN ('visa','mastercard','elo','amex','hipercard','outra')),
  final_4                 char(4) NOT NULL CHECK (final_4 ~ '^[0-9]{4}$'),
  cartao_fingerprint_hash dom_hmac,
  status                  text NOT NULL DEFAULT 'ativo'
                          CHECK (status IN ('ativo','inativo','bloqueado')),
  criado_em               timestamptz NOT NULL DEFAULT now(),
  atualizado_em           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_meio_pagamento_token UNIQUE (psp, token_psp)
);
-- Consulta prevista: "meios de pagamento do usuário X"
CREATE INDEX ix_meio_pagamento_usuario ON meio_pagamento (usuario_id);
-- Consulta prevista: "o mesmo cartão em várias contas?"
CREATE INDEX ix_meio_pagamento_fingerprint ON meio_pagamento (cartao_fingerprint_hash)
  WHERE cartao_fingerprint_hash IS NOT NULL;
CREATE TRIGGER tg_meio_pagamento_atualizado_em BEFORE UPDATE ON meio_pagamento
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();

-- ---------------------------------------------------------------------
-- Dispositivo
-- ---------------------------------------------------------------------

CREATE TABLE dispositivo (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id        uuid NOT NULL REFERENCES usuario(id),
  fingerprint_hash  dom_hmac NOT NULL,
  primeiro_visto_em timestamptz NOT NULL DEFAULT now(),
  ultimo_visto_em   timestamptz NOT NULL DEFAULT now(),
  status            text NOT NULL DEFAULT 'ativo'
                    CHECK (status IN ('ativo','suspeito','bloqueado')),
  atualizado_em     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_dispositivo_visto CHECK (ultimo_visto_em >= primeiro_visto_em),
  -- Também serve de índice para "dispositivos do usuário X".
  CONSTRAINT uq_dispositivo_usuario_fingerprint UNIQUE (usuario_id, fingerprint_hash)
);
-- Consulta prevista: "o mesmo aparelho em várias contas?"
CREATE INDEX ix_dispositivo_fingerprint ON dispositivo (fingerprint_hash);
CREATE TRIGGER tg_dispositivo_atualizado_em BEFORE UPDATE ON dispositivo
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();

-- ---------------------------------------------------------------------
-- Sinal de risco (registro de evento; não é alterado depois de criado)
-- ---------------------------------------------------------------------

CREATE TABLE sinal_risco (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id     uuid REFERENCES usuario(id),
  dispositivo_id uuid REFERENCES dispositivo(id),
  tipo           text NOT NULL
                 CHECK (tipo IN ('multiplas_contas_dispositivo','dado_em_bloqueio','cartao_recusado',
                        'localizacao_inconsistente','cadastro_acelerado','outro')),
  severidade     text NOT NULL CHECK (severidade IN ('baixa','media','alta','critica')),
  detalhes       jsonb NOT NULL DEFAULT '{}'::jsonb,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_sinal_alvo CHECK (usuario_id IS NOT NULL OR dispositivo_id IS NOT NULL)
);
-- Consulta prevista: "sinais recentes do usuário X" (análise de risco antes de liberar serviço)
CREATE INDEX ix_sinal_risco_usuario ON sinal_risco (usuario_id, criado_em DESC);

-- ---------------------------------------------------------------------
-- Bloqueio (lista de bloqueio por hash). expira_em nulo = permanente.
-- Para encerrar um bloqueio, define-se expira_em = now() (o histórico fica).
-- ---------------------------------------------------------------------

CREATE TABLE bloqueio (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo        text NOT NULL
              CHECK (tipo IN ('cpf_hash','dispositivo','celular','cartao_fingerprint','email')),
  valor_hash  dom_hmac NOT NULL,
  motivo      text NOT NULL,
  criado_por  uuid NOT NULL REFERENCES usuario(id),
  criado_em   timestamptz NOT NULL DEFAULT now(),
  expira_em   timestamptz,
  CONSTRAINT ck_bloqueio_expiracao CHECK (expira_em IS NULL OR expira_em > criado_em)
);
-- Consulta prevista: "este hash está bloqueado?" (a cada cadastro, login e pedido)
CREATE INDEX ix_bloqueio_tipo_valor ON bloqueio (tipo, valor_hash);
CREATE TRIGGER tg_bloqueio_criado_por_central BEFORE INSERT OR UPDATE OF criado_por ON bloqueio
  FOR EACH ROW EXECUTE FUNCTION exige_perfil('central', 'criado_por');

CREATE FUNCTION esta_bloqueado(p_tipo text, p_valor_hash bytea) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM bloqueio
                  WHERE tipo = p_tipo AND valor_hash = p_valor_hash
                    AND (expira_em IS NULL OR expira_em > now()))
$$;
COMMENT ON FUNCTION esta_bloqueado(text, bytea) IS
  'Verdadeiro se houver bloqueio vigente (sem expiração ou expiração futura) para o tipo e hash.';
