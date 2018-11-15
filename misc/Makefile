#
#  definition variables de environnement de test
#
export EFK_SERVICE_NAME = efk
export APP = debug
export APP_PATH := $(shell pwd)
export APP_DATA := $(APP_PATH)/data

export COMPOSE_PROJECT_NAME = test_${APP}_${EFK_SERVICE_NAME}

export TEST_APP_PATH=${APP_PATH}
export TEST_APP_DATA=${APP_DATA}

export EFK_DOCKER_COMPOSE_RUN = ${TEST_APP_PATH}/docker-compose-run-${EFK_SERVICE_NAME}.yml

export efk_stack_conf_dir = ${TEST_APP_PATH}/${EFK_SERVICE_NAME}-conf
export efk_stack_data_dir = ${TEST_APP_DATA}

export fluentd_image_full = ${APP}-fluentd:v1.1.3-debian
export PLUGIN_VERSION=$(shell cat ../VERSION)
build:
	docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} build  --no-cache --force-rm

up: up-cloud up-fluentd run-test

run-test:
	id=$$(docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} up -d fluentd) ; \
	docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} exec -T fluentd /bin/bash -c 'for i in $$(seq 1 10) ; do echo "{\"event\":\"message$$i\"}" | fluent-cat test.tag ; done'

up-fluentd:
	docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} up fluentd
up-cloud:
	docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} up -d cloud
	docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} exec cloud /bin/bash -c 'timeout=120 ; ret=1 ; until [ "$$timeout" -le 0 -o "$$ret" -eq "0"  ] ; do curl -s --fail -XGET http://127.0.0.1:35357/v3 ; ret=$$? ; echo "Wait $$timeout" ; ((timeout--)) ; sleep 1 ; done'
	docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} exec cloud /bin/bash -c '/swift/bin/register-swift-endpoint.sh http://cloud:8080'

down:
	docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} down
down-fluentd:
	docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} stop fluentd
	docker-compose -f ${EFK_DOCKER_COMPOSE_RUN} rm -f fluentd
