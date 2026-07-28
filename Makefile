.PHONY: all compile run shell test clean release container-build container-run

# Container tool + image coordinates (override on the command line, e.g.
#   make container-build CONTAINER=docker IMAGE=registry.example.com/stw:1.0).
# Defaults to Podman (daemonless, rootless); the Dockerfile builds
# unchanged under Docker too.
CONTAINER ?= podman
IMAGE     ?= submarine-trench-war:latest
PORT      ?= 8080

all: compile

compile:
	rebar3 compile

## Run the server in a foreground shell (Ctrl+C twice to quit).
run:
	rebar3 shell

shell: run

test:
	rebar3 eunit

clean:
	rebar3 clean
	rm -rf _build

release:
	rebar3 as prod release

## Build the reproducible production container image.
container-build:
	$(CONTAINER) build -t $(IMAGE) .

## Run the container, publishing the HTTP/WebSocket port.
container-run:
	$(CONTAINER) run --rm -p $(PORT):8080 --name stw $(IMAGE)
