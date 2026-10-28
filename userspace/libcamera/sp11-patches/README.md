# SP11 libcamera IPA patch set (+sp11.3)

Applied on Ubuntu's `libcamera 0.7.0-1ubuntu2` (quilt, in series order):

1. `sensor-helper-imx681.patch` — adds `CameraSensorHelperImx681` to
   `src/ipa/libipa/camera_sensor_helper.cpp`: CCS gain model
   `gain = 1024/(1024-code)` with a 16.0x ceiling at code 960,
   `gainCode` clamped 0..960, `blackLevel_ = 4096`. Numerically identical
   to the helper shipped in the Surface Pro 11's `ipa_soft_simple.so`.
2. `soft-ipa-context-dgain-fields.patch` — IPA context fields for the
   digital-gain extension.
3. `soft-ipa-dgain-extension.patch` — when the sensor exposes
   `V4L2_CID_DIGITAL_GAIN`, the AGC target gain may exceed the sensor's
   analogue ceiling (16x); the surplus goes to the digital path at
   write-back, and `AnalogueGain`/`DigitalGain` are reported separately
   in metadata. Reproduces the shipped IPA's "gain 1-255.938 (0.15)" and
   "Digital gain supported up to 15.9961x" behaviour. Stock behaviour is
   unchanged for sensors without that control.
4. `soft-ipa-agc-fast-convergence.patch` — the AGC ladder starts at
   maximum exposure / minimum gain (the sensor's exposure register comes
   up near its low end; the old 10%-per-cycle walk needed ~15 s after
   stream start to reach an indoor equilibrium) and steps by +40%/-30%
   per statistics cycle. Clamps and ladder order unchanged.

## Build

    # on the SP11 with the Ubuntu libcamera sources
    cp <patches> debian/patches/   # add to debian/patches/series in order
    dch -v 0.7.0-1ubuntu2+sp11.3   # or reuse changelog-sp11.3
    dpkg-buildpackage -us -uc -b -j4

Install ONLY the `libcamera-ipa` deb (the core library stays the
distro/shipped one). Note: the stock packaging does not ship
`/usr/share/libcamera/ipa/simple/imx681.yaml` — restore your tuning file
after upgrading the IPA deb (the deb replaces the package's file set).

Verify after install:

    sudo systemctl --user restart pipewire wireplumber
    sha256sum /usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_soft_simple.so
    # expect 71044542a7491d97ac07f2699be811536577e825226d2e028934ed72045f5af6
    # journal during the next stream:
    #   IPASoft: Digital gain supported up to 15.9961x (codes 256-4095)
    #   IPASoft: Exposure 1-3076, gain 1-255.938 (0.15)

This patch set was quorum-reviewed (5 blind auditors; per-claim 3-of-5;
two operational findings adopted: back up the libexec IPA-proxy workers
before install, and restart pipewire + hash-check after — journal lines
alone cannot discriminate old vs new IPA because both print identical
config lines).