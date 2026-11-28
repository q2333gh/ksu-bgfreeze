use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::path::Path;

/// Holds an exclusive flock for the daemon lifetime.
pub struct DaemonLock {
    _file: File,
}

impl DaemonLock {
    pub fn try_acquire(path: &Path) -> io::Result<Self> {
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .open(path)?;
        let fd = file.as_raw_fd();
        // SAFETY: flock on our exclusively opened lock file.
        let rc = unsafe { libc::flock(fd, libc::LOCK_EX | libc::LOCK_NB) };
        if rc != 0 {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EWOULDBLOCK)
                || err.raw_os_error() == Some(libc::EAGAIN)
            {
                return Err(io::Error::new(io::ErrorKind::WouldBlock, "lock held"));
            }
            return Err(err);
        }
        Ok(Self { _file: file })
    }
}

impl Drop for DaemonLock {
    fn drop(&mut self) {
        let fd = self._file.as_raw_fd();
        unsafe {
            let _ = libc::flock(fd, libc::LOCK_UN);
        }
    }
}
