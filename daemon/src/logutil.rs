use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct Logger {
    path: PathBuf,
}

impl Logger {
    pub fn open(path: &Path) -> io::Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        Ok(Self {
            path: path.to_path_buf(),
        })
    }

    pub fn write(&mut self, msg: &str) -> io::Result<()> {
        self.rotate_if_needed()?;
        let mut f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        let ts = now_stamp();
        writeln!(f, "{ts} {msg}")?;
        Ok(())
    }

    fn rotate_if_needed(&self) -> io::Result<()> {
        let meta = match fs::metadata(&self.path) {
            Ok(m) => m,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(e) => return Err(e),
        };
        if meta.len() > 200_000 {
            let bak = self.path.with_extension("log.1");
            let _ = fs::rename(&self.path, bak);
        }
        Ok(())
    }
}

fn now_stamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Lightweight stamp; avoid forking `date`.
    format!("{secs}")
}
