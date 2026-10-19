# Promoted to the build tree

The four bridge-FDB-offload patches that used to live here were promoted into
`target/linux/airoha/patches-6.18/` as `931-` .. `934-` once they had passed the
compile verification recorded in `BUILD-VERIFICATION.md`. From that point on they
are applied by every build of this tree (Actions included).

**The stage-1 path (untagged unicast bridged L2B) is now verified on hardware**
on the HG5382A with the 940 image: 300 non-IP frames promoted one `BND L2B`
entry, and a second 300-frame run was delivered 300/300 with `fdb_promoted`
unchanged. See `DEFECT-FIXES.md` Stage 8 for the measured entry and counters.

The limitations documented in `README.md` still apply to the parts not
exercised by that test: v1 only offloads untagged unicast FDB entries (so a
`vlan_filtering` bridge such as `pon0:t` + `lan1:u*` with VLAN 3114 is left
to the software bridge), flooding/multicast stay in software, the P-bit is not
programmed, and the 300 s bridge FDB ageing problem is only *measured* by 934,
not solved. PPPoE shares the same non-IP L2B path, but its end-to-end path over
fibre is not yet verified.
