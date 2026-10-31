//! Builds the CryptoKit shim on macOS. Swift's `device-key` item holds CryptoKit's
//! `dataRepresentation`, which only CryptoKit can load, so the Rust client has to go through it for
//! the handle to survive the cutover.
use std::{env, path::PathBuf, process::Command};

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let source = "src/enclave.swift";
    println!("cargo:rerun-if-changed={source}");
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
        "aarch64" => "arm64",
        other => other,
    }
    .to_string();
    let status = Command::new("xcrun")
        .args(["--sdk", "macosx", "swiftc", "-O", "-parse-as-library", "-static", "-emit-library", "-module-name", "LocalFlowEnclave"])
        .args(["-target", &format!("{arch}-apple-macos13"), "-o"])
        .arg(out.join("liblocalflow_enclave.a"))
        .arg(source)
        .status()
        .expect("xcrun swiftc");
    assert!(status.success(), "swiftc failed on {source}");
    let sdk = Command::new("xcrun").args(["--sdk", "macosx", "--show-sdk-path"]).output().expect("xcrun");
    let sdk = String::from_utf8(sdk.stdout).unwrap();
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=localflow_enclave");
    println!("cargo:rustc-link-search=native={}/usr/lib/swift", sdk.trim());
}
