# Config snapshots

Exact runtime configuration behind a tagged known-good build. To restore: check out the tag,
run `tools/install-macos.sh` on the Mac with the launchd env from the JSON (regions, log level),
rsync + build + copy on imac (see memory/README), and put the two config.toml files back.

- 20261109-1450 (tag `good-20261109-1450`): proportional entry, imac rectangle at physical size
  3008,0,2906,1647; Mac clients imac right+bottom; imac clients ms left+top. User: "爽，大斜线也直接过来了".
