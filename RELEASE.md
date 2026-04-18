# Release cadence

This fork's release lifecycle is bound to [`dev-brewery/photoframe`](https://github.com/dev-brewery/photoframe) releases. Every photoframe release gets a matching pi-gen tag at whatever `bookworm-photoframe` commit was used to build that release's image.

## Why tags at all

Before this policy, the photoframe CI checked out pi-gen at the `bookworm-photoframe` branch head. Builds floated on whatever was latest. That worked but left no way to answer "which pi-gen produced photoframe v3.0.0-rc1?" without digging through dates. Tags make the pairing explicit and immutable.

## Naming

Pi-gen tag name = photoframe tag name, exactly. `v3.0.0-rc1`, `v3.0.0-rc2`, `v3.0.0`, `v3.1.0-rc1`, `v3.0.1` — no pi-gen-specific version space.

## Per-release steps (pi-gen side)

For each photoframe release `vX.Y.Z[-rcN]`:

1. Land any build-tooling changes on `bookworm-photoframe` — new apt deps, Dockerfile tweaks, stage-script fixes, whatever this release requires.
2. Bump `config.example`:
   ```
   export PHOTOFRAME_BRANCH=<prev tag>   →   export PHOTOFRAME_BRANCH=<new tag>
   ```
   Commit message convention: `release: bump PHOTOFRAME_BRANCH to <tag>`.
3. Push `bookworm-photoframe`.
4. `git tag -a <tag> -m '<message>' bookworm-photoframe`
5. `git push origin <tag>`

The config bump + the tag happen in lockstep. A one-line config bump is cheap, happens every release even when nothing else changed, and makes manual builds reproducible:

```bash
git clone --branch vX.Y.Z https://github.com/dev-brewery/pi-gen.git
cd pi-gen
cp config.example config
./build-docker.sh
# builds photoframe vX.Y.Z with zero overrides
```

## Ordering with photoframe

**The pi-gen tag must exist before the photoframe tag is pushed.** Photoframe's `.github/workflows/build-image.yml` resolves `PI_GEN_REF` from `github.ref_name` on tag push, so it checks out pi-gen at the matching tag. If the pi-gen tag is missing, workflow checkout fails fast with a "ref not found" — this is the forcing function, not a bug.

## Off-cycle pi-gen fixes

Pi-gen fixes that don't coincide with a photoframe release just land on `bookworm-photoframe`. No tag. They come along with the next release naturally.

## Branches

- **`bookworm-photoframe`**: the active trunk. Default branch. All substantive work lives here.
- **`photoframe-legacy-2026-04`**: archived April 2026 snapshot kept for history/redirect. Do not commit here.

Legacy 2017–2018 Raspbian tags (`v1.1.1`, `v1.2.0`, Stretch/Jessie dates) are inherited fork history and unrelated to the current photoframe cadence.
