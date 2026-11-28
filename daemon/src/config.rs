use std::fs;
use std::io;
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Stop,
    Disable,
}

pub struct Paths {
    pub moddir: PathBuf,
    pub data: PathBuf,
    pub blacklist: PathBuf,
    pub modefile: PathBuf,
    pub lock: PathBuf,
    pub pidfile: PathBuf,
    pub log: PathBuf,
    pub circuit: PathBuf,
    pub packages_list: PathBuf,
    /// Must exist to allow mode=disable at all.
    pub allow_disable: PathBuf,
    /// Boot may keep disable mode only if this + allow_disable exist.
    pub allow_disable_on_boot: PathBuf,
}

impl Paths {
    pub fn discover() -> Self {
        let moddir = std::env::var_os("MODDIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/data/adb/modules/ksu-bgfreeze"));
        let data = PathBuf::from("/data/adb/ksu-bgfreeze");
        let mut blacklist = data.join("blacklist.txt");
        if !blacklist.is_file() {
            blacklist = moddir.join("config/blacklist.txt");
        }
        Self {
            modefile: data.join("mode"),
            lock: data.join("daemon.lock"),
            pidfile: data.join("daemon.pid"),
            log: PathBuf::from("/data/local/tmp/ksu-bgfreeze.log"),
            circuit: data.join("circuit.open"),
            packages_list: PathBuf::from("/data/system/packages.list"),
            allow_disable: data.join("allow-disable"),
            allow_disable_on_boot: data.join("allow-disable-on-boot"),
            blacklist,
            data,
            moddir,
        }
    }

    pub fn disable_allowed(&self) -> bool {
        self.allow_disable.is_file()
    }

    /// Boot may keep disable only when both allow files exist (service.sh also enforces).
    #[allow(dead_code)]
    pub fn boot_disable_allowed(&self) -> bool {
        self.allow_disable.is_file() && self.allow_disable_on_boot.is_file()
    }
}

pub struct Settings {
    pub mode: Mode,
}

impl Settings {
    pub fn load(paths: &Paths) -> io::Result<Self> {
        let mut s = Self { mode: Mode::Stop };
        s.reload_mode(paths)?;
        Ok(s)
    }

    pub fn reload_mode(&mut self, paths: &Paths) -> io::Result<()> {
        if paths.circuit.is_file() {
            self.mode = Mode::Stop;
            return Ok(());
        }
        let raw = fs::read_to_string(&paths.modefile).unwrap_or_else(|_| "stop".into());
        let m = raw.trim();
        self.mode = match m {
            "disable" | "tombstone" | "hail" => {
                if paths.disable_allowed() {
                    Mode::Disable
                } else {
                    // Hard gate: refuse disable without allow file
                    let _ = fs::write(&paths.modefile, b"stop\n");
                    Mode::Stop
                }
            }
            _ => Mode::Stop,
        };
        Ok(())
    }
}
