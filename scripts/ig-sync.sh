#!/bin/sh
# Instagram → sivuston Työmaalta-osio ja palvelugalleriat.
#
# Hakee tilin julkaisut (Instagram API with Instagram Login), tallentaa kuvat WebP:nä
# ja kirjoittaa syötteen $DATA_DIR/media/feed.json, jonka nginx jakaa osoitteessa
# /media/feed.json. Sivu lukee syötteen selaimessa; hashtag-ohjaus on components.jsx:ssä.
#
# Ajo: Coolifyn Scheduled Task (esim. kerran tunnissa) ja kontin käynnistys.
#
# Ympäristömuuttujat:
#   IG_ACCESS_TOKEN  pitkäikäinen token (Meta App Dashboard). Skripti uusii tokenin
#                    viikoittain ja tallentaa uusimman tiedostoon $DATA_DIR/state/ig-token.
#                    Uusi arvo tässä muuttujassa korvaa tallennetun tokenin.
#   DATA_DIR         pysyvä hakemisto, oletus /data (Coolifyn persistent storage)
#   IG_API           oletus https://graph.instagram.com
#   IG_LIMIT         haettavien julkaisujen määrä, oletus 30
#   ALERT_URL        valinnainen ilmoitusosoite virheille (esim. https://ntfy.sh/oma-topic)
set -eu

DATA_DIR="${DATA_DIR:-/data}"
API="${IG_API:-https://graph.instagram.com}"
LIMIT="${IG_LIMIT:-30}"
MEDIA="$DATA_DIR/media"
IMG="$MEDIA/ig"
STATE="$DATA_DIR/state"
WEEK=604800

log() { echo "[ig-sync] $*"; }

# Sama hälytys korkeintaan kerran päivässä.
alert_daily() {
  key=$1; shift
  log "VIRHE: $*"
  today=$(date +%Y-%m-%d)
  [ "$(cat "$STATE/alerted-$key" 2>/dev/null || true)" = "$today" ] && return 0
  echo "$today" > "$STATE/alerted-$key"
  if [ -n "${ALERT_URL:-}" ]; then
    curl -fsS -m 10 -d "SähköTepi IG-synkka: $*" "$ALERT_URL" >/dev/null 2>&1 || true
  fi
}

# api POLKU [curl-argumentit…] → vastauksen runko, virheessä paluuarvo 1
api() {
  path=$1; shift
  resp=$(curl -sS -m 60 -G "$API/$path" "$@" --data-urlencode "access_token=$TOKEN" -w '\n%{http_code}') || return 1
  code=$(printf '%s' "$resp" | tail -n 1)
  body=$(printf '%s' "$resp" | sed '$d')
  if [ "$code" != 200 ]; then
    log "HTTP $code $path: $(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null || true)"
    return 1
  fi
  printf '%s' "$body"
}

mkdir -p "$IMG" "$STATE"
chmod 700 "$STATE"

# Yksi ajo kerrallaan. Yli tunnin vanha lukko on jäänne keskeytyneestä ajosta.
LOCK="$STATE/sync.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  started=$(cat "$LOCK/started" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - started )) -lt 3600 ]; then
    log "edellinen ajo kesken, ohitetaan"
    exit 0
  fi
  rm -rf "$LOCK"
  mkdir "$LOCK"
fi
date +%s > "$LOCK/started"
TMP="$STATE/tmp.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP" "$LOCK"' EXIT
trap 'exit 1' INT TERM

# Token: uusi arvo ympäristömuuttujassa korvaa tallennetun.
if [ -n "${IG_ACCESS_TOKEN:-}" ] && [ "$IG_ACCESS_TOKEN" != "$(cat "$STATE/ig-token-seed" 2>/dev/null || true)" ]; then
  (umask 077; printf '%s' "$IG_ACCESS_TOKEN" > "$STATE/ig-token"; printf '%s' "$IG_ACCESS_TOKEN" > "$STATE/ig-token-seed")
  rm -f "$STATE/ig-token-refreshed" "$STATE/ig-token-expires"
fi
TOKEN=$(cat "$STATE/ig-token" 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  log "IG_ACCESS_TOKEN puuttuu, ohitetaan"
  exit 0
fi

# Tokenin uusinta kerran viikossa (pitkäikäinen token on voimassa 60 päivää).
now=$(date +%s)
last=$(cat "$STATE/ig-token-refreshed" 2>/dev/null || echo 0)
if [ $((now - last)) -ge $WEEK ]; then
  if out=$(api refresh_access_token --data-urlencode "grant_type=ig_refresh_token"); then
    new=$(printf '%s' "$out" | jq -r '.access_token // empty')
    expires_in=$(printf '%s' "$out" | jq -r '.expires_in // empty')
    if [ -n "$new" ]; then
      (umask 077; printf '%s' "$new" > "$STATE/ig-token")
      TOKEN=$new
      echo "$now" > "$STATE/ig-token-refreshed"
      [ -n "$expires_in" ] && echo $((now + expires_in)) > "$STATE/ig-token-expires"
      log "token uusittu"
    fi
  else
    log "tokenin uusinta ei onnistunut (alle vuorokauden vanhaa tokenia ei voi uusia), jatketaan nykyisellä"
  fi
fi
expires=$(cat "$STATE/ig-token-expires" 2>/dev/null || echo 0)
if [ "$expires" -gt 0 ] && [ $((expires - now)) -lt $WEEK ]; then
  alert_daily expiry "token vanhenee $(( (expires - now) / 86400 )) päivän kuluttua, tarkista uusinta"
fi

# Julkaisut. Karusellista kaikki kuvat, videosta kansikuva.
FIELDS='id,caption,media_type,media_url,thumbnail_url,permalink,timestamp,children{media_type,media_url,thumbnail_url}'
if ! api me/media --data-urlencode "fields=$FIELDS" --data-urlencode "limit=$LIMIT" > "$TMP/raw.json"; then
  alert_daily fetch "julkaisujen haku epäonnistui"
  exit 1
fi
jq '[.data[]? | {
  id,
  shortcode: (((.permalink // "") | capture("/(?:p|reel|tv)/(?<s>[^/?]+)") | .s) // .id),
  permalink,
  caption: (.caption // ""),
  timestamp: ((.timestamp // "") | sub("\\+0000$"; "Z")),
  isVideo: (.media_type == "VIDEO"),
  sources: [ (if .media_type == "CAROUSEL_ALBUM" then (.children.data // [])[] else . end)
             | (if .media_type == "VIDEO" then .thumbnail_url else .media_url end) // empty ]
}]' "$TMP/raw.json" > "$TMP/posts.json"

if [ "$(jq length "$TMP/posts.json")" -eq 0 ]; then
  alert_daily empty "rajapinta palautti 0 julkaisua, vanha syöte jätetään voimaan"
  exit 1
fi

# Kuvat: Instagramin CDN-osoitteet vanhenevat, joten kuvat tallennetaan omalle palvelimelle.
jq -r '.[] | .id as $id | .sources | to_entries[] | "\($id)_\(.key) \(.value)"' "$TMP/posts.json" > "$TMP/sources.txt"
while read -r name url; do
  [ -s "$IMG/$name-lg.webp" ] && [ -s "$IMG/$name-sm.webp" ] && continue
  if curl -fsS -m 60 -o "$TMP/$name.img" "$url" \
    && cwebp -quiet -q 80 "$TMP/$name.img" -o "$TMP/$name-lg.webp" \
    && cwebp -quiet -q 76 -resize 640 0 "$TMP/$name.img" -o "$TMP/$name-sm.webp"; then
    mv "$TMP/$name-lg.webp" "$TMP/$name-sm.webp" "$IMG/"
  else
    log "kuva ohitettiin: $name"
  fi
done < "$TMP/sources.txt"

# Syöte: vain julkaisut, joiden kuvat ovat tallessa.
ls "$IMG" | sed -n 's/-lg\.webp$//p' > "$TMP/have.txt"
jq -n --rawfile have "$TMP/have.txt" --slurpfile posts "$TMP/posts.json" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  ($have | split("\n") | map(select(length > 0) | {key: ., value: true}) | from_entries) as $h
  | { updated: $now,
      posts: [ $posts[0][] | .id as $id
        | { shortcode, permalink, caption, timestamp, isVideo,
            images: [ .sources | keys[] | "\($id)_\(.)" | select($h[.])
                      | { sm: "media/ig/\(.)-sm.webp", lg: "media/ig/\(.)-lg.webp" } ] }
        | select(.images | length > 0) ] }' > "$TMP/feed.json"
mv "$TMP/feed.json" "$MEDIA/feed.json"

# Poistetut julkaisut: kuvat pois.
jq -r '.[] | .id as $id | .sources | keys[] | "\($id)_\(.)"' "$TMP/posts.json" > "$TMP/keep.txt"
for f in "$IMG"/*.webp; do
  [ -e "$f" ] || continue
  n=$(basename "$f" .webp)
  n=${n%-lg}
  n=${n%-sm}
  grep -qxF "$n" "$TMP/keep.txt" || rm -f "$f"
done

echo "$now" > "$STATE/last-success"
log "valmis: $(jq '.posts | length' "$MEDIA/feed.json") julkaisua"
