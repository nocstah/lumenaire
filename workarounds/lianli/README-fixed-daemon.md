# Optional: running a patched lian-li-linux daemon

`pc-lights` works with the stock `lianli-daemon`. This page describes an
**optional**, manual workaround for two daemon bugs that some hardware hits.
`pc-lights install` never builds, downloads or installs a daemon binary, and
never writes the drop-in below; it only reports one that you set up yourself
(`pc-lights detect` records it as the workaround `lianli.fixed_binary`).

## Do you need it?

Only if you see one of these:

- **Changes take minutes to land, or never do.** `pc-lights on` reports
  success, the daemon's config file has the new colours, but the fans and
  screens keep the old look, or change a minute or more later. The daemon's
  memory also keeps growing.
  Cause: the daemon queues a device poll every second whatever happens. When a
  poll takes longer than that (a HydroShift II OLED Curve pump read waits out a
  2 s USB timeout on every poll), the queue grows without bound and IPC
  requests such as `SetConfig` wait behind the backlog.
  Upstream: issue lian-li-linux #219, fix in PR #220 ("bound queued device
  polls").
- **No pump RPM or coolant temperature** from a HydroShift II OLED Curve
  (`0416:8051`), and the Lumenaire panel shows "–" for both.
  Cause: the daemon reads the LED controller's 64-byte replies into an 8-byte
  buffer, so every telemetry read overflows and the next one times out.
  Upstream: issue #222, fix in PR #223 ("read full-size replies from the OLED
  Curve LED MCU"). This fix also removes the 2 s stall behind #219.

If neither applies to you, stop here. Once your packaged `lian-li-linux`
includes both fixes, you don't need any of this.

## Build it

You need a Rust toolchain, `git` and `nasm` (the LCD encoder needs it). Build
in a capped cgroup if other heavy jobs run (`pcl-heavy` does that):

```bash
git clone https://github.com/sgtaziz/lian-li-linux ~/src/lian-li-linux
cd ~/src/lian-li-linux
# check out the SAME version as your installed package (see below); for a
# -git package the commit is in its version, e.g. 1.1.2.r0.g9485465 -> 9485465
git checkout 9485465
# apply the two upstream PRs (#220, #223) on top, e.g. with gh:
gh pr diff 220 | git apply
gh pr diff 223 | git apply
cargo build --release -p lianli-daemon
install -Dm755 target/release/lianli-daemon ~/.local/lib/pc-lights/lianli-daemon-fixed
```

**Match the version.** pc-lights writes to the daemon live through its write
guard, which is stamped with the daemon's version. A patched daemon built from
a different version than the GUI and tools you have installed makes every live
write fail the guard, and pc-lights falls back to stopping and restarting the
daemon for each change (slow, but safe). Check with
`pacman -Q lianli-linux-git` (or your package) against
`echo '{"method":"GetDaemonInfo"}' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/lianli-daemon.sock`.

## Run it

Point the user unit at the binary with a drop-in; the packaged unit and binary
stay untouched:

```bash
mkdir -p ~/.config/systemd/user/lianli-daemon.service.d
cat > ~/.config/systemd/user/lianli-daemon.service.d/zz-fixed-binary.conf <<'CONF'
[Service]
ExecStart=
ExecStart=%h/.local/lib/pc-lights/lianli-daemon-fixed
CONF
systemctl --user daemon-reload
systemctl --user restart lianli-daemon   # the lights and screens re-apply within ~30 s
```

The empty `ExecStart=` clears the packaged one; the name `zz-…` makes it load
after any other drop-in (for example pc-lights' `wake-fan-lcds.conf`, which
only adds an `ExecStartPre`).

## Undo it

Do this **whenever you upgrade the lian-li-linux package**, and for good once
the fixes are released:

```bash
rm ~/.config/systemd/user/lianli-daemon.service.d/zz-fixed-binary.conf
systemctl --user daemon-reload
systemctl --user restart lianli-daemon
```

`pc-lights detect` warns when the drop-in is present and the running daemon's
version differs from the installed package.
