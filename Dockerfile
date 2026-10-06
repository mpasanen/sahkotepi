FROM nginx:alpine
# Instagram-synkka (scripts/ig-sync.sh): curl, jq ja cwebp
RUN apk add --no-cache curl jq libwebp-tools
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY SahkoTepi-Standalone.html /usr/share/nginx/html/index.html
COPY tietosuoja.html /usr/share/nginx/html/tietosuoja.html
COPY assets /usr/share/nginx/html/assets
COPY scripts/ig-sync.sh /opt/ig-sync.sh
COPY scripts/ig-sync-on-start.sh /docker-entrypoint.d/40-ig-sync.sh
RUN chmod +x /opt/ig-sync.sh /docker-entrypoint.d/40-ig-sync.sh \
 && mkdir -p /data/media /data/state
EXPOSE 80
