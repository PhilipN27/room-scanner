# Pinned Amazon RDS CA bundle

- Asset: `rds-global-bundle-2026-08-19.pem`
- SHA-256: `e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3`
- Retrieved: 2026-08-19
- Source: <https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem>
- Authority: [Amazon RDS TLS certificate bundles](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html)

AWS documents `global-bundle.pem` as the PEM bundle for commercial regions and
states that an application trust store should contain root CA certificates, not
intermediate certificates. The migration operator reads this tracked bundle
from its deployed `/var/task` asset path, verifies this exact SHA-256 before
opening PostgreSQL, and requires TLS hostname verification. Replacing the
bundle requires a deliberate asset, hash, review, and live rotation rehearsal;
this file does not authorize an AWS deployment or certificate rotation.
