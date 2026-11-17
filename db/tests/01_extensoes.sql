-- 01 — Extensões instaladas
SELECT pg_temp.confere(
  (SELECT count(*) = 3 FROM pg_extension WHERE extname IN ('postgis','citext','pgcrypto')),
  'extensões postgis, citext e pgcrypto instaladas');

SELECT pg_temp.confere(
  (SELECT split_part(postgis_lib_version(), '.', 1) = '3'),
  'PostGIS 3.x disponível');

SELECT pg_temp.confere(
  octet_length(pg_temp.hmac_teste('12345678909')) = 32,
  'hmac SHA-256 de teste gera 32 bytes');
