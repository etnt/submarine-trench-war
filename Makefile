.PHONY: all compile run shell test clean release

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
