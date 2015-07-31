# RabbitMQ Test Suites

## Useful targets

    make unit # runs the Erlang unit tests
    make lite # runs the Erlang unit tests and the Java client / functional tests
    make full # runs both the above plus the QPid test suite
    make test # runs the Erlang multi-node integration tests
    make all  # runs all of the above

The multi-node tests take a long time, so you might want to run a subset:

    make test FILTER=dynamic_ha               # <- run just one suite
    make test FILTER=dynamic_ha:change_policy # <- run just one test

The multi-node tests also default to coverage off, to turn it on:

    make test COVER=true

This repository is not related to plugin tests; run "make test" in a
plugin directory to test that plugin.
