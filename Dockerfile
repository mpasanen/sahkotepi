FROM nginx:alpine
COPY SahkoTepi-Standalone.html /usr/share/nginx/html/index.html
COPY assets /usr/share/nginx/html/assets
EXPOSE 80
