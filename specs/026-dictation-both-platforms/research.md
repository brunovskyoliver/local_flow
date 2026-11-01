# Research: Feature 026
## R1 sherpa-onnx
Phase 0 used v2.0.1 and `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` on a VM: English WER 4.78%, Slovak 15.87%, RTF 0.036, 752-830 MB peak per file, not x64 evidence. The Slovak figure is inside the owner's allowance of 5 points worse. A Rust crate would build ONNX Runtime at compile time and break cross-builds; dynamic loading avoids that. Licences: sherpa-onnx Apache-2.0, ONNX Runtime MIT, Parakeet CC-BY-4.0 with attribution in the notices.
## R2 Hashes
Pinned hashes must come from really downloaded files. Record the source and date; never write a hash that wasn't computed here.
