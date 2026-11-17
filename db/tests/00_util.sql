-- Utilitários de teste. Prefixado pelo testar.sh a cada arquivo; vivem em pg_temp
-- (somem ao fim da sessão, não deixam objeto no banco).
-- Dados de teste são FICTÍCIOS e marcados com [TESTE] / dominio exemplo.invalid.

-- Executa p_sql e exige que falhe com o SQLSTATE p_estado.
CREATE FUNCTION pg_temp.espera_erro(p_sql text, p_estado text, p_desc text)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_estado text; v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_estado = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
  END;
  IF v_estado IS NULL THEN
    RAISE EXCEPTION 'FALHOU: % -> o comando foi aceito, mas deveria falhar com %', p_desc, p_estado;
  ELSIF v_estado <> p_estado THEN
    RAISE EXCEPTION 'FALHOU: % -> esperava erro %, veio % (%)', p_desc, p_estado, v_estado, v_msg;
  END IF;
  RAISE NOTICE 'OK: % [% %]', p_desc, v_estado, v_msg;
END $f$;

-- Executa p_sql e exige que seja aceito.
CREATE FUNCTION pg_temp.aceita(p_sql text, p_desc text)
RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_estado text; v_msg text;
BEGIN
  BEGIN
    EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_estado = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RAISE EXCEPTION 'FALHOU: % -> deveria ser aceito, mas deu % (%)', p_desc, v_estado, v_msg;
  END;
  RAISE NOTICE 'OK: %', p_desc;
END $f$;

-- Exige que a condição seja verdadeira.
CREATE FUNCTION pg_temp.confere(p_condicao boolean, p_desc text)
RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  IF p_condicao IS NOT TRUE THEN
    RAISE EXCEPTION 'FALHOU: %', p_desc;
  END IF;
  RAISE NOTICE 'OK: %', p_desc;
END $f$;

-- HMAC fictício de teste (a chave real fica fora do repositório, na aplicação).
CREATE FUNCTION pg_temp.hmac_teste(p_valor text)
RETURNS bytea LANGUAGE sql IMMUTABLE AS $f$
  SELECT hmac(p_valor, 'chave-ficticia-de-teste', 'sha256')
$f$;
