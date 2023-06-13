.PHONY: compile check clean cover dialyzer eqc pulse test xref
REBAR ?= rebar3

compile:
	$(REBAR) as prod compile

clean:
	$(REBAR) clean

cover: test
	$(REBAR) cover

test:
	$(REBAR) eunit

dialyzer:
	$(REBAR) as check dialyzer

eqc:
	$(REBAR) as eqc eqc

xref:
	$(REBAR) as check xref

PULSE_TESTING_TIME ?= 30

pulse:
	$(REBAR) as pulse compile
	mkdir -p .pulse
	cp eqc/pulse/Emakefile .pulse
	cp _build/pulse/lib/bitcask/ebin/bitcask.app .pulse
	(cd .pulse; \
		erl -make; \
		erl -noshell -s bitcask_pulse run_tests $(PULSE_TESTING_TIME))

check: test dialyzer xref
