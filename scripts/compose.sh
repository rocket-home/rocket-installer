#!/usr/bin/env bash
# Единственная точка входа в docker compose.
#
# ЗАЧЕМ. Makefile звал docker compose сам, своей строкой. После появления профиля zigbee
# make-цели и скрипты разошлись бы в том, какие сервисы вообще «существуют»: make up поднимал
# бы z2m там, где smoke его уже не ждёт. Профили считаются в одном месте — compose() в
# lib/common.sh, — и обе дороги ведут через него.
. "$(dirname "$0")/lib/common.sh"
compose "$@"
