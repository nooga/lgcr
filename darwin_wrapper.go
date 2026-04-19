// lgcr macOS shim: forwards every invocation into the Lima 'letgo' VM,
// where the real Linux lgcr binary does the work. Kept minimal so there's
// nothing to diverge — the linux binary is the source of truth.
//
// Layout: ./lgcr (this) and ./lgcr.linux (the real one) live side-by-side.
// Lima bind-mounts /Users, so the linux binary at a /Users path is reachable
// inside the VM at the same path.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

func main() {
	self, err := os.Executable()
	if err != nil {
		die("can't resolve own path: " + err.Error())
	}
	if resolved, err := filepath.EvalSymlinks(self); err == nil {
		self = resolved
	}
	linuxBin := filepath.Join(filepath.Dir(self), "lgcr.linux")
	if _, err := os.Stat(linuxBin); err != nil {
		die("missing Linux binary alongside this shim: " + linuxBin +
			"\nRebuild with ./bundle.sh (needs sibling let-go checkout).")
	}

	limactl, err := exec.LookPath("limactl")
	if err != nil {
		die("Lima is not installed.\n  brew install lima")
	}
	out, _ := exec.Command(limactl, "list", "letgo", "--format", "{{.Status}}").Output()
	if !strings.Contains(string(out), "Running") {
		die("Lima 'letgo' VM is not running. Start it:\n" +
			"  limactl start --name=letgo --vm-type=vz --mount-writable --cpus=2 --memory=2")
	}

	argv := append([]string{"limactl", "shell", "letgo", "sudo", linuxBin}, os.Args[1:]...)
	if err := syscall.Exec(limactl, argv, os.Environ()); err != nil {
		die("exec limactl: " + err.Error())
	}
}

func die(msg string) {
	fmt.Fprintln(os.Stderr, "lgcr: "+msg)
	os.Exit(1)
}
