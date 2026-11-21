#!/usr/bin/env bash
# Confere, no Keycloak local, que o tema de login "safetycar" está montado e em uso, que tudo o
# que a página carrega vem do próprio Keycloak e que a CSP não mudou. Só leitura (GETs).
#
#   bash keycloak/scripts/conferir_tema.sh
#
# Pré-requisitos: docker compose up -d (keycloak saudável) e, num realm já existente, o tema
# escolhido no console (Realm settings → Themes → Login theme = safetycar).
# Lê só KEYCLOAK_PORTA do .env. Cada verificação imprime OK ou FALHOU; sai com 1 se alguma falhar.
set -euo pipefail
source "$(dirname "$0")/../../db/scripts/_comum.sh"

PORTA="$(le_env KEYCLOAK_PORTA)"; PORTA="${PORTA:-8080}"
BASE="http://localhost:$PORTA"
REALM=safetycar-dev
CSP_ESPERADA="frame-src 'self'; frame-ancestors 'self'; object-src 'none';"

FALHAS=0; TOTAL=0
ok()     { TOTAL=$((TOTAL + 1)); echo "   OK: $*"; }
falhou() { TOTAL=$((TOTAL + 1)); FALHAS=$((FALHAS + 1)); echo "   FALHOU: $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

estado="$(docker compose ps --format '{{.Health}}' keycloak 2>/dev/null || true)"
if [[ "$estado" != healthy ]]; then
  echo "ERRO: o contêiner 'keycloak' não está saudável (estado: '${estado:-parado}'). Rode: docker compose up -d" >&2
  exit 1
fi

echo "== montagem"
if MSYS_NO_PATHCONV=1 docker compose exec -T keycloak test -f /opt/keycloak/themes/safetycar/login/theme.properties; then
  ok "tema montado em /opt/keycloak/themes/safetycar"
else
  falhou "tema não montado (falta o volume no docker-compose.yml? rode: docker compose up -d keycloak)"
fi
rw="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/opt/keycloak/themes/safetycar"}}{{.RW}}{{end}}{{end}}' "$(docker compose ps -q keycloak)")"
case "$rw" in
  false) ok "volume do tema somente leitura" ;;
  true)  falhou "o volume do tema aceita escrita (deveria ser :ro)" ;;
  *)     falhou "volume do tema não encontrado no contêiner" ;;
esac

echo "== página de login"
# PKCE fictício: a página de login é exibida antes de qualquer troca de código.
DESAFIO="$(printf 'conferir-tema-%s' "$RANDOM" | sha256sum | cut -c1-43)"
URL="$BASE/realms/$REALM/protocol/openid-connect/auth?client_id=safetycar-web&response_type=code&scope=openid&redirect_uri=http%3A%2F%2Flocalhost%3A5173%2Fentrando&code_challenge=$DESAFIO&code_challenge_method=S256"
codigo="$(curl -s -o "$TMP/pagina.html" -D "$TMP/cabecalhos" -w '%{http_code}' "$URL")"
[[ "$codigo" == 200 ]] && ok "login responde 200" || falhou "login respondeu $codigo"

csp="$(grep -i '^content-security-policy:' "$TMP/cabecalhos" | head -n 1 | cut -d: -f2- | sed 's/^ *//; s/\r$//')"
[[ "$csp" == "$CSP_ESPERADA" ]] && ok "CSP inalterada ($csp)" || falhou "CSP diferente: '$csp'"

grep -q 'lang="pt-BR"' "$TMP/pagina.html" && ok "página em pt-BR" || falhou "página não está em pt-BR"
grep -q 'class="sc-nome"' "$TMP/pagina.html" && ok "cabeçalho do tema (SAFETY CAR)" || falhou "cabeçalho do tema ausente (o realm usa o tema safetycar?)"
grep -qE '/login/safetycar/css/safetycar\.css' "$TMP/pagina.html" && ok "página carrega o safetycar.css" || falhou "safetycar.css não referenciado"
grep -q 'pf-v5-theme-dark' "$TMP/pagina.html" && falhou "script de modo escuro presente (darkMode deveria ser false)" || ok "sem script de modo escuro"

# Endereços que a página carrega (href, src). Fora o namespace do SVG, todos do próprio Keycloak.
grep -oE '(href|src)="[^"]+"' "$TMP/pagina.html" | sed -E 's/^(href|src)="//; s/"$//; s/&amp;/\&/g' | sort -u >"$TMP/enderecos"
externos="$(grep -E '^(https?:)?//' "$TMP/enderecos" | grep -vE "^https?://(localhost|127\.0\.0\.1)(:$PORTA)?/" || true)"
[[ -z "$externos" ]] && ok "nenhum host externo na página" || falhou "hosts externos: $(echo "$externos" | tr '\n' ' ')"

echo "== recursos"
# confere_recurso <url> <padrão de content-type>
confere_recurso() {
  local url="$1" tipo="$2" resp
  resp="$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$url")"
  if [[ "$resp" == 200\ * && "${resp#* }" =~ $tipo ]]; then ok "${url#"$BASE"} ($resp)"; else falhou "${url#"$BASE"} ($resp)"; fi
}

css_url=""
while read -r e; do
  case "$e" in
    /resources/*.css) confere_recurso "$BASE$e" '^text/css' ;;
    /resources/*.js)  confere_recurso "$BASE$e" '^(text|application)/javascript' ;;
    # O Keycloak serve o .ico como application/octet-stream.
    /resources/*.ico) confere_recurso "$BASE$e" '^(image/|application/octet-stream)' ;;
    *) continue ;;
  esac
  [[ "$e" == */login/safetycar/css/safetycar.css ]] && css_url="$BASE$e"
done <"$TMP/enderecos"

if [[ -n "$css_url" ]]; then
  curl -s "$css_url" >"$TMP/safetycar.css"
  dir_css="${css_url%/*}"
  dir_recursos="${dir_css%/*}"
  # url("../...") do CSS do tema (os data: ficam de fora).
  while read -r r; do
    case "$r" in
      *.woff2) confere_recurso "$dir_recursos/$r" '^font/woff2' ;;
      *.png)   confere_recurso "$dir_recursos/$r" '^image/png' ;;
      *)       confere_recurso "$dir_recursos/$r" '.' ;;
    esac
  done < <(grep -oE 'url\("\.\./[^"]+"\)' "$TMP/safetycar.css" | sed -E 's/^url\("\.\.\///; s/"\)$//' | sort -u)
else
  falhou "sem o safetycar.css, os recursos do tema não foram conferidos"
fi

echo
echo "== $((TOTAL - FALHAS))/$TOTAL verificações OK"
(( FALHAS == 0 ))
