# Fixtures

Every file in this directory is a decoy. `play-service-account.json` carries
a real-shaped RSA private key (generated once with `openssl genrsa 2048` and
pasted in), because `validate-play-json.sh` and its tests need something
`openssl pkey`/`openssl rsa` will actually parse — but the key was never
used to authenticate anything, is not tied to any Google Cloud project, and
the `project_id`/`client_email`/`client_id` fields are made up.
`play-oauth-client.json` is a hand-written OAuth-client-download shape (the
wrong file type Play Console sometimes hands out instead of a service
account key) with an equally fake `client_secret`. None of these values are
credentials for anything real; do not reuse them.
