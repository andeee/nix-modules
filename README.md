# nix-modules

Public, shared NixOS / Home Manager module library. **No hosts, no users, no
secrets** — those live in the consumer repos (`private/nixos`, work repo).

## Contract for consumers

- Every input declared in this flake's `flake.nix` **must** be `follows`-ed by
  the consumer, otherwise a second, differently-pinned nixpkgs enters the
  consumer's closures.
- Modules register as `flake.modules.nixos.<name>` (via import-tree) and are
  exported as `nixosModules.<name>` / `homeManagerModules.<name>` by
  `modules/expose-modules.nix`.
- Relative paths must stay inside this repo — no `../../` references to
  consumer files.

## Modules worth knowing about

### `auto-upgrade` — converge on a git branch without a human

```nix
nixos.auto-upgrade;   # then:
autoUpgrade = {
  enable = true;
  repoUrl = "git+ssh://git@forge.example/owner/repo";
  window = "*-*-* 02:15:00";
  gate = "built-marker";                                  # or "substitutable"
  builtMarkerPath = "/var/lib/ci/last-built-rev";
  fetch = {
    identityFile = "/run/secrets/fetch-ssh-key";           # consumer renders this
    host = "forge.example";
    hostPublicKey = "ssh-ed25519 AAAA…";
  };
  exclusiveLock = "/var/lib/ci/ci.lock";                   # only where CI runs
  retention.generations = 10;
  reboot.window = "Sat *-*-* 02:55:00";
};
```

What the consumer has to provide, and why:

- **`repoUrl`/`fetch`** — the repository and a read-only credential. The module
  never declares a secret: `identityFile` is a *path*, rendered by the consumer's
  secret manager. It also does not configure a cache; pair it with
  `binary-cache-client`, otherwise the `substitutable` gate cannot answer.
- **`gate`** — what must be true about a revision before activation.
  `built-marker` reads a marker the CI job writes after building and publishing
  (`rev=<sha>`, `built=<iso>`, `hosts=<names>`), which costs one `git ls-remote`
  and no evaluation; `substitutable` runs `nix build --dry-run` instead, which is
  one host evaluation.
- **`exclusiveLock`** — set it only on a host that shares a machine with a CI
  runner, and have the runner hold that lock for a whole job. The preflight waits
  for it (then skips the window) and the activation holds it.
- **`window`/`reboot.window`** — policy, so they live in the consumer. Stagger
  them: the reboot window must differ from the upgrade window, and a host sharing
  a build machine wants a quiet hour.
- **`notify`** — announces the activation to every active graphical session and
  waits `leadSeconds`, which is what makes a noon window on a laptop survivable.
- **`retention`** — the cap is applied to the loader the host actually boots
  through (lanzaboote or systemd-boot) and `nix.gc` prunes generations, so a
  daily cadence cannot fill the ESP.
- **`protectInteractiveSession`** — keeps `greetd` from being restarted by an
  activation: `switch-to-configuration` has no display-manager exception, and a
  greeter restart takes the session hanging off it with it. Current nixpkgs already
  sets this on its own greetd unit, so the option is a guarantee from *this* module
  rather than from another module's implementation — plus coverage for a host
  whose greeter is not nixpkgs'.

The unit reports exactly one line per run (`activated:`, `skipped: … <reason>`,
`failed: …`, `reboot required (…)`), reads its run state from
`/run/nixos-upgrade`, and never reboots from the activation path.

### `binary-cache-client` — additional substituters, bounded failure

```nix
binaryCacheClient = {
  enable = true;
  caches = [ { url = "https://cache.example.org/ns"; publicKey = "ns-1:…"; } ];
};
```

Adds to `extra-substituters`/`extra-trusted-public-keys` (never replaces
`substituters`, so cache.nixos.org and caches other modules contribute stay), and
sets `connect-timeout = 5`, `fallback = true`, `download-attempts = 1` so an
unreachable cache — a VPN that blocks it, a machine off site — costs seconds
instead of stalling a build. These are *system* settings: a `nix build` run by a
systemd unit as root does not read flake `nixConfig`.

## Adding a module

1. Drop it in `modules/features/` (NixOS) — verbatim copy, no drive-by edits.
2. It must be free of: `sops`, personal usernames/paths, `inputs.*` (unless
   also added to `flake.nix`), and work/company specifics.
3. `nix flake show` to confirm it registers as a `NixOS module`.
