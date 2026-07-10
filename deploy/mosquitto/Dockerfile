FROM eclipse-mosquitto:2.0.22

# curl+jq — для token-agent (OAuth-ротация MQTT-JWT);
# ca-certificates — TLS-мост к mq.rocket-home.ru:8883 (bridge_capath).
RUN apk add --no-cache curl jq ca-certificates

RUN sed -i 's/#password_file/password_file \/mosquitto\/etc\/password/g' /mosquitto/config/mosquitto.conf \
    && sed -i '/^listener/d' /mosquitto/config/mosquitto.conf \
    && sed -i '/^socket_domain/d' /mosquitto/config/mosquitto.conf \
    && sed -i 's/#include_dir.*/include_dir \/mosquitto\/conf.d/' /mosquitto/config/mosquitto.conf \
    && echo "include_dir /mosquitto/dynamic" >> /mosquitto/config/mosquitto.conf \
    && echo "listener 1883 0.0.0.0" >> /mosquitto/config/mosquitto.conf \
    && echo "protocol mqtt" >> /mosquitto/config/mosquitto.conf \
    && echo "allow_anonymous false" >> /mosquitto/config/mosquitto.conf

COPY entrypoint.sh /entrypoint.sh
COPY token-agent.sh /token-agent.sh
RUN chmod +x /entrypoint.sh /token-agent.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/mosquitto", "-c", "/mosquitto/config/mosquitto.conf"]
