-- 22 — Parâmetros de negócio (0018), como safetycar_migrator.
-- Usuários FICTÍCIOS: A administrador; M e N com administrar_parametros; X operador sem permissão.
-- O arquivo roda numa só transação: now() é o início dela, e cada troca de valor começa em
-- clock_timestamp(). Por isso as consultas depois das trocas passam o instante explícito.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d2a01', gen_random_uuid(), 'par-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d2a02', gen_random_uuid(), 'par-m@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d2a03', gen_random_uuid(), 'par-n@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d2a05', gen_random_uuid(), 'par-x@exemplo.invalid', 'central', 'ativo');

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $f$
  SELECT ('00000000-0000-4000-8000-0000000d2a0' ||
          CASE p WHEN 'A' THEN '1' WHEN 'M' THEN '2' WHEN 'N' THEN '3' ELSE '5' END)::uuid
$f$;
CREATE TEMP TABLE v (k text PRIMARY KEY, id uuid);
CREATE FUNCTION pg_temp.id(p text) RETURNS uuid LANGUAGE sql STABLE AS $f$ SELECT id FROM v WHERE k = p $f$;
CREATE FUNCTION pg_temp.agora(p text) RETURNS numeric LANGUAGE sql AS $f$
  SELECT parametro_vigente(p, clock_timestamp())
$f$;

-- ---------- Catálogo e carga ----------
SELECT pg_temp.confere(
  (SELECT tipo = 'percentual' AND minimo = 1 AND maximo = 50 AND sensivel FROM parametro WHERE chave = 'limite_variacao_reajuste')
  AND (SELECT tipo = 'dias' AND minimo = 1 AND maximo = 180 AND NOT sensivel FROM parametro WHERE chave = 'alerta_documento_dias')
  AND (SELECT count(*) = 2 FROM parametro),
  'catálogo: limite (percentual, 1 a 50, sensível) e alerta (dias, 1 a 180, comum)');
SELECT pg_temp.confere(
  parametro_vigente('limite_variacao_reajuste') = 20 AND parametro_vigente('alerta_documento_dias') = 30,
  'carga: limite 20 e alerta 30');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 AND bool_and(origem = 'migracao' AND referencia_alinhamento LIKE '%23/11/2026%'
                                    AND alterado_por IS NULL AND papel_bd = 'safetycar_migrator')
     FROM parametro_valor),
  'carga com origem migração e referência ao desenho de 23/11/2026');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM auditoria WHERE entidade = 'parametro_valor' AND acao = 'parametrizacao_insert'
      AND papel_bd = 'safetycar_migrator'),
  'carga na auditoria');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM vw_parametro_vigente WHERE (chave, valor) IN (('limite_variacao_reajuste', 20), ('alerta_documento_dias', 30))),
  'vw_parametro_vigente mostra os valores de agora');
SELECT pg_temp.espera_erro($$UPDATE parametro SET maximo = 100 WHERE chave = 'limite_variacao_reajuste'$$,
  '23514', 'o máximo do limite não passa do teto de 50%');
SELECT pg_temp.espera_erro($$UPDATE parametro SET sensivel = false WHERE chave = 'limite_variacao_reajuste'$$,
  '23514', 'o limite do reajuste é sempre sensível');
SELECT pg_temp.espera_erro($$UPDATE parametro SET minimo = 200 WHERE chave = 'alerta_documento_dias'$$,
  '23514', 'mínimo acima do máximo');
SELECT pg_temp.espera_erro($$TRUNCATE parametro_valor$$, 'SC010', 'TRUNCATE no histórico de valores é bloqueado');

SELECT pg_temp.espera_erro($$SELECT parametro_vigente('nao_existe')$$, '22023', 'parâmetro inexistente');
INSERT INTO parametro (chave, descricao, tipo, minimo, maximo, sensivel)
VALUES ('teste_sem_valor', '[TESTE] parâmetro sem valor', 'dias', 0, 10, false);
SELECT pg_temp.espera_erro($$SELECT parametro_vigente('teste_sem_valor')$$,
  'SC013', 'parâmetro sem valor vigente: nunca vale zero');

-- ---------- Equipe ----------
SELECT conceder_permissao_inicial(pg_temp.u('A'), '[TESTE] administrador');
SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u(o), '[TESTE] equipe') FROM unnest(ARRAY['M','N','X']) o;
SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u(o), 'administrar_parametros', '[TESTE] parâmetros')
  FROM unnest(ARRAY['M','N']) o;

-- ---------- Parâmetro comum: alteração direta ----------
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('X'), 'alerta_documento_dias', 45, '[TESTE]')$$,
  'SC016', 'sem administrar_parametros não altera');
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('M'), 'limite_variacao_reajuste', 25, '[TESTE]')$$,
  'SC027', 'parâmetro sensível não é alterado direto');
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('M'), 'alerta_documento_dias', 181, '[TESTE]')$$,
  'SC026', 'acima do máximo (180)');
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('M'), 'alerta_documento_dias', 0, '[TESTE]')$$,
  'SC026', 'abaixo do mínimo (1)');
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('M'), 'alerta_documento_dias', 10.5, '[TESTE]')$$,
  'SC026', 'dias são inteiros');
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('M'), 'alerta_documento_dias', NULL, '[TESTE]')$$,
  '22023', 'valor nulo');
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('M'), 'alerta_documento_dias', 30, '[TESTE]')$$,
  '22023', 'valor igual ao vigente: nada a alterar');
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('M'), 'alerta_documento_dias', 45, ' ')$$,
  '22023', 'sem motivo');
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('M'), 'nao_existe', 1, '[TESTE]')$$,
  '22023', 'parâmetro inexistente');

INSERT INTO v (k, id) SELECT 'alerta45', alterar_parametro(pg_temp.u('M'), 'alerta_documento_dias', 45,
                                                       '[TESTE] mais antecedência', 'alinhamento, seção X (fictícia)');
SELECT pg_temp.confere(pg_temp.agora('alerta_documento_dias') = 45, 'M altera o alerta para 45');
SELECT pg_temp.confere(
  (SELECT origem = 'central_direta' AND alterado_por = pg_temp.u('M') AND aprovado_por IS NULL
          AND referencia_alinhamento = 'alinhamento, seção X (fictícia)' FROM parametro_valor WHERE id = pg_temp.id('alerta45'))
  AND (SELECT o.fim_vigencia = n.inicio_vigencia AND o.valor = 30
         FROM parametro_valor n JOIN parametro_valor o ON o.parametro_chave = n.parametro_chave AND o.id <> n.id
        WHERE n.id = pg_temp.id('alerta45')),
  'novo valor com origem, autor e referência; o anterior (30) fecha no instante em que o novo abre');
SELECT pg_temp.confere(
  parametro_vigente('alerta_documento_dias', (SELECT inicio_vigencia FROM parametro_valor WHERE id = pg_temp.id('alerta45')) - interval '1 microsecond') = 30,
  'antes do início vale 30: nada retroage');

-- ---------- Parâmetro sensível: pedido e decisão ----------
SELECT pg_temp.espera_erro($$SELECT solicitar_alteracao_parametro(pg_temp.u('M'), 'alerta_documento_dias', 60, '[TESTE]')$$,
  'SC027', 'parâmetro comum não vai por pedido');
SELECT pg_temp.espera_erro($$SELECT solicitar_alteracao_parametro(pg_temp.u('X'), 'limite_variacao_reajuste', 25, '[TESTE]')$$,
  'SC016', 'sem administrar_parametros não pede');
SELECT pg_temp.espera_erro($$SELECT solicitar_alteracao_parametro(pg_temp.u('M'), 'limite_variacao_reajuste', 51, '[TESTE]')$$,
  'SC026', 'limite acima de 50');
SELECT pg_temp.espera_erro($$SELECT solicitar_alteracao_parametro(pg_temp.u('M'), 'limite_variacao_reajuste', 0.5, '[TESTE]')$$,
  'SC026', 'limite abaixo de 1');
SELECT pg_temp.espera_erro($$SELECT solicitar_alteracao_parametro(pg_temp.u('M'), 'limite_variacao_reajuste', 20.555, '[TESTE]')$$,
  'SC026', 'percentual com mais de 2 casas');
SELECT pg_temp.espera_erro($$SELECT solicitar_alteracao_parametro(pg_temp.u('M'), 'limite_variacao_reajuste', 20, '[TESTE]')$$,
  '22023', 'pedido com valor igual ao vigente');

INSERT INTO v (k, id) SELECT 'P1', solicitar_alteracao_parametro(pg_temp.u('M'), 'limite_variacao_reajuste', 25.5,
                                                             '[TESTE] inflação', 'alinhamento, seção Y (fictícia)');
SELECT pg_temp.confere(
  (SELECT situacao = 'solicitado' AND valor_na_criacao = 20 AND valor_novo = 25.5 AND solicitado_por = pg_temp.u('M')
     FROM vw_parametro_alteracao WHERE id = pg_temp.id('P1'))
  AND pg_temp.agora('limite_variacao_reajuste') = 20,
  'pedido P1 (20 → 25,5) guarda o valor da criação; o limite continua 20');
SELECT pg_temp.espera_erro($$SELECT solicitar_alteracao_parametro(pg_temp.u('N'), 'limite_variacao_reajuste', 30, '[TESTE]')$$,
  'SC024', 'outro pedido para o mesmo parâmetro, com P1 em aberto');

SELECT pg_temp.espera_erro($$SELECT aprovar_alteracao_parametro(pg_temp.u('M'), pg_temp.id('P1'), '[TESTE]')$$,
  'SC017', 'quem pediu não aprova');
SELECT pg_temp.espera_erro($$SELECT rejeitar_alteracao_parametro(pg_temp.u('M'), pg_temp.id('P1'), '[TESTE]')$$,
  'SC017', 'quem pediu não rejeita (cancela)');
SELECT pg_temp.espera_erro($$SELECT aprovar_alteracao_parametro(pg_temp.u('X'), pg_temp.id('P1'), '[TESTE]')$$,
  'SC016', 'sem administrar_parametros não aprova');
SELECT pg_temp.espera_erro($$SELECT aprovar_alteracao_parametro(pg_temp.u('N'), gen_random_uuid(), '[TESTE]')$$,
  '22023', 'pedido inexistente');
SELECT revogar_permissao(pg_temp.u('A'), pg_temp.u('N'), 'administrar_parametros', '[TESTE] troca');
SELECT pg_temp.espera_erro($$SELECT aprovar_alteracao_parametro(pg_temp.u('N'), pg_temp.id('P1'), '[TESTE]')$$,
  'SC016', 'permissão revogada não aprova');
SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('N'), 'administrar_parametros', '[TESTE] retorno');
SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('N'), false, '[TESTE] afastamento');
SELECT pg_temp.espera_erro($$SELECT aprovar_alteracao_parametro(pg_temp.u('N'), pg_temp.id('P1'), '[TESTE]')$$,
  'SC016', 'operador inativo não aprova');
SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('N'), true, '[TESTE] retorno');

INSERT INTO v (k, id) SELECT 'limite25', aprovar_alteracao_parametro(pg_temp.u('N'), pg_temp.id('P1'), '[TESTE] de acordo');
SELECT pg_temp.confere(pg_temp.agora('limite_variacao_reajuste') = 25.5, 'N aprova: o limite passa a 25,5');
SELECT pg_temp.confere(
  (SELECT origem = 'central_aprovada' AND alterado_por = pg_temp.u('M') AND aprovado_por = pg_temp.u('N')
          AND alteracao_id = pg_temp.id('P1') AND referencia_alinhamento = 'alinhamento, seção Y (fictícia)'
     FROM parametro_valor WHERE id = pg_temp.id('limite25'))
  AND (SELECT situacao = 'aprovado' AND decidido_por = pg_temp.u('N')
              AND inicio_efetivo = (SELECT inicio_vigencia FROM parametro_valor WHERE id = pg_temp.id('limite25'))
         FROM vw_parametro_alteracao WHERE id = pg_temp.id('P1'))
  AND (SELECT o.fim_vigencia = n.inicio_vigencia AND o.valor = 20
         FROM parametro_valor n JOIN parametro_valor o ON o.parametro_chave = n.parametro_chave AND o.fim_vigencia = n.inicio_vigencia
        WHERE n.id = pg_temp.id('limite25')),
  'novo valor com quem pediu, quem aprovou e o pedido; decisão com o início; o 20 fecha no mesmo instante');
SELECT pg_temp.espera_erro($$SELECT aprovar_alteracao_parametro(pg_temp.u('N'), pg_temp.id('P1'), '[TESTE]')$$,
  'SC020', 'pedido aprovado não é aprovado de novo');
SELECT pg_temp.espera_erro($$SELECT rejeitar_alteracao_parametro(pg_temp.u('N'), pg_temp.id('P1'), '[TESTE]')$$,
  'SC020', 'pedido aprovado não é rejeitado');
SELECT pg_temp.espera_erro($$SELECT cancelar_alteracao_parametro(pg_temp.u('M'), pg_temp.id('P1'), '[TESTE]')$$,
  'SC020', 'pedido aprovado não é cancelado');

-- ---------- Rejeição e cancelamento ----------
INSERT INTO v (k, id) SELECT 'P2', solicitar_alteracao_parametro(pg_temp.u('N'), 'limite_variacao_reajuste', 15, '[TESTE] reduzir');
SELECT pg_temp.aceita($$SELECT rejeitar_alteracao_parametro(pg_temp.u('M'), pg_temp.id('P2'), '[TESTE] não agora')$$,
  'M rejeita P2');
SELECT pg_temp.confere(pg_temp.agora('limite_variacao_reajuste') = 25.5
  AND (SELECT situacao = 'rejeitado' FROM vw_parametro_alteracao WHERE id = pg_temp.id('P2')),
  'rejeitar não altera o valor');
INSERT INTO v (k, id) SELECT 'P3', solicitar_alteracao_parametro(pg_temp.u('N'), 'limite_variacao_reajuste', 18, '[TESTE] outra ideia');
SELECT pg_temp.espera_erro($$SELECT cancelar_alteracao_parametro(pg_temp.u('X'), pg_temp.id('P3'), '[TESTE]')$$,
  'SC016', 'quem não pediu nem administra parâmetros não cancela');
SELECT pg_temp.aceita($$SELECT cancelar_alteracao_parametro(pg_temp.u('N'), pg_temp.id('P3'), '[TESTE] desisti')$$,
  'N cancela o próprio pedido');
SELECT pg_temp.confere(pg_temp.agora('limite_variacao_reajuste') = 25.5
  AND (SELECT situacao = 'cancelado' AND decidido_por = pg_temp.u('N') FROM vw_parametro_alteracao WHERE id = pg_temp.id('P3')),
  'cancelar não altera o valor');

-- ---------- Escrita direta: as regras valem para qualquer escritor ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO parametro_valor (parametro_chave, valor, origem, motivo, alterado_por, inicio_vigencia)
  VALUES ('limite_variacao_reajuste', 30, 'central_direta', '[TESTE] direto', pg_temp.u('M'), now() + interval '1 day')$$,
  'SC027', 'sensível com origem central_direta é recusado também por INSERT direto');
SELECT pg_temp.espera_erro($$
  INSERT INTO parametro_valor (parametro_chave, valor, origem, motivo, inicio_vigencia)
  VALUES ('alerta_documento_dias', 500, 'migracao', '[TESTE] direto', now() + interval '1 day')$$,
  'SC026', 'valor fora da faixa é recusado também por INSERT direto');
SELECT pg_temp.espera_erro($$
  INSERT INTO parametro_valor (parametro_chave, valor, origem, motivo, alterado_por, aprovado_por, alteracao_id, inicio_vigencia)
  VALUES ('limite_variacao_reajuste', 30, 'central_aprovada', '[TESTE]', pg_temp.u('M'), pg_temp.u('M'), pg_temp.id('P2'),
          now() + interval '1 day')$$,
  '23514', 'quem pediu e quem aprovou nunca são a mesma pessoa');
SELECT pg_temp.espera_erro($$
  INSERT INTO parametro_valor (parametro_chave, valor, origem, motivo, inicio_vigencia, fim_vigencia)
  VALUES ('alerta_documento_dias', 50, 'migracao', '[TESTE] sobreposto', now() + interval '1 day', now() + interval '2 days')$$,
  '23P01', 'vigências sobrepostas no mesmo parâmetro (EXCLUDE)');
SELECT pg_temp.espera_erro($$UPDATE parametro_valor SET valor = 99 WHERE id = pg_temp.id('alerta45')$$,
  'SC012', 'valor não é alterado: troca = nova linha');
SELECT pg_temp.espera_erro($$DELETE FROM parametro_valor WHERE id = pg_temp.id('alerta45')$$,
  'SC012', 'valor não é apagado');
SELECT pg_temp.espera_erro($$UPDATE parametro_alteracao SET valor_novo = 1 WHERE id = pg_temp.id('P2')$$,
  'SC010', 'pedido não é alterado');
SELECT pg_temp.espera_erro($$DELETE FROM parametro_alteracao_decisao$$,
  'SC010', 'decisão não é apagada');
SELECT pg_temp.espera_erro($$
  INSERT INTO parametro_alteracao (parametro_chave, valor_novo, motivo, solicitado_por)
  VALUES ('alerta_documento_dias', 60, '[TESTE] direto', pg_temp.u('M'))$$,
  'SC027', 'pedido para parâmetro comum é recusado também por INSERT direto');

-- ---------- Auditoria ----------
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_parametro_alterado' AND entidade_id = pg_temp.id('alerta45')
             AND ator_usuario_id = pg_temp.u('M') AND (antes ->> 'valor')::numeric = 30 AND (depois ->> 'valor')::numeric = 45)
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_parametro_solicitado' AND entidade_id = pg_temp.id('P1')
             AND ator_usuario_id = pg_temp.u('M') AND (antes ->> 'valor')::numeric = 20 AND (depois ->> 'valor')::numeric = 25.5)
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_parametro_decidido' AND entidade_id = pg_temp.id('P1')
             AND ator_usuario_id = pg_temp.u('N') AND depois ->> 'situacao' = 'aprovado'
             AND (antes ->> 'valor')::numeric = 20 AND (depois ->> 'valor')::numeric = 25.5)
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_parametro_decidido' AND entidade_id = pg_temp.id('P2')
             AND ator_usuario_id = pg_temp.u('M') AND depois ->> 'situacao' = 'rejeitado')
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_parametro_decidido' AND entidade_id = pg_temp.id('P3')
             AND ator_usuario_id = pg_temp.u('N') AND depois ->> 'situacao' = 'cancelado'),
  'eventos alterado, solicitado e decidido (aprovado, rejeitado, cancelado), com ator e valores antes e depois');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM auditoria WHERE entidade = 'parametro_valor' AND acao = 'parametrizacao_update'
      AND ator_usuario_id IN (pg_temp.u('M'), pg_temp.u('N')))
  AND (SELECT count(*) = 2 FROM auditoria WHERE entidade = 'parametro_valor' AND acao = 'parametrizacao_insert'
      AND ator_usuario_id IN (pg_temp.u('M'), pg_temp.u('N'))),
  'valores encerrados e criados na auditoria automática, com o ator');

-- ---------- Falha da auditoria desfaz a operação ----------
INSERT INTO v (k, id) SELECT 'P4', solicitar_alteracao_parametro(pg_temp.u('M'), 'limite_variacao_reajuste', 30, '[TESTE] falha');
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
SELECT pg_temp.espera_erro($$SELECT alterar_parametro(pg_temp.u('M'), 'alerta_documento_dias', 60, '[TESTE] falha')$$,
  'TS001', 'alteração direta com a auditoria falhando é recusada');
SELECT pg_temp.espera_erro($$SELECT aprovar_alteracao_parametro(pg_temp.u('N'), pg_temp.id('P4'), '[TESTE] falha')$$,
  'TS001', 'aprovação com a auditoria falhando é recusada');
SET LOCAL teste.falhar_auditoria = 'nao';
SELECT pg_temp.confere(
  pg_temp.agora('alerta_documento_dias') = 45 AND pg_temp.agora('limite_variacao_reajuste') = 25.5
  AND (SELECT situacao = 'solicitado' FROM vw_parametro_alteracao WHERE id = pg_temp.id('P4')),
  'nada ficou gravado: alerta 45, limite 25,5 e P4 em aberto');

-- ---------- Ator e dados pessoais ----------
SELECT pg_temp.confere(coalesce(current_setting('safetycar.ator_usuario_id', true), '') = '',
  'o ator não fica pendurado depois das funções');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM auditoria
               WHERE (acao LIKE 'central_parametro%'
                      OR entidade IN ('parametro','parametro_valor','parametro_alteracao','parametro_alteracao_decisao'))
                 AND (coalesce(antes::text, '') || coalesce(depois::text, '')) LIKE '%@%'),
  'nenhum e-mail na auditoria dos parâmetros');
