_:
{
  # Unattended convergence on a git branch, gated on evidence about the revision.
  #
  # The change this module was extracted from had one guiding rule: a machine
  # that switches itself must never have to *build* what it switches to, and it
  # must never do so at a moment when nobody is watching. Everything below
  # follows from that:
  #
  #   * `gate` decides whether a revision may be activated at all — from a marker
  #     a CI job wrote (`built-marker`, costs one `git ls-remote`), from a
  #     substitutability probe (`substitutable`, costs one host evaluation), or
  #     not at all (`none`).
  #   * A gate that cannot be answered is a *skip*, not a failure: "the cache was
  #     unreachable" is a routine condition, and a nightly red unit is how a host
  #     gets ignored.
  #   * The activation path never reboots; a separate, lock-gated weekly window
  #     does that (`reboot`).
  #   * `exclusiveLock` lets a host share a machine with a CI runner: two fleet
  #     evaluations at once is how such a box ends up in swap.
  #   * `retention` is part of the module because a daily cadence against an
  #     uncapped boot loader is a slow, year-long disk bug.
  #
  # What stays in the consuming repository is policy: which hosts participate,
  # at what times, which repository, which cache, and which secret holds the
  # fetch key. This module knows none of those.
  flake.modules.nixos.auto-upgrade =
    { config, lib, options, pkgs, ... }:
    let
      cfg = config.autoUpgrade;

      # The toplevel attribute to probe in the `substitutable` gate. It matches
      # the hostname on the hosts this was written for; a mismatch is a preflight
      # failure (the attribute is simply absent), never a silent skip.
      hostAttr = config.networking.hostName;

      # Runtime decision state (tmpfs): the resolved revision, the skip/fail
      # markers and the dry-run transcript. Nothing survives a reboot — every
      # window re-decides. The one exception is `reboot-pending`, whose *absence*
      # after a reboot is exactly the point (the debt it recorded was paid).
      stateDir = "/run/nixos-upgrade";

      # `git ls-remote` rejects the `git+ssh://` scheme nix wants, so the same
      # repository is needed in the scp-like spelling. Derived from `repoUrl`
      # when possible (no port), overridable otherwise.
      derivedSshUrl =
        let
          m = builtins.match "git\\+ssh://([^/:]+)/(.*)" cfg.repoUrl;
        in
        if m != null then "${builtins.elemAt m 0}:${builtins.elemAt m 1}" else null;

      sshUrl = if cfg.sshUrl != null then cfg.sshUrl else derivedSshUrl;

      # Absolute paths: a systemd unit does not inherit a useful PATH, and
      # `lib.getExe*` keeps them correct when a package moves a binary.
      inherit (pkgs) coreutils;

      cut = lib.getExe' coreutils "cut";
      head = lib.getExe' coreutils "head";
      tail = lib.getExe' coreutils "tail";
      readlink = lib.getExe' coreutils "readlink";
      trueCmd = lib.getExe' coreutils "true";
      flock = lib.getExe' pkgs.util-linux "flock";
      wall = lib.getExe' pkgs.util-linux "wall";
      runuser = lib.getExe' pkgs.util-linux "runuser";
      git = lib.getExe pkgs.gitMinimal;
      nix = lib.getExe config.nix.package;
      grep = lib.getExe pkgs.gnugrep;
      sed = lib.getExe pkgs.gnused;
      loginctl = lib.getExe' config.systemd.package "loginctl";
      notifySend = lib.getExe pkgs.libnotify;

      # Whether an ssh failure resolving the ref needs a human. Prints `fatal`
      # (exit 1) for credentials, host key and missing repository, and
      # `transient` (exit 0) for everything else — DNS, timeouts, an unreachable
      # network. The default is `transient`: a machine on a train must not be an
      # incident, but a revoked deploy key must be visible in `systemctl --failed`.
      classifyRefError = pkgs.writeShellScriptBin "nixos-upgrade-classify" ''
        set -uo pipefail
        msg="''${1-}"
        case "$msg" in
          *"Permission denied"*|*"Host key verification failed"*|*"Repository not found"*|*"repository not found"*|*"Access denied"*|*"access denied"*|*"does not appear to be a git repository"*)
            echo fatal
            exit 1
            ;;
          *)
            echo transient
            exit 0
            ;;
        esac
      '';

      # Announce the imminent activation. A terminal message first (works on a
      # bare VT, needs no session), then every *active graphical* session through
      # its own bus. Root cannot simply call `notify-send`: it has no session, so
      # each session is addressed with its owner, its `XDG_RUNTIME_DIR` and its
      # bus socket. Silently no-ops when nobody is logged in.
      notifyUsers = pkgs.writeShellScriptBin "nixos-upgrade-notify" ''
        set -uo pipefail
        message="''${1:-Unattended upgrade}"

        printf '\n%s\n' "==> $message" | ${wall} 2>/dev/null || true

        while read -r id uid user _; do
          [ -n "''${id:-}" ] || continue
          type="$(${loginctl} show-session "$id" -p Type --value 2>/dev/null || true)"
          active="$(${loginctl} show-session "$id" -p Active --value 2>/dev/null || true)"
          [ "$active" = "yes" ] || continue
          case "$type" in
            x11|wayland|mir) ;;
            *) continue ;;
          esac
          runtime="/run/user/$uid"
          [ -S "$runtime/bus" ] || continue
          ${runuser} -u "$user" -- env \
            XDG_RUNTIME_DIR="$runtime" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" \
            ${notifySend} \
            --app-name=unattended-upgrade --urgency=normal --expire-time=120000 \
            "Unattended upgrade" "$message" || true
        done < <(${loginctl} list-sessions --no-legend 2>/dev/null || true)
      '';

      # The single place an outcome line is written, so a run can never produce
      # two of them. `writeShellScriptBin`, not `writeShellScript`: the latter's
      # output *is* the script, so `getExe` would point at a nonexistent `bin/`
      # directory and systemd would fail to spawn this silently — losing the one
      # line the whole design reports through.
      outcomeScript = pkgs.writeShellScriptBin "nixos-upgrade-outcome" ''
        rev="$(cat ${stateDir}/rev 2>/dev/null || echo unknown)"
        if [ -e ${stateDir}/skip ] || [ -e ${stateDir}/failed ]; then
          : # preflight already logged skipped:/failed: with a reason
        elif [ "$EXIT_STATUS" = 0 ]; then
          echo "nixos-upgrade: activated: rev=$rev"

          # A `switch` cannot change the kernel the machine is running: compare
          # what was booted with what is active now and record the debt. Reported,
          # never rebooted from here (see `reboot`).
          changed=""
          sep=""
          for part in kernel initrd; do
            booted="$(${readlink} -f /run/booted-system/$part 2>/dev/null || true)"
            active="$(${readlink} -f /run/current-system/$part 2>/dev/null || true)"
            if [ "$booted" != "$active" ]; then
              changed="$changed$sep$part"
              sep=","
            fi
          done
          if [ -n "$changed" ]; then
            {
              echo "rev=$rev"
              echo "changed:$changed"
            } > ${stateDir}/reboot-pending
            echo "nixos-upgrade: reboot required ($changed changed)"
          else
            rm -f ${stateDir}/reboot-pending
          fi
        else
          echo "nixos-upgrade: failed: rev=$rev activation exited $EXIT_STATUS"
        fi
      '';

      greetdEnabled = lib.attrByPath [ "services" "greetd" "enable" ] false config;
      lanzabooteEnabled = lib.attrByPath [ "boot" "lanzaboote" "enable" ] false config;
      systemdBootEnabled = lib.attrByPath [ "boot" "loader" "systemd-boot" "enable" ] false config;
    in
    {
      options.autoUpgrade = {
        enable = lib.mkEnableOption "unattended activation of a git branch";

        window = lib.mkOption {
          type = lib.types.str;
          default = "*-*-* 03:15:00";
          example = "*-*-* 12:15:00";
          description = ''
            `OnCalendar` expression for this host's upgrade window.

            Choose it deliberately: a host that shares a machine with a CI runner
            wants a quiet hour, a laptop wants an hour when it is powered on and
            nobody is working. Hosts are expected to stagger themselves — this
            module does not invent a random spread, because an operator needs to
            know when to look at which journal.
          '';
        };

        repoUrl = lib.mkOption {
          type = lib.types.str;
          example = "git+ssh://git@forge.example/owner/repo";
          description = ''
            Flake URL of the repository to follow, without a query string. The
            module appends `?ref=…` (or `?rev=…` for the gate).

            `git+ssh://` with a pinned host key and a read-only deploy key is the
            intended spelling: a token in a URL ends up in the store and in logs.
          '';
        };

        sshUrl = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "git@forge.example:owner/repo";
          description = ''
            The scp-like spelling of `repoUrl`, used by `git ls-remote`. Derived
            from `repoUrl` when that has no port; set it explicitly when it does.
          '';
        };

        ref = lib.mkOption {
          type = lib.types.str;
          default = "main";
          description = ''
            Branch to follow. Resolved fresh on every run (nix injects `--refresh`
            for any `flake`), so `main` really means "whatever is on main now" and
            not "whatever the lock said".
          '';
        };

        gate = lib.mkOption {
          type = lib.types.enum [
            "none"
            "substitutable"
            "built-marker"
          ];
          default = "substitutable";
          description = ''
            What must be true about a revision before it may be activated.

            - `built-marker`: a CI job wrote `builtMarkerPath` after building and
              publishing *that* revision. Cheapest (one `git ls-remote` and a
              string compare, no evaluation) and the strongest statement, but only
              available where the marker is readable — typically the host that
              runs the CI.
            - `substitutable`: `nix build --dry-run` shows the toplevel closure can
              be fetched. One extra host evaluation per run, and it fails open in
              the useful direction: an unreachable cache skips the window.
            - `none`: activate whatever the ref points at. Only sensible for a
              host that builds locally anyway.
          '';
        };

        builtMarkerPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/var/lib/ci/last-built-rev";
          description = ''
            File written by the CI job after a successful build+publish. Required
            for `gate = "built-marker"`.

            Format — one `key=value` per line, unknown keys ignored, written via a
            temporary file and a rename so a half-written marker can never be
            observed:

                rev=<commit>
                built=<iso-8601 timestamp>
                hosts=<space-separated host names>
          '';
        };

        fetch = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                identityFile = lib.mkOption {
                  type = lib.types.str;
                  example = "/run/secrets/fetch-ssh-key";
                  description = ''
                    Path to the private half of a dedicated, read-only,
                    repository-scoped deploy key. A *runtime* path: the consuming
                    repository renders it with its secret manager, this module only
                    references it.
                  '';
                };

                host = lib.mkOption {
                  type = lib.types.str;
                  example = "forge.example";
                  description = "Host alias the key is offered to.";
                };

                hostPublicKey = lib.mkOption {
                  type = lib.types.str;
                  example = "ssh-ed25519 AAAA…";
                  description = ''
                    The forge's pinned ssh host key. Verification stays ON; this is
                    a pin, not a substitute for it. Take the fingerprint from an
                    out-of-band source.
                  '';
                };

                knownHostsName = lib.mkOption {
                  type = lib.types.str;
                  default = "auto-upgrade-fetch";
                  description = "Attribute name used for the `programs.ssh.knownHosts` entry.";
                };
              };
            }
          );
          default = null;
          description = ''
            Fetch credential. Null for a repository that needs none (public over
            https); set it for anything private.

            Two things matter and are easy to get wrong: `IdentitiesOnly`, so
            root's other keys are never offered to the forge, and offering the key
            to exactly one host alias, so it also applies to the two URL spellings
            (`git+ssh://git@host/…` for nix, `git@host:…` for `git ls-remote`).
          '';
        };

        exclusiveLock = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "/var/lib/ci/ci.lock";
          description = ''
            An `flock(1)` file this run must share with whatever else uses the
            machine — typically a CI runner.

            Why a lock and not a unit dependency: a runner daemon is *active*
            whether or not a job is running, so `systemctl is-active` cannot
            express "a build is in progress", while a job that takes an exclusive
            flock for its whole duration can. Two touch points, two reasons: the
            preflight waits for the lock before evaluating (concurrent evaluations
            are what starves a small box), and the activation holds it (a switch
            that restarts a cache daemon mid-push turns a green job red).
          '';
        };

        waitTimeoutSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 900;
          description = ''
            How long to wait for `exclusiveLock` before giving up on the window.
            Expiring is not a failure: the run skips and the next window tries
            again, which is the right trade on a daily cadence. (A weekly cadence
            would argue for waiting longer.)
          '';
        };

        notify = {
          enable = lib.mkEnableOption "announcing the activation to logged-in users" // {
            default = false;
          };

          leadSeconds = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 120;
            description = ''
              How long to wait between the notice and the activation, so the
              notice cannot arrive after the service restarts it is warning about.
              The run only reaches this point once the gate has approved the
              revision, so a skipped window never notifies anybody.
            '';
          };
        };

        protectInteractiveSession = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Keep an unattended activation from restarting the graphical greeter.

            `switch-to-configuration` restarts any unit whose content changed, and
            a greeter restart takes the session hanging off it down with it —
            losing a work session is a worse failure than a greeter change waiting
            for the next login.

            Current nixpkgs already sets `restartIfChanged = false` on its greetd
            unit, so on a stock greeter this option changes nothing (verified
            2026-11-20: a laptop activation that replaced the entire greetd unit
            left the session running, `NRestarts = 0`). It stays because the
            guarantee should come from *this* module — an unattended activation
            must not depend on another module's implementation detail — and because
            it covers a host whose greeter is not nixpkgs' own.

            Network and audio services are deliberately *not* protected: their
            restarts are survivable, and a machine that never restarts
            infrastructure silently runs stale configuration for months.
          '';
        };

        retention = {
          enable = lib.mkEnableOption "bounding generations and store growth" // {
            default = true;
          };

          generations = lib.mkOption {
            type = lib.types.ints.positive;
            default = 10;
            description = ''
              Bootable generations to keep. Applied to whichever loader the host
              actually uses (`boot.lanzaboote.configurationLimit` when lanzaboote
              is enabled, otherwise `boot.loader.systemd-boot.configurationLimit`)
              — setting the wrong one is a silent no-op, which is exactly the bug
              a daily cadence turns into a full boot partition.
            '';
          };

          gcDates = lib.mkOption {
            type = lib.types.str;
            default = "*-*-* 04:30:00";
            description = "`OnCalendar` expression for `nix.gc`.";
          };

          gcOptions = lib.mkOption {
            type = lib.types.str;
            default = "--delete-older-than 14d";
            description = ''
              Options for `nix-collect-garbage`. Note this deletes *generations*
              older than the given age, not only unreferenced store paths — that
              is what actually reclaims space when activations happen daily.
            '';
          };
        };

        # The script derivations rendered into the units, exposed (internally)
        # so a check can execute them. A string-scraped store path would look
        # identical in the unit but would not make the check depend on it, so the
        # file would simply be missing inside the build sandbox.
        _helpers = lib.mkOption {
          type = lib.types.attrsOf lib.types.package;
          internal = true;
          readOnly = true;
          default = {
            classify = classifyRefError;
            notify = notifyUsers;
            outcome = outcomeScript;
          };
          description = "Script derivations used by the units (for checks).";
        };

        reboot = {
          window = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "Sat *-*-* 02:55:00";
            description = ''
              Weekly window in which this host may reboot itself, or null to never
              reboot. Never part of the activation path: an unattended reboot of a
              host that serves something is how a configuration bug becomes an
              unreachable machine. Place it after the host's own upgrade window so
              a kernel from that window is running promptly.

              The window must differ from `window`; a reboot and a switch racing
              each other is not a configuration anybody wants to debug.
            '';
          };

          onlyWhenPending = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Reboot only when the last activation left kernel/initrd debt. Set to
              false for "bounded uptime": the host reboots on its weekly window
              whatever is pending.
            '';
          };
        };
      };

      config = lib.mkIf cfg.enable (lib.mkMerge [
        {
          assertions = [
            {
              assertion = cfg.repoUrl != "";
              message = "autoUpgrade.repoUrl must be set.";
            }
            {
              assertion = sshUrl != null;
              message = ''
                autoUpgrade.sshUrl could not be derived from repoUrl (a port in the URL
                has no scp-like spelling). Set autoUpgrade.sshUrl explicitly.
              '';
            }
            {
              assertion = cfg.gate != "built-marker" || cfg.builtMarkerPath != null;
              message = "autoUpgrade.gate = \"built-marker\" requires autoUpgrade.builtMarkerPath.";
            }
            {
              assertion = cfg.reboot.window == null || cfg.reboot.window != cfg.window;
              message = "autoUpgrade.reboot.window must differ from autoUpgrade.window.";
            }
          ];

          # Upstream adds `--refresh` (and the flake) itself whenever `flake` is set,
          # so `system.autoUpgrade.flags` must not repeat it: `flags` is a list
          # option and would concatenate into a duplicate argument.
          system.autoUpgrade = {
            enable = true;
            flake = "${cfg.repoUrl}?ref=${cfg.ref}";
            operation = "switch";
            # Reboot debt is reported (`reboot-pending`), never acted on here.
            allowReboot = false;
            # A window missed while the host was down runs once it returns. On a
            # laptop that means "shortly after the next resume", which is why the
            # consuming side may want `notify` enabled.
            persistent = true;
            dates = cfg.window;
          };

          # The ref is resolved over ssh and the credential is rendered at boot, so
          # neither a network race nor a not-yet-decrypted secret may be part of the
          # run.
          systemd.services.nixos-upgrade = {
            after = [
              "network-online.target"
            ]
            ++ lib.optional (cfg.fetch != null) "sops-nix.service";
            wants = [ "network-online.target" ]
              ++ lib.optional (cfg.fetch != null) "sops-nix.service";

            preStart = ''
              set -uo pipefail

              state=${stateDir}
              mkdir -p "$state"
              rm -f "$state/skip" "$state/failed" "$state/rev" "$state/preflight.log" "$state/lsremote.out"

              ${lib.optionalString (cfg.exclusiveLock != null) ''
                # Probe the lock and *wait* for it before evaluating: a CI job and a
                # host evaluation running at once is what starves a small box. Only
                # probed here — a file descriptor cannot be handed from preStart to
                # the activation, which takes the lock again below.
                lock=${cfg.exclusiveLock}
                if ! ${flock} -n "$lock" ${trueCmd}; then
                  echo "nixos-upgrade: $lock is held, waiting up to ${toString cfg.waitTimeoutSeconds}s"
                  waited=0
                  held=1
                  while [ "$held" = 1 ]; do
                    if ${flock} -n "$lock" ${trueCmd}; then held=0; break; fi
                    if [ "$waited" -ge ${toString cfg.waitTimeoutSeconds} ]; then break; fi
                    sleep 10
                    waited=$((waited + 10))
                  done
                  if [ "$held" = 1 ]; then
                    echo "nixos-upgrade: skipped: $lock still held after ${toString cfg.waitTimeoutSeconds}s"
                    touch "$state/skip"
                    exit 0
                  fi
                  echo "nixos-upgrade: $lock came free after $waited seconds, continuing"
                fi
              ''}

              # Resolve the branch without evaluating anything: one ls-remote, so
              # the logged revision is exactly what this run decided on even if the
              # ref moves during the upgrade itself.
              # `git` exits 128 on every transport or authentication failure, and
              # NixOS wraps this script in `set -e`: without the `|| status=$?` the
              # shell aborts right here and the classification below never runs, so
              # every cause would look the same (or produce no line at all).
              status=0
              ${git} ls-remote ${sshUrl} "refs/heads/${cfg.ref}" > "$state/lsremote.out" 2> "$state/lsremote.err" || status=$?
              rev="$(${head} -n 1 "$state/lsremote.out" | ${cut} -f1)"

              if [ "$status" -ne 0 ] || [ -z "$rev" ]; then
                reason="$(${tail} -n 1 "$state/lsremote.err" 2>/dev/null || true)"
                reason="''${reason:-unknown error}"

                # Credential and repository problems are a human's business (a
                # rotated deploy key must show up); a unreachable network is not.
                if ! class="$(${lib.getExe classifyRefError} "$reason")"; then
                  echo "nixos-upgrade: failed: rev=unknown cannot resolve refs/heads/${cfg.ref}: $reason"
                  touch "$state/failed"
                  exit 1
                fi
                echo "nixos-upgrade: skipped: cannot resolve refs/heads/${cfg.ref}: $reason"
                touch "$state/skip"
                exit 0
              fi
              echo "$rev" > "$state/rev"

              ${lib.optionalString (cfg.gate == "built-marker") ''
                marker=${lib.escapeShellArg (toString cfg.builtMarkerPath)}
                if [ ! -r "$marker" ]; then
                  echo "nixos-upgrade: skipped: rev=$rev no built marker at $marker"
                  touch "$state/skip"
                  exit 0
                fi

                builtRev="$(${sed} -n 's/^rev=//p' "$marker" | ${head} -n 1)"
                builtHosts="$(${sed} -n 's/^hosts=//p' "$marker" | ${head} -n 1)"

                if [ -z "$builtRev" ]; then
                  echo "nixos-upgrade: skipped: rev=$rev built marker at $marker is not parseable"
                  touch "$state/skip"
                  exit 0
                fi

                # A host added to the flake is not built until CI has seen it; the
                # marker says which hosts a run actually covered.
                case " $builtHosts " in
                  *" ${hostAttr} "* ) ;;
                  *)
                    echo "nixos-upgrade: skipped: rev=$rev marker does not list ${hostAttr} (hosts: ''${builtHosts:-none})"
                    touch "$state/skip"
                    exit 0
                    ;;
                esac

                if [ "$builtRev" != "$rev" ]; then
                  echo "nixos-upgrade: skipped: rev=$rev not built yet (marker says $builtRev)"
                  touch "$state/skip"
                  exit 0
                fi
              ''}

              ${lib.optionalString (cfg.gate == "substitutable") ''
                # Pinned to the revision just resolved, so the probe and the logged
                # outcome describe the same tree. Ask nix whether the toplevel's
                # *closure* can be fetched: `--dry-run` is the only cheap way to
                # answer that for a whole closure (a toplevel can be cached while a
                # dependency is not).
                target="${cfg.repoUrl}?rev=$rev#nixosConfigurations.${hostAttr}.config.system.build.toplevel"

                if ! ${nix} build --dry-run --no-link "$target" > "$state/preflight.log" 2>&1; then
                  echo "nixos-upgrade: skipped: rev=$rev preflight could not be answered ($(${tail} -n 1 "$state/preflight.log"))"
                  touch "$state/skip"
                  exit 0
                fi

                # Nix announces both halves of the answer on stderr: what it can
                # fetch and what it would have to build. Any build means the window
                # is not free.
                if ${grep} -qE 'these [0-9]+ derivations? will be built' "$state/preflight.log"; then
                  echo "nixos-upgrade: skipped: rev=$rev not fully substitutable ($(${grep} -oE 'these [0-9]+ derivations? will be built' "$state/preflight.log" | ${head} -n 1))"
                  touch "$state/skip"
                  exit 0
                fi
              ''}
            '';

            # Prepended (not appended) to the upstream script: a skipped window must
            # not reach `nixos-rebuild` at all, and the notice must come before it.
            script = lib.mkBefore ''
              if [ -e ${stateDir}/skip ]; then
                echo "nixos-upgrade: preflight skipped this window, not upgrading"
                exit 0
              fi

              ${lib.optionalString (cfg.exclusiveLock != null) ''
                # Held on fd 9 for the rest of the run, i.e. inherited by the
                # `nixos-rebuild switch` this script ends with. `9>>` rather than
                # `9>` so it cannot truncate a lock file another process has open.
                exec 9>>${cfg.exclusiveLock}
                ${flock} -w ${toString cfg.waitTimeoutSeconds} 9 ||
                  echo "nixos-upgrade: lock still held after ${toString cfg.waitTimeoutSeconds}s, activating anyway"
              ''}

              ${lib.optionalString cfg.notify.enable ''
                rev="$(cat ${stateDir}/rev 2>/dev/null || echo unknown)"
                echo "nixos-upgrade: notifying logged-in users, activating rev=$rev in ${toString cfg.notify.leadSeconds}s"
                ${lib.getExe notifyUsers} "System upgrade in ${toString cfg.notify.leadSeconds}s (rev ''${rev:0:7}). Services whose configuration changed will restart." || true
                sleep ${toString cfg.notify.leadSeconds}
              ''}
            '';

            # Runs on success and on failure (systemd's ExecStopPost, which NixOS
            # exposes through serviceConfig), and is the only writer of the outcome
            # line.
            serviceConfig.ExecStopPost = lib.getExe outcomeScript;
          };

          programs.ssh = lib.mkIf (cfg.fetch != null) {
            # Offered to exactly one alias, explicitly; `IdentitiesOnly` keeps
            # root's other keys from being offered instead.
            extraConfig = ''
              Host ${cfg.fetch.host}
                IdentityFile ${cfg.fetch.identityFile}
                IdentitiesOnly yes
            '';

            knownHosts.${cfg.fetch.knownHostsName} = {
              hostNames = [ cfg.fetch.host ];
              publicKey = cfg.fetch.hostPublicKey;
            };
          };

          nix.gc = lib.mkIf cfg.retention.enable {
            automatic = true;
            dates = cfg.retention.gcDates;
            options = cfg.retention.gcOptions;
          };

        }

        # The cap has to land on the loader the host actually boots through. On a
        # lanzaboote host the systemd-boot option is inert (usually force-disabled
        # by the lanzaboote module), so writing only that one would silently leave
        # the cap unset — the exact silent no-op a daily cadence turns into a full
        # boot partition.
        #
        # Guarded by `options ?` rather than `mkIf`: a definition for an option that
        # does not exist is a hard evaluation error even when its condition is
        # false, so a consumer without the lanzaboote module would fail to evaluate
        # rather than skip the assignment.
        (lib.optionalAttrs (options ? boot.loader.systemd-boot) {
          boot.loader.systemd-boot.configurationLimit = lib.mkIf
            (
              cfg.retention.enable && !lanzabooteEnabled && systemdBootEnabled
            )
            cfg.retention.generations;
        })

        (lib.optionalAttrs (options ? boot.lanzaboote) {
          boot.lanzaboote.configurationLimit = lib.mkIf (cfg.retention.enable && lanzabooteEnabled)
            cfg.retention.generations;
        })

        # Same reasoning for the greeter: only touch it when the platform has one.
        # `mkIf` alone is not enough twice over — it would both error on a missing
        # option and create an empty greetd unit on a host that has no greeter.
        (lib.optionalAttrs (options ? services.greetd) {
          systemd.services.greetd = lib.mkIf (cfg.protectInteractiveSession && greetdEnabled) {
            restartIfChanged = false;
          };
        })

        {
          systemd.services.nixos-upgrade-reboot = lib.mkIf (cfg.reboot.window != null) {
            description = "Reboot for a pending kernel/initrd change (unattended)";
            after = [ "network-online.target" ];

            script = ''
              set -uo pipefail
              state=${stateDir}
              pending=""
              if [ -e "$state/reboot-pending" ]; then
                pending="$(cat "$state/reboot-pending")"
              fi

              ${lib.optionalString cfg.reboot.onlyWhenPending ''
                if [ -z "$pending" ]; then
                  echo "nixos-upgrade-reboot: skipped: no pending kernel/initrd change"
                  exit 0
                fi
              ''}

              # Never reboot through a CI job: the lock is what a running build
              # holds for its whole duration.
              ${lib.optionalString (cfg.exclusiveLock != null) ''
                lock=${cfg.exclusiveLock}
                if ! ${flock} -n "$lock" ${trueCmd}; then
                  echo "nixos-upgrade-reboot: skipped: $lock is held by a CI job"
                  exit 0
                fi
              ''}

              # An activation in flight owns the machine until it is done.
              if ${lib.getExe' config.systemd.package "systemctl"} is-active --quiet nixos-upgrade.service; then
                echo "nixos-upgrade-reboot: skipped: nixos-upgrade.service is running"
                exit 0
              fi

              # The line goes out *before* the reboot: the unit is torn down by the
              # reboot itself, so a post-stop hook would lose the only evidence
              # that this was intentional.
              echo "nixos-upgrade-reboot: rebooting (''${pending:-no pending change, weekly window})"
              ${lib.getExe' config.systemd.package "systemctl"} reboot
            '';

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = false;
            };
          };

          systemd.timers.nixos-upgrade-reboot = lib.mkIf (cfg.reboot.window != null) {
            description = "Weekly window for a pending reboot";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnCalendar = cfg.reboot.window;
              Persistent = true;
            };
          };
        }
      ]);
    };
}
