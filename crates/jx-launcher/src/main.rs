use std::env;
use std::fs::{self, File};
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{self, Command};
use flate2::read::GzDecoder;
use tar::Archive;

fn main() {
    if let Err(e) = run() {
        eprintln!("jx-launcher: {}", e);
        process::exit(1);
    }
}

fn run() -> io::Result<()> {
    // 1. Resolve launcher directory
    let exe_path = env::current_exe()?;
    let launcher_dir = exe_path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "could not resolve launcher dir"))?
        .to_path_buf();

    // 2. Read version.txt
    let version_path = launcher_dir.join("version.txt");
    let version = fs::read_to_string(&version_path)?
        .trim()
        .to_string();
    if version.is_empty() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "version.txt is empty"));
    }

    // 3. Determine target triple at compile time
    let target = target_triple();

    // 4. Compute cache paths
    let cache_dir = dirs::cache_dir()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "could not determine cache dir"))?
        .join("jx")
        .join("releases")
        .join(&version)
        .join(target);

    let partial_dir = cache_dir.with_extension("partial");
    let bin_jx = cache_dir.join("bin").join("jx");

    // 5. Extract if needed
    if !bin_jx.exists() {
        let tarball_path = launcher_dir.join("jx-release.tar.gz");
        if !tarball_path.exists() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("sidecar tarball not found: {}", tarball_path.display()),
            ));
        }

        // Clean up any stale partial dir
        if partial_dir.exists() {
            fs::remove_dir_all(&partial_dir)?;
        }
        fs::create_dir_all(&partial_dir)?;

        extract_tarball(&tarball_path, &partial_dir)?;

        // Ensure bin/jx exists after extraction
        if !partial_dir.join("bin").join("jx").exists() {
            fs::remove_dir_all(&partial_dir)?;
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "extracted tarball does not contain bin/jx",
            ));
        }

        // Atomic rename: partial -> final
        fs::rename(&partial_dir, &cache_dir)?;
    }

    // 6. Ensure bin/jx is executable
    let mut perms = fs::metadata(&bin_jx)?.permissions();
    let mode = perms.mode();
    if mode & 0o111 == 0 {
        perms.set_mode(mode | 0o111);
        fs::set_permissions(&bin_jx, perms)?;
    }

    // 7. Collect argv for passthrough
    let args: Vec<String> = env::args().skip(1).collect();

    // 8. Exec into bin/jx, replacing this process
    let mut cmd = Command::new(&bin_jx);
    cmd.args(&args);
    cmd.current_dir(&launcher_dir);

    let err = cmd.exec();
    Err(err)
}

fn target_triple() -> &'static str {
    if cfg!(target_os = "macos") && cfg!(target_arch = "aarch64") {
        "aarch64-apple-darwin"
    } else if cfg!(target_os = "linux") && cfg!(target_arch = "x86_64") {
        "x86_64-unknown-linux-gnu"
    } else {
        panic!("unsupported target platform")
    }
}

fn extract_tarball(tarball: &Path, dest: &Path) -> io::Result<()> {
    let file = File::open(tarball)?;
    let decoder = GzDecoder::new(file);
    let mut archive = Archive::new(decoder);

    for entry_result in archive.entries()? {
        let mut entry = entry_result?;

        // Validate entry path to prevent path traversal
        let path = entry.path()?;
        let cleaned = path.components().collect::<PathBuf>();
        if cleaned.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("tar entry contains path traversal: {}", path.display()),
            ));
        }

        let out_path = dest.join(&cleaned);

        // Extra safety: ensure the output path stays within dest
        if !out_path.starts_with(dest) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("tar entry escapes destination: {}", path.display()),
            ));
        }

        entry.unpack_in(dest)?;
    }

    Ok(())
}
