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
            blacklist,
            data,
            moddir,
        }
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
            "disable" | "tombstone" | "hail" => Mode::Disable,
            _ => Mode::Stop,
        };
        Ok(())
    }
}
