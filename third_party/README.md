# Sotto source

`sotto/` is a source snapshot from https://github.com/davis7dotsh/sotto at commit
`c1d5f0bbaff19a1559621943dff49ba89b4a96a0`. `LOCALFLOW-UPSTREAM.json` records
provenance and the omitted inference submodules. The upstream MIT license and
third-party notices are preserved.

This snapshot is the reference for native UI reuse. LocalFlow builds its own
single app through `make macos`; it does not build this package or run Sotto's
server. The adapted sidebar and theme live in
`apps/macos/LocalFlow/App/LocalFlowApp.swift`. Keep changes there; retain the
snapshot for comparison with future upstream revisions.

The upstream instructions describe Sotto's server-based product. They do not
describe LocalFlow's offline speech, local history or optional future Go service.
No submodule source, package dependencies or model weights were downloaded with
this snapshot. To investigate a complete upstream build, clone the recorded
revision separately and follow its README.
