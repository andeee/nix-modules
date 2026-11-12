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

## Adding a module

1. Drop it in `modules/features/` (NixOS) — verbatim copy, no drive-by edits.
2. It must be free of: `sops`, personal usernames/paths, `inputs.*` (unless
   also added to `flake.nix`), and work/company specifics.
3. `nix flake show` to confirm it registers as a `NixOS module`.
