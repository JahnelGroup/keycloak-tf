TAG=0.2.8
KEYCLOAK_VERSION=21.1.0
REPO=543622040505.dkr.ecr.us-west-2.amazonaws.com/keycloak
IMAGE_URL=$(REPO):$(KEYCLOAK_VERSION)_$(TAG)
REGION=us-west-2
PROFILE=jg-playground

login:
	aws --profile $(PROFILE) ecr get-login-password --region $(REGION) | docker login --username AWS --password-stdin $(IMAGE_URL)

build:
	docker buildx build --load --platform linux/amd64 . -t $(IMAGE_URL)

run: build
	docker run -it --entrypoint bash $(IMAGE_URL)

push: login
	docker buildx build --push --platform linux/amd64 . -t $(IMAGE_URL)

