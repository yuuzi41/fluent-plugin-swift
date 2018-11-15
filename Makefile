name = fluent-plugin-swift
build:
	docker-compose build  --no-cache --force-rm
up:
	docker-compose up -d
down:
	docker-compose down
copy-gem: up
	id=$$(docker-compose ps -q $(name)) ; \
        version=$(shell cat VERSION) ; \
        docker-compose exec -T $(name) ls -l /app/pkg/$(name)-$$version.gem ; \
        docker cp $$id:/app/pkg/$(name)-$$version.gem . ; \
        docker cp $$id:/app/pkg/$(name)-$$version.gem misc/fluentd/
	docker-compose down
