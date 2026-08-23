# Seed for backglance/homebrew-tap

This directory is the initial content of the tap repository
[`backglance/homebrew-tap`](https://github.com/backglance/homebrew-tap), kept here so
`brew style` can gate the cask before the tap exists and so tap creation is a copy, not
an authoring step. Create the tap once, when release secrets are configured
([CI_CD.md](../../docs/deployment/CI_CD.md#cask-bumpyml--tap-pr-after-a-release)):

```bash
gh repo create backglance/homebrew-tap --public \
  --description "Homebrew tap for Backglance"
git clone https://github.com/backglance/homebrew-tap
mkdir -p homebrew-tap/Casks
sed '1,3d' Scripts/tap/Casks/backglance.rb > homebrew-tap/Casks/backglance.rb   # drop the seed header
cd homebrew-tap && git add Casks && git commit -m "backglance cask" && git push
```

**After that, the tap's copy is canonical.** Bumps happen there —
`cask-bump.yml` opens a PR against the tap on every release, and
`Scripts/bump_cask.sh <version>` is the same flow by hand. Nothing updates this seed,
and it does not need updating; its `version`/`sha256` are placeholders the first bump
rewrites. The cask's content is specified in
[PACKAGING_NOTARIZATION.md → Homebrew cask](../../docs/deployment/PACKAGING_NOTARIZATION.md#homebrew-cask);
change the spec and the tap together if the cask ever needs to change shape.
