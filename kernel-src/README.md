# Base kernel-camera sources

These trees are `karsies-wq/sp11-imx681-linux` (commit `b08f76f`) with the
freeze-fix patches applied:

- `ccs/ccs-core.c`, `ccs.h` — DIGITAL_GAIN cached no-op for IMX681,
  mid-stream exposure/gain write throttle, entity-name override to
  `imx681` for DT compatible `sony,imx681`;
- `ccs/ccs-imx681-init.h` — stream-on digital gain pinned to ≈15.99×;
- `camss/camss.c` — supporting changes.

Build against the jglathe x1e80100 tree
(`https://github.com/jglathe/linux_ms_dev_kit`, branch
`jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` or newer):
copy these directories over the matching `drivers/media/...` subdirs, or
build out-of-tree. Modules land in `/lib/modules/$(uname -r)/updates/`.