//! Hail-style whole-package disable — one attempt, verify once, fail-fast.

use std::collections::HashSet;
use std::io;
use std::time::Duration;

use crate::ipc::run_capped;

pub fn is_critical(pkg: &str) -> bool {
    matches!(
        pkg,
        "android"
            | "com.android.systemui"
            | "com.android.phone"
            | "com.android.server.telecom"
            | "com.android.settings"
            | "com.android.permissioncontroller"
            | "com.android.providers.settings"
            | "com.android.nfc"
            | "com.android.keychain"
            | "com.android.keystore"
            | "com.android.shell"
            | "com.android.bluetooth"
            | "com.android.vending"
            | "com.google.android.gms"
            | "com.google.android.gsf"
    ) || pkg.starts_with("com.android.launcher")
        || pkg.starts_with("com.android.providers.media")
        || pkg.starts_with("com.android.inputmethod")
        || pkg.starts_with("com.google.android.inputmethod")
        || pkg.starts_with("com.android.networkstack")
        || pkg.starts_with("com.oplus.")
        || pkg.starts_with("net.oneplus.")
        || pkg.starts_with("com.oneplus.")
        || pkg.starts_with("com.coloros.")
        || pkg.starts_with("com.qti.")
        || pkg.starts_with("com.qualcomm.")
        || pkg.starts_with("com.android.lmk")
        || pkg.starts_with("me.weishu.kernelsu")
        || pkg.starts_with("com.rifsxd.ksunext")
        || pkg.starts_with("com.topjohnwu.magisk")
}

pub fn is_binder_fail(msg: &str) -> bool {
    msg.contains("Failed transaction")
        || msg.contains("DeadObject")
        || msg.contains("NullPointerException")
        || msg.contains("RemoteException")
        || msg.contains("TimedOut")
        || msg.contains("timeout")
}

fn current_user() -> u32 {
    run_capped(
        "/system/bin/am",
        &["get-current-user"],
        Duration::from_secs(2),
        64,
    )
    .ok()
    .and_then(|b| String::from_utf8_lossy(&b).trim().parse().ok())
    .unwrap_or(0)
}

/// Θ(D) — one binder call.
pub fn list_disabled() -> io::Result<HashSet<String>> {
    let out = run_capped(
        "/system/bin/pm",
        &["list", "packages", "-d"],
        Duration::from_secs(3),
        256 * 1024,
    )?;
    let mut set = HashSet::new();
    for line in String::from_utf8_lossy(&out).lines() {
        if let Some(pkg) = line.strip_prefix("package:") {
            set.insert(pkg.trim().to_string());
        }
    }
    Ok(set)
}

pub fn apply_disable(pkg: &str) -> io::Result<()> {
    if is_critical(pkg) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "critical package",
        ));
    }
    let uid = current_user();
    let uid_s = uid.to_string();

    if let Err(e) = run_capped(
        "/system/bin/am",
        &["force-stop", "--user", &uid_s, pkg],
        Duration::from_secs(3),
        1024,
    ) {
        if is_binder_fail(&e.to_string()) {
            return Err(e);
        }
        // force-stop non-binder failure: continue to disable once
    }

    let out = run_capped(
        "/system/bin/pm",
        &["disable", "--user", &uid_s, pkg],
        Duration::from_secs(3),
        4096,
    );
    match out {
        Ok(_) => {}
        Err(e) => {
            // binder fails already counted inside run_capped
            return Err(e);
        }
    }

    let disabled = list_disabled()?;
    if disabled.contains(pkg) {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::Other,
            "verify-fail: package still enabled",
        ))
    }
}

pub fn revive(pkg: &str) -> io::Result<()> {
    let uid = current_user();
    let uid_s = uid.to_string();
    let _ = run_capped(
        "/system/bin/pm",
        &["enable", "--user", &uid_s, pkg],
        Duration::from_secs(3),
        1024,
    );
    let _ = run_capped(
        "/system/bin/pm",
        &["unsuspend", "--user", &uid_s, pkg],
        Duration::from_secs(3),
        1024,
    );
    Ok(())
}
