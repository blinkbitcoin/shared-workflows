# Fixture apps for the store-notes suite

`base/` is an app with a store-notes prompt and a store listing in two
locales, beside the `review_information` directory deliver keeps there; the
suite passes it. Each directory under `cases/` is laid over a copy of
`base/`, and its `case.json` says whether the suite passes there and what its
output must say. The suite runs the real generator, and a local stand-in for
the model, so these apps need no `node_modules`.
