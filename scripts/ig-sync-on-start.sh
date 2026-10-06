#!/bin/sh
# nginx-kuvan /docker-entrypoint.d-koukku: päivittää Instagram-syötteen taustalla
# kontin käynnistyessä, ettei uusi deploy jää odottamaan ajastettua synkkaa.
/opt/ig-sync.sh &
exit 0
