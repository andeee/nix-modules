{ inputs, ... }:
{
  # Checks for `auto-upgrade` (modules/features/auto-upgrade.nix).
  #
  # Everything that can be wrong here is wrong at eval time or inside a shell
  # string, so every property is checked on a *synthetic* node: the library has no
  # hosts, no repository and no secrets, and a check must not invent any. Where
  # the behaviour lives in a script, the script is executed against stubbed
  # commands and a faked state directory rather than inspected by substring — a
  # substring match passes just as happily when the logic is inverted.
  perSystem =
    { pkgs, lib, system, ... }:
    let
      # `greetd` is part of nixpkgs, so "a greeter is present" needs no stub — only
      # `services.greetd.enable`. lanzaboote is an external flake this library has
      # no input for, so its two options are stubbed; the point of the retention
      # decision is exactly *which* of two loaders is present.
      lanzabooteStub = {
        options.boot.lanzaboote = {
          enable = lib.mkEnableOption "lanzaboote (test stub)";
          configurationLimit = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
          };
        };
        config.boot.lanzaboote.enable = true;
      };

      mkNode =
        extra:
        inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            inputs.self.nixosModules.auto-upgrade
            {
              system.stateVersion = "26.05";
              networking.hostName = "synthetic";
              autoUpgrade = {
                enable = true;
                repoUrl = "git+ssh://git@forge.invalid/example/repo";
                builtMarkerPath = "/var/lib/ci/last-built-rev";
              };
            }
            extra
          ];
        };

      # The host that shares a machine with CI: marker gate, lock, notice, weekly
      # reboot, fetch credential, lanzaboote, greetd.
      marker = mkNode {
        imports = [ lanzabooteStub ];
        services.greetd.enable = true;
        autoUpgrade = {
          gate = "built-marker";
          window = "*-*-* 02:15:00";
          exclusiveLock = "/var/lib/ci/ci.lock";
          waitTimeoutSeconds = 900;
          notify.enable = true;
          notify.leadSeconds = 120;
          fetch = {
            identityFile = "/run/secrets/fetch-ssh-key";
            host = "forge.invalid";
            hostPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYONLY";
          };
          reboot = {
            window = "Sat *-*-* 02:55:00";
            onlyWhenPending = false;
          };
        };
      };

      # The laptop-shaped host: substitutability gate, no lock, no notice, no
      # reboot, systemd-boot.
      subst = mkNode {
        boot.loader.systemd-boot.enable = true;
        autoUpgrade = {
          gate = "substitutable";
          window = "*-*-* 12:15:00";
        };
      };

      # No gate, no retention, conservative reboot policy, and no greeter.
      pending = mkNode {
        autoUpgrade = {
          gate = "none";
          window = "*-*-* 03:15:00";
          retention.enable = false;
          reboot.window = "Sat *-*-* 04:45:00";
        };
      };

      markerCfg = marker.config;
      substCfg = subst.config;
      pendingCfg = pending.config;

      unit = markerCfg.systemd.services.nixos-upgrade;
      substUnit = substCfg.systemd.services.nixos-upgrade;
      helpers = markerCfg.autoUpgrade._helpers;

      preflight = lib.trim unit.preStart;
      substPreflight = lib.trim substUnit.preStart;
      activation = lib.trim unit.script;
      substActivation = lib.trim substUnit.script;

      rebootScript = lib.trim markerCfg.systemd.services.nixos-upgrade-reboot.script;
      pendingRebootScript = lib.trim pendingCfg.systemd.services.nixos-upgrade-reboot.script;

      sshConfig = markerCfg.environment.etc."ssh/ssh_config".text;
      sshKnownHosts = markerCfg.environment.etc."ssh/ssh_known_hosts".text;

      upgradeUnit = markerCfg.system.autoUpgrade;
      timer = markerCfg.systemd.timers.nixos-upgrade.timerConfig;
      rebootTimer = markerCfg.systemd.timers.nixos-upgrade-reboot.timerConfig;

      count = needle: haystack: lib.length (lib.splitString needle haystack) - 1;

      # Stubs for the four commands the notice and reboot scripts call. Written as
      # derivations (not heredocs inside the build script) so their indentation is
      # real indentation and their shebangs are on line 1.
      stubLoginctl = pkgs.writeShellScriptBin "loginctl" ''
        # `list-sessions` prints "id uid user seat active type", which is the same
        # column order the real tool uses for the first three fields.
        case "''${1:-}" in
          list-sessions) cat "$SESSIONS" ;;
          show-session)
            # loginctl show-session <id> -p <property> --value
            key="''${4:-}"
            line=$(grep -E "^[[:space:]]*''${2:-} " "$SESSIONS" || true)
            [ -n "$line" ] || exit 1
            set -- $line
            case "$key" in
              Type) echo "$6" ;;
              Active) echo "$5" ;;
            esac
            ;;
        esac
      '';

      stubRunuser = pkgs.writeShellScriptBin "runuser" ''
        # The real invocation is `runuser -u USER -- env … notify-send …`; the
        # user is what the assertions care about.
        echo "$*" >> "$NOTIFY_LOG"
      '';

      stubWall = pkgs.writeShellScriptBin "wall" ''
        while read -r line; do echo "wall: $line" >> "$NOTIFY_LOG"; done
      '';

      stubSystemctl = pkgs.writeShellScriptBin "systemctl" ''
        if [ "''${1:-}" = is-active ]; then exit 1; fi
        echo "systemctl $*" >> "$REBOOT_LOG"
      '';

      failures =
        lib.optional (upgradeUnit.flake != "git+ssh://git@forge.invalid/example/repo?ref=main")
          "the unit does not follow the configured ref (flake = ${upgradeUnit.flake})"
        ++ lib.optional (upgradeUnit.operation != "switch") "operation must be \"switch\""
        ++ lib.optional upgradeUnit.allowReboot "allowReboot must stay false: the activation never reboots"
        ++ lib.optional (!upgradeUnit.persistent) "persistent must stay true: a missed window must run when the host returns"
        ++ lib.optional (count "--refresh" (lib.concatStringsSep " " upgradeUnit.flags) != 1)
          "expected exactly one --refresh in flags; upstream injects it for any flake, so the module must not add its own"
        ++ lib.optional (count "flock" preflight == 0)
          "the preflight does not probe exclusiveLock: a CI job and an evaluation could run at once"
        ++ lib.optional (!(lib.hasInfix "still held after 900s" preflight))
          "the lock timeout does not skip the window"
        ++ lib.optional (lib.hasInfix "flock" substPreflight || lib.hasInfix "flock" substActivation)
          "a host without exclusiveLock still waits on a lock"
        ++ lib.optional (!(lib.hasInfix "ls-remote git@forge.invalid:example/repo" preflight))
          "the scp-like URL was not derived from repoUrl (git rejects git+ssh://)"
        ++ lib.optional (!(lib.hasInfix "nixos-upgrade-classify" preflight))
          "ref-resolution failures are not classified"
        ++ lib.optional (!(lib.hasInfix "refs/heads/main" preflight)) "the configured ref is not resolved"
        ++ lib.optional (!(lib.hasInfix "rev=$rev marker does not list synthetic" preflight))
          "the marker gate does not require the marker to cover this host"
        ++ lib.optional (!(lib.hasInfix "marker says $builtRev" preflight))
          "the marker gate does not compare revisions"
        ++ lib.optional (lib.hasInfix "nix build --dry-run" preflight)
          "the built-marker gate still evaluates the flake: that is the cost it exists to avoid"
        ++ lib.optional (!(lib.hasInfix "nixosConfigurations.synthetic" substPreflight))
          "the substitutability gate does not pin the revision to this host's toplevel"
        ++ lib.optional (!(lib.hasInfix "preflight could not be answered" substPreflight))
          "an unanswerable preflight is not a skip"
        ++ lib.optional (!(lib.hasPrefix "if [ -e /run/nixos-upgrade/skip ]" activation))
          "the skip guard is not prepended to the activation: a skipped window would still switch"
        ++ lib.optional (lib.hasInfix "--boot" activation || lib.hasInfix "--boot" substActivation)
          "the activation carries a reboot flag"
        ++ lib.optional (!(lib.hasInfix "nixos-upgrade-notify" activation))
          "notify.enable = true does not reference the notifier"
        ++ lib.optional (!(lib.hasInfix "sleep 120" activation))
          "the configured lead time is not applied before the activation"
        ++ lib.optional (lib.hasInfix "nixos-upgrade-notify" substActivation)
          "a host with notify disabled still notifies"
        ++ lib.optional (!(lib.hasInfix "nixos-upgrade-outcome" unit.serviceConfig.ExecStopPost))
          "ExecStopPost does not point at the outcome script"
        ++ lib.optional (!(lib.hasInfix "Host forge.invalid" sshConfig))
          "no Host block for the fetch host in the rendered ssh_config"
        ++ lib.optional (!(lib.hasInfix "IdentityFile /run/secrets/fetch-ssh-key" sshConfig))
          "the fetch credential is not the IdentityFile"
        ++ lib.optional (!(lib.hasInfix "IdentitiesOnly yes" sshConfig))
          "IdentitiesOnly is missing: root's other keys could be offered"
        ++ lib.optional (lib.hasInfix "StrictHostKeyChecking" sshConfig)
          "ssh_config overrides StrictHostKeyChecking: host key verification must stay on"
        ++ lib.optional (!(lib.hasInfix "forge.invalid " sshKnownHosts))
          "the pinned host key is not in /etc/ssh/ssh_known_hosts"
        ++ lib.optional markerCfg.systemd.services.greetd.restartIfChanged
          "an activation can restart greetd and kill the session under it"
        ++ lib.optional (pendingCfg.systemd.services ? greetd)
          "a host without a greeter gets a greetd unit definition anyway"
        ++ lib.optional (lib.toList rebootTimer.OnCalendar != [ "Sat *-*-* 02:55:00" ])
          "the reboot timer does not fire on the configured window (${lib.concatStringsSep "," (lib.toList rebootTimer.OnCalendar)})"
        ++ lib.optional (lib.toList rebootTimer.OnCalendar == lib.toList timer.OnCalendar)
          "the reboot window equals the upgrade window"
        ++ lib.optional (lib.hasInfix "no pending kernel/initrd change" rebootScript)
          "reboot.onlyWhenPending = false still refuses to reboot without debt"
        ++ lib.optional (!(lib.hasInfix "no pending kernel/initrd change" pendingRebootScript))
          "reboot.onlyWhenPending = true does not skip a week without debt"
        ++ lib.optional (!(lib.hasInfix "held by a CI job" rebootScript))
          "the reboot unit does not respect exclusiveLock"
        ++ lib.optional (!(lib.hasInfix "nixos-upgrade.service is running" rebootScript))
          "the reboot unit does not wait for an activation in flight"
        ++ lib.optional (!(lib.hasInfix "systemctl\" reboot" rebootScript) && !(lib.hasInfix "systemctl reboot" rebootScript))
          "the reboot unit does not reboot at all"
        ++ lib.optional (markerCfg.boot.lanzaboote.configurationLimit != 10)
          "retention was not applied to the lanzaboote loader this host boots through"
        ++ lib.optional (substCfg.boot.loader.systemd-boot.configurationLimit != 10)
          "retention was not applied to the systemd-boot loader this host boots through"
        ++ lib.optional (!substCfg.nix.gc.automatic) "periodic garbage collection is not enabled"
        ++ lib.optional (substCfg.nix.gc.options != "--delete-older-than 14d")
          "garbage collection does not prune generations (nix.gc.options = ${substCfg.nix.gc.options})"
        ++ lib.optional pendingCfg.nix.gc.automatic "retention.enable = false still enables nix.gc"
        ++ lib.optional (pendingCfg.boot.loader.systemd-boot.configurationLimit != null)
          "retention.enable = false still sets a generation cap";
    in
    {
      checks.auto-upgrade =
        pkgs.runCommand "check-auto-upgrade"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.gnused
              pkgs.util-linux
              pkgs.python3
              helpers.classify
              helpers.notify
              helpers.outcome
            ];
            inherit (unit.serviceConfig) ExecStopPost;
            inherit sshConfig sshKnownHosts;
            inherit (helpers) notify;
            loginctlStub = lib.getExe' stubLoginctl "loginctl";
            runuserStub = lib.getExe' stubRunuser "runuser";
            wallStub = lib.getExe' stubWall "wall";
            systemctlStub = lib.getExe' stubSystemctl "systemctl";
            passAsFile = [
              "preflight"
              "activation"
              "rebootScript"
              "pendingRebootScript"
            ];
            inherit preflight activation rebootScript pendingRebootScript;
          }
          (
            lib.optionalString (failures != [ ]) ''
              cat >&2 <<'EOF'
              FAIL: auto-upgrade renders the wrong configuration:
              ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failures}

              See modules/features/auto-upgrade.nix.
              EOF
              exit 1
            ''
            + ''
              set -euo pipefail

              fail() { echo "FAIL: $*" >&2; exit 1; }

              mkdir -p work
              busy=$(mktemp -d)
              export SESSIONS=$busy/sessions NOTIFY_LOG=$busy/log REBOOT_LOG=$busy/reboot.log
              : > "$NOTIFY_LOG"
              : > "$REBOOT_LOG"

              # ---- outcome line -------------------------------------------------
              cat "$ExecStopPost" > work/outcome.sh
              sed -i -e "s#/run/nixos-upgrade#$PWD/work/state#g" \
                     -e "s#/run/booted-system#$PWD/work/booted#g" \
                     -e "s#/run/current-system#$PWD/work/current#g" \
                     work/outcome.sh
              chmod +x work/outcome.sh
              mkdir -p work/state work/gen-a work/gen-b
              for part in kernel initrd; do
                echo a > "work/gen-a/$part"
                echo b > "work/gen-b/$part"
              done
              ln -s gen-a work/booted
              ln -s gen-a work/current
              echo deadbeefcafe > work/state/rev

              expect_line() {
                desc=$1; want=$2; shift 2
                got=$(env "$@" ./work/outcome.sh 2>&1)
                printf '%s\n' "$got" | grep -qx "$want" ||
                  fail "$desc: wanted '$want', got: $got"
              }

              expect_line "success" "nixos-upgrade: activated: rev=deadbeefcafe" EXIT_STATUS=0
              test ! -e work/state/reboot-pending || fail "reboot-pending written without a kernel change"

              rm work/current && ln -s gen-b work/current
              expect_line "kernel debt" "nixos-upgrade: reboot required (kernel,initrd changed)" EXIT_STATUS=0
              test -e work/state/reboot-pending || fail "no reboot-pending after a kernel change"

              rm -f work/state/reboot-pending
              expect_line "failed activation" "nixos-upgrade: failed: rev=deadbeefcafe activation exited 1" EXIT_STATUS=1
              test ! -e work/state/reboot-pending || fail "reboot-pending written by a failed run"

              rm work/current && ln -s gen-a work/current
              expect_line "clean again" "nixos-upgrade: activated: rev=deadbeefcafe" EXIT_STATUS=0
              test ! -e work/state/reboot-pending || fail "stale reboot-pending survived a clean activation"

              touch work/state/skip
              test -z "$(env EXIT_STATUS=0 ./work/outcome.sh 2>&1)" || fail "a skipped window also logged an outcome line"
              rm work/state/skip

              # ---- ref-error classification -------------------------------------
              classify=$(command -v nixos-upgrade-classify) || fail "the classify helper is not on PATH"
              grep -q "nixos-upgrade-classify" "$preflightPath" ||
                fail "the preflight does not call the classify helper"

              test "$("$classify" 'git@forge: Permission denied (publickey).')" = fatal ||
                fail "ssh authentication failure is not fatal"
              test "$("$classify" 'Host key verification failed.')" = fatal ||
                fail "host key failure is not fatal"
              test "$("$classify" 'remote: Repository not found.')" = fatal ||
                fail "a missing repository is not fatal"
              test "$("$classify" 'ssh: Could not resolve hostname forge: Name or service not known')" = transient ||
                fail "a DNS failure is not transient"
              test "$("$classify" 'ssh: connect to host forge port 22: Connection timed out')" = transient ||
                fail "a timeout is not transient"
              test "$("$classify" 'Network is unreachable')" = transient ||
                fail "an unreachable network is not transient"
              test "$("$classify" "")" = transient || fail "an unknown message is not transient"

              # ---- notice -------------------------------------------------------
              # Point the notifier's absolute tool paths at the stubs, and its
              # per-session runtime directory at the sandbox.
              sed -e "s#/nix/store/[^ ]*-systemd[^/]*/bin/loginctl#$loginctlStub#g" \
                  -e "s#/nix/store/[^ ]*-util-linux[^/]*/bin/runuser#$runuserStub#g" \
                  -e "s#/nix/store/[^ ]*-util-linux[^/]*/bin/wall#$wallStub#g" \
                  -e "s#/run/user#$PWD/work/run/user#g" \
                  "$notify/bin/nixos-upgrade-notify" > work/notify.sh
              chmod +x work/notify.sh
              grep -q "$runuserStub" work/notify.sh || fail "the runuser stub was not substituted"
              grep -q "$loginctlStub" work/notify.sh || fail "the loginctl stub was not substituted"

              # id uid user seat active type — a mix of graphical/inactive plus one
              # active text session (a VT must not get a desktop notification).
              {
                echo "1 1000 alice seat0 yes wayland"
                echo "2 1001 bob seat0 no wayland"
                echo "3 1002 carol seat0 yes x11"
                echo "4 1003 dave seat0 yes tty"
              } > "$SESSIONS"
              mkdir -p work/run/user/1000 work/run/user/1001 work/run/user/1002 work/run/user/1003
              # The notifier requires a real unix socket, which is what systemd
              # creates for a session; a plain file must not pass.
              mksocket() { python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"; }
              mksocket work/run/user/1000/bus
              mksocket work/run/user/1002/bus
              touch work/run/user/1001/bus

              ./work/notify.sh "upgrade in 120s" || fail "the notifier exited non-zero with sessions present"
              grep -q alice "$NOTIFY_LOG" || fail "no notice for the active wayland session"
              grep -q carol "$NOTIFY_LOG" || fail "no notice for the active x11 session"
              grep -q bob "$NOTIFY_LOG" && fail "notified an inactive session"
              grep -q dave "$NOTIFY_LOG" && fail "notified a text session"
              grep -q "upgrade in 120s" "$NOTIFY_LOG" || fail "the message did not reach the session"
              # The stub logs its arguments, so a notice line starts with "-u".
              notices=$(grep -c '^-u ' "$NOTIFY_LOG" || true)
              test "$notices" -eq 2 || fail "expected exactly two graphical notices, got $notices"

              # A bus *socket* is required: a regular file (1001) and a missing
              # one (1003) must both be skipped, and an inactive session (bob)
              # never reaches the bus at all.
              : > "$NOTIFY_LOG"
              rm -f work/run/user/1000/bus
              ./work/notify.sh "no bus" || fail "the notifier failed without a bus socket"
              grep -q alice "$NOTIFY_LOG" && fail "notified a session without a bus socket"
              grep -q bob "$NOTIFY_LOG" && fail "notified an inactive session"

              # Nobody logged in: silence, not an error.
              : > "$SESSIONS"
              ./work/notify.sh "nobody home" || fail "the notifier failed when nobody is logged in"

              # ---- reboot unit --------------------------------------------------
              sed -e "s#/run/nixos-upgrade#$PWD/work/state#g" \
                  -e "s#/var/lib/ci/ci.lock#$PWD/work/ci.lock#g" \
                  -e "s#/nix/store/[^ ]*-systemd[^/]*/bin/systemctl#$systemctlStub#g" \
                  "$rebootScriptPath" > work/reboot.sh
              sed -e "s#/run/nixos-upgrade#$PWD/work/state#g" \
                  -e "s#/nix/store/[^ ]*-systemd[^/]*/bin/systemctl#$systemctlStub#g" \
                  "$pendingRebootScriptPath" > work/reboot-pending.sh
              chmod +x work/reboot.sh work/reboot-pending.sh
              grep -q "$systemctlStub" work/reboot.sh || fail "the systemctl stub was not substituted"

              # Debt present, lock free: the line must precede the reboot call.
              echo "rev=deadbeefcafe" > work/state/reboot-pending
              : > work/ci.lock
              stdout=$(./work/reboot.sh)
              printf '%s\n' "$stdout" | grep -q "nixos-upgrade-reboot: rebooting" ||
                fail "no reboot line with debt present: $stdout"
              grep -qx "systemctl reboot" "$REBOOT_LOG" || fail "the unit did not call systemctl reboot"
              echo_line=$(grep -n "rebooting" work/reboot.sh | head -n 1 | cut -d: -f1)
              reboot_line=$(grep -n "systemctl reboot" work/reboot.sh | head -n 1 | cut -d: -f1)
              test "$echo_line" -lt "$reboot_line" ||
                fail "the reboot line is logged after the reboot, so it would be lost"

              # Lock held by CI: skip, do not reboot.
              : > "$REBOOT_LOG"
              flock work/ci.lock -c 'sleep 30' &
              holder=$!
              sleep 1
              stdout=$(./work/reboot.sh)
              printf '%s\n' "$stdout" | grep -q "held by a CI job" || fail "no skip when CI holds the lock: $stdout"
              test ! -s "$REBOOT_LOG" || fail "rebooted while CI held the lock"
              kill "$holder" 2>/dev/null || true
              wait "$holder" 2>/dev/null || true

              # onlyWhenPending = true and no debt: skip.
              rm -f work/state/reboot-pending
              stdout=$(./work/reboot-pending.sh)
              printf '%s\n' "$stdout" | grep -q "no pending kernel/initrd change" ||
                fail "the default policy reboots without debt: $stdout"

              # ---- rendered credential -----------------------------------------
              printf '%s' "$sshConfig" > work/ssh_config
              printf '%s' "$sshKnownHosts" > work/ssh_known_hosts
              grep -q "Host forge.invalid" work/ssh_config || fail "ssh_config lost the Host block"
              grep -q "IdentitiesOnly yes" work/ssh_config || fail "ssh_config lost IdentitiesOnly"
              grep -q "forge.invalid " work/ssh_known_hosts || fail "the pinned host key is missing"

              echo "✓ auto-upgrade: gates, notice, reboot policy, credential and outcome lines behave as specified"
              touch $out
            ''
          );
    };
}
