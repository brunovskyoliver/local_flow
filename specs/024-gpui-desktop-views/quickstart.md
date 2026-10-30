# Quickstart: Feature 024

```sh
cargo test --workspace                 # headless view and logic tests
python3 scripts/check-parity-inventory.py
LOCALFLOW_DATA_ROOT=$PWD/build/fixture-root cargo run -p localflow    # the app, on fixture data
```
