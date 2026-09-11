.PHONY: default compile clean distclean upgrade fmt fmt-check xref eunit ct dialyzer test ci repl

default: compile

compile:
	rebar3 compile

clean:
	rebar3 clean --all

distclean: clean
	rm -rf _build
	rm -f rebar.lock

upgrade:
	rebar3 upgrade --all

fmt:
	rebar3 fmt

fmt-check:
	rebar3 fmt --check

# cowboy and the test helpers only exist in the test profile, so xref has to
# run there or every optional cowboy_req call looks undefined.
xref:
	rebar3 as test xref

eunit:
	rebar3 eunit

ct:
	rebar3 ct

# The dialyzer profile adds cowboy to the PLT without pulling the test sources
# into the analysis.
dialyzer:
	rebar3 as dialyzer dialyzer

test: xref eunit ct dialyzer

ci: fmt-check test

repl:
	rebar3 shell
