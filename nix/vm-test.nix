# Start chezterm in a headless sway, type a command into it with wtype and
# check that the shell ran it; keeps a grim screenshot and a --dump-frame
# image in the output.
{ pkgs, chezterm }:

pkgs.testers.runNixOSTest {
  name = "chezterm";

  nodes.machine = {
    environment.systemPackages = [
      chezterm
      pkgs.sway
      pkgs.wtype
      pkgs.grim
    ];
    fonts.packages = [ pkgs.dejavu_fonts ];
    environment.etc."sway-test.conf".text = ''
      output HEADLESS-1 resolution 1024x768
      default_border none
    '';
    virtualisation.memorySize = 1024;
  };

  testScript = ''
    runtime = "XDG_RUNTIME_DIR=/run/user/0"
    # systemd-run units get a minimal PATH; sway's wrapper needs dbus-run-session.
    path = "PATH=/run/current-system/sw/bin"
    wl = f"{runtime} WAYLAND_DISPLAY=wayland-1"

    def run_unit(name, env, command):
        # Transient units, so the processes do not hold the test shell's output.
        setenv = " ".join(f"--setenv={e}" for e in env.split())
        machine.succeed(f"systemd-run --unit={name} --working-directory=/tmp {setenv} {command}")

    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p -m 0700 /run/user/0")

    try:
        run_unit(
            "sway",
            f"{path} {runtime} WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1",
            "sway -c /etc/sway-test.conf",
        )
        machine.wait_until_succeeds("test -S /run/user/0/wayland-1", timeout=120)

        run_unit("chezterm", f"{path} {wl} SHELL=/bin/sh", "chezterm")
        machine.wait_until_succeeds(
            f"SWAYSOCK=$(echo /run/user/0/sway-ipc.*.sock) {wl} swaymsg -t get_tree"
            " | grep -q '\"app_id\": \"chezterm\"'",
            timeout=300,
        )

        # Each wtype call is a new virtual keyboard, so give chezterm time for
        # the keymap between keys.
        machine.succeed(f"{wl} wtype -s 200 'echo typed-into-chezterm > /tmp/marker'")
        machine.succeed(f"{wl} wtype -s 200 -k Return")
        machine.wait_until_succeeds("grep -qx typed-into-chezterm /tmp/marker", timeout=300)

        machine.succeed(f"{wl} grim /tmp/screenshot.png")
        machine.copy_from_machine("/tmp/screenshot.png")

        # The hidden --dump-frame option renders one frame to a PPM and exits.
        machine.succeed(
            f"{wl} timeout 120 chezterm --dump-frame /tmp/frame.ppm:1000"
            " -e sh -c 'echo dumped; sleep 60' </dev/null >/tmp/dump.log 2>&1"
        )
        machine.succeed("head -c 2 /tmp/frame.ppm | grep -qx P6")
        machine.copy_from_machine("/tmp/frame.ppm")
    finally:
        print(machine.execute("journalctl --no-pager -u sway -u chezterm")[1])
  '';
}
