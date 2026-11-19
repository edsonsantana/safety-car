-- 0012 — Política de alteração da parametrização e carga inicial.
--
-- Política (decidida nesta fase):
--   - O safetycar_app SÓ LÊ as tabelas de parametrização (GRANTs nas 0009 a 0011; conferido abaixo).
--   - Alterações só por MIGRAÇÃO revisada no Git, aplicada pelo safetycar_migrator. Um papel
--     administrativo (backoffice) fica para quando existir; criá-lo exige CREATEROLE, que o
--     migrator não tem.
--   - Toda alteração vai para a auditoria (trigger auditar_parametrizacao, papel em papel_bd).
--     Numa migração, para registrar a pessoa responsável:
--       SET LOCAL safetycar.ator_usuario_id = '<uuid do usuário central>';
--
-- Carga: NENHUM valor de negócio é decidido aqui. Tudo entra como situacao = 'a_definir'
-- (valores zerados), e as funções de consulta recusam com SC013. Os requisitos por nível são
-- uma PROPOSTA (também a_definir), registrada como tal em observacao.

-- ---------------------------------------------------------------------
-- Conferência: o app não escreve em nenhuma tabela de parametrização
-- ---------------------------------------------------------------------

REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON
  nivel_verificacao, requisito_verificacao, nivel_requisito, servico_nivel_minimo,
  regra_taxa, politica_garantia, provedor_pagamento,
  tipo_parceiro, servico_catalogo
FROM safetycar_app, PUBLIC;

DO $$
DECLARE v_tabela text;
BEGIN
  FOREACH v_tabela IN ARRAY ARRAY['nivel_verificacao','requisito_verificacao','nivel_requisito',
                                  'servico_nivel_minimo','regra_taxa','politica_garantia',
                                  'provedor_pagamento','tipo_parceiro','servico_catalogo'] LOOP
    IF NOT has_table_privilege('safetycar_app', v_tabela, 'SELECT') THEN
      RAISE EXCEPTION '0012: safetycar_app deveria ler %', v_tabela;
    END IF;
    IF has_table_privilege('safetycar_app', v_tabela, 'INSERT, UPDATE, DELETE, TRUNCATE') THEN
      RAISE EXCEPTION '0012: safetycar_app não pode escrever em %', v_tabela;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------
-- Requisitos por nível: PROPOSTA, a_definir
-- ---------------------------------------------------------------------

INSERT INTO nivel_requisito (perfil, requisito_codigo, nivel, situacao, observacao) VALUES
  -- Tomador (2FA não é requisito: é incentivado)
  ('tomador',  'email',                   1, 'a_definir', 'PROPOSTA (0012): e-mail verificado'),
  ('tomador',  'celular',                 1, 'a_definir', 'PROPOSTA (0012): celular verificado'),
  ('tomador',  'documento_foto',          2, 'a_definir', 'PROPOSTA (0012): documento com foto conferido com o CPF'),
  ('tomador',  'selfie',                  2, 'a_definir', 'PROPOSTA (0012): selfie conferida com o documento e o CPF'),
  ('tomador',  'meio_pagamento_garantia', 3, 'a_definir', 'PROPOSTA (0012): meio de pagamento válido para a garantia'),
  -- Parceiro
  ('parceiro', 'email',                   1, 'a_definir', 'PROPOSTA (0012): e-mail verificado'),
  ('parceiro', 'celular',                 1, 'a_definir', 'PROPOSTA (0012): celular verificado'),
  ('parceiro', 'mfa',                     1, 'a_definir', 'PROPOSTA (0012): 2FA obrigatório para parceiro, a confirmar com o Adailton'),
  ('parceiro', 'documento_foto',          2, 'a_definir', 'PROPOSTA (0012): documento com foto do responsável'),
  ('parceiro', 'selfie',                  2, 'a_definir', 'PROPOSTA (0012): selfie do responsável'),
  ('parceiro', 'documentos_parceiro',     3, 'a_definir', 'PROPOSTA (0012): documentos exigidos pelo tipo aprovados'),
  ('parceiro', 'conta_recebimento',       3, 'a_definir', 'PROPOSTA (0012): conta de recebimento aprovada');

-- ---------------------------------------------------------------------
-- Nível mínimo por serviço e perfil: a_definir (sem nível)
-- ---------------------------------------------------------------------

INSERT INTO servico_nivel_minimo (servico_codigo, perfil, nivel_minimo, situacao, observacao)
SELECT s.codigo, p.perfil, NULL, 'a_definir', 'A DEFINIR (carga 0012)'
  FROM servico_catalogo s
 CROSS JOIN (VALUES ('tomador'), ('parceiro')) AS p(perfil);

-- ---------------------------------------------------------------------
-- Regras de taxa: nacionais, a_definir, valor 0, nas combinações aprovadas de tipo e serviço
-- ---------------------------------------------------------------------

CREATE TEMP TABLE carga_tipo_servico (tipo text, servico text) ON COMMIT DROP;
INSERT INTO carga_tipo_servico VALUES
  ('guincho',  'guincho_leve'),
  ('guincho',  'guincho_pesado'),
  ('mecanica', 'mecanica_movel'),
  ('mecanica', 'bateria'),
  ('mecanica', 'pneu'),
  ('mecanica', 'combustivel'),
  ('chaveiro', 'chaveiro');

-- As combinações só valem se os códigos existirem nos catálogos.
DO $$
DECLARE v_faltando text;
BEGIN
  SELECT string_agg(c.tipo || '/' || c.servico, ', ') INTO v_faltando
    FROM carga_tipo_servico c
   WHERE NOT EXISTS (SELECT 1 FROM tipo_parceiro    WHERE codigo = c.tipo)
      OR NOT EXISTS (SELECT 1 FROM servico_catalogo WHERE codigo = c.servico);
  IF v_faltando IS NOT NULL THEN
    RAISE EXCEPTION '0012: combinações com código inexistente no catálogo: %', v_faltando;
  END IF;
END $$;

INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor,
                        situacao, observacao)
SELECT c.tipo, c.servico, NULL, k.componente, k.unidade, 0, 'a_definir', k.observacao
  FROM carga_tipo_servico c
 CROSS JOIN (VALUES
   ('base',                'centavos',        'A DEFINIR (carga 0012)'),
   ('por_km',              'centavos_por_km', 'A DEFINIR (carga 0012); base_distancia padrão linha_reta'),
   ('minimo',              'centavos',        'A DEFINIR (carga 0012)'),
   ('cancelamento',        'centavos',        'A DEFINIR (carga 0012); unidade também a definir (centavos ou pontos-base)'),
   ('nao_comparecimento',  'centavos',        'A DEFINIR (carga 0012)'),
   ('comissao_plataforma', 'pontos_base',     'A DEFINIR (carga 0012)')
 ) AS k(componente, unidade, observacao);

-- ---------------------------------------------------------------------
-- Política de garantia: todos os serviços x níveis x modalidades, a_definir, valor 0
-- ---------------------------------------------------------------------

INSERT INTO politica_garantia (servico_codigo, nivel_verificacao, modalidade, calculo,
                               valor_centavos, percentual_bp, situacao, observacao)
SELECT s.codigo, n.nivel, m.modalidade, 'valor_fixo', 0, NULL, 'a_definir',
       'A DEFINIR (carga 0012); cálculo (fixo ou percentual) também a definir'
  FROM servico_catalogo s
 CROSS JOIN nivel_verificacao n
 CROSS JOIN (VALUES ('pre_autorizacao_cartao'), ('pix_pre_pago')) AS m(modalidade);

-- ---------------------------------------------------------------------
-- Provedores de pagamento: nenhum (processador ainda não escolhido)
-- ---------------------------------------------------------------------
