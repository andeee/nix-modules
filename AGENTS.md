# AGENTS.md — nix-modules (public module library)

Shared NixOS / Home Manager **module library**. It deliberately contains **no
hosts, no users, no secrets** — those live in the consumer repos
(`private/nixos` for personal/fleet, a separate work repo for work machines).

## Working Agreement — Read First

Same rule as the personal fleet repo: AI agents must **not modify anything**
(files, memory, commits) **unless the owner explicitly asks for that specific
change** in the current request. Observation commands (`nix flake check`,
`nix flake show`, `nix eval …`) are always welcome; edits, `git add`,
commits, and pushes are not.

## Repository Structure

```
.
├── flake.nix              # inputs (pinned; consumers set `follows`) + mkFlake
├── modules/
│   ├── flake-parts.nix     # flake.modules registry bootstrap
│   ├── systems.nix         # x86_64-linux, aarch64-linux
│   ├── formatter.nix       # nixpkgs-fmt
│   ├── pre-commit.nix      # nixpkgs-fmt + deadnix + statix hooks + devShell
│   ├── expose-modules.nix  # exports flake.modules.* as nixosModules/homeManagerModules
│   └── features/           # NixOS feature modules (flake.modules.nixos.<name>)
└── README.md               # consumer contract
```

- `flake.nix` calls `inputs.import-tree ./modules` **as the argument to
  `mkFlake`** (not as an `imports` entry — that breaks import-tree).
- Feature modules register as `flake.modules.nixos.<name>`; consumers import
  them from `nixosModules.<name>` of this flake (or via an adapter that maps
  them back into their local `flake.modules.nixos` registry so host files keep
  reading `nixos.<name>`).

## Rules for What May Live Here

A module belongs in this repo only if it is free of:

- `sops` / any secret path or token
- personal usernames, `/home/<user>` paths, host names
- work/company specifics (domains, VPN endpoints, corporate CAs)
- relative paths escaping the repo (`../../` into a consumer repo, `packages/`,
  `system/`, `containers/`, `_shared/`)
- `pkgs.<custom-overlay>` unless the overlay is provided here

`inputs.*` is allowed only when the input is also declared in `flake.nix`.

**Consumers must `follows` every input declared here**, otherwise a second,
differently-pinned nixpkgs enters their closures. When adding an input here,
say so in the commit message.

## Build Commands

```bash
nix flake show          # verify modules register
nix flake check          # runs pre-commit over all files
nix fmt                  # nixpkgs-fmt
nix develop              # dev shell; installs the pre-commit hook via shellHook
nix develop --command pre-commit run --all-files
```

## Code Style

Same conventions as the fleet repo: 2-space indent, LF, UTF-8, no trailing
whitespace, final newline; kebab-case file names; `lib.getExe` /
`lib.getExe'` instead of hand-built store paths; camelCase variables;
kebab-case option names. Modules should be **options-first** (test-specific and
host-specific values go in options, never in `mkForce` overrides).

## Adding a Module

1. Copy the module in **verbatim** first — no drive-by reformatting or
   "improvements" in the same commit (keeps the consumer's
   `nix store diff-closures` proof clean).
2. Strip anything from the Rules list above.
3. `git add` it — flakes only see tracked files.
4. `nix flake show` → it must appear as a `NixOS module`.
5. `nix flake check` before committing (pre-commit runs on commit only when
   the hook is installed via `nix develop`/direnv).

## Consumers

The consumer repo pins this flake as an input (path/git URL) and sets
`follows` on all of its inputs. Module semantics must never depend on which
repo consumes them.
