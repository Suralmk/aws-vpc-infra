.PHONY: deploy up down logs build

deploy:
	docker compose up -d --build

up:
	docker compose up --build

down:
	docker compose down

logs:
	docker compose logs -f

build:
	docker compose build
