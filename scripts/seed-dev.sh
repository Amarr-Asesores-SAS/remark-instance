#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# seed-dev.sh — llena la instancia LOCAL de Remark42 con comentarios de prueba
# que cubren los escenarios relevantes segun la config (compose.yaml / .env):
#
#   - comentario simple (score 0)
#   - markdown (negrita, cursiva, code, link, cita, lista, code fence)
#   - texto largo cercano a MAX_COMMENT_SIZE (500)
#   - palabra/URL sin espacios (word-break)
#   - emojis unicode (EMOJI=false solo desactiva el picker, no el render)
#   - imagen por markdown
#   - solo upvotes (+4)
#   - votos mixtos (+6 / -2 -> neto +4, con ambos contadores)
#   - 4 dislikes (score -4, por encima de low_score)
#   - score == low_score (-5): la UI lo atenua/colapsa
#   - score == critical_score (-10): oculto tras clic
#   - hilo con respuestas nivel 1/2/3 (el front aplana a 1 nivel)
#   - respuesta con score -6
#   Solo si se pasa ADMIN_PASSWD (HTTP basic admin):
#   - comentario fijado (pin)
#   - comentario borrado (placeholder)
#   - padre borrado con hijo visible
#   - usuario verificado (check)
#   - usuario bloqueado
#   - hilo readonly (URL aparte, no se puede responder)
#
# Los votos se emiten desde contenedores efimeros en la red del compose, cada
# uno con su propia IP: VOTES_IP deduplica por IP del peer TCP real (ignora
# X-Forwarded-For), asi que es la unica forma de acumular varios votos.
#
# Uso:
#   ./scripts/seed-dev.sh [URL]
#   ADMIN_PASSWD=xxxxx ./scripts/seed-dev.sh            # incluye escenarios admin
#   FORCE=1 ./scripts/seed-dev.sh                       # re-sembrar (duplica)
#
# Reset limpio (borra TODO: BoltDB + avatars + backups):
#   docker compose down && rm -rf var && docker compose up -d && ./scripts/seed-dev.sh
# ---------------------------------------------------------------------------
# NB: sin `set -e`. Cada comentario/voto sale de un `docker run` en un
# contenedor efimero; si uno falla (429 transitorio, arranque lento) el
# script debe seguir con el resto, no abortar.
set -uo pipefail

CT="${REMARK_CONTAINER:-ewcam-remark42}"
API="${REMARK_API:-http://127.0.0.1:9081}"
MAIN_URL="${1:-https://estrellaswebcam.com/redna-models}"
RO_URL="${MAIN_URL%/}-readonly"

docker inspect -f '{{.State.Running}}' "$CT" 2>/dev/null | grep -q true || {
  echo "El contenedor '$CT' no esta corriendo. Arranca con: docker compose up -d" >&2
  exit 1
}

SITE="${SITE:-$(docker inspect "$CT" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^SITE=//p')}"
SITE="${SITE:-estrellaswebcam}"
NET="$(docker inspect "$CT" --format '{{range $k,$_ := .NetworkSettings.Networks}}{{$k}}{{end}}')"
IMG="$(docker inspect "$CT" --format '{{.Config.Image}}')"
TARGET="$CT:8080"
[ -n "$NET" ] && [ -n "$IMG" ] || { echo "No pude leer net/img del contenedor $CT" >&2; exit 1; }
SUBNET="$(docker network inspect "$NET" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
case "$SUBNET" in
  172.22.*) : ;;
  *) echo "AVISO: la red $NET usa $SUBNET, no 172.22.0.0/16. Ajusta nextip() o recrea la red." >&2 ;;
esac
export SITE NET IMG TARGET

echo "site=$SITE  net=$NET  img=$IMG"
echo "url principal = $MAIN_URL"

# --- guard de idempotencia -------------------------------------------------
seedcount="$(curl -s "$API/api/v1/last/200?site=$SITE" | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = []
print(sum(1 for x in d if "[seed-dev]" in x.get("text", "")))' 2>/dev/null || echo 0)"

if [ "${seedcount:-0}" -gt 0 ] && [ -z "${FORCE:-}" ]; then
  cat >&2 <<EOF
Ya hay $seedcount comentarios [seed-dev] en el sitio. Re-sembrar los duplicaria.
  Reset limpio:  docker compose down && rm -rf var && docker compose up -d && ./scripts/seed-dev.sh
  Forzar igual:  FORCE=1 ./scripts/seed-dev.sh
EOF
  exit 1
fi

# --- helpers -----------------------------------------------------------
# Script que corre DENTRO de cada contenedor efimero (busybox sh + curl).
# Reintenta login y la accion: bajo rafaga el endpoint puede responder 429.
INNER='
set -u
B="http://$TARGET"
n=0
while [ $n -lt 8 ]; do
  curl -s -D /tmp/h "$B/auth/anonymous/login?user=$U&aud=$SITE&site=$SITE" >/dev/null 2>&1 || true
  JWT=$(grep -oi "jwt=[^;]*" /tmp/h 2>/dev/null | head -1 | cut -d= -f2 || true)
  [ -n "$JWT" ] && break
  n=$((n+1)); sleep 1
done
JTI=$(grep -oi "xsrf-token=[a-f0-9]*" /tmp/h | head -1 | cut -d= -f2 || true)
if [ -z "$JWT" ]; then echo "LOGIN_FAIL"; exit 0; fi

if [ -n "${VOTE:-}" ]; then
  n=0
  while [ $n -lt 6 ]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT -b "JWT=$JWT" -H "X-XSRF-TOKEN: $JTI" \
      "$B/api/v1/vote/$CID?site=$SITE&url=$URL&vote=$VOTE")
    case "$code" in
      429|500|502|503) n=$((n+1)); sleep 2 ;;
      *) break ;;
    esac
  done
  echo "$code"
else
  pfx=""
  [ -n "${PID:-}" ] && pfx="\"pid\":\"$PID\","
  n=0
  while [ $n -lt 6 ]; do
    r=$(curl -s -b "JWT=$JWT" -H "X-XSRF-TOKEN: $JTI" -H "Content-Type: application/json" \
        -d "{${pfx}\"text\":$TJSON,\"locator\":{\"site\":\"$SITE\",\"url\":\"$URL\"}}" \
        "$B/api/v1/comment?site=$SITE")
    id=$(printf "%s" "$r" | grep -o "\"id\":\"[^\"]*\"" | cut -d\" -f4 | tr "\n" " ")
    [ -n "$(printf "%s" "$id" | tr -d " ")" ] && { printf "%s\n" "$id"; exit 0; }
    n=$((n+1)); sleep 2
  done
  echo ""
fi
'

# contador de IP a prueba de subshell (nextip corre dentro de $(...))
IPN_FILE="$(mktemp)"; echo 9 > "$IPN_FILE"
cleanup() { rm -f "$IPN_FILE"; }
trap cleanup EXIT
nextip() {
  local n o b
  n=$(( $(cat "$IPN_FILE") + 1 )); echo "$n" > "$IPN_FILE"
  o=$n; b=210
  while [ "$o" -gt 250 ]; do o=$((o - 241)); b=$((b + 1)); done
  echo "172.22.$b.$o"
}

mkjson() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

_craw() {  # user  tjson  [pid]   -> "<comment_id> <user_id>"   ("" si falla)
  local u="$1" t="$2" p="${3:-}" out k
  for k in 1 2 3; do
    out=$(docker run --rm --network "$NET" --ip "$(nextip)" \
      -e U="$u" -e TJSON="$t" -e PID="$p" -e VOTE= -e CID= -e SITE -e URL -e TARGET \
      --entrypoint sh "$IMG" -c "$INNER" 2>/dev/null | tr -d '\r')
    out="$(printf '%s' "$out" | sed -e 's/^ *//' -e 's/ *$//')"
    if [ -n "$out" ] && [ "$out" != "LOGIN_FAIL" ]; then echo "$out"; return 0; fi
    sleep 2
  done
  echo ""; return 0
}

# create -> SOLO el comment_id (lo que consumen castvotes / pid de replies)
create() { _craw "$@" | awk '{print $1}'; }

castvotes() {  # comment_id  count  vote(+1/-1)  tag
  local cid="$1" n="$2" v="$3" tag="$4" i code ok=0
  [ -n "$cid" ] || { echo "  (sin cid, salto votos)"; return; }
  for i in $(seq 1 "$n"); do
    code=$(docker run --rm --network "$NET" --ip "$(nextip)" \
      -e U="sv_${tag}_$i" -e CID="$cid" -e VOTE="$v" -e SITE -e URL -e TARGET \
      -e TJSON= -e PID= --entrypoint sh "$IMG" -c "$INNER" 2>/dev/null | tr -d '[:space:]')
    [ "$code" = "200" ] && ok=$((ok + 1))
  done
  echo "  votos ${v}: ${ok}/${n} ok"
}

say() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
note() { [ -n "$1" ] && echo "  id: $1" || echo "  !! fallo al crear"; }

# --- textos ----------------------------------------------------------
MD=$'[seed-dev] **negrita**, *cursiva*, `code`, [enlace](https://estrellaswebcam.com).\n\n> cita en bloque\n\n- item uno\n- item dos\n\n```js\nconst saludo = "hola";\nconsole.log(saludo);\n```'
LONG="[seed-dev] $(python3 -c 'print("Lorem ipsum dolor sit amet consectetur adipiscing elit. " * 8)' | cut -c1-470)"
LONGWORD="[seed-dev] palabra sin espacios: $(python3 -c 'print("a"*90)') y URL larga: https://estrellaswebcam.com/redna-models/$(python3 -c 'print("segmento-"*9)')"
IMG_MD=$'[seed-dev] Comentario con imagen:\n\n![demo](https://picsum.photos/240/140)'

export URL="$MAIN_URL"

# --- escenarios sin admin ------------------------------------------
say "simple";      c=$(create seed_a1 "$(mkjson "[seed-dev] Comentario simple, sin votos.")"); note "$c"
say "markdown";    c=$(create seed_a2 "$(mkjson "$MD")");                                       note "$c"
say "texto largo"; c=$(create seed_a3 "$(mkjson "$LONG")");                                     note "$c"
say "word-break";  c=$(create seed_a4 "$(mkjson "$LONGWORD")");                                 note "$c"
say "emojis";      c=$(create seed_a5 "$(mkjson "[seed-dev] Emojis: 🎉🔥😅✅🇨🇴 con texto.")");  note "$c"
say "imagen";      c=$(create seed_a6 "$(mkjson "$IMG_MD")");                                   note "$c"

say "solo upvotes (+4)"
c=$(create seed_a7 "$(mkjson "[seed-dev] Solo votos positivos (+4).")"); note "$c"
castvotes "$c" 4 1 up

say "votos mixtos (+6 / -2)"
c=$(create seed_a8 "$(mkjson "[seed-dev] Votos mixtos: +6 y -2 (neto +4).")"); note "$c"
castvotes "$c" 6 1 mxu
castvotes "$c" 2 -1 mxd

say "4 dislikes (-4, sobre low_score)"
c=$(create seed_a9 "$(mkjson "[seed-dev] Comentario con 4 dislikes (score -4).")"); note "$c"
castvotes "$c" 4 -1 dn

say "score == low_score (-5)"
c=$(create seed_a10 "$(mkjson "[seed-dev] Score -5 (low_score): la UI lo atenua/colapsa.")"); note "$c"
castvotes "$c" 5 -1 lo

say "score == critical_score (-10)"
c=$(create seed_a11 "$(mkjson "[seed-dev] Score -10 (critical_score): oculto tras clic.")"); note "$c"
castvotes "$c" 10 -1 cr

say "hilo anidado nivel 1/2/3 + respuesta con score -6"
root=$(create seed_t0 "$(mkjson "[seed-dev] Hilo: raiz con respuestas anidadas.")");                   echo "  root  $root"
rA=$(  create seed_t1 "$(mkjson "[seed-dev] Respuesta nivel 1 (A).")" "$root");                        echo "  A     $rA"
rA1=$( create seed_t2 "$(mkjson "[seed-dev] Respuesta nivel 2 (A.1) — el front la aplana.")" "$rA");   echo "  A.1   $rA1"
rA11=$(create seed_t3 "$(mkjson "[seed-dev] Respuesta nivel 3 (A.1.1).")" "$rA1");                     echo "  A.1.1 $rA11"
rB=$(  create seed_t4 "$(mkjson "[seed-dev] Respuesta nivel 1 (B), score -6.")" "$root");              echo "  B     $rB"
castvotes "$rB" 6 -1 rb

# --- escenarios admin (opcionales) -------------------------------
if [ -n "${ADMIN_PASSWD:-}" ]; then
  adm() { curl -s -u "admin:$ADMIN_PASSWD" "$@"; }

  say "pin (admin)"
  c=$(create seed_p1 "$(mkjson "[seed-dev] Comentario fijado por admin.")"); note "$c"
  [ -n "$c" ] && adm -X PUT "$API/api/v1/admin/pin/$c?site=$SITE&url=$URL&pin=1" >/dev/null

  say "borrado (admin) -> placeholder"
  c=$(create seed_d1 "$(mkjson "[seed-dev] Este se borra; deberia verse el placeholder.")"); note "$c"
  [ -n "$c" ] && adm -X DELETE "$API/api/v1/admin/comment/$c?site=$SITE&url=$URL" >/dev/null

  say "padre borrado con hijo visible (admin)"
  dp=$(create seed_d2 "$(mkjson "[seed-dev] Padre que sera borrado.")"); echo "  padre $dp"
  dpc=$(create seed_d3 "$(mkjson "[seed-dev] Hijo que sobrevive al borrado del padre.")" "$dp"); echo "  hijo  $dpc"
  [ -n "$dp" ] && adm -X DELETE "$API/api/v1/admin/comment/$dp?site=$SITE&url=$URL" >/dev/null

  say "usuario verificado (admin)"
  read -r c vu <<<"$(_craw seed_mod "$(mkjson "[seed-dev] Comentario de usuaria verificada.")")"
  echo "  comment $c  user $vu"
  [ -n "$vu" ] && adm -X PUT "$API/api/v1/admin/verify/$vu?site=$SITE&verified=1" >/dev/null

  say "usuario bloqueado (admin)"
  read -r c bu <<<"$(_craw seed_troll "$(mkjson "[seed-dev] Comentario de usuario que luego se bloquea.")")"
  echo "  comment $c  user $bu"
  [ -n "$bu" ] && adm -X PUT "$API/api/v1/admin/user/$bu?site=$SITE&block=1&ttl=0" >/dev/null

  say "hilo readonly (admin) -> $RO_URL"
  export URL="$RO_URL"
  c=$(create seed_ro1 "$(mkjson "[seed-dev] Hilo cerrado (readonly): no se puede responder.")"); note "$c"
  c=$(create seed_ro2 "$(mkjson "[seed-dev] Segundo comentario del hilo cerrado.")"); note "$c"
  adm -X PUT "$API/api/v1/admin/readonly?site=$SITE&url=$RO_URL&ro=1" >/dev/null
  export URL="$MAIN_URL"
else
  echo
  echo "ADMIN_PASSWD no seteado -> saltados: pin, borrado, padre-borrado, verificado, bloqueado, readonly."
  echo "  Para incluirlos:  ADMIN_PASSWD=xxxxx ./scripts/seed-dev.sh"
fi

# --- resumen -------------------------------------------------------
say "estado final: $MAIN_URL"
python3 <<PY
import json, re, urllib.request
u = "$API/api/v1/find?site=$SITE&url=$MAIN_URL&format=tree&sort=+time"
d = json.load(urllib.request.urlopen(u))
def strip(t):
    return re.sub("<[^>]+>", "", t).replace(chr(10), " ").strip()[:64]
def walk(nodes, depth):
    for n in nodes:
        c = n["comment"]
        print("  " + "  " * depth + "[%+d] %s" % (c["score"], strip(c.get("text", ""))))
        walk(n.get("replies", []), depth + 1)
walk(d.get("comments", []), 0)
print("  -- comentarios en el hilo: %s" % d.get("info", {}).get("count", "?"))
PY
echo
echo "Listo. Recarga la pagina del frontend que apunta a $MAIN_URL"
